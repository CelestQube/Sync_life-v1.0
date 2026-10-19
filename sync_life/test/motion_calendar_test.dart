import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_life/mocap/motion_statistics.dart';
import 'package:sync_life/ui/app_theme.dart';
import 'package:sync_life/ui/motion_calendar.dart';
import 'package:sync_life/pages/daily_activity_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('short observed segments keep a nonzero duration in the day view',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: DailyActivityPage(
            date: DateTime(2026, 10, 17),
            loadDay: (_) async => {
                  'observed_seconds': .4,
                  'steps': 0,
                  'posture_distribution': [
                    {'name': '无法判断', 'seconds': .4}
                  ],
                  'postures': [
                    {
                      'type': '无法判断',
                      'time': '10:00:00–10:00:00',
                      'duration': '0.0分钟',
                      'duration_seconds': .4
                    }
                  ]
                })));
    await tester.pumpAndSettle();
    expect(find.text('0.0分钟'), findsNothing);
    expect(find.textContaining('不足 1 分钟'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'retained days, deletion refresh, long press dates and month navigation',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.binding.setSurfaceSize(const Size(360, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var retained = true;
      final requestedMonths = <String>[];
      DateTime? selected;
      await tester.pumpWidget(MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
              body: ListView(children: [
            MotionCalendar(
                today: DateTime(2026, 10, 17),
                loadMonth: (month) async {
                  requestedMonths.add(motionDateKey(month));
                  return {
                    'today': '2026-10-17',
                    'days': [
                      {
                        'date': '2026-10-01',
                        'has_records': retained,
                        'observed_seconds': retained ? 120 : 0
                      },
                    ]
                  };
                },
                onOpenDay: (day) async => selected = day),
          ]))));
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('motion-day-2026-10-01'));
      expect(find.bySemanticsLabel(RegExp('2026年10月1日，有活动记录')), findsOneWidget);
      await tester.longPress(first);
      await tester.pump();
      expect(find.text('2026年10月1日'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(selected, DateTime(2026, 10, 1));
      retained = false;
      await tester.tap(find.byTooltip('刷新日历'));
      await tester.pumpAndSettle();
      expect(
          find.bySemanticsLabel(RegExp('2026年10月1日，暂无记录或已删除')), findsOneWidget);
      await tester.tap(find.byTooltip('上个月'));
      await tester.pumpAndSettle();
      expect(requestedMonths.last, '2026-09-01');
      await tester.tap(find.byTooltip('下个月'));
      await tester.pumpAndSettle();
      expect(requestedMonths.last, '2026-10-01');
      final future = tester
          .widget<InkWell>(find.byKey(const ValueKey('motion-day-2026-10-18')));
      expect(future.onTap, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });
  testWidgets(
      'a day without retained observations never shows invented activity',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: DailyActivityPage(
            date: DateTime(2026, 10, 1),
            loadDay: (_) async => {'observed_seconds': 0, 'postures': []})));
    await tester.pumpAndSettle();
    expect(find.text('当天暂无活动记录'), findsOneWidget);
    expect(find.text('活动时间线'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
