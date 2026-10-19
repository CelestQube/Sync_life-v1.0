import 'dart:math' as math;
import 'dart:typed_data';
import 'imu_protocol.dart';

enum BodyPosture { lie, stand, sit, walk, run, unknown, slowWalk, jog }

extension BodyPostureLabel on BodyPosture {
  String get wireName =>
      this == BodyPosture.slowWalk ? 'SLOW_WALK' : name.toUpperCase();
  String get label =>
      const ['卧躺', '站立', '坐立', '行走', '奔跑', '无法判断', '慢走', '慢跑'][index];
  BodyPosture get summaryState => this == BodyPosture.slowWalk
      ? BodyPosture.walk
      : this == BodyPosture.jog
          ? BodyPosture.run
          : this;
}

class PostureEstimate {
  const PostureEstimate(this.time, this.state, this.confidence, this.features);
  final DateTime time;
  final BodyPosture state;

  /// Rule support score, not a statistically calibrated probability.
  final double confidence;
  final Map<String, double> features;
}

class _Sample {
  const _Sample(
      this.time, this.trunk, this.thigh, this.knee, this.swing, this.acc);
  final DateTime time;
  final double trunk, thigh, knee, swing, acc;
}

class _Gait {
  const _Gait(this.cadence, this.periodicity);
  final double cadence, periodicity;
}

/// SMPL local rotations + calibrated, gravity-removed pelvis acceleration.
/// No uncalibrated sensor Euler angles, pooled arm energy, or default standing label.
class PostureClassifier {
  static const algorithmVersion = 'smpl-imu-temporal-v2';
  static const _parents = [
    -1,
    0,
    0,
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    9,
    9,
    12,
    13,
    14,
    16,
    17,
    18,
    19,
    20,
    21
  ];
  final List<_Sample> _window = [];
  BodyPosture _candidate = BodyPosture.unknown;
  BodyPosture _stable = BodyPosture.unknown;
  DateTime? _candidateSince;

  void reset() {
    _window.clear();
    _candidate = BodyPosture.unknown;
    _stable = BodyPosture.unknown;
    _candidateSince = null;
  }

  PostureEstimate add(Float32List pose, Float32List input, DateTime time) {
    if (pose.length != 72 ||
        input.length != 120 ||
        [...pose, ...input].any((value) => !value.isFinite)) {
      throw ArgumentError(
          'Recognition requires a finite SMPL pose and calibrated IMU input');
    }
    if (_window.isNotEmpty) {
      final gap = time.difference(_window.last.time).inMicroseconds / 1e6;
      if (gap <= 0 || gap > .25) reset();
    }
    final rotations = <List<double>>[];
    for (var joint = 0; joint < 24; joint++) {
      final local = axisAngleRotation(pose.sublist(joint * 3, joint * 3 + 3));
      rotations.add(_parents[joint] < 0
          ? local
          : multiply3(rotations[_parents[joint]], local));
    }
    // SMPL zero-pose torso points +Y; thighs point -Y. Rotation around Y
    // changes heading without changing inclination.
    final trunk = _inclination(rotations[9]);
    final thigh = (_inclination(rotations[1]) + _inclination(rotations[2])) / 2;
    final knee = (_inclination(axisAngleRotation(pose.sublist(12, 15))) +
            _inclination(axisAngleRotation(pose.sublist(15, 18)))) /
        2;
    // Hip motion relative to the pelvis keeps cadence invariant to body heading.
    final swing = (_sagittal(axisAngleRotation(pose.sublist(3, 6))) -
            _sagittal(axisAngleRotation(pose.sublist(6, 9)))) *
        180 /
        math.pi;
    // The last selected IMU is the pelvis reference; /30 reverses model scaling.
    final acc = math.sqrt(input[27] * input[27] +
            input[28] * input[28] +
            input[29] * input[29]) *
        30;
    _window.add(_Sample(time, trunk, thigh, knee, swing, acc));
    _window.removeWhere(
        (sample) => time.difference(sample.time).inMilliseconds > 6800);
    final recent = _window
        .where((sample) => time.difference(sample.time).inMilliseconds <= 350)
        .toList();
    final dynamicWindow = _window
        .where((sample) => time.difference(sample.time).inMilliseconds <= 1400)
        .toList();
    final rms = math.sqrt(dynamicWindow.fold<double>(
            0, (sum, sample) => sum + sample.acc * sample.acc) /
        dynamicWindow.length);
    final swings = dynamicWindow.map((sample) => sample.swing).toList();
    final swingRange = swings.reduce(math.max) - swings.reduce(math.min);
    final gait = _gait();
    final features = <String, double>{
      'pelvis_tilt_deg': _inclination(rotations[0]),
      'trunk_tilt_deg': _median(recent.map((sample) => sample.trunk)),
      'thigh_tilt_deg': _median(recent.map((sample) => sample.thigh)),
      'knee_flex_deg': _median(recent.map((sample) => sample.knee)),
      'pelvis_acc_rms': rms.clamp(0, 150).toDouble(),
      'cadence_hz': gait.cadence,
      'leg_swing_deg': swingRange.clamp(0, 180).toDouble(),
    };
    var candidate = BodyPosture.unknown;
    var score = 0.0;
    final duration = time.difference(_window.first.time).inMicroseconds / 1e6;
    final t = features['trunk_tilt_deg']!,
        h = features['thigh_tilt_deg']!,
        k = features['knee_flex_deg']!;
    if (duration >= .5 && _window.length >= 12) {
      if (t >= 65 &&
          h >= 55 &&
          features['pelvis_tilt_deg']! >= 55 &&
          rms < 2.2) {
        candidate = BodyPosture.lie;
        score = .85;
      } else if (t < 40 &&
          h >= 55 &&
          h <= 125 &&
          k >= 45 &&
          k <= 125 &&
          rms < 1.8) {
        candidate = BodyPosture.sit;
        score = .85;
      } else if (t < 45 &&
          duration >= 1.6 &&
          gait.periodicity >= .45 &&
          gait.cadence >= .6 &&
          swingRange >= 6 &&
          rms >= .15) {
        if (gait.cadence >= 2.6 && rms >= 2.4) {
          candidate = BodyPosture.run;
          score = .7 + .2 * gait.periodicity;
        } else if ((gait.cadence >= 2.2 && rms >= 1.4) ||
            (gait.cadence >= 1.8 && rms >= 2.0)) {
          candidate = BodyPosture.jog;
          score = .65 + .2 * gait.periodicity;
        } else if (gait.cadence >= 1.0 && swingRange >= 15 && rms >= .45) {
          candidate = BodyPosture.walk;
          score = .7 + .2 * gait.periodicity;
        } else {
          candidate = BodyPosture.slowWalk;
          score = .65 + .2 * gait.periodicity;
        }
      } else if (t < 30 && h < 35 && k < 35 && rms < 1.1 && swingRange < 12) {
        candidate = BodyPosture.stand;
        score = .9;
      }
    }
    if (candidate != _candidate) {
      _candidate = candidate;
      _candidateSince = time;
    }
    // Report transitions as unknown rather than crediting the old state with new motion.
    final dwell = time.difference(_candidateSince ?? time).inMilliseconds;
    if (candidate != BodyPosture.unknown &&
        dwell < 700 &&
        _stable != BodyPosture.unknown &&
        candidate.summaryState == _stable.summaryState) {
      return PostureEstimate(time, _stable, score, features);
    }
    if (candidate == BodyPosture.unknown || dwell < 700) {
      return PostureEstimate(time, BodyPosture.unknown, 0, features);
    }
    _stable = candidate;
    return PostureEstimate(time, candidate, score, features);
  }

