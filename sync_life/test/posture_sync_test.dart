import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_life/mocap/posture_recording.dart';
import 'package:sync_life/mocap/posture_sync.dart';
import 'package:sync_life/mocap/user_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late MotionOutbox outbox;
  late UserSession session;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    session = UserSession.forTesting();
    await session.signIn(1, 'token-one', 'test-one');
    directory = await Directory.systemTemp.createTemp('sync-life-sync-test-');
    outbox = MotionOutbox(File('${directory.path}/outbox.json'));
    await outbox.append({
      'user_id': 1,
      'event': {'segment_id': 'one'}
    });
  });
  tearDown(() async {
    session.dispose();
    await directory.delete(recursive: true);
  });

  test(
      'failed request retains stable UUID; successful retry deletes only acknowledged records',
      () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.headers['Authorization'], 'Bearer token-one');
      final data = jsonDecode(request.body);
      expect(data['user_id'], 1);
      expect(data['events'].single['segment_id'], 'one');
      // Data must already be durable when network transmission starts.
      final restored = MotionOutbox(outbox.file);
      await restored.load();
      expect(restored.countForUser(1), 1);
      if (requests == 1) throw const SocketException('Response lost');
      return http.Response('{"accepted":["one","foreign"]}', 200);
    });
    final sync = PostureSyncService.forTesting(
        session: session,
        client: client,
        outbox: outbox,
        deviceId: newMotionId());
    addTearDown(sync.dispose);
    await sync.flush();
    expect(outbox.countForUser(1), 1);
    await sync.retry();
    expect(outbox.countForUser(1), 0);
    expect(sync.uploadedSegments, 1);
  });

  test(
      '401 clears the expired session but preserves records for the original owner',
      () async {
    final sync = PostureSyncService.forTesting(
        session: session,
        client: MockClient((_) async => http.Response('{}', 401)),
        outbox: outbox,
        deviceId: newMotionId());
    addTearDown(sync.dispose);
    await sync.flush();
    expect(session.authenticated, isFalse);
    expect(outbox.countForUser(1), 1);
  });

  test(
      'account change during an HTTP response never sends old records under new credentials',
      () async {
    await outbox.append({
      'user_id': 2,
      'event': {'segment_id': 'two'}
    });
    final oldResponse = Completer<http.Response>();
    final newRequest = Completer<void>();
    final client = MockClient((request) async {
      final owner = jsonDecode(request.body)['user_id'];
      if (owner == 1) return oldResponse.future;
      expect(request.headers['Authorization'], 'Bearer token-two');
      expect(jsonDecode(request.body)['events'].single['segment_id'], 'two');
      if (!newRequest.isCompleted) newRequest.complete();
      return http.Response('{"accepted":["two"]}', 200);
    });
    final sync = PostureSyncService.forTesting(
        session: session,
        client: client,
        outbox: outbox,
        deviceId: newMotionId());
    addTearDown(sync.dispose);
    final upload = sync.flush();
    await session.signIn(2, 'token-two', 'test-two');
    oldResponse.complete(http.Response('{}', 409));
    await upload;
    await newRequest.future.timeout(const Duration(seconds: 2));
    // Wait for the disk acknowledgement, without disposing an in-flight uploader.
    for (var i = 0; i < 100 && outbox.countForUser(2) != 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(outbox.countForUser(1), 1);
    expect(outbox.countForUser(2), 0);
    expect(sync.error, isNull);
  });

  test(
      'partial acknowledgement preserves the remainder and 4xx stops automatic retries',
      () async {
    await outbox.append({
      'user_id': 1,
      'event': {'segment_id': 'two'}
    });
    var requests = 0;
    final sync = PostureSyncService.forTesting(
        session: session,
        client: MockClient((_) async {
          requests++;
          return requests == 1
              ? http.Response('{"accepted":["one"]}', 200)
              : http.Response('{}', 400);
        }),
        outbox: outbox,
        deviceId: newMotionId());
    addTearDown(sync.dispose);
    await sync.flush();
    expect(outbox.forUser(1).single['event']['segment_id'], 'two');
    await sync.flush();
    await sync.flush();
    expect(requests, 2);
    expect(outbox.countForUser(1), 1);
  });
}
