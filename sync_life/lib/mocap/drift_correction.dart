import 'dart:math' as math;
import 'dart:typed_data';

List<double> rotation6d(List<double> values) {
  List<double> normalize(List<double> v) {
    final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
    if (!norm.isFinite || norm < 1e-8) throw StateError('自动校正方向无效');
    return v.map((x) => x / norm).toList();
  }

  final x = normalize(values.sublist(0, 3));
  final dot =
      List.generate(3, (i) => x[i] * values[3 + i]).reduce((a, b) => a + b);
  final y = normalize(List.generate(3, (i) => values[3 + i] - dot * x[i]));
  final z = [
    x[1] * y[2] - x[2] * y[1],
    x[2] * y[0] - x[0] * y[2],
    x[0] * y[1] - x[1] * y[0]
  ];
  return [x[0], y[0], z[0], x[1], y[1], z[1], x[2], y[2], z[2]];
}

List<double> orthonormalRotation(List<double> r) =>
    rotation6d([r[0], r[3], r[6], r[1], r[4], r[7]]);

List<double> eulerXYZ(List<double> r) {
  final b = math.asin(r[2].clamp(-1, 1));
  return math.cos(b).abs() > 1e-7
      ? [math.atan2(-r[5], r[8]), b, math.atan2(-r[1], r[0])]
      : [math.atan2(r[7], r[4]), b, 0];
}

/// Exact YZX root-heading regularization from ego_drift_regularization.
/// Removing the predicted Y component avoids treating a real turn as drift.
List<double> regularizeRootDrift(List<double> r) {
  final b = math.asin(r[3].clamp(-1, 1));
  final c = math.cos(b).abs() > 1e-7 ? math.atan2(-r[5], r[4]) : 0.0;
  final cb = math.cos(b), sb = math.sin(b), cc = math.cos(c), sc = math.sin(c);
  return [cb, -sb * cc, sb * sc, sb, cb * cc, -cb * sc, 0, sc, cc];
}

class DriftRequest {
  const DriftRequest(this.history, this.trigger);
  final Float32List history;
  final List<bool> trigger;
}

/// Bounded 256-frame TIC input; same 15-degree diversity cells and per-sensor
/// thresholds as the supplied FullBody script. Static clothes cannot trigger it.
class DriftCorrection {
  final List<Float32List> _history = [];
  DateTime? _lastCheck;
  void reset() {
    _history.clear();
    _lastCheck = null;
  }

  void add(Float32List input) {
    _history.add(Float32List.fromList(input));
    if (_history.length > 256) _history.removeAt(0);
  }

  DriftRequest? request(DateTime now) {
    if (_history.length < 256 ||
        (_lastCheck != null &&
            now.difference(_lastCheck!).inMilliseconds < 1000)) {
      return null;
    }
    _lastCheck = now;
    final cells = List.generate(10, (_) => <int>{});
    for (final frame in _history) {
      for (var i = 0; i < 10; i++) {
        final angles = eulerXYZ(frame.sublist(30 + i * 9, 39 + i * 9));
        final a = (angles[0] * 180 / math.pi / 15).floor() + 12;
        final b = (angles[1] * 180 / math.pi / 15).floor() + 6;
        final c = (angles[2] * 180 / math.pi / 15).floor() + 12;
        cells[i]
            .add(a.clamp(0, 23) + b.clamp(0, 11) * 24 + c.clamp(0, 23) * 288);
      }
    }
    final trigger =
        List.generate(10, (i) => cells[i].length > (i < 2 ? 50 : 30));
    if (trigger.where((value) => value).length < 3) return null;
    final history = Float32List(256 * 120);
    for (var i = 0; i < 256; i++) {
      history.setRange(i * 120, (i + 1) * 120, _history[i]);
    }
    return DriftRequest(history, trigger);
  }

  void applied() {
    if (_history.isNotEmpty) _history.removeRange(0, _history.length - 1);
  }
}