  _Gait _gait() {
    if (_window.length < 30) return const _Gait(0, 0);
    // Resample by timestamps so BLE jitter does not change the apparent cadence.
    final start = _window.first.time, end = _window.last.time;
    final values = <double>[];
    var right = 1;
    for (var micros = 0;
        micros <= end.difference(start).inMicroseconds;
        micros += 33333) {
      final target = start.add(Duration(microseconds: micros));
      while (
          right < _window.length - 1 && _window[right].time.isBefore(target)) {
        right++;
      }
      final a = _window[right - 1], b = _window[right];
      final span = b.time.difference(a.time).inMicroseconds;
      final weight =
          span == 0 ? 0.0 : target.difference(a.time).inMicroseconds / span;
      values.add(a.swing + (b.swing - a.swing) * weight);
    }
    if (values.length < 48) return const _Gait(0, 0);
    final mean = values.reduce((a, b) => a + b) / values.length;
    final centered = values.map((value) => value - mean).toList();
    var best = 0.0, bestLag = 0;
    for (var lag = 10; lag <= 100 && lag < values.length / 2; lag++) {
      var dot = 0.0, left = 0.0, right = 0.0;
      for (var i = lag; i < values.length; i++) {
        dot += centered[i] * centered[i - lag];
        left += centered[i] * centered[i];
        right += centered[i - lag] * centered[i - lag];
      }
      final correlation =
          left * right < 1e-6 ? 0.0 : dot / math.sqrt(left * right);
      // Prefer the first stride period over numerically almost equal multiples.
      if (correlation > best + .001) {
        best = correlation;
        bestLag = lag;
      }
    }
    return bestLag == 0
        ? const _Gait(0, 0)
        : _Gait(
            (60 / bestLag).clamp(0, 5).toDouble(), best.clamp(0, 1).toDouble());
  }
}

double _inclination(List<double> rotation) =>
    math.acos(rotation[4].clamp(-1, 1)) * 180 / math.pi;
double _sagittal(List<double> rotation) =>
    math.atan2(-rotation[7], rotation[4]);
double _median(Iterable<double> values) {
  final sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2];
}

List<double> axisAngleRotation(List<double> axisAngle) {
  final angle =
      math.sqrt(axisAngle.fold<double>(0, (sum, value) => sum + value * value));
  if (angle < 1e-8) return [1, 0, 0, 0, 1, 0, 0, 0, 1];
  final x = axisAngle[0] / angle,
      y = axisAngle[1] / angle,
      z = axisAngle[2] / angle;
  final c = math.cos(angle), s = math.sin(angle), v = 1 - c;
  return [
    c + x * x * v,
    x * y * v - z * s,
    x * z * v + y * s,
    y * x * v + z * s,
    c + y * y * v,
    y * z * v - x * s,
    z * x * v - y * s,
    z * y * v + x * s,
    c + z * z * v
  ];
}
