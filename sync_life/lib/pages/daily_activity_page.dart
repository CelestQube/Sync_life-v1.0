import 'package:flutter/material.dart';
import '../mocap/motion_statistics.dart';
import '../mocap/user_session.dart';
import '../ui/activity_timeline.dart';
import '../ui/app_theme.dart';
import '../ui/motion_calendar.dart';
import '../ui/training_checkin.dart';
import '../ui/app_navigation.dart';

class DailyActivityPage extends StatefulWidget {
  const DailyActivityPage(
      {super.key,
      required this.date,
      this.loadDay = fetchMotionDay,
      this.loadWindow = fetchMotionWindow});
  final DateTime date;
  final MotionDateLoader loadDay;
  final MotionWindowLoader loadWindow;
  @override
  State<DailyActivityPage> createState() => _DailyActivityPageState();
}

class _DailyActivityPageState extends State<DailyActivityPage> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    UserSession.instance.addListener(_accountChanged);
    _load();
  }

  void _accountChanged() {
    if (!mounted) return;
    setState(() => _data = null);
    _load();
  }

  @override
  void dispose() {
    _epoch++;
    UserSession.instance.removeListener(_accountChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.loadDay(widget.date);
      if (mounted && epoch == _epoch) setState(() => _data = data);
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _data = null;
          _error =
              error is StateError ? error.message.toString() : '当天活动暂时无法加载，请重试';
        });
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final observed = activityNumber(_data?['observed_seconds']);
    final distribution =
        (_data?['posture_distribution'] as List? ?? []).whereType<Map>();
    final training = (_data?['training_days'] as List? ?? []).whereType<Map>();
    final report = _data?['daily_report'] as Map?;
    return Scaffold(
      appBar: AppBar(
          title: Text('${widget.date.month} 月 ${widget.date.day} 日的活动'),
          actions: [
            IconButton(
                tooltip: '刷新当天活动',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh))
          ]),
      body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(18),
              children: [
                if (_loading && _data == null)
                  const Center(child: CircularProgressIndicator())
                else if (_error != null)
                  EmptyStateCard(
                      icon: Icons.cloud_off_outlined,
                      title: '当天活动未能加载',
                      description: _error!,
                      action: OutlinedButton(
                          onPressed: _load, child: const Text('重试')))
                else ...[
                  if (!DateUtils.dateOnly(widget.date)
                      .isAfter(DateUtils.dateOnly(DateTime.now())))
                    Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                            onPressed: () => openAssistantDraft(context,
                                '请生成 ${motionDateKey(widget.date)} 的活动日报。'),
                            icon: const Icon(Icons.auto_awesome_outlined,
                                size: 16),
                            label: Text(
                                report == null ? '请小律总结这一天' : '和小律回顾这一天'))),
                  if (training.isNotEmpty)
                    AppCard(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('这天的训练',
                              style: Theme.of(context).textTheme.titleMedium),
                          for (final day in training) ...[
                            const SizedBox(height: 10),
                            Text(
                                (day['exercises'] as List? ?? [])
                                    .whereType<Map>()
                                    .map((item) => '${item['name']}')
                                    .join(' · '),
                                style: const TextStyle(
                                    color: AppColors.deep, height: 1.5)),
                            TrainingCheckin(
                                day: Map<String, dynamic>.from(day),
                                onChanged: _load),
                          ],
                        ])),
                  if (report != null)
                    AppCard(
                        color: AppColors.soft,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('小律的当天总结',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 10),
                              Text('${report['content']}',
                                  maxLines: 7,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      height: 1.6, color: AppColors.deep)),
                              TextButton(
                                  onPressed: () => showModalBottomSheet<void>(
                                      context: context,
                                      isScrollControlled: true,
                                      showDragHandle: true,
                                      builder: (_) => SafeArea(
                                          child: SizedBox(
                                              height: MediaQuery.sizeOf(context)
                                                      .height *
                                                  .7,
                                              child: SingleChildScrollView(
                                                  padding:
                                                      const EdgeInsets.all(20),
                                                  child: SelectableText(
                                                      '${report['content']}',
                                                      style: const TextStyle(
                                                          height: 1.7)))))),
                                  child: const Text('阅读完整总结')),
                              const Text('显示已生成的总结，打开页面不会再次生成。',
                                  style: TextStyle(
                                      color: AppColors.muted, fontSize: 11)),
                            ])),
                  if (observed == 0)
                    const EmptyStateCard(
                        icon: Icons.event_busy_outlined,
                        title: '当天暂无活动记录',
                        description: '这一天没有保留的衣物观测记录，训练打卡仍可单独记录。')
                  else ...[
                    AppCard(
                        color: AppColors.soft,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(motionDateKey(widget.date),
                                  style: const TextStyle(
                                      color: AppColors.deep, fontSize: 13)),
                              const SizedBox(height: 10),
                              Text('记录了 ${activityDuration(observed)}',
                                  style: const TextStyle(
                                      fontSize: 23,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.deep)),
                              const SizedBox(height: 7),
                              Text(
                                  '估算步数 ${activityNumber(_data?['steps']).round()} 步'),
                              const SizedBox(height: 8),
                              const Text('只统计衣物连接期间实际记录的活动',
                                  style: TextStyle(
                                      color: AppColors.muted, fontSize: 12)),
                            ])),
                    AppCard(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('活动分布',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 10),
                          for (final row in distribution)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 7),
                                child: Row(children: [
                                  Expanded(child: Text('${row['name']}')),
                                  Text(
                                      activityDuration(
                                          activityNumber(row['seconds'])),
                                      style: const TextStyle(
                                          color: AppColors.deep))
                                ])),
                        ])),
                    if (_data?['detail_available'] == false)
                      const AppCard(
                          child: Text('30 天以前保留每日总量和各动作时长，具体时间段已合并。',
                              style: TextStyle(
                                  color: AppColors.muted, height: 1.6)))
                    else
                      ActivityTimeline(
                          date: widget.date,
                          slots: (_data?['activity_slots'] as List? ?? [])
                              .whereType<Map>()
                              .toList(),
                          loadWindow: widget.loadWindow),
                  ],
                ],
              ])),
    );
  }
}
