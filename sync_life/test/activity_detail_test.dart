import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_life/ui/activity_timeline.dart';
import 'package:sync_life/ui/app_theme.dart';
import 'package:sync_life/ui/motion_calendar.dart';

void main() {
  testWidgets(
      'overview is bounded and loads five-minute subtypes only after a tap',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!),
        home: Scaffold(
            body: ListView(children: [
          ActivityTimeline(
              date: DateTime(2026, 10, 17),
              slots: List.generate(
                  12,
                  (i) => {
                        'start_minute': i * 120,
                        'end_minute': (i + 1) * 120,
                        'observed_seconds': i == 5 ? 90.0 : 0.0,
                        'states': i == 5
                            ? [
                                {
                                  'name': '慢走',
                                  'color': '#80B5A0',
                                  'seconds': 90
                                }
                              ]
                            : []
                      }),
              loadWindow: (day, start) async {
                loads++;
                expect(start, 600);
                return {
                  'buckets': [
                    {
                      'start_minute': 600,
                      'end_minute': 605,
                      'states': [
                        {'name': '慢走', 'color': '#80B5A0', 'seconds': 60},
                        {'name': '慢跑', 'color': '#CA9867', 'seconds': 30}
                      ]
                    }
                  ]
                };
              })
        ]))));
    await tester.pumpAndSettle();
    expect(loads, 0);
    expect(find.byType(InkWell), findsNWidgets(12));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('activity-slot-600')), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('activity-slot-600')));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(find.text('10:00–10:05'), findsOneWidget);
    expect(find.textContaining('慢走 1 分钟 · 慢跑 不足 1 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'planned future days can open without pretending to have observations',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      DateTime? selected;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ListView(children: [
        MotionCalendar(
            today: DateTime(2026, 10, 17),
            loadMonth: (_) async => {
                  'days': [
                    {
                      'date': '2026-10-18',
                      'has_records': false,
                      'training_status': 'planned'
                    },
                    {
                      'date': '2026-10-16',
                      'has_records': false,
                      'training_status': 'overdue'
                    },
                    {
                      'date': '2026-10-15',
                      'has_records': true,
                      'training_status': 'completed'
                    },
                  ]
                },
            onOpenDay: (date) async {
              selected = date;
            })
      ]))));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('2026年10月18日，待完成')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('motion-day-2026-10-18')));
      await tester.pumpAndSettle();
      expect(selected, DateTime(2026, 10, 18));
      final unplanned = tester
          .widget<InkWell>(find.byKey(const ValueKey('motion-day-2026-10-19')));
      expect(unplanned.onTap, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });
}
