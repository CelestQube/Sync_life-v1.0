import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_life/agent/agent_api.dart';
import 'package:sync_life/mocap/user_session.dart';
import 'package:sync_life/pages/personal_knowledge_page.dart';
import 'package:sync_life/pages/training_plan_page.dart';

class KnowledgeApi extends AgentApi {
  KnowledgeApi(UserSession session) : super(session: session);
  final facts = <Map<String, dynamic>>[];
  final record = <String, dynamic>{
    'id': 'old-plan',
    'revision': 1,
    'document': {
      'summary': '历史计划仍应保留',
      'plan': [
        {
          'date': '2020-01-01',
          'diet': '历史饮食记录',
          'rest': '休息安排',
          'exercises': <dynamic>[]
        }
      ]
    }
  };
  @override
  Future<Map<String, dynamic>> memories() async => {'memories': facts};
  @override
  Future<Map<String, dynamic>> saveMemory(Map<String, dynamic> data,
      {String? id}) async {
    final value = {
      ...data,
      'id': id ?? 'fact-1',
      'revision': 1,
      'expired': false
    };
    facts.add(value);
    return value;
  }

  @override
  Future<Map<String, dynamic>> plans({int offset = 0}) async => {
        'plans': [record],
        'has_more': false
      };
  @override
  Future<Map<String, dynamic>> getPlan(String id) async => record;
}

void main() {
  late KnowledgeApi api;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final session = UserSession.forTesting();
    await session.signIn(1, 'test-token', 'test-user');
    api = KnowledgeApi(session);
  });
  tearDown(() => api.close());
  testWidgets('personal facts are saved only after explicit confirmation',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: PersonalKnowledgePage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加资料'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '饮食偏好');
    await tester.enterText(find.byType(TextField).at(1), '偏好素食');
    expect(api.facts, isEmpty);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(api.facts, hasLength(1));
    expect(find.textContaining('偏好素食'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'past training plans and diet remain visible and available in history',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: TrainingPlanPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('2020-01-01'), findsOneWidget);
    expect(find.text('饮食：历史饮食记录'), findsOneWidget);
    await tester.tap(find.byTooltip('历史计划'));
    await tester.pumpAndSettle();
    expect(find.text('历史训练计划'), findsOneWidget);
    expect(find.textContaining('2020-01-01 起'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
