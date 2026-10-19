// Opt-in: invoked by Django's LiveServerTestCase with an isolated PostgreSQL DB.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_life/agent/agent_api.dart';
import 'package:sync_life/mocap/user_session.dart';

class LoseReceipt extends http.BaseClient {
  final _inner = http.Client();
  bool lost = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (!lost &&
        request.url.path.endsWith('/chat/') &&
        response.statusCode == 200) {
      lost = true;
      await response.stream.drain<void>();
      throw http.ClientException('Synthetic lost receipt after commit');
    }
    return response;
  }

  @override
  void close() => _inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final base = Platform.environment['SYNC_LIFE_TEST_AGENT_API'];
  if (base != null) HttpOverrides.global = null;
  test(
      'Flutter HTTP -> owned conversations, remembered context, confirmed plan and lost receipt',
      () async {
    SharedPreferences.setMockInitialValues({});
    final session = UserSession.forTesting();
    await session.signIn(
        int.parse(Platform.environment['SYNC_LIFE_TEST_USER']!),
        Platform.environment['SYNC_LIFE_TEST_TOKEN']!,
        'isolated-test');
    final transport = LoseReceipt();
    final api = AgentApi(session: session, client: transport, baseUrl: base);
    try {
      await api
          .saveMemory({'category': 'diet', 'key': '饮食偏好', 'value': '偏好素食'});
      final conversation = await api.createConversation();
      final id = conversation['id'] as String;
      final requestId = newRequestId();
      await expectLater(api.chat(id, '测试口令 TEST-CONTEXT', requestId: requestId),
          throwsA(isA<AgentException>()));
      final retry =
          await api.chat(id, '测试口令 TEST-CONTEXT', requestId: requestId);
      expect(retry['response'], '已收到测试问题');
      final next = await api.chat(id, '刚才的口令是什么', requestId: newRequestId());
      expect(next['response'], contains('TEST-CONTEXT'));
      final draft = await api.chat(id, '制定训练计划',
          requestId: newRequestId(), kind: 'training_plan');
      final payload = draft['payload'] as Map;
      final saved = await api.savePlan(
          Map<String, dynamic>.from(payload['plan'] as Map),
          sourceMessageId: (draft['assistant_message'] as Map)['id'] as int);
      expect(saved['revision'], 1);
      expect((await api.plans())['plans'], hasLength(1));
      expect((await api.messages(id))['messages'], hasLength(6));
      final list = (await api.conversations())['conversations'] as List;
      expect(list, hasLength(1));
      expect(list.toString(), isNot(contains('other-owner-secret')));
    } finally {
      api.close();
      session.dispose();
    }
  },
      skip: base == null
          ? 'Run through Django AgentHttpTests with isolated test DB'
          : false);
}
