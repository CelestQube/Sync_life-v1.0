import 'package:flutter/material.dart';
import '../ui/app_theme.dart';
import '../agent/agent_api.dart';

const memoryCategories = {
  'health': '健康状况',
  'diet': '饮食习惯',
  'goal': '训练目标',
  'preference': '个人偏好'
};

Future<bool> editPersonalMemory(BuildContext context, AgentApi api,
    {Map<String, dynamic>? existing, String? initialValue}) async {
  final keyController =
      TextEditingController(text: existing?['key'] as String?);
  final valueController = TextEditingController(
      text: existing?['value'] as String? ?? initialValue);
  final expiryController =
      TextEditingController(text: existing?['expires_on'] as String?);
  var category = existing?['category'] as String? ?? 'preference';
  var saving = false;
  String? error;
  final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: Text(existing == null ? '保存个人资料' : '编辑个人资料'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('保存后可用于所有对话的个性化建议。健康内容按自述保存；请及时修改已变化的信息。'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                      initialValue: category,
                      decoration: const InputDecoration(labelText: '分类'),
                      items: memoryCategories.entries
                          .map((item) => DropdownMenuItem(
                              value: item.key, child: Text(item.value)))
                          .toList(),
                      onChanged: saving
                          ? null
                          : (value) => update(() => category = value!)),
                  TextField(
                      controller: keyController,
                      maxLength: 80,
                      enabled: !saving,
                      decoration: const InputDecoration(
                          labelText: '资料名称', hintText: '例如：食物过敏、运动目标')),
                  TextField(
                      controller: valueController,
                      maxLength: 1000,
                      minLines: 2,
                      maxLines: 5,
                      enabled: !saving,
                      decoration: const InputDecoration(labelText: '内容')),
                  TextField(
                      controller: expiryController,
                      enabled: !saving,
                      decoration: const InputDecoration(
                          labelText: '有效期至（可选）',
                          hintText: '例如 2026-12-31，留空长期保存')),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                ])),
                actions: [
                  TextButton(
                      onPressed: saving
                          ? null
                          : () => Navigator.pop(dialogContext, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: saving
                          ? null
                          : () async {
                              if (keyController.text.trim().isEmpty ||
                                  valueController.text.trim().isEmpty) {
                                update(() => error = '请填写资料名称和内容');
                                return;
                              }
                              final expiry = expiryController.text.trim();
                              if (expiry.isNotEmpty &&
                                  (!RegExp(r'^\d{4}-\d{2}-\d{2}$')
                                          .hasMatch(expiry) ||
                                      DateTime.tryParse(expiry) == null)) {
                                update(() => error = '请按 2026-12-31 的格式填写日期');
                                return;
                              }
                              update(() {
                                saving = true;
                                error = null;
                              });
                              try {
                                await api.saveMemory({
                                  'category': category,
                                  'key': keyController.text.trim(),
                                  'value': valueController.text.trim(),
                                  'expires_on': expiry.isEmpty ? null : expiry,
                                  if (existing != null)
                                    'revision': existing['revision']
                                }, id: existing?['id'] as String?);
                                if (dialogContext.mounted) {
                                  Navigator.pop(dialogContext, true);
                                }
                              } catch (exception) {
                                if (dialogContext.mounted) {
                                  update(() {
                                    saving = false;
                                    error = exception.toString();
                                  });
                                }
                              }
                            },
                      child: Text(saving ? '保存中…' : '确认保存')),
                ],
              )));
  // Route animations can still reference the controllers immediately after pop.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  keyController.dispose();
  valueController.dispose();
  expiryController.dispose();
  return result ?? false;
}

class PersonalKnowledgePage extends StatefulWidget {
  const PersonalKnowledgePage({super.key, this.api});
  final AgentApi? api;
  @override
  State<PersonalKnowledgePage> createState() => _PersonalKnowledgePageState();
}

class _PersonalKnowledgePageState extends State<PersonalKnowledgePage> {
  late final AgentApi _api = widget.api ?? AgentApi();
  List<Map<String, dynamic>> _memories = [];
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _api.session.addListener(_accountChanged);
    _load();
  }

  void _accountChanged() {
    if (!mounted) return;
    _generation++;
    setState(() => _memories = []);
    _load();
  }

  @override
  void dispose() {
    _api.session.removeListener(_accountChanged);
    if (widget.api == null) _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _api.memories();
      if (mounted && generation == _generation) {
        setState(() => _memories =
            List<Map<String, dynamic>>.from(data['memories'] as List));
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _edit([Map<String, dynamic>? item]) async {
    if (await editPersonalMemory(context, _api, existing: item) && mounted) {
      await _load();
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('删除资料'),
                content: Text('删除“${item['key']}”后，它将不再用于个性化回答。历史聊天中的原文仍保留。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (confirmed != true) return;
    try {
      await _api.deleteMemory(item['id'] as String);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('我的资料'), actions: [
          IconButton(
              tooltip: '刷新资料',
              onPressed: _load,
              icon: const Icon(Icons.refresh))
        ]),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('添加资料')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!),
                    TextButton(onPressed: _load, child: const Text('重试'))
                  ]))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                    children: [
                        const AppCard(
                            color: AppColors.soft,
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.bookmark_border_rounded,
                                      color: AppColors.primary, size: 28),
                                  SizedBox(height: 12),
                                  Text('让建议更懂你',
                                      style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.deep)),
                                  SizedBox(height: 8),
                                  Text('记下饮食习惯、健康情况和训练目标。助手会参考你保存的资料，给出更贴合的建议。',
                                      style: TextStyle(
                                          color: AppColors.deep, height: 1.6)),
                                ])),
                        if (_memories.isEmpty)
                          const EmptyStateCard(
                              icon: Icons.edit_note_rounded,
                              title: '从一个小习惯开始',
                              description:
                                  '例如“不吃辣”或“每周想运动三次”。点击右下角添加，也可以长按聊天消息保存。'),
                        for (final item in _memories)
                          Card(
                              child: ListTile(
                            isThreeLine: true,
                            title: Text(
                                '${item['key']} · ${memoryCategories[item['category']] ?? ''}'),
                            subtitle: Text(
                                '${item['value']}\n${item['expired'] == true ? '已到期' : item['expires_on'] == null ? '长期有效' : '有效期至 ${item['expires_on']}'}'),
                            onTap: () => _edit(item),
                            trailing: IconButton(
                                tooltip: '删除资料',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(item)),
                          )),
                      ]),
      );
}
