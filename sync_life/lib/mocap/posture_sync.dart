import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';
import 'posture_classifier.dart';
import 'posture_recording.dart';
import 'user_session.dart';

class PostureSyncService extends ChangeNotifier {
  PostureSyncService._()
      : _session = UserSession.instance,
        _client = http.Client();
  @visibleForTesting
  PostureSyncService.forTesting(
      {required UserSession session,
      required http.Client client,
      required MotionOutbox outbox,
      required String deviceId,
      String endpoint = ApiConfig.motionEventsUrl})
      : _session = session,
        _client = client,
        _outbox = outbox,
        _deviceId = deviceId {
    _endpoint = endpoint;
    _session.addListener(_userChanged);
  }
  static final instance = PostureSyncService._();
  final UserSession _session;
  final http.Client _client;
  String _endpoint = ApiConfig.motionEventsUrl;
  MotionOutbox? _outbox;
  PostureSegmenter? _segmenter;
  Future<void>? _initializing;
  String? _deviceId;
  String _captureId = newMotionId();
  bool _busy = false, _blocked = false;
  bool _observingSession = false;
  Timer? _timer;
  DateTime _retryAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _failures = 0, uploadedSegments = 0;
  int get pendingSegments => _outbox?.countForUser(_session.userId) ?? 0;
  String status = '正在准备动作同步';
  String? error;
  DateTime? _expiredBefore;
  int? _expiredOwner;
  bool get hasExpiredRecords =>
      _expiredBefore != null && _expiredOwner == _session.userId;

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      await _session.initialize();
      if (!_observingSession) {
        _session.addListener(_userChanged);
        _observingSession = true;
      }
      final preferences = await SharedPreferences.getInstance();
      _deviceId = preferences.getString('motionDeviceId') ?? newMotionId();
      await preferences.setString('motionDeviceId', _deviceId!);
      final directory = await getApplicationDocumentsDirectory();
      final outbox =
          MotionOutbox(File('${directory.path}/motion_outbox_v1.json'));
      await outbox.load();
      _outbox = outbox;
      _userChanged();
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => flush());
      await flush();
    } catch (exception) {
      error = '无法读取本地动作记录，请保留应用数据后重试';
      status = '动作同步未就绪';
      notifyListeners();
    }
  }

  void _userChanged() {
    interrupt();
    uploadedSegments = 0;
    _blocked = false;
    _failures = 0;
    _retryAt = DateTime.fromMillisecondsSinceEpoch(0);
    error = null;
    _expiredBefore = null;
    _expiredOwner = null;
    status = _session.authenticated ? '已登录，等待真实动作记录' : '请登录后记录和同步动作';
    notifyListeners();
    unawaited(flush());
  }

  void beginCapture() {
    interrupt();
    _captureId = newMotionId();
  }

  void record(PostureEstimate estimate) {
    if (_outbox == null || !_session.authenticated) return;
    _segmenter ??= PostureSegmenter(
        userId: _session.userId!,
        deviceId: _deviceId!,
        sessionId: _captureId,
        onSegment: _save);
    _segmenter!.add(estimate);
  }

  void interrupt() {
    _segmenter?.interrupt();
    _segmenter = null;
  }

  void _save(Map<String, dynamic> envelope) {
    final operation = _outbox!.append(envelope);
    status = '动作已在本地记录，等待同步';
    notifyListeners();
    unawaited(operation.then((_) => flush()).catchError((Object exception) {
      error = '无法保存动作记录，请检查手机存储空间';
      status = '本地保存失败，请保留应用数据';
      notifyListeners();
    }));
  }

  Future<void> retry() async {
    if (_outbox == null) {
      _initializing = null;
      await initialize();
      return;
    }
    _blocked = false;
    _retryAt = DateTime.fromMillisecondsSinceEpoch(0);
    await flush();
  }

  Future<void> discardExpiredRecords() async {
    final owner = _session.userId, cutoff = _expiredBefore;
    if (_busy ||
        owner == null ||
        owner != _expiredOwner ||
        cutoff == null ||
        _outbox == null) {
      return;
    }
    await _outbox!.discardExpired(owner, cutoff);
    _expiredBefore = null;
    _expiredOwner = null;
    if (_session.userId == owner) await retry();
  }

  Future<void> flush() async {
    if (_busy ||
        _blocked ||
        _outbox == null ||
        !_session.authenticated ||
        DateTime.now().isBefore(_retryAt)) {
      return;
    }
    final owner = _session.userId!, token = _session.token!;
    final batch = _outbox!.forUser(owner);
    if (batch.isEmpty) return;
    _busy = true;
    try {
      // Make the entire batch durable before any network call.
      await _outbox!.persist();
      final response = await _client
          .post(Uri.parse(_endpoint),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token'
              },
              body: jsonEncode({
                'protocol': 1,
                'user_id': owner,
                'events': batch.map((entry) => entry['event']).toList()
              }))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 401) {
        if (_session.userId == owner && _session.token == token) {
          await _session.signOut();
        }
        throw StateError('登录已失效；本地记录保留，请重新登录');
      }
      if (response.statusCode != 200) {
        if (response.statusCode == 410 &&
            _session.userId == owner &&
            _session.token == token) {
          final expired = jsonDecode(response.body) as Map;
          if (expired['code'] == 'detail_window_expired') {
            _expiredBefore = DateTime.tryParse('${expired['detail_cutoff']}');
            _expiredOwner = owner;
            _blocked = true;
            throw StateError('有超过 30 天的离线记录未能补传，请先整理过期记录。');
          }
        }
        if (response.statusCode >= 400 &&
            response.statusCode < 500 &&
            _session.userId == owner &&
            _session.token == token) {
          _blocked = true;
        }
        throw StateError('服务器未接收记录（${response.statusCode}），请检查手机时间或联系维护人员');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final allowed = batch
          .map((entry) => (entry['event'] as Map)['segment_id'] as String)
          .toSet();
      final accepted = (data['accepted'] as List)
          .cast<String>()
          .toSet()
          .intersection(allowed);
      if (accepted.isEmpty) throw StateError('服务器未确认任何动作记录');
      await _outbox!.acknowledge(owner, accepted);
      if (_session.userId == owner && _session.token == token) {
        uploadedSegments += accepted.length;
        status = '已同步动作记录';
        error = null;
        _failures = 0;
      }
    } catch (exception) {
      if ((_session.userId == owner && _session.token == token) ||
          !_session.authenticated) {
        error = exception is StateError
            ? exception.message.toString()
            : '暂时无法连接服务器，请检查网络后重试';
        status = '同步未完成，本地记录已保留';
        _failures++;
        _retryAt = DateTime.now()
            .add(Duration(seconds: (2 << _failures.clamp(0, 5)).clamp(2, 60)));
      }
    } finally {
      _busy = false;
      notifyListeners();
      if (_session.authenticated &&
          (_session.userId != owner || _session.token != token)) {
        unawaited(flush());
      }
    }
  }

  @override
  void dispose() {
    interrupt();
    _timer?.cancel();
    _client.close();
    _session.removeListener(_userChanged);
    super.dispose();
  }
}
