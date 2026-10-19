import 'dart:convert';
import 'package:flutter/material.dart';
import '../ui/app_theme.dart';
import '../agent/agent_api.dart';
import '../utils/training_plan_storage.dart';
import '../ui/training_checkin.dart';
import '../ui/app_navigation.dart';

class TrainingPlanPage extends StatefulWidget {
  const TrainingPlanPage({super.key, this.initialPlanId, this.api});
  final String? initialPlanId;
  final AgentApi? api;

  @override
  State<TrainingPlanPage> createState() => _TrainingPlanPageState();
}

class _TrainingPlanPageState extends State<TrainingPlanPage> {
  late final AgentApi _api = widget.api ?? AgentApi();
  late final PlanRepository _repository = PlanRepository(_api);
  Map<String, dynamic>? _trainingPlan;
  List<Map<String, dynamic>> _history = [];
  String? _error;
  bool _isLoading = true, _saving = false, _moreHistory = false;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    _api.session.addListener(_accountChanged);
    _loadTrainingPlan(id: widget.initialPlanId);
  }

  void _accountChanged() {
    _epoch++;
    if (!mounted) return;
    setState(() {
      _trainingPlan = null;
      _history = [];
      _saving = false;
    });
    _loadTrainingPlan();
  }

  @override
  void dispose() {
    _epoch++;
    _api.session.removeListener(_accountChanged);
    if (widget.api == null) _api.close();
    super.dispose();
  }

  Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  Future<void> _loadTrainingPlan({String? id}) async {
    final epoch = ++_epoch;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final document = await _repository.load(id: id);
      if (mounted && epoch == _epoch) setState(() => _trainingPlan = document);
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _error = error.toString();
          if (error is AgentException &&
              [401, 403, 404].contains(error.status)) {
            _trainingPlan = null;
          }
        });
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveTrainingPlan(Map<String, dynamic> plan) async {
    if (_saving) return;
    final epoch = _epoch;
    setState(() => _saving = true);
    try {
      final saved = await _repository.save(plan);
      if (mounted && epoch == _epoch) {
        setState(() {
          _trainingPlan = saved;
          _error = null;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('训练计划已同步到账号')));
      }
    } catch (error) {
      if (mounted && epoch == _epoch) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _saving = false);
    }
  }

  void _editDayPlan(int index) {
    if (_trainingPlan == null || _saving) return;
    final draft = _copy(_trainingPlan!);
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => DayPlanEditPage(
                dayPlan: Map<String, dynamic>.from(
                    (draft['plan'] as List)[index] as Map),
                onSave: (updated) {
                  (draft['plan'] as List)[index] = updated;
                  _saveTrainingPlan(draft);
                })));
  }

  Future<void> _deleteDayPlan(int index) async {
    if (_trainingPlan == null || _saving) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('删除训练日'),
                content: const Text('这会更新账号中的这份计划。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (confirmed != true || !mounted || _trainingPlan == null) return;
    final draft = _copy(_trainingPlan!);
    (draft['plan'] as List).removeAt(index);
    if ((draft['plan'] as List).isEmpty) {
      await _deleteCurrent();
    } else {
      await _saveTrainingPlan(draft);
    }
  }

  void _addNewDayPlan() {
    if (_trainingPlan == null || _saving) return;
    final draft = _copy(_trainingPlan!);
    final days = draft['plan'] as List;
    if (days.length >= 31) return;
    final date = days.isEmpty
        ? DateTime.now()
        : DateTime.parse(days.last['date'] as String)
            .add(const Duration(days: 1));
    final stamp =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => DayPlanEditPage(
                dayPlan: {'date': stamp, 'exercises': []},
                onSave: (day) {
                  days.add(day);
                  _saveTrainingPlan(draft);
                })));
  }

  Future<void> _deleteCurrent() async {
    final id = _trainingPlan?['_cloud_id'] as String?;
    if (id == null) return;
    try {
      await _repository.delete(id);
      if (mounted) await _loadTrainingPlan();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _loadHistory({bool more = false}) async {
    final data = await _api.plans(offset: more ? _history.length : 0);
    _history = [
      ...(more ? _history : <Map<String, dynamic>>[]),
      ...List<Map<String, dynamic>>.from(data['plans'] as List)
    ];
    _moreHistory = data['has_more'] == true;
  }

  Future<void> _showHistory() async {
    try {
      await _loadHistory();
      if (!mounted) return;
      final selected = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => SafeArea(
                      child: SizedBox(
                    height: MediaQuery.sizeOf(context).height * .65,
                    child:
                        ListView(padding: const EdgeInsets.all(16), children: [
                      const Text('历史训练计划',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
                      const Text('过期计划仍保留在账号中，不会因日期过去而删除。'),
                      if (_history.isEmpty)
                        const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('暂无已保存计划')),
                      for (final row in _history)
                        ListTile(
                            title: Text(
                                (row['document'] as Map)['summary'] as String),
                            subtitle: Text(
                                '${((row['document'] as Map)['plan'] as List).first['date']} 起 · 版本 ${row['revision']}'),
                            onTap: () =>
                                Navigator.pop(context, row['id'] as String)),
                      if (_moreHistory)
                        TextButton(
                            onPressed: () async {
                              try {
                                await _loadHistory(more: true);
                                if (context.mounted) update(() {});
                              } catch (error) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(error.toString())));
                                }
                              }
                            },
                            child: const Text('加载更多')),
                    ]),
                  ))));
      if (selected != null && mounted) await _loadTrainingPlan(id: selected);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _importLegacy() async {
    try {
      final legacy = await TrainingPlanStorage.readLegacyPlan();
      if (!mounted) return;
      if (legacy == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('手机中没有旧版计划文件')));
        return;
      }
      final yes = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('导入旧版计划'),
                  content: Text(
                      '确认这份旧版手机计划属于当前账号后再导入。概述：${legacy['summary'] ?? '训练计划'}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('导入到当前账号'))
                  ]));
      if (yes == true && mounted) await _saveTrainingPlan(legacy);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('训练计划'), actions: [
          IconButton(
              tooltip: '历史计划',
              onPressed: _saving ? null : _showHistory,
              icon: const Icon(Icons.history)),
          IconButton(
              tooltip: '刷新计划',
              onPressed: _saving
                  ? null
                  : () => _loadTrainingPlan(
                      id: _trainingPlan?['_cloud_id'] as String?),
              icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'import') {
                  await _importLegacy();
                  return;
                }
                final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                            title: const Text('删除整份计划'),
                            content: const Text('这会从当前账号删除这份计划，无法撤销。'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('取消')),
                              TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('删除'))
                            ]));
                if (confirm == true && mounted) await _deleteCurrent();
              },
              itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'import', child: Text('导入旧版手机计划')),
                    if (_trainingPlan != null)
                      const PopupMenuItem(
                          value: 'delete', child: Text('删除整份计划'))
                  ]),
        ]),
        body: Column(children: [
          if (_saving) const LinearProgressIndicator(),
          if (_trainingPlan?['_offline'] == true)
            const InfoBanner('当前显示已保存的计划，联网后可以刷新和修改。', warning: true),
          if (_error != null) InfoBanner(_error!, warning: true),
          Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _trainingPlan == null
                      ? _buildEmptyState()
                      : _buildTrainingPlan()),
        ]),
      );

  Widget _buildEmptyState() =>
      ListView(padding: const EdgeInsets.all(18), children: [
        EmptyStateCard(
            icon: Icons.event_note_outlined,
            title: '暂无训练计划',
            description: '告诉助手你的目标和时间，一起安排适合你的训练。',
            action: FilledButton.icon(
                onPressed: () {
                  requestedMainTab.value = null;
                  requestedMainTab.value = 1;
                  Navigator.popUntil(context, (route) => route.isFirst);
                },
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                label: const Text('和助手安排训练'))),
      ]);

  Widget _buildTrainingPlan() {
    final planList = _trainingPlan!['plan'] as List;
    final canAddMore = planList.length < 31;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_trainingPlan!['summary'] != null)
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              color: AppColors.soft,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '这段时间的安排',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _trainingPlan!['summary'],
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ...List.generate(planList.length, (index) {
            final dayPlan = planList[index];
            return _buildDayCard(dayPlan, index);
          }),
          // 添加新一天的按钮
          if (canAddMore)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _addNewDayPlan,
                  icon: const Icon(Icons.add),
                  label: Text('添加新一天 (${planList.length}/31)'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDayCard(Map<String, dynamic> dayPlan, int index) {
    final matches = (_trainingPlan?['_training_days'] as List? ?? [])
        .whereType<Map>()
        .where((row) => row['date'] == dayPlan['date']);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                    child: Text(
                  '${dayPlan['date']}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                )),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      onPressed: () => _editDayPlan(index),
                      tooltip: '编辑当天计划',
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 20, color: AppColors.danger),
                      onPressed: () => _deleteDayPlan(index),
                      tooltip: '删除当天计划',
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (matches.isNotEmpty)
              TrainingCheckin(
                  day: Map<String, dynamic>.from(matches.first),
                  api: _api,
                  offline: _trainingPlan?['_offline'] == true,
                  onChanged: () => _loadTrainingPlan(
                      id: _trainingPlan?['_cloud_id'] as String?)),
            if ((dayPlan['diet'] as String? ?? '').isNotEmpty)
              Text('饮食：${dayPlan['diet']}'),
            if ((dayPlan['rest'] as String? ?? '').isNotEmpty)
              Text('休息：${dayPlan['rest']}'),
            if (dayPlan['exercises'] == null ||
                (dayPlan['exercises'] as List).isEmpty)
              Text(
                '暂无训练项目，点击编辑添加',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[500],
                  fontStyle: FontStyle.italic,
                ),
              )
            else
              ...List.generate(dayPlan['exercises'].length, (exerciseIndex) {
                final exercise = dayPlan['exercises'][exerciseIndex];
                return _buildExerciseItem(exercise);
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildExerciseItem(Map<String, dynamic> exercise) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  exercise['name'],
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  '${exercise['start_time']} - ${exercise['end_time']} · ${exercise['intensity']} · ${exercise['duration']}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DayPlanEditPage extends StatefulWidget {
  final Map<String, dynamic> dayPlan;
  final Function(Map<String, dynamic>) onSave;

  const DayPlanEditPage({
    super.key,
    required this.dayPlan,
    required this.onSave,
  });

  @override
  State<DayPlanEditPage> createState() => _DayPlanEditPageState();
}

class _DayPlanEditPageState extends State<DayPlanEditPage> {
  late List<Map<String, dynamic>> _exercises;
  late List<Map<String, TextEditingController>> _exerciseControllers;

  @override
  void initState() {
    super.initState();
    _exercises =
        List<Map<String, dynamic>>.from(widget.dayPlan['exercises'] ?? []);

    // 初始化控制器，每个训练项目一个控制器组
    _exerciseControllers = _exercises.map((exercise) {
      return {
        'name': TextEditingController(text: exercise['name'] ?? ''),
        'start_time':
            TextEditingController(text: exercise['start_time'] ?? '08:00'),
        'end_time':
            TextEditingController(text: exercise['end_time'] ?? '08:30'),
        'intensity': TextEditingController(text: exercise['intensity'] ?? '中等'),
        'duration': TextEditingController(text: exercise['duration'] ?? '30分钟'),
      };
    }).toList();
  }

  @override
  void dispose() {
    for (var controllers in _exerciseControllers) {
      controllers.forEach((key, controller) {
        controller.dispose();
      });
    }
    super.dispose();
  }

  void _addExercise() {
    setState(() {
      _exercises.add({
        'name': '新训练项目',
        'start_time': '08:00',
        'end_time': '08:30',
        'intensity': '中等',
        'duration': '30分钟',
        'description': '',
      });
      _exerciseControllers.add({
        'name': TextEditingController(text: '新训练项目'),
        'start_time': TextEditingController(text: '08:00'),
        'end_time': TextEditingController(text: '08:30'),
        'intensity': TextEditingController(text: '中等'),
        'duration': TextEditingController(text: '30分钟'),
      });
    });
  }

  void _removeExercise(int index) {
    setState(() {
      _exercises.removeAt(index);
      // 释放控制器
      _exerciseControllers[index].forEach((key, controller) {
        controller.dispose();
      });
      _exerciseControllers.removeAt(index);
    });
  }

  void _save() {
    final updatedPlan = Map<String, dynamic>.from(widget.dayPlan);

    // 更新训练项目
    final updatedExercises = _exercises.asMap().entries.map((entry) {
      int index = entry.key;
      var exercise = entry.value;
      var controllers = _exerciseControllers[index];

      return {
        ...exercise,
        'name': controllers['name']?.text ?? exercise['name'],
        'start_time': controllers['start_time']?.text ?? exercise['start_time'],
        'end_time': controllers['end_time']?.text ?? exercise['end_time'],
        'intensity': controllers['intensity']?.text ?? exercise['intensity'],
        'duration': controllers['duration']?.text ?? exercise['duration'],
        'description': exercise['description'] ?? '',
      };
    }).toList();

    updatedPlan['exercises'] = updatedExercises;
    widget.onSave(updatedPlan);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('编辑 ${widget.dayPlan['date']}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '训练项目',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...List.generate(_exercises.length, (index) {
              return _buildExerciseEditCard(index);
            }),
            TextButton.icon(
              onPressed: _addExercise,
              icon: const Icon(Icons.add),
              label: const Text('添加训练项目'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExerciseEditCard(int index) {
    final controllers = _exerciseControllers[index];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '项目 ${index + 1}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: AppColors.danger),
                  onPressed: () => _removeExercise(index),
                ),
              ],
            ),
            TextField(
              controller: controllers['name'],
              decoration: const InputDecoration(
                labelText: '训练名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: '开始时间',
                      border: OutlineInputBorder(),
                    ),
                    controller: controllers['start_time'],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: '结束时间',
                      border: OutlineInputBorder(),
                    ),
                    controller: controllers['end_time'],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                labelText: '强度',
                border: OutlineInputBorder(),
              ),
              controller: controllers['intensity'],
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                labelText: '时长',
                border: OutlineInputBorder(),
              ),
              controller: controllers['duration'],
            ),
          ],
        ),
      ),
    );
  }
}
