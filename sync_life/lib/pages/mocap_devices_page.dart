import 'package:flutter/material.dart';
import '../mocap/imu_protocol.dart';
import '../mocap/mocap_service.dart';
import '../mocap/posture_status.dart';
import '../ui/app_theme.dart';

class MocapDevicesPage extends StatefulWidget {
  const MocapDevicesPage({super.key});
  @override
  State<MocapDevicesPage> createState() => _MocapDevicesPageState();
}

class _MocapDevicesPageState extends State<MocapDevicesPage> {
  final service = MocapService.instance;
  late final Map<GarmentRole, TextEditingController> addresses;
  @override
  void initState() {
    super.initState();
    service.initialize();
    addresses = {
      GarmentRole.upper: TextEditingController(
          text:
              service.links[GarmentRole.upper]!.address ?? 'E7:3F:41:95:B3:7C'),
      GarmentRole.lower: TextEditingController(
          text:
              service.links[GarmentRole.lower]!.address ?? 'C1:24:88:0D:A3:2E'),
    };
  }

  @override
  void dispose() {
    for (final controller in addresses.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String label(GarmentRole role) => role == GarmentRole.upper ? '上衣' : '裤子';

  Widget garmentCard(GarmentRole role) {
    final link = service.links[role]!;
    final state = link.ready
        ? '已连接'
        : link.state == 'connecting'
            ? '连接中'
            : '未连接';
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.checkroom_outlined,
                      color: AppColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(label(role),
                          style: Theme.of(context).textTheme.titleMedium)),
                  StatusPill(state, warm: !link.ready),
                ]),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: const Text('设备地址与详情',
                      style: TextStyle(fontSize: 12, color: AppColors.muted)),
                  children: [
                    TextField(
                        controller: addresses[role],
                        enabled: link.state == 'disconnected',
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: '蓝牙设备地址')),
                    const SizedBox(height: 8),
                    Text(
                        '已接收 ${link.packets} 次 · 异常 ${link.decoder.rejectedPackets} 次',
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(children: [
                  FilledButton(
                      onPressed: link.state == 'disconnected'
                          ? () => service.connect(
                              role, addresses[role]!.text.trim().toUpperCase())
                          : null,
                      child: const Text('连接')),
                  const SizedBox(width: 12),
                  TextButton(
                      onPressed: link.state != 'disconnected'
                          ? () => service.disconnect(role)
                          : null,
                      child: const Text('断开')),
                ]),
              ],
            )));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final devices = service.devices.values.toList()
          ..sort((a, b) {
            final aWear = a.name.toLowerCase().contains('smartwear'),
                bWear = b.name.toLowerCase().contains('smartwear');
            return aWear != bWear ? (aWear ? -1 : 1) : b.rssi.compareTo(a.rssi);
          });
        return Scaffold(
          appBar: AppBar(title: const Text('连接衣物')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            const AppCard(
                color: AppColors.soft,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('两步，开始记录',
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: AppColors.deep)),
                      SizedBox(height: 10),
                      Text('1  开启蓝牙和衣物电源，连接上衣、裤子。\n2  站直并平举双臂，点击下方校准。',
                          style: TextStyle(color: AppColors.deep, height: 1.8)),
                      SizedBox(height: 8),
                      Text('连接前，请先断开衣物与电脑的连接。',
                          style:
                              TextStyle(color: AppColors.muted, fontSize: 12)),
                    ])),
            garmentCard(GarmentRole.upper),
            garmentCard(GarmentRole.lower),
            Text(service.status,
                style: Theme.of(context).textTheme.titleMedium),
            const PostureStatus(),
            if (service.error != null)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: InfoBanner(service.error!, warning: true)),
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: service.bothReady && !service.calibrating
                    ? service.calibrate
                    : null,
                icon: const Icon(Icons.accessibility_new),
                label:
                    Text(service.calibrating ? '正在校准，请保持姿势…' : '站直、平举双臂并校准')),
            if (service.calibrated)
              OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回查看动作')),
            const SizedBox(height: 20),
            OutlinedButton.icon(
                onPressed: service.scanning ? null : service.scan,
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(service.scanning ? '扫描中…' : '扫描附近设备')),
            if (!service.scanning && devices.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('找不到衣物？扫描附近设备后，选择对应的上衣或裤子。',
                      style: TextStyle(color: AppColors.muted, fontSize: 13))),
            for (final device in devices)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(device.name.isEmpty ? '未命名设备' : device.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          Text(device.address,
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 12)),
                          Wrap(spacing: 8, children: [
                            for (final role in GarmentRole.values)
                              TextButton(
                                  onPressed: service.links[role]!.state ==
                                          'disconnected'
                                      ? () {
                                          addresses[role]!.text =
                                              device.address;
                                          service.connect(role, device.address);
                                        }
                                      : null,
                                  child: Text('连接为${label(role)}'))
                          ]),
                        ],
                      ))),
          ]),
        );
      });
}
