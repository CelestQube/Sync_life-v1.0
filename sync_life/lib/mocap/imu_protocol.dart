import 'dart:math' as math;
import 'dart:typed_data';
import 'drift_correction.dart';

enum GarmentRole { upper, lower }

class ImuSample {
  const ImuSample(this.acceleration, this.quaternion);
  final List<double> acceleration;

  /// Sensor wire order is x, y, z, w.
  final List<double> quaternion;

  List<double> get rotation {
    final q = quaternion;
    final norm = q.fold<double>(0, (sum, v) => sum + v * v);
    final s = 2 / norm;
    final x = q[0], y = q[1], z = q[2], w = q[3];
    return [
      1 - s * (y * y + z * z),
      s * (x * y - w * z),
      s * (x * z + w * y),
      s * (x * y + w * z),
      1 - s * (x * x + z * z),
      s * (y * z - w * x),
      s * (x * z - w * y),
      s * (y * z + w * x),
      1 - s * (x * x + y * y),
    ];
  }
}

class ImuFrame {
  const ImuFrame(this.timestamp, this.samples);
  final int timestamp;
  final List<ImuSample> samples;
}

/// Packed MyDatas in receive_bleak_085.py: header(4), left(140), right(72), check(1).
/// Firmware's length/checksum semantics are undocumented; do not invent a CRC.
class ImuPacketDecoder {
  static const packetSize = 217;
  final List<int> _pending = [];
  int rejectedPackets = 0;

  List<ImuFrame> add(Uint8List notification, GarmentRole role) {
    _pending.addAll(notification);
    final frames = <ImuFrame>[];
    while (_pending.length >= 2) {
      if (_pending[0] != 0xff || _pending[1] != 0xfe) {
        _pending.removeAt(0);
        continue;
      }
      if (_pending.length < packetSize) break;
      final data = ByteData.sublistView(
          Uint8List.fromList(_pending.sublist(0, packetSize)));
      final samples = <ImuSample>[];
      // Lower garment omits left sensor 3, matching the Python receiver.
      final offsets = role == GarmentRole.upper
          ? [8, 42, 76, 110, 148, 182]
          : [8, 42, 76, 148, 182];
      for (final offset in offsets) {
        final a = List.generate(
            3, (i) => data.getFloat32(offset + 6 + i * 4, Endian.little));
        final q = List.generate(
            4, (i) => data.getFloat32(offset + 18 + i * 4, Endian.little));
        if ([...a, ...q].every((v) => v.isFinite) &&
            q.fold<double>(0, (s, v) => s + v * v) >= 1e-3) {
          samples.add(ImuSample(a, q));
        }
      }
      if (samples.length == offsets.length) {
        frames.add(ImuFrame(data.getUint32(4, Endian.little), samples));
        _pending.removeRange(0, packetSize);
      } else {
        rejectedPackets++;
        _pending.removeAt(
            0); // Search for a new header after a corrupt/truncated frame.
      }
    }
    return frames;
  }
}

List<ImuSample> selectModelSensors(ImuFrame upper, ImuFrame lower) => [
      // jacket_6IMU deliberately selects five of six, followed by pants_5IMU.
      for (final i in [5, 1, 4, 0, 3]) upper.samples[i],
      for (final i in [4, 1, 3, 0, 2]) lower.samples[i],
    ];

List<ImuSample> averageFrames(List<ImuFrame> frames) {
  if (frames.isEmpty) throw StateError('没有可用的校准帧');
  return List.generate(frames.first.samples.length, (sensor) {
    final a = List<double>.filled(3, 0), q = List<double>.filled(4, 0);
    final reference = frames.first.samples[sensor].quaternion;
    for (final frame in frames) {
      final sample = frame.samples[sensor];
      final dot = List.generate(4, (i) => reference[i] * sample.quaternion[i])
          .reduce((a, b) => a + b);
      for (var i = 0; i < 3; i++) {
        a[i] += sample.acceleration[i] / frames.length;
      }
      for (var i = 0; i < 4; i++) {
        q[i] += sample.quaternion[i] * (dot < 0 ? -1 : 1);
      }
    }
    final norm = math.sqrt(q.fold<double>(0, (s, v) => s + v * v));
    if (norm < 1e-6) throw StateError('校准四元数无效，请保持 T 字站姿');
    return ImuSample(a, q.map((v) => v / norm).toList());
  });
}

