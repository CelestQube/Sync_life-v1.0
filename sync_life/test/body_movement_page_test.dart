import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_life/pages/body_movement_page.dart';
import 'package:sync_life/ui/app_theme.dart';

Map<String, dynamic> data(String range) => {
      'user_id': 1,
      'observed_seconds': range == 'day' ? 0 : 120,
      'unknown_seconds': 0,
      'steps': 0,
      'active_time': 0,
      'posture_angles': [],
      'posture_distribution': [
        for (final label in ['站立', '坐立', '卧躺', '行走', '奔跑', '无法判断'])
          {'name': label, 'color': '#2196F3', 'value': 0, 'hours': '0.00h'},
      ],
      'postures': range == 'day'
          ? []
          : [
              for (var i = 1; i <= (range == 'week' ? 7 : 30); i++)
                {
                  'date': '09-${i.toString().padLeft(2, '0')}',
                  'sitting': '0',
                  'standing': '0',
                  'walking': '0',
                  'running': '0',
                  'lying': '0',
                  'unknown': '0'
                },
            ],
      'activity_trend': [
        for (var i = 0; i < (range == 'month' ? 30 : 8); i++)
          {'label': '09/$i', 'steps': 0}
      ],
    };

Map<String, dynamic> monthData(DateTime month) => {
      'user_id': 1,
      'month': '${month.year}-${month.month.toString().padLeft(2, '0')}',
      'today': DateTime.now().toIso8601String().substring(0, 10),
      'days': [
        for (var day = 1;
            day <= DateTime(month.year, month.month + 1, 0).day;
            day++)
          {
            'date': DateTime(month.year, month.month, day)
                .toIso8601String()
                .substring(0, 10),
            'has_records': day == 1,
            'observed_seconds': day == 1 ? 120 : 0
          },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
      'calendar opens the selected historic day and keeps its real timeline',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    DateTime? requested;
    final observed = data('day')
      ..['observed_seconds'] = 120
      ..['activity_slots'] = [
        {
          'start_minute': 600,
          'end_minute': 720,
          'observed_seconds': 120,
          'states': [
            {'name': '行走', 'seconds': 120, 'color': '#4CAF50'}
          ]
        }
      ];
    observed['posture_distribution'][3]['value'] = 100;
    observed['posture_distribution'][3]['seconds'] = 120;
    observed['posture_distribution'][3]['hours'] = '0.03h';
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: BodyMovementPage(
            loadStatistics: (range) async => data(range),
            loadCalendar: (month) async => monthData(month),
            loadDay: (day) async {
              requested = day;
              return observed;
            })));
    await tester.pumpAndSettle();
    final day = DateTime(DateTime.now().year, DateTime.now().month);
    final key = 'motion-day-${day.toIso8601String().substring(0, 10)}';
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(ListView).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    expect(requested, day);
    expect(find.text('每天的活动'), findsNothing);
    await tester.scrollUntilVisible(find.text('10:00–12:00'), 180,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('记录 2 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('活动日历'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'empty today still allows calendar history and has no empty charts',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: BodyMovementPage(
            loadStatistics: (range) async => data(range),
            loadCalendar: (month) async => monthData(month),
            loadDay: (_) async => data('day'))));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无衣物动作记录'), findsOneWidget);
    expect(find.text('活动分布'), findsNothing);
    expect(tester.getSize(find.byType(EmptyStateCard)), isNotNull);
    expect(tester.getSize(find.byType(EmptyStateCard)).height, lessThan(230));
    await tester.tap(find.text('近 30 天'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('活动日历'), 180,
        scrollable: find.byType(Scrollable).first);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'overview and calendar remain scrollable with large text on a small phone',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!),
        home: BodyMovementPage(
            loadStatistics: (range) async => data(range),
            loadCalendar: (month) async => monthData(month))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('活动日历'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.textContaining('点击查看活动与训练，长按查看日期'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
