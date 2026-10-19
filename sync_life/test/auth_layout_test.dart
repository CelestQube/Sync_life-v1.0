import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_life/pages/login_page.dart';
import 'package:sync_life/pages/register_page.dart';
import 'package:sync_life/ui/app_theme.dart';

void main() {
  testWidgets(
      'login and registration actions stay reachable above the keyboard',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Widget app(Widget page) => MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
                viewInsets: const EdgeInsets.only(bottom: 260)),
            child: child!),
        home: page);
    await tester.pumpWidget(app(const LoginPage()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('登录'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(app(const RegisterPage()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('注册并开始'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
