import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_life/agent/agent_api.dart';
import 'package:sync_life/agent/pending_chat_store.dart';
import 'package:sync_life/mocap/user_session.dart';
import 'package:sync_life/utils/training_plan_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late UserSession session;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    session = UserSession.forTesting();
    await session.signIn(1, 'test-token-1', 'test-user');
  });

  test(
      'chat sends a stable request ID and Bearer token without trusting a client owner field',
      () async {
    final requestId = newRequestId();
    final api = AgentApi(
        session: session,
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer test-token-1');
          final body = jsonDecode(request.body) as Map;
          expect(body['request_id'], requestId);
          expect(body.containsKey('user_id'), false);
          expect(request.url.path, '/api/agent/chat/');
          return http.Response.bytes(
              utf8.encode(jsonEncode({'response': 'ok'})), 200);
        }));
    addTearDown(api.close);
    expect(
        (await api.chat('conversation', '你好',
            requestId: requestId))['response'],
        'ok');
  });

  test('in-flight response is rejected after switching accounts', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final api = AgentApi(
        session: session,
        client: MockClient((_) {
          started.complete();
          return response.future;
        }));
    addTearDown(api.close);
    final pending = api.memories();
    await started.future;
    final expected = expectLater(
        pending,
        throwsA(isA<AgentException>()
            .having((error) => error.code, 'code', 'session_changed')));
    await session.signIn(2, 'test-token-2', 'other');
    response.complete(http.Response('{"memories":[{"value":"private"}]}', 200));
    await expected;
  });

  test(
      'pending requests survive page recreation and are isolated by account and API origin',
      () async {
    final api = AgentApi(session: session, baseUrl: 'http://localhost/a');
    final otherOrigin =
        AgentApi(session: session, baseUrl: 'http://localhost/b');
    addTearDown(api.close);
    addTearDown(otherOrigin.close);
    await PendingChatStore(api)
        .put('c', {'message': '尚未确认', 'request_id': 'same-id'});
    expect((await PendingChatStore(api).load('c'))?['request_id'], 'same-id');
    expect(await PendingChatStore(otherOrigin).load('c'), isNull);
    await session.signIn(2, 'test-token-2', 'other');
    expect(await PendingChatStore(api).load('c'), isNull);
    await session.signIn(1, 'test-token-1', 'test-user');
    await PendingChatStore(api).remove('c');
    expect(await PendingChatStore(api).load('c'), isNull);
  });

  test(
      'cloud plans retain revision, use only the correct offline cache, and do not resurrect deleted data',
      () async {
    var online = true, empty = false, deleted = false;
    final record = {
      'id': 'saved-plan',
      'revision': 3,
      'document': {'summary': '账号一的计划', 'plan': <dynamic>[]}
    };
    final api = AgentApi(
        session: session,
        client: MockClient((request) async {
          if (!online) {
            return http.Response.bytes(utf8.encode('{"error":"暂时断网"}'), 503);
          }
          if (deleted) {
            return http.Response.bytes(utf8.encode('{"error":"已删除"}'), 404);
          }
          if (request.method == 'PATCH') {
            expect(request.url.path.endsWith('/plans/saved-plan/'), true);
            expect((jsonDecode(request.body) as Map)['revision'], 3);
            return http.Response.bytes(
                utf8.encode(jsonEncode({...record, 'revision': 4})), 200);
          }
          return http.Response.bytes(
              utf8.encode(jsonEncode({
                'plans': empty ? [] : [record]
              })),
              200);
        }));
    addTearDown(api.close);
    final repository = PlanRepository(api);
    final loaded = (await repository.load())!;
    expect(loaded['_revision'], 3);
    expect((await repository.save(loaded))['_revision'], 4);
    online = false;
    expect((await repository.load())?['_offline'], true);
    await session.signIn(2, 'test-token-2', 'other');
    await expectLater(repository.load(), throwsA(isA<AgentException>()));
    await session.signIn(1, 'test-token-1', 'test-user');
    online = true;
    deleted = true;
    await expectLater(
        repository.load(id: 'saved-plan'),
        throwsA(isA<AgentException>()
            .having((error) => error.status, 'status', 404)));
    deleted = false;
    empty = true;
    expect(await repository.load(), isNull);
    online = false;
    await expectLater(repository.load(), throwsA(isA<AgentException>()));
  });
}
