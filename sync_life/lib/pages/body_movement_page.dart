import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/training_plan_storage.dart';
import '../mocap/motion_statistics.dart';
import '../mocap/user_session.dart';
import '../ui/app_theme.dart';
import '../ui/motion_calendar.dart';
import 'daily_activity_page.dart';
import 'mocap_devices_page.dart';

enum TimeRange { day, week, month }

class BodyMovementPage extends StatefulWidget {
  final Function(String)? onGenerateReport;
  final Future<Map<String, dynamic>> Function(String) loadStatistics;
  const BodyMovementPage(
      {super.key,
      this.active = true,
      this.onGenerateReport,
      this.loadStatistics = fetchMotionStatistics,
      this.loadCalendar = fetchMotionCalendar,
      this.loadDay = fetchMotionDay});
  final MotionDateLoader loadCalendar, loadDay;
  final bool active;
  @override
  State<BodyMovementPage> createState() => _BodyMovementPageState();
}

class _BodyMovementPageState extends State<BodyMovementPage> {
  TimeRange _selectedRange = TimeRange.day;
  Map<String, dynamic>? _data, _trainingPlan;
  bool _loading = false;
  String? _error;
  Timer? _refresh;
  int _requestVersion = 0, _planVersion = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
    _loadPlan();
    UserSession.instance.addListener(_accountChanged);
    _refresh = Timer.periodic(const Duration(seconds: 15), (_) {
      if (widget.active && !_loading && UserSession.instance.authenticated) {
        _fetch();
      }
    });
  }

  @override
  void didUpdateWidget(covariant BodyMovementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _fetch();
      _loadPlan();
    }
  }

  void _accountChanged() {
    if (!mounted) return;
    setState(() {
      _data = null;
      _trainingPlan = null;
    });
    _fetch();
    _loadPlan();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    UserSession.instance.removeListener(_accountChanged);
    super.dispose();
  }

  Future<void> _loadPlan() async {
    final version = ++_planVersion;
    try {
      final plan = await TrainingPlanStorage.loadTrainingPlan();
      if (mounted && version == _planVersion) {
        setState(() => _trainingPlan = plan);
      }
    } catch (_) {/* The overview stays usable if a plan is unavailable. */}
  }

  Future<void> _fetch() async {
    if (!mounted) return;
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.loadStatistics(_selectedRange.name);
      if (mounted && version == _requestVersion) setState(() => _data = data);
    } catch (error) {
      if (mounted && version == _requestVersion) {
        setState(() {
          _data = null;
          _error = error is StateError
              ? error.message.toString()
              : '暂时无法加载，请检查网络后重试';
        });
      }
    } finally {
      if (mounted && version == _requestVersion) {
        setState(() => _loading = false);
      }
    }
  }

  double _number(dynamic value) => double.tryParse('$value') ?? 0;
  String _duration(double seconds) {
    if (seconds < 60) return '${seconds.round()} 秒';
    if (seconds < 3600) return '${(seconds / 60).round()} 分钟';
    return '${(seconds / 3600).toStringAsFixed(1)} 小时';
  }

  bool get _hasRecords => _number(_data?['observed_seconds']) > 0;
  void _connect() => Navigator.push(context,
      MaterialPageRoute<void>(builder: (_) => const MocapDevicesPage()));

  Future<void> _openPlan() async {
    await Navigator.pushNamed(context, '/training_plan');
    if (mounted) _loadPlan();
  }

  void _report() {
    final type = {
      TimeRange.day: '日报',
      TimeRange.week: '周报',
      TimeRange.month: '月报'
    }[_selectedRange];
    widget.onGenerateReport?.call('请生成我的$type，使用服务器实际采集的数据；用于分享，不包含个人健康隐私。');
  }

  Widget _planCard() {
    final days = (_trainingPlan?['plan'] as List? ?? []).whereType<Map>();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final matches = days.where((day) => day['date'] == today);
    final day = matches.isEmpty ? null : matches.first;
    final exercises =
        (day?['exercises'] as List? ?? []).whereType<Map>().toList();
    return AppCard(
        color: AppColors.deep,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.event_available_outlined,
                color: Color(0xFFB9DAD0), size: 21),
            const SizedBox(width: 9),
            Expanded(
                child: Text(day != null ? '今天的安排' : '我的训练计划',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600))),
            const StatusPill('按自己的节奏'),
          ]),
          const SizedBox(height: 14),
          Text(
              day == null
                  ? (_trainingPlan == null ? '给今天留一点活动时间' : '今天没有安排训练')
                  : exercises.isEmpty
                      ? '今天好好休息'
                      : exercises.take(2).map((e) => e['name']).join(' · '),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  height: 1.4,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 7),
          Text(
              day != null && exercises.isNotEmpty
                  ? '${exercises.first['start_time'] ?? ''} 开始${exercises.length > 2 ? ' · 共 ${exercises.length} 项' : ''}'
                  : '按自己的节奏，照顾好身体。',
              style: const TextStyle(color: Color(0xFFC6DDD6), height: 1.5)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF739F94)),
                  minimumSize: const Size(0, 42)),
              onPressed: _openPlan,
              icon: const Icon(Icons.arrow_forward, size: 17),
              label: Text(_trainingPlan == null ? '安排训练' : '查看计划')),
        ]));
  }

  Widget _metric(IconData icon, String label, String value, String note) =>
      Expanded(
          child: AppCard(
              padding: const EdgeInsets.all(15),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(icon, color: AppColors.primary, size: 18),
                      const SizedBox(width: 7),
                      Expanded(
                          child: Text(label,
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 13)))
                    ]),
                    const SizedBox(height: 10),
                    Text(value,
                        style: const TextStyle(
                            fontSize: 23,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                            color: AppColors.deep)),
                    const SizedBox(height: 5),
                    Text(note,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.muted)),
                  ])));

  static const _postureColors = [
    Color(0xFF237C70),
    Color(0xFF7EA99C),
    Color(0xFFC4D8CF),
    Color(0xFF4A9C8F),
    Color(0xFF194F4D),
    Color(0xFFD6BC92)
  ];

  Widget _distribution() {
    final rows = (_data?['posture_distribution'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final total =
        rows.fold<double>(0, (sum, row) => sum + _number(row['value']));
    return AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('活动分布', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      const Text('只统计衣物连接期间记录到的活动',
          style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SizedBox(height: 16),
      if (total > 0) ...[
        ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Row(children: [
              for (var i = 0; i < rows.length; i++)
                if (_number(rows[i]['value']) > 0)
                  Expanded(
                      flex: (_number(rows[i]['value']) / total * 10000)
                          .round()
                          .clamp(1, 10000),
                      child: Container(
                          height: 14,
                          color: _postureColors[i % _postureColors.length])),
            ])),
        const SizedBox(height: 16),
      ],
      Wrap(spacing: 20, runSpacing: 12, children: [
        for (var i = 0; i < rows.length; i++)
          SizedBox(
              width: 135,
              child: Row(children: [
                Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                        color: _postureColors[i % _postureColors.length],
                        shape: BoxShape.circle)),
                const SizedBox(width: 7),
                Expanded(child: Text('${rows[i]['name']}')),
                Text('${rows[i]['hours'] ?? '0.00h'}',
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 12))
              ])),
      ]),
    ]));
  }

  Future<void> _openDay(DateTime date) async {
    await Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) =>
                DailyActivityPage(date: date, loadDay: widget.loadDay)));
    if (mounted) _fetch();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('同律 · 日常'), actions: [
          IconButton(
              tooltip: '刷新动作记录',
              onPressed: () {
                _fetch();
                _loadPlan();
              },
              icon: const Icon(Icons.refresh_rounded)),
          if (!UserSession.instance.authenticated)
            TextButton(
                onPressed: () => Navigator.pushNamed(context, '/login'),
                child: const Text('登录')),
        ]),
        body: RefreshIndicator(
            onRefresh: () async {
              await Future.wait([_fetch(), _loadPlan()]);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
              children: [
                _planCard(),
                SectionHeading('活动概览',
                    trailing: Text(
                        '${DateTime.now().month} 月 ${DateTime.now().day} 日',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.muted))),
                Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                        color: const Color(0xFFE5EEEA),
                        borderRadius: BorderRadius.circular(14)),
                    child: Row(children: [
                      for (final entry in const {
                        TimeRange.day: '今天',
                        TimeRange.week: '近 7 天',
                        TimeRange.month: '近 30 天'
                      }.entries)
                        Expanded(
                            child: Semantics(
                                selected: _selectedRange == entry.key,
                                child: TextButton(
                                    style: TextButton.styleFrom(
                                        backgroundColor:
                                            _selectedRange == entry.key
                                                ? Colors.white
                                                : Colors.transparent,
                                        foregroundColor:
                                            _selectedRange == entry.key
                                                ? AppColors.deep
                                                : AppColors.muted,
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(10))),
                                    onPressed: () {
                                      if (_selectedRange != entry.key) {
                                        setState(
                                            () => _selectedRange = entry.key);
                                        _fetch();
                                      }
                                    },
                                    child: Text(entry.value)))),
                    ])),
                const SizedBox(height: 14),
                if (_loading && _data == null)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 30),
                      child: Center(child: CircularProgressIndicator()))
                else if (_error != null)
                  EmptyStateCard(
                      icon: Icons.cloud_off_outlined,
                      title: '暂时没有加载成功',
                      description: _error!,
                      action: OutlinedButton.icon(
                          onPressed: _fetch,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('重新加载')))
                else ...[
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _metric(
                        Icons.directions_walk_rounded,
                        '估算步数',
                        _hasRecords
                            ? '${_number(_data?['steps']).round()}'
                            : '—',
                        _hasRecords ? '根据衣物活动估算' : '连接衣物后开始记录'),
                    const SizedBox(width: 12),
                    _metric(
                        Icons.timelapse_rounded,
                        '记录时长',
                        _hasRecords
                            ? _duration(_number(_data?['observed_seconds']))
                            : '—',
                        _hasRecords ? '已记录的活动时间' : '还没有活动记录'),
                  ]),
                  if (!_hasRecords)
                    EmptyStateCard(
                        icon: Icons.bluetooth_searching_rounded,
                        title: '暂无衣物动作记录',
                        description: '连接上衣和裤子后，活动会自动记录在这里。',
                        action: FilledButton.icon(
                            onPressed: _connect,
                            icon: const Icon(Icons.bluetooth, size: 18),
                            label: const Text('连接衣物')))
                  else ...[
                    _distribution(),
                  ],
                ],
                MotionCalendar(
                    loadMonth: widget.loadCalendar,
                    onOpenDay: _openDay,
                    refreshToken: _data?['last_observation_at']),
                if (_hasRecords && widget.onGenerateReport != null)
                  OutlinedButton.icon(
                      onPressed: _report,
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: const Text('请助手整理活动小结')),
              ],
            )),
      );
}
