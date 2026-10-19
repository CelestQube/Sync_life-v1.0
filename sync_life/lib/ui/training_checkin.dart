import 'package:flutter/material.dart';
import '../agent/agent_api.dart';
import 'activity_updates.dart';
import 'app_theme.dart';
import 'app_navigation.dart';

const trainingColors = {
  'planned': Color(0xFF547EA8),
  'completed': Color(0xFF3D8A6B),
  'overdue': Color(0xFFB67E4A),
};
const trainingLabels = {
  'planned': '待完成',
  'completed': '已打卡',
  'overdue': '逾期未打卡'
};

class TrainingCheckin extends StatefulWidget {
  const TrainingCheckin(
      {super.key,
      required this.day,
      this.onChanged,
      this.api,
      this.offline = false});
  final Map<String, dynamic> day;
  final VoidCallback? onChanged;
  final AgentApi? api;
  final bool offline;
  @override
  State<TrainingCheckin> createState() => _TrainingCheckinState();
}

class _TrainingCheckinState extends State<TrainingCheckin> {
  bool _busy = false;
  Future<void> _checkIn() async {
    final completed = widget.day['status'] == 'completed';
    var draft = '${widget.day['note'] ?? ''}';
    final note = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(completed ? '撤销当天打卡？' : '记录这次训练'),
                content: completed
                    ? const Text('撤销后可再次打卡。')
                    : TextFormField(
                        initialValue: draft,
                        onChanged: (value) => draft = value,
                        maxLength: 500,
                        maxLines: 3,
                        decoration: const InputDecoration(
                            labelText: '训练感受（可选）',
                            hintText: '例如：按计划完成，今天有些疲劳')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, draft),
                      child: Text(completed ? '撤销打卡' : '完成打卡'))
                ]));
    if (note == null || !mounted) return;
    setState(() => _busy = true);
    final api = widget.api ?? AgentApi();
    try {
      await api.checkInTraining(widget.day['id'] as int,
          completed: !completed,
          revision: widget.day['revision'] as int,
          note: completed ? '' : note);
      activityUpdates.value++;
      if (mounted) widget.onChanged?.call();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (widget.api == null) api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.day['status'] as String? ?? 'planned';
    final today = DateUtils.dateOnly(DateTime.now());
    final day = DateTime.tryParse('${widget.day['date']}');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.day['is_current'] == false)
        const Text('历史安排，已由较新的计划替代',
            style: TextStyle(color: AppColors.muted, fontSize: 12)),
      Row(children: [
        Icon(
            status == 'completed'
                ? Icons.check_circle_outline
                : Icons.event_available_outlined,
            size: 18,
            color: trainingColors[status]),
        const SizedBox(width: 6),
        Expanded(
            child: Text(trainingLabels[status] ?? '待完成',
                style: TextStyle(color: trainingColors[status]))),
        TextButton(
            onPressed: _busy ||
                    widget.offline ||
                    widget.day['is_current'] == false ||
                    day == null ||
                    day.isAfter(today)
                ? null
                : _checkIn,
            child: Text(_busy
                ? '保存中…'
                : status == 'completed'
                    ? '撤销打卡'
                    : '训练打卡'))
      ]),
      if ('${widget.day['note'] ?? ''}'.isNotEmpty)
        Text('${widget.day['note']}',
            style: const TextStyle(color: AppColors.muted, fontSize: 12)),
      if (status == 'completed')
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => openAssistantDraft(context,
                    '请先评价 ${widget.day['date']} 的训练完成情况和训练感受，再根据实际完成情况调整下一周训练计划。'),
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                label: const Text('和小律复盘，安排下次训练'))),
    ]);
  }
}
