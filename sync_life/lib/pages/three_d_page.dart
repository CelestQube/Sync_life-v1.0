import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import '../mocap/mocap_service.dart';
import 'mocap_devices_page.dart';
import '../mocap/posture_status.dart';
import '../ui/app_theme.dart';

class ThreeDPage extends StatefulWidget {
  const ThreeDPage({super.key, this.active = true});
  final bool active;
  @override
  ThreeDPageState createState() => ThreeDPageState();
}

class ThreeDPageState extends State<ThreeDPage> {
  final _service = MocapService.instance;
  UnityWidgetController? _unity;
  StreamSubscription<Float32List>? _poses;
  Timer? _probe;
  bool _ready = false, _sending = false;
  String? _error;
  int _sent = 0, _applied = 0;

  @override
  void initState() {
    super.initState();
    _service.initialize();
    _poses = _service.poses.listen(_sendPose);
  }

  @override
  void dispose() {
    _probe?.cancel();
    _poses?.cancel();
    _unity?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ThreeDPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) _updateVisibility();
  }

  Future<void> _updateVisibility() async {
    try {
      if (widget.active) {
        await _unity?.resume();
        final pose = _service.latestPose;
        if (pose != null) await _sendPose(pose);
      } else {
        // Only rendering pauses; app-scoped BLE inference/recording continues.
        await _unity?.pause();
      }
    } catch (_) {/* The initial Unity handshake will retry after creation. */}
  }

  void onUnityCreated(UnityWidgetController controller) {
    _unity = controller;
    if (!widget.active) _updateVisibility();
    _probe?.cancel();
    _probe = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _ready) {
        timer.cancel();
        return;
      }
      try {
        await controller.postMessage('SyncLifeMoCapBridge', 'Ping', '');
      } catch (e) {
        if (mounted) setState(() => _error = 'Unity 通信失败：$e');
      }
      if (timer.tick >= 20 && mounted && !_ready) {
        setState(
            () => _error = 'Unity 尚未确认动捕接口。请确认 Android Unity 导出库已包含手机直连脚本。');
        timer.cancel();
      }
    });
  }

  void onUnityMessage(dynamic message) {
    try {
      final data = jsonDecode(message.toString()) as Map<String, dynamic>;
      if (!mounted) return;
      if (data['type'] == 'mocap_ready' &&
          data['protocol'] == 1 &&
          data['jointCount'] == 24) {
        setState(() {
          _ready = true;
          _error = null;
        });
        final pose = _service.latestPose;
        if (pose != null) _sendPose(pose);
      } else if (data['type'] == 'mocap_applied') {
        setState(() => _applied = (data['frames'] as num).toInt());
      } else if (data['type'] == 'mocap_error') {
        setState(() => _error = data['message'] as String);
      }
    } on FormatException {
      /* Other Unity messages belong to the existing plugin. */
    } on TypeError {/* Ignore unrelated plugin messages. */}
  }

  Future<void> _sendPose(Float32List pose) async {
    if (!widget.active || !_ready || _unity == null || _sending) return;
    _sending = true;
    try {
      await _unity!.postMessage('SyncLifeMoCapBridge', 'ReceivePose',
          jsonEncode({'pose': pose.toList()}));
      if (mounted) setState(() => _sent++);
    } catch (e) {
      if (mounted) {
        setState(() {
          _ready = false;
          _error = '发送姿态失败：$e';
        });
      }
    } finally {
      _sending = false;
    }
  }

  void _openDevices() => Navigator.push(context,
      MaterialPageRoute<void>(builder: (_) => const MocapDevicesPage()));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('动作跟随'), actions: [
          IconButton(
              tooltip: '连接衣物',
              icon: const Icon(Icons.bluetooth_rounded),
              onPressed: _openDevices),
        ]),
        body: Column(children: [
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  // Keep the camera wide enough to show both outstretched arms.
                  child: Center(
                      child: AspectRatio(
                          aspectRatio: .82,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: Stack(fit: StackFit.expand, children: [
                              UnityWidget(
                                  onUnityCreated: onUnityCreated,
                                  onUnityUnloaded: () {
                                    if (mounted) setState(() => _ready = false);
                                  },
                                  onUnityMessage: onUnityMessage,
                                  useAndroidViewSurface: true,
                                  fullscreen: false),
                              if (!_ready)
                                IgnorePointer(
                                    child: Center(
                                        child: Container(
                                  margin: const EdgeInsets.all(24),
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                      color: AppColors.deep,
                                      borderRadius: BorderRadius.circular(16)),
                                  child: Text(
                                      _error != null
                                          ? '人物暂时未能打开，请重新进入此页'
                                          : '正在准备人物…',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Colors.white, height: 1.5)),
                                ))),
                              Positioned(
                                  top: 12,
                                  left: 12,
                                  child: StatusPill(_ready ? '人物已准备好' : '正在准备',
                                      warm: !_ready)),
                            ]),
                          ))))),
          SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .38),
                child: SingleChildScrollView(
                    child: AnimatedBuilder(
                        animation: _service,
                        builder: (context, _) => Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(18, 14, 18, 10),
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                        _service.calibrating
                                            ? '正在重新校准'
                                            : _service.calibrated
                                                ? '跟随你的每一个动作'
                                                : '连接衣物，开始跟随',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    const SizedBox(height: 5),
                                    Text(
                                        _service.calibrating ||
                                                _service.calibrated
                                            ? _service.status
                                            : '打开上衣和裤子，连接后站直、平举双臂完成校准。',
                                        style: const TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 13,
                                            height: 1.5)),
                                    if (_service.calibrated)
                                      const Padding(
                                          padding: EdgeInsets.only(top: 8),
                                          child: PostureStatus()),
                                    if (_service.error != null)
                                      const Padding(
                                          padding: EdgeInsets.only(top: 6),
                                          child: Text('衣物连接遇到问题，请打开连接页面查看。',
                                              style: TextStyle(
                                                  color: AppColors.danger,
                                                  fontSize: 13))),
                                    const SizedBox(height: 12),
                                    Row(children: [
                                      Expanded(
                                          child: FilledButton.icon(
                                              onPressed: _openDevices,
                                              icon: const Icon(
                                                  Icons.bluetooth_connected,
                                                  size: 19),
                                              label: const Text('衣物连接'))),
                                      const SizedBox(width: 10),
                                      Expanded(
                                          child: OutlinedButton.icon(
                                        onPressed: _service.bothReady &&
                                                !_service.calibrating
                                            ? _service.recalibrate
                                            : null,
                                        icon: const Icon(
                                            Icons.restart_alt_rounded,
                                            size: 19),
                                        label: Text(_service.calibrating
                                            ? '${_service.calibrationSeconds > 0 ? '${_service.calibrationSeconds} 秒' : '准备中'}…'
                                            : '重新校准'),
                                      )),
                                    ]),
                                    ExpansionTile(
                                      tilePadding: EdgeInsets.zero,
                                      dense: true,
                                      shape: const Border(),
                                      collapsedShape: const Border(),
                                      title: const Text('连接详情',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: AppColors.muted)),
                                      children: [
                                        Align(
                                            alignment: Alignment.centerLeft,
                                            child: SelectableText(
                                                '画面连接：${_ready ? '已就绪' : '等待中'}\n已发送 $_sent 帧 · 已接收 $_applied 帧\n动作计算：${_service.poseFrames} 帧 · ${_service.inferenceMs.toStringAsFixed(1)} ms\n自动校正：${_service.driftCorrections} 次 · 关节运动约束已启用'
                                                '${_service.enhancementError == null ? '' : '\n${_service.enhancementError}'}'
                                                '${_error == null ? '' : '\n$_error'}${_service.error == null ? '' : '\n${_service.error}'}',
                                                style: const TextStyle(
                                                    fontSize: 12,
                                                    color: AppColors.muted,
                                                    height: 1.6)))
                                      ],
                                    ),
                                  ]),
                            ))),
              )),
        ]),
      );
}
