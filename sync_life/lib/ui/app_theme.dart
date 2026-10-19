import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract class AppColors {
  static const primary = Color(0xFF18766F);
  static const deep = Color(0xFF194F4D);
  static const background = Color(0xFFF2F7F6);
  static const soft = Color(0xFFE3F1ED);
  static const ink = Color(0xFF203937);
  static const muted = Color(0xFF6F8280);
  static const line = Color(0xFFDCE7E3);
  static const warm = Color(0xFF946B35);
  static const warmSurface = Color(0xFFFAF1E3);
  static const danger = Color(0xFFB44E49);
}

ThemeData buildAppTheme() {
  final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        primary: AppColors.primary,
        onPrimary: Colors.white,
        secondary: AppColors.deep,
        surface: Colors.white,
        onSurface: AppColors.ink,
        error: AppColors.danger,
      ));
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    textTheme: base.textTheme.copyWith(
      titleLarge: const TextStyle(
          fontSize: 22,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: AppColors.ink),
      titleMedium: const TextStyle(
          fontSize: 16,
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: AppColors.ink),
      bodyLarge:
          const TextStyle(fontSize: 16, height: 1.5, color: AppColors.ink),
      bodyMedium:
          const TextStyle(fontSize: 14, height: 1.5, color: AppColors.ink),
      bodySmall:
          const TextStyle(fontSize: 12, height: 1.5, color: AppColors.muted),
    ),
    appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 20,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: AppColors.background,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarContrastEnforced: false,
        )),
    cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppColors.line))),
    inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF5F8F7),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        labelStyle: const TextStyle(color: AppColors.muted),
        hintStyle: const TextStyle(color: AppColors.muted, fontSize: 14),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.line)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide:
                const BorderSide(color: AppColors.primary, width: 1.5))),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48), shape: shape)),
    elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            minimumSize: const Size(0, 48),
            shape: shape)),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            minimumSize: const Size(0, 46),
            side: const BorderSide(color: AppColors.line),
            shape: shape)),
    chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.white,
        selectedColor: AppColors.soft,
        side: const BorderSide(color: AppColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        labelStyle: const TextStyle(fontSize: 13, color: AppColors.deep)),
    dividerTheme:
        const DividerThemeData(color: AppColors.line, thickness: 1, space: 1),
    listTileTheme: const ListTileThemeData(
        iconColor: AppColors.primary,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 2)),
    navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.soft,
        height: 70,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? AppColors.deep
                : AppColors.muted))),
    snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.deep,
        shape: shape),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 1),
    dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
    bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true),
  );
}

class AppCard extends StatelessWidget {
  const AppCard(
      {super.key,
      required this.child,
      this.color = Colors.white,
      this.padding = const EdgeInsets.all(18)});
  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) =>
      Card(color: color, child: Padding(padding: padding, child: child));
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 10),
      child: Row(children: [
        Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
        if (trailing != null) trailing!
      ]));
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.warm = false});
  final String label;
  final bool warm;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: warm ? AppColors.warmSurface : AppColors.soft,
          borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: warm ? AppColors.warm : AppColors.deep)));
}

class EmptyStateCard extends StatelessWidget {
  const EmptyStateCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.description,
      this.action});
  final IconData icon;
  final String title, description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => AppCard(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: AppColors.soft,
                  borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: AppColors.primary, size: 24)),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 5),
                Text(description,
                    style:
                        const TextStyle(color: AppColors.muted, height: 1.5)),
              ])),
        ]),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 14), child: action!),
      ]));
}

class InfoBanner extends StatelessWidget {
  const InfoBanner(this.text, {super.key, this.action, this.warning = false});
  final String text;
  final Widget? action;
  final bool warning;
  @override
  Widget build(BuildContext context) => Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
          color: warning ? AppColors.warmSurface : AppColors.soft,
          borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(warning ? Icons.info_outline : Icons.check_circle_outline,
            size: 19, color: warning ? AppColors.warm : AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: warning ? AppColors.warm : AppColors.deep))),
        if (action != null) action!
      ]));
}
