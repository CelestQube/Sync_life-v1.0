import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'agent_api.dart';

/// Only unacknowledged requests; bounded and scoped to both account and API origin.
class PendingChatStore {
  PendingChatStore(this.api);
  final AgentApi api;
  Future<Map<String, dynamic>?> load(String conversationId) async {
    final scope = await api.storageScope();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('agent_pending_$scope');
    if (raw == null) return null;
    final value = (jsonDecode(raw) as Map)[conversationId];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<void> put(String conversationId, Map<String, dynamic> request) async {
    final scope = await api.storageScope();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('agent_pending_$scope');
    final values = raw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (!values.containsKey(conversationId) && values.length >= 20) {
      throw const AgentException('已有 20 段对话包含未确认消息，请先重试或整理这些对话');
    }
    values[conversationId] = request;
    await prefs.setString('agent_pending_$scope', jsonEncode(values));
  }

  Future<void> remove(String conversationId) async {
    final scope = await api.storageScope();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('agent_pending_$scope');
    if (raw == null) return;
    final values = Map<String, dynamic>.from(jsonDecode(raw) as Map)
      ..remove(conversationId);
    if (values.isEmpty) {
      await prefs.remove('agent_pending_$scope');
    } else {
      await prefs.setString('agent_pending_$scope', jsonEncode(values));
    }
  }
}