List<double> multiply3(List<double> a, List<double> b) =>
    List.generate(9, (index) {
      final r = index ~/ 3, c = index % 3;
      return a[r * 3] * b[c] +
          a[r * 3 + 1] * b[3 + c] +
          a[r * 3 + 2] * b[6 + c];
    });

List<double> transpose3(List<double> a) =>
    [a[0], a[3], a[6], a[1], a[4], a[7], a[2], a[5], a[8]];
List<double> rotate3(List<double> r, List<double> v) => List.generate(
    3, (i) => r[i * 3] * v[0] + r[i * 3 + 1] * v[1] + r[i * 3 + 2] * v[2]);

/// FullBody T-pose reference with per-sensor TIC global/local drift shifts.
class MocapCalibration {
  MocapCalibration(List<ImuSample> reference) {
    if (reference.length != 10) throw ArgumentError('模型需要 10 个 IMU');
    final root =
        multiply3(reference.last.rotation, [-1, 0, 0, 0, 1, 0, 0, 0, -1]);
    final length = math.sqrt(root[2] * root[2] + root[5] * root[5]);
    if (length < 1e-4) throw StateError('根传感器方向无法校准，请按 T 字站姿重新校准');
    final zx = root[2] / length, zy = root[5] / length;
    // Columns: y cross z, vertical (0,0,1), horizontal z.
    _smplToImu = transpose3([-zy, 0, zx, zx, 0, zy, 0, 1, 0]);
    _deviceToBone = reference
        .map((s) => transpose3(multiply3(_smplToImu, s.rotation)))
        .toList();
  }
  late final List<double> _smplToImu;
  late final List<List<double>> _deviceToBone;
  final _globalShift =
      List.generate(10, (_) => <double>[1, 0, 0, 0, 1, 0, 0, 0, 1]);
  final _localShift =
      List.generate(10, (_) => <double>[1, 0, 0, 0, 1, 0, 0, 0, 1]);

  void applyDrift(Float32List prediction, List<bool> trigger) {
    if (prediction.length != 120 ||
        trigger.length != 10 ||
        prediction.any((v) => !v.isFinite)) {
      throw StateError('自动校正输出无效');
    }
    // Validate every matrix before committing any update.
    final global = List.generate(
        10, (i) => rotation6d(prediction.sublist(i * 6, i * 6 + 6)));
    global[9] = regularizeRootDrift(global[9]);
    final local = List.generate(
        10, (i) => rotation6d(prediction.sublist(60 + i * 6, 66 + i * 6)));
    for (var i = 0; i < 10; i++) {
      if (!trigger[i]) continue;
      _globalShift[i] = orthonormalRotation(
          multiply3(transpose3(global[i]), _globalShift[i]));
      _localShift[i] =
          orthonormalRotation(multiply3(_localShift[i], transpose3(local[i])));
    }
  }

  Float32List transform(List<ImuSample> samples) {
    if (samples.length != 10) throw ArgumentError('模型需要 10 个 IMU');
    final result = Float32List(120);
    for (var i = 0; i < 10; i++) {
      final r = samples[i].rotation;
      final globalAcc = rotate3(r, samples[i].acceleration);
      globalAcc[2] -= 9.8;
      final globalRotation = multiply3(_globalShift[i], _smplToImu);
      final acc = rotate3(globalRotation, globalAcc);
      final orientation = multiply3(
          multiply3(multiply3(globalRotation, r), _deviceToBone[i]),
          _localShift[i]);
      for (var j = 0; j < 3; j++) {
        result[i * 3 + j] = acc[j] / 30;
      }
      for (var j = 0; j < 9; j++) {
        result[30 + i * 9 + j] = orientation[j];
      }
    }
    return result;
  }
}
