import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_life/main.dart';

class _CapturePage extends StatefulWidget {
  const _CapturePage(this.onCreate, this.onDispose);
  final VoidCallback onCreate, onDispose;
  @override
  State<_CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<_CapturePage> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Center(child: Text('同一轮动捕'));
}

void main() {
  testWidgets(
      'tab switching retains capture view and its state until main route exits',
      (tester) async {
    var created = 0, disposed = 0;
    await tester.pumpWidget(MaterialApp(
        home: MainScreen(pagesForTesting: [
      const Text('活动首页'),
      const Text('上一次对话'),
      _CapturePage(() => created++, () => disposed++),
      const Text('个人资料')
    ])));
    expect(created, 0);
    await tester.tap(find.text('动作'));
    await tester.pumpAndSettle();
    expect(created, 1);
    expect(disposed, 0);
    await tester.tap(find.text('助手'));
    await tester.pumpAndSettle();
    expect(find.text('上一次对话'), findsOneWidget);
    expect(disposed, 0);
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('动作'));
    await tester.pumpAndSettle();
    expect(created, 1);
    expect(disposed, 0);
    expect(find.text('同一轮动捕'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(disposed, 1);
  });
}
