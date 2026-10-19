import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_life/agent/agent_api.dart';
import 'package:sync_life/mocap/user_session.dart';
import 'package:sync_life/pages/smart_agent_page.dart';
import 'package:sync_life/ui/app_theme.dart';

class FakeAgentApi extends AgentApi {
  FakeAgentApi(UserSession session) : super(session: session);
  final rows = <String, List<Map<String, dynamic>>>{
    'one': [
      {
        'id': 1,
        'role': 'user',
        'content': '第一窗口独有内容',
        'request_id': 'old',
        'kind': 'chat',
        'status': 'complete',
        'payload': <String, dynamic>{}
      }
    ],
    'two': [
      {
        'id': 2,
        'role': 'user',
        'content': '第二窗口独有内容',
        'request_id': 'old-2',
        'kind': 'chat',
        'status': 'complete',
        'payload': <String, dynamic>{}
      }
    ],
  };
  final submitted = <String>[];
  final requests = <Map<String, dynamic>>[];
  bool failOnce = false;
  bool placesConfigured = false;
  bool locationHandshake = false;
  bool clarifyFood = false;
  Map<String, dynamic> conversation(String id) => {
        'id': id,
        'title': id == 'one' ? '第一段对话' : '第二段对话',
        'archived': false,
        'updated_at': '2026-10-08T12:00:00+08:00',
        'busy': false
      };
  @override
  Future<Map<String, dynamic>> status() async {
    return {'configured': true, 'places_configured': placesConfigured};
  }

  @override
  Future<Map<String, dynamic>> conversations(
      {bool archived = false, int offset = 0}) async {
    return {
      'conversations': [conversation('one'), conversation('two')],
      'has_more': false
    };
  }

  @override
  Future<Map<String, dynamic>> getConversation(String id) async =>
      conversation(id);
  @override
  Future<Map<String, dynamic>> createConversation() async =>
      conversation('two');
  @override
  Future<Map<String, dynamic>> messages(String id, {int? before}) async {
    return {
      'messages': rows[id] ?? [],
      'conversation': conversation(id),
      'digests': [],
      'has_more': false,
      'next_before': null
    };
  }

  @override
  Future<Map<String, dynamic>> chat(String conversationId, String message,
      {required String requestId,
      String kind = 'auto',
      double? latitude,
      double? longitude}) async {
    submitted.add(requestId);
    requests.add({
      'message': message,
      'request_id': requestId,
      'kind': kind,
      'latitude': latitude,
      'longitude': longitude
    });
    if (failOnce) {
      failOnce = false;
      throw const AgentException('测试断网');
    }
    final user = {
      'id': 3,
      'request_id': requestId,
      'role': 'user',
      'content': message,
      'kind': kind,
      'status': 'complete',
      'payload': <String, dynamic>{}
    };
    if (locationHandshake && latitude == null) {
      user['status'] = 'failed';
      rows[conversationId] = [
        ...rows[conversationId]!.where((row) => row['request_id'] != requestId),
        user
      ];
      return {'location_required': true, 'user_message': user};
    }
    final assistant = {
      'id': 4,
      'request_id': requestId,
      'role': 'assistant',
      'content': clarifyFood ? '先告诉我想吃什么，再查附近餐馆。' : '收到本窗口的问题',
      'kind': kind,
      'status': 'complete',
      'payload': <String, dynamic>{}
    };
    rows[conversationId] = [
      ...rows[conversationId]!.where((row) => row['request_id'] != requestId),
      user,
      assistant
    ];
    return {
      'user_message': user,
      'assistant_message': assistant,
      'response': '收到本窗口的问题'
    };
  }
}

