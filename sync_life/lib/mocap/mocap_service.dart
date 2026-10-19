import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'imu_protocol.dart';
import 'posture_classifier.dart';
import 'posture_sync.dart';
import 'drift_correction.dart';

class MocapDevice {
  const MocapDevice(this.address, this.name, this.rssi);
  final String address, name;
  final int rssi;
}

class GarmentLink {
  String? address;
  String state = 'disconnected';
  ImuPacketDecoder decoder = ImuPacketDecoder();
  final List<ImuFrame> recent = [];
  DateTime? receivedAt;
  int packets = 0;
  bool get ready => state == 'ready';
  bool get fresh =>
      ready &&
      receivedAt != null &&
      DateTime.now().difference(receivedAt!).inMilliseconds < 500;
  void clearData() {
    decoder = ImuPacketDecoder();
    recent.clear();
    receivedAt = null;
    packets = 0;
  }
}

/// Shared between the profile device panel and Unity page; no server or PC socket.
class MocapService extends ChangeNotifier with WidgetsBindingObserver {
  MocapService._();
  @visibleForTesting
  MocapService.forTesting();
  static final instance = MocapService._();
  static const _methods = MethodChannel('sync_life/mocap');
  static const _events = EventChannel('sync_life/mocap_events');
  final devices = <String, MocapDevice>{};
  final links = {for (final role in GarmentRole.values) role: GarmentLink()};
  final _poses = StreamController<Float32List>.broadcast();
  Stream<Float32List> get poses => _poses.stream;
  final _classifier = PostureClassifier();
  final _drift = DriftCorrection();
  Float32List? latestPose;
  int driftCorrections = 0;
  String? enhancementError;
  Duration? _previousInference;
  final Stopwatch _captureClock = Stopwatch();
  DateTime? _captureStart;
  PostureEstimate? posture;
  bool scanning = false, calibrating = false, calibrated = false;
  int calibrationSeconds = 0;
  String? error;
  String status = '请连接上衣和裤子';
  int poseFrames = 0;
  double inferenceMs = 0;
  bool get bothReady => links.values.every((link) => link.ready);
  bool get receiving => links.values.every((link) => link.fresh);
  bool _initialized = false,
      _busy = false,
      _background = false,
      _disposed = false;
  int _generation = 0;
  int _lastUpperPacket = -1, _lastLowerPacket = -1;
  MocapCalibration? _calibration;
  Timer? _ticker;
  StreamSubscription<dynamic>? _eventSubscription;

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    // Tests use an isolated service and never initialize the network outbox.
    if (identical(this, instance)) {
      unawaited(PostureSyncService.instance.initialize());
    }
    WidgetsBinding.instance.addObserver(this);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      error = '手机直连目前支持 Android';
      return;
    }
    _eventSubscription = _events
        .receiveBroadcastStream()
        .listen(_event, onError: (Object e) => _failed(e));
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) => _tick());
  }

  void _failed(Object e) {
    error = e is PlatformException ? (e.message ?? e.code) : e.toString();
    notifyListeners();
  }

  void _event(dynamic value) {
    final event = Map<String, dynamic>.from(value as Map);
    switch (event['type']) {
      case 'device':
        final address = event['address'] as String;
        devices[address] =
            MocapDevice(address, event['name'] as String, event['rssi'] as int);
        break;
      case 'scan':
        scanning = event['active'] as bool;
        break;
      case 'error':
        error = event['message'] as String;
        break;
      case 'connection':
        final role = GarmentRole.values.byName(event['role'] as String);
        final link = links[role]!;
        link.state = event['state'] as String;
        if (!link.ready) {
          link.clearData();
          _invalidate();
          status = link.state == 'connecting'
              ? '正在连接${role == GarmentRole.upper ? '上衣' : '裤子'}'
              : '设备已断开，请重新连接并校准';
        } else {
          status = bothReady ? '请保持 T 字站姿并校准' : '请连接另一件衣物';
        }
        if (event['message'] != null) error = event['message'] as String;
        break;
      case 'packet':
        final link = links[GarmentRole.values.byName(event['role'] as String)]!;
        if (!link.ready) return;
        final frames = link.decoder.add(event['data'] as Uint8List,
            GarmentRole.values.byName(event['role'] as String));
        if (frames.isEmpty) return;
        link.recent.addAll(frames);
        if (link.recent.length > 60) {
          link.recent.removeRange(0, link.recent.length - 60);
        }
        link.receivedAt = DateTime.now();
        link.packets += frames.length;
        return; // Refresh the status panel at the processing tick, not every BLE callback.
    }
    notifyListeners();
  }

  void _invalidate() {
    _generation++;
    _calibration = null;
    calibrated = false;
    _lastUpperPacket = _lastLowerPacket = -1;
    _classifier.reset();
    _drift.reset();
    _previousInference = null;
    latestPose = null;
    posture = null;
    _captureClock.stop();
    if (identical(this, instance)) PostureSyncService.instance.interrupt();
  }

  Future<void> scan() async {
    initialize();
    error = null;
    devices.clear();
    try {
      if (await _methods.invokeMethod<bool>('permissions') != true) {
        throw StateError('需要允许附近设备/蓝牙权限');
      }
      await _methods.invokeMethod<void>('scan');
    } catch (e) {
      _failed(e);
    }
    notifyListeners();
  }

  Future<void> connect(GarmentRole role, String address) async {
    initialize();
    error = null;
    try {
      if (await _methods.invokeMethod<bool>('permissions') != true) {
        throw StateError('需要允许蓝牙权限');
      }
      await _methods.invokeMethod<void>(
          'connect', {'role': role.name, 'address': address});
      links[role]!.address = address;
    } catch (e) {
      _failed(e);
    }
    notifyListeners();
  }

  Future<void> disconnect(GarmentRole role) async {
    try {
      await _methods.invokeMethod<void>('disconnect', {'role': role.name});
    } catch (e) {
      _failed(e);
    }
  }

  Future<void> calibrate() async {
    if (_disposed || calibrating || !bothReady || _background) return;
    _invalidate();
    final generation = _generation;
    calibrating = true;
    error = null;
    status = '正在暂停当前动作，请准备站直、平举双臂';
    notifyListeners();
    try {
      await _methods.invokeMethod<void>('prepare');
      // The native single executor first finishes any old inference, then clears
      // its recurrent state. Old Dart results are rejected by _generation.
      await _methods.invokeMethod<void>('reset');
      if (_disposed || _generation != generation || _background) return;
      // Collect new frames, rather than using movements from before the user pressed calibrate.
      for (final link in links.values) {
        link.recent.clear();
      }
      for (var seconds = 3; seconds > 0; seconds--) {
        if (_generation != generation || _background) {
          throw StateError('校准中断，请重新连接或回到前台');
        }
        calibrationSeconds = seconds;
        status = '保持站直、双臂平举，$seconds 秒后完成校准';
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (_generation != generation ||
          !receiving ||
          links.values.any((link) => link.recent.length < 30)) {
        throw StateError('衣物数据不足或已中断，请检查设备后重新校准');
      }
      final upper =
          ImuFrame(0, averageFrames(links[GarmentRole.upper]!.recent));
      final lower =
          ImuFrame(0, averageFrames(links[GarmentRole.lower]!.recent));
      final calibration = MocapCalibration(selectModelSensors(upper, lower));
      if (_generation != generation || !receiving || _background) {
        throw StateError('校准中断，请重试');
      }
      _calibration = calibration;
      calibrated = true;
      _captureStart = DateTime.now().toUtc();
      _captureClock
        ..reset()
        ..start();
      if (identical(this, instance)) PostureSyncService.instance.beginCapture();
      poseFrames = 0;
      driftCorrections = 0;
      enhancementError = null;
      status = '校准完成，正在等待姿态';
    } catch (e) {
      if (!_disposed && generation == _generation) {
        _failed(e);
        status = '校准未完成，请站直、平举双臂后重试';
      }
    } finally {
      calibrating = false;
      calibrationSeconds = 0;
      if (!_disposed) notifyListeners();
    }
  }

  /// Stop the previous capture without dropping the BLE stream needed to calibrate.
  Future<void> recalibrate() => calibrate();

  Future<void> _tick() async {
    if (_background || calibrating) return;
    if (!receiving) {
      if (calibrated) {
        _invalidate();
        status = '数据中断，请检查连接后重新校准';
      }
      if (bothReady) notifyListeners();
      return;
    }
    if (_busy || _calibration == null) {
      if (bothReady) notifyListeners();
      return;
    }
    final upper = links[GarmentRole.upper]!, lower = links[GarmentRole.lower]!;
    // Feed each latest pair at most once; do not keep advancing LSTM on frozen input.
    if (upper.packets == _lastUpperPacket ||
        lower.packets == _lastLowerPacket) {
      return;
    }
    if (upper.receivedAt!.difference(lower.receivedAt!).inMilliseconds.abs() >
        100) {
      return;
    }
    _lastUpperPacket = upper.packets;
    _lastLowerPacket = lower.packets;
    _busy = true;
    final generation = _generation;
    final clock = Stopwatch()..start();
    try {
      final input = _calibration!
          .transform(selectModelSensors(upper.recent.last, lower.recent.last));
      final elapsed = _captureClock.elapsed;
      final dt = _previousInference == null
          ? 1 / 30
          : (elapsed - _previousInference!).inMicroseconds / 1e6;
      _previousInference = elapsed;
      final pose = await _methods
          .invokeMethod<Float32List>('infer', {'input': input, 'dt': dt});
      if (generation != _generation || _background) return;
      if (pose == null || pose.length != 72 || pose.any((v) => !v.isFinite)) {
        throw StateError('姿态输出无效');
      }
      inferenceMs = clock.elapsedMicroseconds / 1000;
      poseFrames++;
      final observedAt = _captureStart!.add(_captureClock.elapsed);
      posture = _classifier.add(pose, input, observedAt);
      if (identical(this, instance)) {
        PostureSyncService.instance.record(posture!);
      }
      status = '正在接收动作';
      latestPose = pose;
      _poses.add(pose);
      notifyListeners();
      _drift.add(input);
      final correction = _drift.request(observedAt);
      if (correction != null) {
        try {
          final shifts = await _methods.invokeMethod<Float32List>(
              'calibrateDrift', {'history': correction.history});
          if (generation != _generation || _background) return;
          if (shifts == null) throw StateError('自动校正未返回数据');
          _calibration!.applyDrift(shifts, correction.trigger);
          _drift.applied();
          driftCorrections++;
          enhancementError = null;
        } catch (e) {
          if (generation == _generation) {
            enhancementError = '自动校正暂不可用：$e';
            _drift.reset();
          }
        }
      }
    } catch (e) {
      if (generation == _generation) {
        _invalidate();
        status = '推理失败，请重新校准';
        _failed(e);
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidate();
    _background = true;
    _ticker?.cancel();
    _eventSubscription?.cancel();
    _poses.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission dialogs / notification shade briefly lose focus without
    // leaving the app; they must not discard an otherwise live calibration.
    if (state == AppLifecycleState.inactive) return;
    _background = state != AppLifecycleState.resumed;
    if (_background && (calibrated || calibrating)) {
      _invalidate();
      status = '已暂停，回到前台后请重新校准';
      notifyListeners();
    }
  }
}
