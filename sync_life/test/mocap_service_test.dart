import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_life/mocap/imu_protocol.dart';
import 'package:sync_life/mocap/mocap_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('sync_life/mocap');
  const events = MethodChannel('sync_life/mocap_events');
  const codec = StandardMethodCodec();
  final fixture =
      jsonDecode(File('test/fixtures/mocap_reference.json').readAsStringSync())
          as Map<String, dynamic>;

  testWidgets(
      'disconnect invalidates calibration and discards an in-flight inference',
      (tester) async {
    final service = MocapService.forTesting();
    var disposed = false;
    Completer<Float32List>? pending;
    var inferenceCalls = 0, emitted = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'permissions') return true;
      if (call.method == 'infer') {
        inferenceCalls++;
        expectSync((call.arguments as Map)['input'], hasLength(120));
        return pending?.future ?? Float32List(72);
      }
      return null;
    });
    service.initialize();
    final subscription = service.poses.listen((_) => emitted++);
    addTearDown(() async {
      if (!disposed) service.dispose();
      subscription.cancel();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    await tester.pump();
    Future<void> event(Map<String, Object> value) async {
      await messenger.handlePlatformMessage(
          'sync_life/mocap_events', codec.encodeSuccessEnvelope(value), (_) {});
      await tester.pump();
    }

    Future<void> packets() async {
      for (final role in GarmentRole.values) {
        await event({
          'type': 'packet',
          'role': role.name,
          'data': base64Decode(fixture[role == GarmentRole.upper
              ? 'upperReference'
              : 'lowerReference'] as String)
        });
      }
    }

    for (final role in GarmentRole.values) {
      await event({'type': 'connection', 'role': role.name, 'state': 'ready'});
    }
    expect(service.bothReady, isTrue);
    final calibration = service.calibrate();
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      await packets();
      await tester.pump(const Duration(milliseconds: 33));
    }
    await calibration;
    expect(service.calibrated, isTrue,
        reason: '${service.status}; ${service.error}');
    expect(inferenceCalls, greaterThan(0));
    pending = Completer<Float32List>();
    final before = emitted;
    await packets();
    await tester.pump(const Duration(milliseconds: 33));
    await event(
        {'type': 'connection', 'role': 'upper', 'state': 'disconnected'});
    expect(service.calibrated, isFalse);
    pending.complete(Float32List(72));
    await tester.pump();
    expect(emitted, before);
    final count = inferenceCalls;
    await tester.pump(const Duration(milliseconds: 200));
    expect(inferenceCalls, count);
    service.dispose();
    disposed = true;
    subscription.cancel();
    await tester.pump();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
      'recalibration drops old inference, waits three seconds and restarts only one capture',
      (tester) async {
    final service = MocapService.forTesting();
    final messenger = tester.binding.defaultBinaryMessenger;
    var inferenceCalls = 0, resets = 0, emitted = 0;
    var disposed = false;
    Completer<Float32List>? pending;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'reset') resets++;
      if (call.method == 'infer') {
        inferenceCalls++;
        return pending?.future ?? Float32List(72);
      }
      return null;
    });
    service.initialize();
    final subscription = service.poses.listen((_) => emitted++);
    addTearDown(() {
      if (!disposed) service.dispose();
      subscription.cancel();
      messenger.setMockMethodCallHandler(events, null);
      messenger.setMockMethodCallHandler(methods, null);
    });
    await tester.pump();
    Future<void> event(Map<String, Object> value) async {
      await messenger.handlePlatformMessage(
          'sync_life/mocap_events', codec.encodeSuccessEnvelope(value), (_) {});
      await tester.pump();
    }

    Future<void> packets() async {
      for (final role in GarmentRole.values) {
        await event({
          'type': 'packet',
          'role': role.name,
          'data': base64Decode(fixture[role == GarmentRole.upper
              ? 'upperReference'
              : 'lowerReference'] as String)
        });
      }
    }

    for (final role in GarmentRole.values) {
      await event({'type': 'connection', 'role': role.name, 'state': 'ready'});
    }
    final first = service.calibrate();
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      await packets();
      await tester.pump(const Duration(milliseconds: 33));
    }
    await first;
    expect(service.calibrated, isTrue);
    pending = Completer<Float32List>();
    await packets();
    await tester.pump(const Duration(milliseconds: 33));
    final before = emitted, callsBefore = inferenceCalls;
    final restart = service.recalibrate();
    await tester.pump();
    expect(service.calibrated, isFalse);
    expect(service.calibrating, isTrue);
    expect(service.calibrationSeconds, 3);
    expect(resets, 2);
    await service.recalibrate();
    expect(resets, 2,
        reason: 'Rapid repeated taps must not start another calibration');
    pending.complete(Float32List(72));
    pending = null;
    await tester.pump();
    for (var i = 0; i < 80; i++) {
      await packets();
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(service.calibrating, isTrue);
    expect(emitted, before);
    expect(inferenceCalls, callsBefore);
    for (var i = 0; i < 20; i++) {
      await packets();
      await tester.pump(const Duration(milliseconds: 33));
    }
    await restart;
    expect(service.calibrated, isTrue,
        reason: '${service.status}; ${service.error}');
    expect(inferenceCalls, greaterThan(callsBefore));
    expect(emitted, greaterThan(before));
    final interrupted = service.recalibrate();
    await tester.pump();
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 3));
    await interrupted;
    expect(service.calibrated, isFalse);
    expect(service.status, contains('已暂停'));
    expect(tester.takeException(), isNull);
    service.dispose();
    disposed = true;
    subscription.cancel();
    await tester.pump();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}
