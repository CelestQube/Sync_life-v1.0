// Opt-in only: a Django LiveServerTestCase supplies its isolated PostgreSQL test DB.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_life/mocap/posture_recording.dart';
import 'package:sync_life/mocap/posture_sync.dart';
import 'package:sync_life/mocap/user_session.dart';

class _LoseFirstReceipt extends http.BaseClient {
  final _inner = http.Client();
  bool lost = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (!lost && response.statusCode == 200) {
      lost = true;
      await response.stream.drain<void>();
      throw const SocketException(
          'Synthetic test: receipt lost after server commit');
    }
    return response;
  }

  @override
  void close() => _inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = Platform.environment['SYNC_LIFE_TEST_API'];
  if (api != null) HttpOverrides.global = null;
  test(
      'Dart outbox -> real Django HTTP -> PostgreSQL -> statistics, including lost receipt',
      () async {
    SharedPreferences.setMockInitialValues({});
    final owner = int.parse(Platform.environment['SYNC_LIFE_TEST_USER']!);
    final token = Platform.environment['SYNC_LIFE_TEST_TOKEN']!;
    final session = UserSession.forTesting();
    await session.signIn(owner, token, 'isolated-test');
    final directory =
        await Directory.systemTemp.createTemp('sync-life-http-test-');
    final outbox = MotionOutbox(File('${directory.path}/outbox.json'));
    final fixture = jsonDecode(
        File('../server/Sync/posture/fixtures/phone_motion_synthetic.json')
            .readAsStringSync());
    final events = fixture['events'] as List;
    final base = DateTime.parse(events.first['start_time']);
    final shift = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 20))
        .difference(base);
    for (final raw in events) {
      final event = Map<String, dynamic>.from(raw as Map);
      for (final key in ['start_time', 'end_time']) {
        event[key] =
            DateTime.parse(event[key]).add(shift).toUtc().toIso8601String();
      }
      await outbox.append({'user_id': owner, 'event': event});
    }
    final transport = _LoseFirstReceipt();
    final sync = PostureSyncService.forTesting(
        session: session,
        client: transport,
        outbox: outbox,
        deviceId: newMotionId(),
        endpoint: '$api/motion/events/');
    try {
      await sync.flush();
      expect(transport.lost, isTrue);
      expect(outbox.countForUser(owner), events.length);
      await sync.retry();
      expect(outbox.countForUser(owner), 0);
      expect(sync.uploadedSegments, events.length);
      final response = await http.post(Uri.parse('$api/body-movement/'),
          headers: session.headers,
          body: jsonEncode({'user_id': owner, 'time_range': 'month'}));
      expect(response.statusCode, 200);
      final stats = jsonDecode(response.body);
      expect(stats['user_id'], owner);
      expect(stats['observed_seconds'], greaterThan(25));
      for (final state in ['LIE', 'STAND', 'SIT', 'WALK', 'RUN', 'UNKNOWN']) {
        expect(stats['state_durations_seconds'][state], greaterThan(0));
      }
      expect(stats['steps'], greaterThan(0));
    } finally {
      sync.dispose();
      session.dispose();
      await directory.delete(recursive: true);
    }
  },
      skip: api == null
          ? 'Run via Django HttpMotionTests to use an isolated test database'
          : false);
}
