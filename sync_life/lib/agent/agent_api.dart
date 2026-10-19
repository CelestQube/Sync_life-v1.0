import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../mocap/user_session.dart';

class AgentException implements Exception {
  final String message;
  final int? status;
  final String? code;
  const AgentException(this.message, {this.status, this.code});
  @override
  String toString() => message;
}

String newRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class AgentApi {
  AgentApi({http.Client? client, UserSession? session, String? baseUrl})
      : _client = client ?? http.Client(),
        session = session ?? UserSession.instance,
        baseUrl = baseUrl ?? ApiConfig.agentUrl;

  final http.Client _client;
  final UserSession session;
  final String baseUrl;

  Future<String> storageScope() async {
    await session.initialize();
    if (!session.authenticated) {
      throw const AgentException('请先登录', status: 401);
    }
    return base64Url.encode(utf8.encode('$baseUrl|${session.userId}'));
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      [Map<String, dynamic>? body]) async {
    await session.initialize();
    if (!session.authenticated) {
      throw const AgentException('请先登录后使用智能服务', status: 401);
    }
    final owner = session.userId;
    final token = session.token;
    final request = http.Request(method, Uri.parse('$baseUrl/$path'));
    request.headers.addAll(session.headers);
    if (body != null) request.body = jsonEncode(body);
    try {
      final streamed =
          await _client.send(request).timeout(const Duration(seconds: 110));
      final response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 10));
      if (owner != session.userId || token != session.token) {
        throw const AgentException('账号已切换，请重新加载', code: 'session_changed');
      }
      Map<String, dynamic> result;
      try {
        result =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      } catch (_) {
        throw AgentException('后端返回格式不正确，请检查服务地址', status: response.statusCode);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AgentException(result['error'] as String? ?? '请求失败，请稍后重试',
            status: response.statusCode, code: result['code'] as String?);
      }
      return result;
    } on TimeoutException {
      throw const AgentException('请求超时，请刷新对话或重试；已收到的消息不会重复保存');
    } on http.ClientException {
      throw const AgentException('无法连接服务器，请检查网络和后端地址');
    }
  }

  Future<Map<String, dynamic>> status() => _request('GET', 'status/');
  Future<Map<String, dynamic>> conversations(
          {bool archived = false, int offset = 0}) =>
      _request(
          'GET', 'conversations/?archived=$archived&offset=$offset&limit=30');
  Future<Map<String, dynamic>> createConversation() =>
      _request('POST', 'conversations/', {});
  Future<Map<String, dynamic>> getConversation(String id) =>
      _request('GET', 'conversations/$id/');
  Future<Map<String, dynamic>> updateConversation(
          String id, Map<String, dynamic> data) =>
      _request('PATCH', 'conversations/$id/', data);
  Future<void> deleteConversation(String id) async =>
      _request('DELETE', 'conversations/$id/', {});
  Future<Map<String, dynamic>> messages(String id, {int? before}) => _request(
      'GET',
      'conversations/$id/messages/?limit=50${before == null ? '' : '&before=$before'}');
  Future<Map<String, dynamic>> pin(String conversationId, int id, bool value) =>
      _request('PATCH', 'conversations/$conversationId/messages/$id/',
          {'pinned': value});
  Future<Map<String, dynamic>> chat(String conversationId, String message,
          {required String requestId,
          String kind = 'auto',
          double? latitude,
          double? longitude}) =>
      _request('POST', 'chat/', {
        'conversation_id': conversationId,
        'request_id': requestId,
        'message': message,
        'kind': kind,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude
      });
  Future<Map<String, dynamic>> memories() => _request('GET', 'memories/');
  Future<Map<String, dynamic>> saveMemory(Map<String, dynamic> data,
          {String? id}) =>
      _request(id == null ? 'POST' : 'PATCH',
          id == null ? 'memories/' : 'memories/$id/', data);
  Future<void> deleteMemory(String id) async =>
      _request('DELETE', 'memories/$id/', {});
  Future<Map<String, dynamic>> plans({int offset = 0}) =>
      _request('GET', 'plans/?limit=20&offset=$offset');
  Future<Map<String, dynamic>> getPlan(String id) =>
      _request('GET', 'plans/$id/');
  Future<Map<String, dynamic>> savePlan(Map<String, dynamic> document,
          {String? id, int? revision, int? sourceMessageId}) =>
      _request(
          id == null ? 'POST' : 'PATCH', id == null ? 'plans/' : 'plans/$id/', {
        'document': document,
        if (revision != null) 'revision': revision,
        if (sourceMessageId != null) 'source_message_id': sourceMessageId
      });
  Future<void> deletePlan(String id) async =>
      _request('DELETE', 'plans/$id/', {});
  Future<Map<String, dynamic>> checkInTraining(int id,
          {required bool completed, required int revision, String note = ''}) =>
      _request('PATCH', 'training-days/$id/',
          {'completed': completed, 'revision': revision, 'note': note});
  void close() => _client.close();
}
