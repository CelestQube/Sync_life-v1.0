import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_life/mocap/drift_correction.dart';
import 'package:sync_life/mocap/imu_protocol.dart';

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/mocap_enhancements.json').readAsStringSync()) as Map;
  final drift = fixture['drift'] as Map;
  final history = Float32List.fromList(
      (drift['history'] as List).map((x) => (x as num).toDouble()).toList());
  test('TIC requires 256 frames and enough motion in at least three sensors',
      () {
    final correction = DriftCorrection();
    final time = DateTime.utc(2026);
    for (var i = 0; i < 255; i++) {
      correction.add(history.sublist(i * 120, (i + 1) * 120));
    }
    expect(correction.request(time), isNull);
    correction.add(history.sublist(255 * 120));
    final request = correction.request(time)!;
    expect(request.history, orderedEquals(history));
    expect(request.trigger, everyElement(true));
    correction.applied();
    expect(correction.request(time.add(const Duration(seconds: 2))), isNull);
    correction.reset();
    for (var i = 0; i < 256; i++) {
      correction.add(history.sublist(0, 120));
    }
    expect(correction.request(time), isNull);
    correction.reset();
    for (var i = 0; i < 256; i++) {
      final frame = history.sublist(0, 120);
      frame.setRange(30, 48, history.sublist(i * 120 + 30, i * 120 + 48));
      correction.add(frame);
    }
    expect(correction.request(time), isNull);
  });
  test(
      'drift multiplication, transpose and root-heading regularization match Python',
      () {
    final raw = jsonDecode(
        File('test/fixtures/mocap_reference.json').readAsStringSync()) as Map;
    ImuFrame frame(String name, GarmentRole role) =>
        ImuPacketDecoder().add(base64Decode(raw[name] as String), role).single;
    final calibration = MocapCalibration(selectModelSensors(
        frame('upperReference', GarmentRole.upper),
        frame('lowerReference', GarmentRole.lower)));
    final samples = selectModelSensors(frame('upperCurrent', GarmentRole.upper),
        frame('lowerCurrent', GarmentRole.lower));
    final before = calibration.transform(samples);
    calibration.applyDrift(
        Float32List.fromList((drift['prediction'] as List)
            .map((x) => (x as num).toDouble())
            .toList()),
        List.filled(10, true));
    final after = calibration.transform(samples);
    final global =
        (drift['global'] as List).map((x) => (x as num).toDouble()).toList();
    final local =
        (drift['local'] as List).map((x) => (x as num).toDouble()).toList();
    for (var i = 0; i < 10; i++) {
      final expectedAcc = rotate3(
          global.sublist(i * 9, i * 9 + 9), before.sublist(i * 3, i * 3 + 3));
      final expectedRotation = multiply3(
          multiply3(global.sublist(i * 9, i * 9 + 9),
              before.sublist(30 + i * 9, 39 + i * 9)),
          local.sublist(i * 9, i * 9 + 9));
      for (var j = 0; j < 3; j++) {
        expect(after[i * 3 + j], closeTo(expectedAcc[j], 1e-5));
      }
      for (var j = 0; j < 9; j++) {
        expect(after[30 + i * 9 + j], closeTo(expectedRotation[j], 1e-5));
      }
    }
  });
}
