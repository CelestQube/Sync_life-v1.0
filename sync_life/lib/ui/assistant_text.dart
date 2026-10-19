import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Small, selectable formatter for the headings and emphasis used by replies.
/// It keeps source text intact for copying and treats all links as plain text.
class AssistantText extends StatelessWidget {
  const AssistantText(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .bodyMedium!
        .copyWith(fontSize: 15, height: 1.65);
    if (!RegExp(r'\*\*|^#{1,4} |^\s*[-*] ', multiLine: true).hasMatch(text)) {
      return SelectableText(text, style: style);
    }
    final spans = <InlineSpan>[];
    final lines = text.split('\n');
    for (var index = 0; index < lines.length; index++) {
      var line = lines[index];
      final heading = RegExp(r'^#{1,4}\s+').hasMatch(line);
      line = line
          .replaceFirst(RegExp(r'^#{1,4}\s+'), '')
          .replaceFirst(RegExp(r'^\s*[-*]\s+'), '•  ');
      final lineStyle = heading
          ? style.copyWith(fontWeight: FontWeight.w700, color: AppColors.deep)
          : style;
      var offset = 0;
      for (final match in RegExp(r'\*\*(.+?)\*\*').allMatches(line)) {
        if (match.start > offset) {
          spans.add(TextSpan(
              text: line.substring(offset, match.start), style: lineStyle));
        }
        spans.add(TextSpan(
            text: match.group(1),
            style: lineStyle.copyWith(fontWeight: FontWeight.w700)));
        offset = match.end;
      }
      spans.add(TextSpan(text: line.substring(offset), style: lineStyle));
      if (index != lines.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return SelectableText.rich(TextSpan(style: style, children: spans));
  }
}
