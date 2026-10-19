import 'package:flutter/material.dart';

/// Switch an existing main tab without replacing the capture-owning route.
final requestedMainTab = ValueNotifier<int?>(null);
final requestedAgentDraft = ValueNotifier<String?>(null);

void openAssistantDraft(BuildContext context, String text) {
  requestedAgentDraft.value = null;
  requestedAgentDraft.value = text;
  Navigator.popUntil(context, (route) => route.isFirst);
}