void main() {
  late FakeAgentApi api;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final session = UserSession.forTesting();
    await session.signIn(1, 'test-token', 'test-user');
    api = FakeAgentApi(session);
  });
  tearDown(() => api.close());
  testWidgets(
      'typed food queries obtain location only after server asks, preserving one request ID',
      (tester) async {
    api.placesConfigured = true;
    api.locationHandshake = true;
    var locations = 0;
    await tester.pumpWidget(MaterialApp(
        home: SmartAgentPage(
            api: api,
            restaurantLocation: () async {
              locations++;
              return {'latitude': 31.2, 'longitude': 121.5};
            })));
    await tester.pumpAndSettle();
    expect(locations, 0);
    await tester.enterText(find.byType(TextField), '帮我找附近的越南河粉');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(locations, 1);
    expect(api.requests, hasLength(2));
    expect(api.requests.first['latitude'], isNull);
    expect(api.requests.last['latitude'], 31.2);
    expect(api.submitted.first, api.submitted.last);
    expect(find.text('帮我找附近的越南河粉'), findsOneWidget);
    expect(find.text('收到本窗口的问题'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'nearby button asks about current recommendations and never defaults to salad',
      (tester) async {
    api.placesConfigured = true;
    api.clarifyFood = true;
    var locations = 0;
    await tester.pumpWidget(MaterialApp(
        home: SmartAgentPage(
            api: api,
            restaurantLocation: () async {
              locations++;
              return {'latitude': 31.2, 'longitude': 121.5};
            })));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('附近餐馆'));
    await tester.tap(find.text('附近餐馆'));
    await tester.pumpAndSettle();
    expect(api.requests.single['kind'], 'restaurant_recommend');
    expect(api.requests.single['message'], '查找你刚才推荐食物的附近餐馆');
    expect(api.requests.single['latitude'], isNull);
    expect(locations, 0);
    expect(find.text('先告诉我想吃什么，再查附近餐馆。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'location denial stays retryable and can later complete without changing the user message',
      (tester) async {
    api.placesConfigured = true;
    api.locationHandshake = true;
    var denied = true;
    await tester.pumpWidget(MaterialApp(
        home: SmartAgentPage(
            api: api,
            restaurantLocation: () async {
              if (denied) throw const AgentException('测试定位未授权');
              return {'latitude': 31.2, 'longitude': 121.5};
            })));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '找附近的牛肉面');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(api.requests, hasLength(1));
    expect(find.text('重试这条消息'), findsOneWidget);
    denied = false;
    await tester.tap(find.text('重试这条消息'));
    await tester.pumpAndSettle();
    expect(api.requests, hasLength(3));
    expect(api.submitted.toSet(), hasLength(1));
    expect(find.text('找附近的牛肉面'), findsOneWidget);
    expect(find.text('收到本窗口的问题'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a location completed after signing out is not transmitted',
      (tester) async {
    api.placesConfigured = true;
    api.locationHandshake = true;
    final location = Completer<Map<String, double>>();
    await tester.pumpWidget(MaterialApp(
        home: SmartAgentPage(
            api: api, restaurantLocation: () => location.future)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '找附近寿司店');
    await tester.tap(find.byTooltip('发送'));
    // The busy indicator intentionally animates while the location future is pending.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(api.requests, hasLength(1));
    await api.session.signOut();
    location.complete({'latitude': 31.2, 'longitude': 121.5});
    await tester.pumpAndSettle();
    expect(api.requests, hasLength(1));
    expect(find.text('去登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'navigation hints are drafts and reopening never sends a model request',
      (tester) async {
    Future<void> open() async {
      await tester.pumpWidget(MaterialApp(
          theme: buildAppTheme(),
          home: SmartAgentPage(api: api, initialMessage: '请生成本月活动月报')));
      await tester.pumpAndSettle();
    }

    await open();
    expect(api.submitted, isEmpty);
    expect(find.text('今天想要小律怎么帮助你？'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '请生成本月活动月报');
    await tester.pumpWidget(const SizedBox());
    await open();
    expect(api.submitted, isEmpty);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(api.submitted, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
        MaterialApp(theme: buildAppTheme(), home: SmartAgentPage(api: api)));
    await tester.pumpAndSettle();
    expect(api.submitted, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'chat can send with large text and an open keyboard on a small phone',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
                viewInsets: const EdgeInsets.only(bottom: 260)),
            child: child!),
        home: SmartAgentPage(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '今天适合散步吗');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(api.submitted, hasLength(1));
    expect(find.text('收到本窗口的问题'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'narrow phone can switch conversation windows without mixing messages',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: SmartAgentPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('第一窗口独有内容'), findsOneWidget);
    await tester.tap(find.byTooltip('对话列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二段对话'));
    await tester.pumpAndSettle();
    expect(find.text('第二窗口独有内容'), findsOneWidget);
    expect(find.text('第一窗口独有内容'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'offline submission remains retryable with the same ID and succeeds once',
      (tester) async {
    api.failOnce = true;
    await tester.pumpWidget(MaterialApp(home: SmartAgentPage(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '离线后再试');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('离线后再试'), findsOneWidget);
    expect(find.text('重试这条消息'), findsOneWidget);
    await tester.tap(find.text('重试这条消息'));
    await tester.pumpAndSettle();
    expect(api.submitted.length, 2);
    expect(api.submitted.first, api.submitted.last);
    expect(find.text('收到本窗口的问题'), findsOneWidget);
    expect(find.text('离线后再试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('leaving and reopening restores an unacknowledged message',
      (tester) async {
    api.failOnce = true;
    await tester.pumpWidget(MaterialApp(home: SmartAgentPage(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '仍未确认的消息');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: SmartAgentPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('仍未确认的消息'), findsOneWidget);
    expect(find.text('重试这条消息'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'unacknowledged requests cannot be overwritten and can be discarded',
      (tester) async {
    api.failOnce = true;
    await tester.pumpWidget(MaterialApp(home: SmartAgentPage(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '未确认的旧请求');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新的请求');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(api.submitted, hasLength(1));
    await tester.tap(find.byTooltip('消息操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃本次重试'));
    await tester.pumpAndSettle();
    expect(find.text('未确认的旧请求'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(api.submitted, hasLength(2));
    expect(api.submitted.first, isNot(api.submitted.last));
    expect(find.text('收到本窗口的问题'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('signing out removes the previous owner messages from view',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: SmartAgentPage(api: api)));
    await tester.pumpAndSettle();
    await api.session.signOut();
    await tester.pumpAndSettle();
    expect(find.text('第一窗口独有内容'), findsNothing);
    expect(find.text('去登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
