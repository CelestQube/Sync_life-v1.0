import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../config/api_config.dart';
import 'posture_classifier.dart';

String newMotionId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Records only observed intervals. Ownership is fixed before the first sample.
class PostureSegmenter {
  PostureSegmenter(
      {required this.userId,
      required this.deviceId,
      required this.sessionId,
      required this.onSegment});
  final int userId;
  final String deviceId, sessionId;
  final void Function(Map<String, dynamic>) onSegment;
  PostureEstimate? _first, _last;
  int _frames = 0;
  double _confidence = 0;
  final Map<String, double> _features = {};

  void add(PostureEstimate estimate) {
    if (_last != null) {
      final gap = estimate.time.difference(_last!.time).inMicroseconds;
      if (gap <= 0 || gap > 250000 || estimate.state != _last!.state) {
        interrupt();
      }
    }
    _first ??= estimate;
    _last = estimate;
    _frames++;
    _confidence += estimate.confidence;
    estimate.features.forEach(
        (name, value) => _features[name] = (_features[name] ?? 0) + value);
    if (estimate.time.difference(_first!.time).inMilliseconds >= 5000) {
      interrupt();
      // Start the next adjacent chunk at the same actually observed boundary.
      add(estimate);
    }
  }

  void interrupt() {
    if (_frames >= 2 && _last!.time.isAfter(_first!.time)) {
      onSegment({
        'user_id': userId,
        'event': {
          'segment_id': newMotionId(),
          'device_id': deviceId,
          'session_id': sessionId,
          'start_time': _first!.time.toUtc().toIso8601String(),
          'end_time': _last!.time.toUtc().toIso8601String(),
          'state': _first!.state.wireName,
          'confidence': _confidence / _frames,
          'features':
              _features.map((key, value) => MapEntry(key, value / _frames)),
          'frame_count': _frames,
          'source': 'phone_ble',
          'algorithm_version': PostureClassifier.algorithmVersion,
        },
      });
    }
    _first = _last = null;
    _frames = 0;
    _confidence = 0;
    _features.clear();
  }
}

/// Durable outbox. HTTP acknowledgement is the only operation that removes data.
class MotionOutbox {
  MotionOutbox(this.file, {this.namespace = ApiConfig.baseUrl});
  final File file;
  // Numeric user IDs are local to a backend, not globally unique identities.
  final String namespace;
  final List<Map<String, dynamic>> _pending = [];
  Future<void> _writes = Future.value();
  List<Map<String, dynamic>> forUser(int id, {int limit = 50}) => _pending
      .where((entry) =>
          entry['user_id'] == id && entry['api_base_url'] == namespace)
      .take(limit)
      .toList();
  int countForUser(int? id) => _pending
      .where((entry) =>
          entry['user_id'] == id && entry['api_base_url'] == namespace)
      .length;

  Future<void> load() async {
    if (!await file.exists()) {
      final temporary = File('${file.path}.tmp');
      if (await temporary.exists()) await temporary.rename(file.path);
    }
    if (!await file.exists()) return;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['protocol'] != 1) throw StateError('不支持的本地动作记录版本');
    _pending.addAll((data['pending'] as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map)));
  }

  Future<void> append(Map<String, dynamic> envelope) {
    _pending.add({...envelope, 'api_base_url': namespace});
    return _persist();
  }

  Future<void> acknowledge(int owner, Set<String> accepted) async {
    _pending.removeWhere((entry) =>
        entry['user_id'] == owner &&
        entry['api_base_url'] == namespace &&
        accepted.contains((entry['event'] as Map)['segment_id']));
    await _persist();
  }

  Future<void> persist() => _persist();
  Future<int> discardExpired(int owner, DateTime cutoff) async {
    final before = _pending.length;
    _pending.removeWhere((entry) {
      if (entry['user_id'] != owner || entry['api_base_url'] != namespace) {
        return false;
      }
      final end = DateTime.tryParse('${(entry['event'] as Map)['end_time']}');
      return end != null && !end.isAfter(cutoff);
    });
    await _persist();
    return before - _pending.length;
  }

  Future<void> _persist() {
    final snapshot = jsonEncode({'protocol': 1, 'pending': _pending});
    final operation = _writes.catchError((Object _) {}).then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(file.path);
    });
    _writes = operation;
    return operation;
  }
}
