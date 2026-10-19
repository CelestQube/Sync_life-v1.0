import 'package:flutter/material.dart';
import '../mocap/motion_statistics.dart';
import '../mocap/user_session.dart';
import 'app_theme.dart';
import 'activity_updates.dart';
import 'training_checkin.dart';

typedef MotionDateLoader = Future<Map<String, dynamic>> Function(DateTime date);

class MotionCalendar extends StatefulWidget {
  const MotionCalendar(
      {super.key,
      this.loadMonth = fetchMotionCalendar,
      required this.onOpenDay,
      this.today,
      this.refreshToken});
  final MotionDateLoader loadMonth;
  final Future<void> Function(DateTime date) onOpenDay;
  final DateTime? today;
  final Object? refreshToken;
  @override
  State<MotionCalendar> createState() => _MotionCalendarState();
}

class _MotionCalendarState extends State<MotionCalendar> {
  late DateTime _today = DateUtils.dateOnly(widget.today ?? DateTime.now());
  late DateTime _month = DateTime(_today.year, _today.month);
  Map<String, Map> _days = {};
  bool _loading = true;
  String? _error;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    activityUpdates.addListener(_load);
    UserSession.instance.addListener(_accountChanged);
    _load();
  }

  void _accountChanged() {
    if (!mounted) return;
    setState(() => _days = {});
    _load();
  }

  @override
  void dispose() {
    activityUpdates.removeListener(_load);
    _epoch++;
    UserSession.instance.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MotionCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loadMonth != widget.loadMonth ||
        oldWidget.refreshToken != widget.refreshToken &&
            DateUtils.isSameMonth(_month, _today)) {
      _load();
    }
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
      _days = {};
    });
    try {
      final data = await widget.loadMonth(_month);
      if (!mounted || epoch != _epoch) return;
      final today = DateTime.tryParse(data['today'] as String? ?? '');
      setState(() {
        if (today != null) _today = DateUtils.dateOnly(today);
        _days = {
          for (final day in (data['days'] as List).whereType<Map>())
            day['date'] as String: day
        };
      });
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() => _error =
            error is StateError ? error.message.toString() : '日历暂时无法加载，请重试');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  void _move(int months) {
    setState(() => _month = DateTime(_month.year, _month.month + months));
    _load();
  }

  Future<void> _open(DateTime day) async {
    await widget.onOpenDay(day);
    if (mounted) _load();
  }

  Widget _legend(Color color, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(fontSize: 11, color: AppColors.muted)),
      ]);
  @override
  Widget build(BuildContext context) {
    final offset = _month.weekday - 1;
    final length = DateTime(_month.year, _month.month + 1, 0).day;
    final canNext = _month.isBefore(DateTime(_today.year + 1, _today.month));
    return AppCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.calendar_month_outlined,
                size: 19, color: AppColors.primary),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('活动日历',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            IconButton(
                tooltip: '刷新日历',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 19)),
          ]),
          Row(children: [
            IconButton(
                tooltip: '上个月',
                onPressed:
                    _loading || _month.year <= 1900 ? null : () => _move(-1),
                icon: const Icon(Icons.chevron_left_rounded)),
            Expanded(
                child: Text('${_month.year} 年 ${_month.month} 月',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: AppColors.deep))),
            IconButton(
                tooltip: '下个月',
                onPressed: !_loading && canNext ? () => _move(1) : null,
                icon: const Icon(Icons.chevron_right_rounded)),
          ]),
          if (_loading)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_error!,
                          style: const TextStyle(color: AppColors.muted)),
                      TextButton(onPressed: _load, child: const Text('重新加载日历')),
                    ]))
          else ...[
            Row(children: [
              for (final label in ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                    child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(label,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.muted))))
            ]),
            GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7, crossAxisSpacing: 5, mainAxisSpacing: 5),
                itemCount: offset + length,
                itemBuilder: (context, index) {
                  if (index < offset) return const SizedBox.shrink();
                  final day =
                      DateTime(_month.year, _month.month, index - offset + 1);
                  final key = motionDateKey(day),
                      row = _days[motionDateKey(day)];
                  final hasData = row?['has_records'] == true;
                  final training = row?['training_status'] as String?;
                  final hasPlan = trainingColors.containsKey(training);
                  final color = trainingColors[training] ??
                      (hasData ? AppColors.primary : null);
                  final future = day.isAfter(_today),
                      today = DateUtils.isSameDay(day, _today);
                  final dateLabel = '${day.year}年${day.month}月${day.day}日';
                  return Semantics(
                      label:
                          '$dateLabel，${hasPlan ? trainingLabels[training] : future ? '尚未到来' : hasData ? '有活动记录' : '暂无记录或已删除'}',
                      button: !future || hasPlan,
                      child: Tooltip(
                          message: dateLabel,
                          triggerMode: TooltipTriggerMode.longPress,
                          child: Material(
                              color: color ??
                                  (future
                                      ? const Color(0xFFF7F9F8)
                                      : const Color(0xFFE6ECE9)),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(
                                      color: today
                                          ? AppColors.primary
                                          : Colors.transparent,
                                      width: 1.5)),
                              child: InkWell(
                                  key: ValueKey('motion-day-$key'),
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: future && !hasPlan
                                      ? null
                                      : () => _open(day),
                                  child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Text('${day.day}',
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight:
                                                    today || color != null
                                                        ? FontWeight.w700
                                                        : FontWeight.w500,
                                                color: color != null
                                                    ? Colors.white
                                                    : future
                                                        ? const Color(
                                                            0xFFBECAC5)
                                                        : AppColors.muted)),
                                        if (hasData && hasPlan)
                                          Positioned(
                                              bottom: 5,
                                              child: Container(
                                                  width: 4,
                                                  height: 4,
                                                  decoration:
                                                      const BoxDecoration(
                                                          color: Colors.white,
                                                          shape: BoxShape
                                                              .circle))),
                                      ])))));
                }),
            const SizedBox(height: 14),
            Wrap(spacing: 14, runSpacing: 6, children: [
              _legend(AppColors.primary, '有活动记录'),
              _legend(const Color(0xFFE6ECE9), '暂无记录'),
              _legend(trainingColors['planned']!, '有训练安排'),
              _legend(trainingColors['completed']!, '已打卡'),
              _legend(trainingColors['overdue']!, '逾期未打卡'),
            ]),
            const SizedBox(height: 8),
            const Text('点击查看活动与训练，长按查看日期；训练色块中的白点表示也有活动记录',
                style: TextStyle(color: AppColors.muted, fontSize: 11)),
          ],
        ]));
  }
}
