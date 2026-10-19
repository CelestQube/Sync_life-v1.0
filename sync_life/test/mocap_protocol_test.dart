import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_life/mocap/imu_protocol.dart';

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/mocap_reference.json').readAsStringSync())
          as Map<String, dynamic>;
  Uint8List packet(String name) => base64Decode(fixture[name] as String);
  ImuFrame frame(String name, GarmentRole role) =>
      ImuPacketDecoder().add(packet(name), role).single;

  test('packed BNO085 packets and model selection match Python 6+5 receiver',
      () {
    final upper = frame('upperReference', GarmentRole.upper);
    final lower = frame('lowerReference', GarmentRole.lower);
    expect(upper.timestamp, 1234);
    expect(upper.samples.length, 6);
    expect(lower.samples.length, 5);
    final selected = selectModelSensors(upper, lower);
    expect(
        selected.map((s) => s.acceleration[0]),
        orderedEquals([5.2, 1.2, 4.2, .2, 3.2, 4.2, 1.2, 3.2, .2, 2.2]
            .map((v) => closeTo(v, 1e-6))));
  });

  test(
      'static calibration agrees with original PyTorch methods to float32 precision',
      () {
    final calibration = MocapCalibration(selectModelSensors(
        frame('upperReference', GarmentRole.upper),
        frame('lowerReference', GarmentRole.lower)));
    final input = calibration.transform(selectModelSensors(
        frame('upperCurrent', GarmentRole.upper),
        frame('lowerCurrent', GarmentRole.lower)));
    final expected = (fixture['expectedInput'] as List).cast<num>();
    expect(input.length, 120);
    for (var i = 0; i < input.length; i++) {
      expect(input[i], closeTo(expected[i].toDouble(), 2e-6),
          reason: 'input[$i]');
    }
  });

  test('decoder handles fragmented and coalesced notifications and stray bytes',
      () {
    final bytes = packet('upperReference');
    final decoder = ImuPacketDecoder();
    expect(
        decoder.add(
            Uint8List.fromList([10, 20, ...bytes.take(19)]), GarmentRole.upper),
        isEmpty);
    final result = decoder.add(
        Uint8List.fromList([...bytes.skip(19), ...bytes]), GarmentRole.upper);
    expect(result.length, 2);
    expect(result.first.samples.last.quaternion,
        orderedEquals(result.last.samples.last.quaternion));
  });

  test('invalid sensor values are rejected and following valid packet recovers',
      () {
    final invalid = Uint8List.fromList(packet('upperReference'));
    ByteData.sublistView(invalid).setFloat32(8 + 6, double.nan, Endian.little);
    final decoder = ImuPacketDecoder();
    final result = decoder.add(
        Uint8List.fromList([...invalid, ...packet('upperReference')]),
        GarmentRole.upper);
    expect(result.length, 1);
    expect(decoder.rejectedPackets, greaterThan(0));
  });

  test('opposite quaternion signs do not cancel during T-pose averaging', () {
    final original = frame('upperReference', GarmentRole.upper);
    final opposite = ImuFrame(
        1235,
        original.samples
            .map((s) =>
                ImuSample(s.acceleration, s.quaternion.map((v) => -v).toList()))
            .toList());
    final average = averageFrames([original, opposite]);
    for (var i = 0; i < average.length; i++) {
      for (var j = 0; j < 9; j++) {
        expect(average[i].rotation[j],
            closeTo(original.samples[i].rotation[j], 1e-6));
      }
    }
  });
}
