import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import 'user_session.dart';

String motionDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

Future<Map<String, dynamic>> _requestMotion(Uri uri,
    {Map<String, dynamic>? body}) async {
  final session = UserSession.instance;
  await session.initialize();
  if (!session.authenticated) throw StateError('请登录后查看个人活动记录');
  final owner = session.userId, token = session.token;
  final response = await (body == null
          ? http.get(uri, headers: session.headers)
          : http.post(uri, headers: session.headers, body: jsonEncode(body)))
      .timeout(const Duration(seconds: 10));
  if (session.userId != owner || session.token != token) {
    throw StateError('账号已切换，请刷新活动记录');
  }
  if (response.statusCode == 401) {
    await session.signOut();
    throw StateError('登录已失效，请重新登录');
  }
  if (response.statusCode != 200) {
    throw StateError('暂时无法获取活动记录，请稍后重试');
  }
  final data = jsonDecode(response.body) as Map<String, dynamic>;
  if (data['user_id'] != owner) throw StateError('记录账号不匹配，请重新登录');
  return data;
}

Future<Map<String, dynamic>> fetchMotionStatistics(String range) =>
    _requestMotion(Uri.parse(ApiConfig.bodyMovementUrl),
        body: {'time_range': range});

Future<Map<String, dynamic>> fetchMotionDay(DateTime day) async {
  final key = motionDateKey(day);
  final data = await _requestMotion(
      Uri.parse('${ApiConfig.baseUrl}/posture/motion/day/')
          .replace(queryParameters: {'date': key}));
  if (data['date'] != key) throw StateError('活动日期未能核对，请刷新后重试');
  return data;
}

Future<Map<String, dynamic>> fetchMotionWindow(
    DateTime day, int startMinute) async {
  final key = motionDateKey(day);
  final data = await _requestMotion(
      Uri.parse('${ApiConfig.baseUrl}/posture/motion/window/').replace(
          queryParameters: {'date': key, 'start_minute': '$startMinute'}));
  if (data['date'] != key || data['start_minute'] != startMinute) {
    throw StateError('时间段未能核对，请重试');
  }
  return data;
}

Future<Map<String, dynamic>> fetchMotionCalendar(DateTime month) async {
  final key = motionDateKey(month).substring(0, 7);
  final data = await _requestMotion(
      Uri.parse('${ApiConfig.baseUrl}/posture/motion/calendar/')
          .replace(queryParameters: {'month': key}));
  if (data['month'] != key) throw StateError('月份未能核对，请刷新日历');
  return data;
}

String motionDataContext(Map<String, dynamic> data) =>
    '衣物实际观测时段：${data['window_start']} 至 ${data['window_end']}。'
    '已观测 ${data['observed_seconds']} 秒，其中可分类 ${data['classified_seconds']} 秒、'
    '无法判断 ${data['unknown_seconds']} 秒。未佩戴、断连和未上传时段均无记录；'
    '占比仅针对已观测时长。规则支持评分不是准确率，不推断全天活动或医学结论。'
    '步数由步频估算，距离和热量尚未估算。\n';
