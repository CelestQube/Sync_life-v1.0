import 'package:flutter/material.dart';
import '../mocap/motion_statistics.dart';
import '../mocap/user_session.dart';
import 'app_theme.dart';

typedef MotionWindowLoader = Future<Map<String, dynamic>> Function(
    DateTime day, int startMinute);
double activityNumber(dynamic value) => double.tryParse('$value') ?? 0;
String activityDuration(double seconds) => seconds <= 0
    ? '0 分钟'
    : seconds < 60
        ? '不足 1 分钟'
        : seconds < 3600
            ? '${(seconds / 60).round()} 分钟'
            : '${(seconds / 3600).toStringAsFixed(1)} 小时';
String minuteLabel(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
Color activityColor(dynamic hex) => Color(
    int.tryParse('FF${'$hex'.replaceAll('#', '')}', radix: 16) ?? 0xFF729B8E);

class ActivityTimeline extends StatelessWidget {
  const ActivityTimeline(
      {super.key,
      required this.date,
      required this.slots,
      this.loadWindow = fetchMotionWindow});
  final DateTime date;
  final List<Map> slots;
  final MotionWindowLoader loadWindow;

  @override
  Widget build(BuildContext context) => AppCard(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('一天的活动', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Text('点选时间段，查看每 5 分钟的活动；留白表示未采集。',
            style:
                TextStyle(color: AppColors.muted, fontSize: 12, height: 1.5)),
        const SizedBox(height: 16),
        GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: slots.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: MediaQuery.sizeOf(context).width < 360 ||
                        MediaQuery.textScalerOf(context).scale(10) > 13
                    ? 2
                    : 3,
                mainAxisSpacing: 9,
                crossAxisSpacing: 9,
                mainAxisExtent:
                    MediaQuery.textScalerOf(context).scale(10) > 13 ? 88 : 76),
            itemBuilder: (context, index) {
              final slot = slots[index], start = slot['start_minute'] as int;
              final states =
                  (slot['states'] as List? ?? []).whereType<Map>().toList();
              final observed = activityNumber(slot['observed_seconds']);
              final label = '${minuteLabel(start)}–${minuteLabel(start + 120)}';
              return Semantics(
                  label: '$label，${observed > 0 ? '有活动，点击查看' : '未采集'}',
                  button: observed > 0,
                  child: Material(
                      color: observed > 0
                          ? AppColors.soft
                          : const Color(0xFFF2F5F3),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                          key: ValueKey('activity-slot-$start'),
                          borderRadius: BorderRadius.circular(10),
                          onTap: observed <= 0
                              ? null
                              : () => showModalBottomSheet<void>(
                                  context: context,
                                  isScrollControlled: true,
                                  showDragHandle: true,
                                  builder: (_) => _ActivityWindow(
                                      date: date,
                                      start: start,
                                      load: loadWindow)),
                          child: Padding(
                              padding: const EdgeInsets.all(9),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(label,
                                        style: const TextStyle(
                                            fontSize: 10,
                                            color: AppColors.deep)),
                                    _ActivityBar(states: states, total: 7200),
                                    Text(
                                        observed > 0
                                            ? '记录 ${activityDuration(observed)}'
                                            : '未采集',
                                        style: const TextStyle(
                                            fontSize: 10,
                                            color: AppColors.muted))
                                  ])))));
            }),
        const SizedBox(height: 12),
        const Text('慢走计入行走，慢跑计入奔跑；点开后仍分别展示。',
            style: TextStyle(color: AppColors.muted, fontSize: 11)),
      ]));
}

class _ActivityBar extends StatelessWidget {
  const _ActivityBar({required this.states, required this.total});
  final List<Map> states;
  final double total;
  @override
  Widget build(BuildContext context) {
    final observed = states.fold<double>(
        0, (sum, row) => sum + activityNumber(row['seconds']));
    return ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
            height: 6,
            child: Row(children: [
              for (final row in states)
                if (activityNumber(row['seconds']) > 0)
                  Expanded(
                      flex: (activityNumber(row['seconds']) * 100)
                          .round()
                          .clamp(1, 100000000),
                      child: ColoredBox(
                          color: activityColor(row['color']),
                          child: const SizedBox.expand())),
              if (total > observed)
                Expanded(
                    flex:
                        ((total - observed) * 100).round().clamp(1, 100000000),
                    child: const ColoredBox(
                        color: Color(0xFFE0E7E3), child: SizedBox.expand())),
            ])));
  }
}

class _ActivityWindow extends StatefulWidget {
  const _ActivityWindow(
      {required this.date, required this.start, required this.load});
  final DateTime date;
  final int start;
  final MotionWindowLoader load;
  @override
  State<_ActivityWindow> createState() => _ActivityWindowState();
}

class _ActivityWindowState extends State<_ActivityWindow> {
  late Future<Map<String, dynamic>> _future =
      widget.load(widget.date, widget.start);
  @override
  void initState() {
    super.initState();
    UserSession.instance.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (mounted) {
      setState(() => _future = widget.load(widget.date, widget.start));
    }
  }

  @override
  void dispose() {
    UserSession.instance.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
      child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                    '${minuteLabel(widget.start)}–${minuteLabel(widget.start + 120)} 的活动',
                    style: Theme.of(context).textTheme.titleMedium)),
            Expanded(
                child: FutureBuilder<Map<String, dynamic>>(
                    future: _future,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return Center(
                            child: TextButton(
                                onPressed: () => setState(() {
                                      _future = widget.load(
                                          widget.date, widget.start);
                                    }),
                                child: const Text('未能加载，点击重试')));
                      }
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final rows = (snapshot.data!['buckets'] as List)
                          .whereType<Map>()
                          .toList();
                      return ListView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            final states = (row['states'] as List)
                                .whereType<Map>()
                                .toList();
                            return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          '${minuteLabel(row['start_minute'] as int)}–${minuteLabel(row['end_minute'] as int)}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: AppColors.muted)),
                                      const SizedBox(height: 7),
                                      _ActivityBar(states: states, total: 300),
                                      const SizedBox(height: 7),
                                      Text(
                                          states.isEmpty
                                              ? '未采集'
                                              : states
                                                  .map((state) =>
                                                      '${state['name']} ${activityDuration(activityNumber(state['seconds']))}')
                                                  .join(' · '),
                                          style: const TextStyle(
                                              color: AppColors.deep,
                                              fontSize: 13,
                                              height: 1.5)),
                                    ]));
                          });
                    })),
          ])));
}
