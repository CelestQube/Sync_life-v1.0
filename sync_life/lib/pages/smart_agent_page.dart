import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../agent/agent_api.dart';
import '../agent/pending_chat_store.dart';
import 'personal_knowledge_page.dart';
import 'training_plan_page.dart';
import '../ui/app_theme.dart';
import '../ui/assistant_text.dart';

class SmartAgentPage extends StatefulWidget {
  const SmartAgentPage(
      {super.key, this.initialMessage, this.api, this.restaurantLocation});
  final String? initialMessage;
  final AgentApi? api;
  final Future<Map<String, double>> Function()? restaurantLocation;
  @override
  SmartAgentPageState createState() => SmartAgentPageState();
}

class SmartAgentPageState extends State<SmartAgentPage> {
  late final AgentApi _api = widget.api ?? AgentApi();
  late final PendingChatStore _outbox = PendingChatStore(_api);
  bool _initialSubmitted = false, _currentArchived = false;
  bool _draftPrepared = false;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _scaffold = GlobalKey<ScaffoldState>();
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _digests = [];
  Map<String, dynamic>? _configuration;
  Map<String, dynamic>? _pending;
  String? _conversationId;
  String _title = '新对话';
  String? _error;
  bool _loading = true, _busy = false, _serverBusy = false, _archived = false;
  bool _moreConversations = false, _moreMessages = false;
  int? _before;
  int _epoch = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _api.session.addListener(_accountChanged);
    _initialize();
  }

  void _accountChanged() {
    if (!mounted) return;
    _epoch++;
    _poll?.cancel();
    setState(() {
      _messages = [];
      _conversations = [];
      _digests = [];
      _configuration = null;
      _conversationId = null;
      _pending = null;
      _input.clear();
      _busy = false;
      _serverBusy = false;
      _currentArchived = false;
      _draftPrepared = false;
    });
    _initialize();
  }

  @override
  void dispose() {
    _epoch++;
    _poll?.cancel();
    _api.session.removeListener(_accountChanged);
    _input.dispose();
    _scroll.dispose();
    if (widget.api == null) _api.close();
    super.dispose();
  }

  Future<void> _initialize() async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _api.session.initialize();
      if (!mounted || epoch != _epoch) return;
      if (!_api.session.authenticated) {
        setState(() => _loading = false);
        return;
      }
      _configuration = await _api.status();
      await _loadConversations();
      if (!mounted || epoch != _epoch) return;
      if (!_initialSubmitted && widget.initialMessage?.isNotEmpty == true) {
        _initialSubmitted = true;
        prepareDraft(widget.initialMessage!);
      } else if (!_draftPrepared) {
        final prefs = await SharedPreferences.getInstance();
        final scope = await _api.storageScope();
        final last = prefs.getString('agent_last_$scope');
        final matches = _conversations.where((item) => item['id'] == last);
        Map<String, dynamic>? selected = matches.isEmpty ? null : matches.first;
        if (selected == null && last != null) {
          try {
            selected = await _api.getConversation(last);
          } on AgentException catch (error) {
            if (error.status != 404) rethrow;
          }
        }
        if (selected != null || _conversations.isNotEmpty) {
          await _openConversation(selected ?? _conversations.first);
        }
      }
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = error.toString());
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  /// Navigation only prepares a draft. A model request always needs a send tap.
  void prepareDraft(String text) {
    if (!mounted || _busy || _serverBusy || _pending != null) return;
    _poll?.cancel();
    setState(() {
      _conversationId = null;
      _draftPrepared = true;
      _title = '新对话';
      _messages = [];
      _digests = [];
      _currentArchived = false;
      _input.text = text;
    });
  }

  Future<void> _loadConversations({bool more = false}) async {
    final epoch = _epoch;
    final data = await _api.conversations(
        archived: _archived, offset: more ? _conversations.length : 0);
    if (!mounted || epoch != _epoch) return;
    final rows = List<Map<String, dynamic>>.from(data['conversations'] as List);
    setState(() {
      _conversations = more ? [..._conversations, ...rows] : rows;
      _moreConversations = data['has_more'] == true;
    });
  }

  Future<void> _openConversation(Map<String, dynamic> item) async {
    if (_busy) return;
    final epoch = _epoch;
    _poll?.cancel();
    setState(() {
      _conversationId = item['id'] as String;
      _title = item['title'] as String;
      _currentArchived = item['archived'] == true;
      _messages = [];
      _digests = [];
      _error = null;
      _pending = null;
      _serverBusy = false;
      _loading = true;
    });
    try {
      final restored = await _outbox.load(item['id'] as String);
      if (!mounted || epoch != _epoch || _conversationId != item['id']) return;
      _pending = restored;
      await _loadMessages();
      final prefs = await SharedPreferences.getInstance();
      final scope = await _api.storageScope();
      if (mounted && epoch == _epoch && _conversationId == item['id']) {
        await prefs.setString('agent_last_$scope', item['id'] as String);
      }
    } catch (error) {
      if (mounted && epoch == _epoch && _conversationId == item['id']) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && epoch == _epoch && _conversationId == item['id']) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadMessages({bool older = false}) async {
    final id = _conversationId;
    final epoch = _epoch;
    if (id == null) return;
    final data = await _api.messages(id, before: older ? _before : null);
    if (!mounted || id != _conversationId || epoch != _epoch) return;
    final rows = List<Map<String, dynamic>>.from(data['messages'] as List);
    if (!older && _pending != null) {
      final matching = rows.where((row) =>
          row['request_id'] == _pending!['request_id'] &&
          row['role'] == 'user');
      if (matching.isNotEmpty &&
          (matching.first['status'] == 'complete' ||
              matching.first['status'] == 'failed')) {
        await _outbox.remove(id);
        if (!mounted || id != _conversationId || epoch != _epoch) return;
        _pending = null;
      } else if (matching.isEmpty) {
        rows.add({
          'role': 'user',
          'content': _pending!['message'],
          'kind': _pending!['kind'],
          'request_id': _pending!['request_id'],
          'status': 'failed',
          'error': '上次请求尚未收到服务器确认，可重试。',
          'payload': <String, dynamic>{}
        });
      }
    }
    if (!mounted || id != _conversationId || epoch != _epoch) return;
    setState(() {
      _messages = older ? [...rows, ..._messages] : rows;
      _digests = List<Map<String, dynamic>>.from(data['digests'] as List);
      _moreMessages = data['has_more'] == true;
      _before = data['next_before'] as int?;
      final conversation = data['conversation'] as Map<String, dynamic>;
      _title = conversation['title'] as String;
      _serverBusy = conversation['busy'] == true;
      _currentArchived = conversation['archived'] == true;
    });
    if (!older) _scrollDown();
    _poll?.cancel();
    if (_serverBusy && !_busy) {
      _poll = Timer(const Duration(seconds: 4), () async {
        try {
          await _loadMessages();
        } catch (_) {
          if (mounted) setState(() => _error = '回复仍在处理中，请稍后刷新');
        }
      });
    }
  }

  Future<void> _newConversation() async {
    if (_busy) return;
    final epoch = _epoch;
    try {
      final item = await _api.createConversation();
      if (!mounted || epoch != _epoch) return;
      _archived = false;
      await _loadConversations();
      if (mounted) await _openConversation(item);
    } catch (error) {
      _notice(error.toString());
    }
  }

  void _scrollDown() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _submit(String text,
      {String kind = 'auto',
      String? requestId,
      double? latitude,
      double? longitude}) async {
    text = text.trim();
    if (text.isEmpty ||
        _busy ||
        _serverBusy ||
        _currentArchived ||
        !_api.session.authenticated) {
      return;
    }
    if (requestId == null && _pending != null) {
      _notice('还有一条未确认消息，请先重试，或在消息操作中放弃重试。');
      return;
    }
    final epoch = _epoch;
    if (_conversationId == null) await _newConversation();
    if (!mounted || epoch != _epoch || _conversationId == null) return;
    final id = _conversationId!;
    final request = requestId ?? newRequestId();
    setState(() {
      _busy = true;
      _error = null;
      _input.clear();
      _pending = {
        'message': text,
        'kind': kind,
        'request_id': request,
        'latitude': latitude,
        'longitude': longitude
      };
      if (!_messages.any(
          (item) => item['request_id'] == request && item['role'] == 'user')) {
        _messages.add({
          'role': 'user',
          'content': text,
          'request_id': request,
          'kind': kind,
          'status': 'pending',
          'payload': <String, dynamic>{}
        });
      } else {
        final row = _messages.firstWhere(
            (item) => item['request_id'] == request && item['role'] == 'user');
        row['status'] = 'pending';
        row['error'] = '';
      }
    });
    _scrollDown();
    try {
      await _outbox.put(id, _pending!);
      if (!mounted || epoch != _epoch) return;
      var result = await _api.chat(id, text,
          requestId: request,
          kind: kind,
          latitude: latitude,
          longitude: longitude);
      if (!mounted || epoch != _epoch || id != _conversationId) return;
      if (result['location_required'] == true) {
        final serverRow =
            Map<String, dynamic>.from(result['user_message'] as Map);
        setState(() {
          _messages.removeWhere((item) =>
              item['request_id'] == request && item['role'] == 'user');
          _messages.add({...serverRow, 'status': 'pending'});
        });
        if (_configuration?['places_configured'] != true) {
          throw const AgentException('餐馆查询暂不可用，请刷新或稍后再试。');
        }
        final position = await _restaurantPosition();
        if (!mounted || epoch != _epoch || id != _conversationId) return;
        latitude = position['latitude'];
        longitude = position['longitude'];
        _pending = {..._pending!, 'latitude': latitude, 'longitude': longitude};
        await _outbox.put(id, _pending!);
        if (!mounted || epoch != _epoch || id != _conversationId) return;
        result = await _api.chat(id, text,
            requestId: request,
            kind: kind,
            latitude: latitude,
            longitude: longitude);
        if (!mounted || epoch != _epoch || id != _conversationId) return;
        if (result['location_required'] == true) {
          throw const AgentException('定位未能完成，请重新获取位置后重试。');
        }
      }
      await _outbox.remove(id);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _messages.removeWhere((item) => item['request_id'] == request);
        _messages.add(Map<String, dynamic>.from(result['user_message'] as Map));
        _messages
            .add(Map<String, dynamic>.from(result['assistant_message'] as Map));
        _pending = null;
      });
      await _loadConversations();
    } catch (error) {
      if (!mounted || epoch != _epoch || id != _conversationId) return;
      if (error is AgentException && error.code == 'request_compacted') {
        await _outbox.remove(id);
        if (!mounted || epoch != _epoch || id != _conversationId) return;
        _pending = null;
      }
      setState(() {
        _error = error.toString();
        for (final row in _messages.where((item) =>
            item['request_id'] == request && item['role'] == 'user')) {
          row['status'] = 'failed';
          row['error'] = error.toString();
        }
      });
      try {
        await _loadMessages();
      } catch (_) {/* Keep the retryable local request when offline. */}
    } finally {
      if (mounted && epoch == _epoch && id == _conversationId) {
        setState(() => _busy = false);
        _scrollDown();
        if (_serverBusy) {
          try {
            await _loadMessages();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _retry(Map<String, dynamic> row) async {
    final pending =
        _pending?['request_id'] == row['request_id'] ? _pending : null;
    await _submit(row['content'] as String,
        kind: row['kind'] as String? ?? 'auto',
        requestId: row['request_id'] as String?,
        latitude: pending?['latitude'] as double?,
        longitude: pending?['longitude'] as double?);
  }

  Future<void> _restaurant() async {
    if (_busy || _serverBusy) return;
    if (_configuration?['places_configured'] != true) {
      _notice('后端尚未配置地图服务，暂不能查询真实餐馆。');
      return;
    }
    await _submit('查找你刚才推荐食物的附近餐馆', kind: 'restaurant_recommend');
  }

  Future<Map<String, double>> _restaurantPosition() async {
    if (widget.restaurantLocation != null) return widget.restaurantLocation!();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const AgentException('请先开启手机定位服务，再重试这条查询。');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw AgentException(permission == LocationPermission.deniedForever
            ? '定位权限已关闭，请在手机设置中允许定位，再重试这条查询。'
            : '未取得本次定位授权，尚未查询餐馆；允许定位后可重试。');
      }
      final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 15));
      return {'latitude': position.latitude, 'longitude': position.longitude};
    } on AgentException {
      rethrow;
    } catch (_) {
      throw const AgentException('暂时无法获取定位，请稍后重试这条查询。');
    }
  }

  Future<void> _savePlan(Map<String, dynamic> row) async {
    try {
      final payload = Map<String, dynamic>.from(row['payload'] as Map);
      final saved = await _api.savePlan(
          Map<String, dynamic>.from(payload['plan'] as Map),
          sourceMessageId: row['id'] as int?);
      if (!mounted) return;
      setState(() => row['payload'] = {'saved_plan_id': saved['id']});
      _notice('训练计划已保存到账号，可在训练计划页面查看和编辑');
    } catch (error) {
      _notice(error.toString());
    }
  }

  Future<void> _messageMenu(Map<String, dynamic> row) async {
    final epoch = _epoch;
    final id = _conversationId;
    final action = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: const Icon(Icons.copy),
                  title: const Text('复制内容'),
                  onTap: () => Navigator.pop(context, 'copy')),
              if (row['role'] == 'user')
                ListTile(
                    leading: const Icon(Icons.bookmark_add_outlined),
                    title: const Text('保存为个人资料'),
                    onTap: () => Navigator.pop(context, 'remember')),
              if (_pending?['request_id'] == row['request_id'] &&
                  !_busy &&
                  !_serverBusy)
                ListTile(
                    leading: const Icon(Icons.cancel_outlined),
                    title: const Text('放弃本次重试'),
                    onTap: () => Navigator.pop(context, 'discard')),
              if (row['id'] != null)
                ListTile(
                    leading: const Icon(Icons.push_pin_outlined),
                    title: Text(row['pinned'] == true ? '取消保留原文' : '长期保留这条原文'),
                    onTap: () => Navigator.pop(context, 'pin')),
            ])));
    if (!mounted || epoch != _epoch || id != _conversationId) return;
    try {
      if (action == 'discard' && id != null) {
        await _outbox.remove(id);
        if (!mounted || epoch != _epoch || id != _conversationId) return;
        setState(() {
          _pending = null;
          _messages.removeWhere((item) =>
              item['id'] == null && item['request_id'] == row['request_id']);
        });
      }
      if (action == 'copy') {
        await Clipboard.setData(ClipboardData(text: row['content'] as String));
        _notice('已复制');
      }
      if (action == 'remember') {
        if (!mounted) return;
        await editPersonalMemory(context, _api,
            initialValue: row['content'] as String);
      }
      if (action == 'pin') {
        final updated = await _api.pin(
            _conversationId!, row['id'] as int, row['pinned'] != true);
        if (mounted) {
          setState(() {
            row['pinned'] = updated['pinned'];
          });
        }
      }
    } catch (error) {
      _notice(error.toString());
    }
  }

  Future<void> _share(String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    _notice('报告已复制，请在发布前检查内容');
    try {
      await launchUrl(Uri.parse('xhsdiscover://'),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _manageConversation(
      Map<String, dynamic> row, String action) async {
    if (_busy) return;
    final epoch = _epoch;
    try {
      if (action == 'rename') {
        final controller = TextEditingController(text: row['title'] as String);
        final value = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('重命名对话'),
                    content: TextField(controller: controller, maxLength: 80),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () =>
                              Navigator.pop(context, controller.text.trim()),
                          child: const Text('保存'))
                    ]));
        if (value?.isNotEmpty == true) {
          if (!mounted || epoch != _epoch) return;
          await _api.updateConversation(row['id'] as String, {'title': value});
          if (!mounted || epoch != _epoch) return;
          if (row['id'] == _conversationId) setState(() => _title = value!);
        }
      } else if (action == 'archive') {
        await _api.updateConversation(
            row['id'] as String, {'archived': row['archived'] != true});
      } else if (action == 'delete') {
        if (!mounted) return;
        final confirm = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('删除对话'),
                    content: const Text('这会删除该对话的原文和摘录。单独保存的个人资料和训练计划仍保留。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('删除'))
                    ]));
        if (confirm != true || !mounted || epoch != _epoch) return;
        await _api.deleteConversation(row['id'] as String);
        await _outbox.remove(row['id'] as String);
      }
      if (!mounted || epoch != _epoch) return;
      if (row['id'] == _conversationId && action != 'rename') {
        _poll?.cancel();
        setState(() {
          _conversationId = null;
          _messages = [];
          _digests = [];
          _title = '新对话';
          _serverBusy = false;
          _currentArchived = false;
          _pending = null;
        });
      }
      await _loadConversations();
    } catch (error) {
      _notice(error.toString());
    }
  }

  void _showDigests() => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
              child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              const Text('较早对话摘录',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const Text('较早的聊天会整理成简短摘录，部分细节可能省略。重要内容可以长按消息保留，或存入“我的资料”。'),
              for (final item in _digests)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SelectableText(
                        '${item['month']} · ${item['message_count']} 条消息\n${item['text']}')),
            ]),
          )));

  Widget _messageCard(Map<String, dynamic> row) {
    final user = row['role'] == 'user';
    final payload = Map<String, dynamic>.from(row['payload'] as Map? ?? {});
    final plan = payload['plan'] as Map?;
    return Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: GestureDetector(
              onLongPress: () => _messageMenu(row),
              child: Card(
                color: user ? AppColors.soft : const Color(0xFFFFFEFB),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(user ? 18 : 5),
                        bottomRight: Radius.circular(user ? 5 : 18)),
                    side: BorderSide(
                        color:
                            user ? const Color(0xFFC9E1D8) : AppColors.line)),
                margin:
                    EdgeInsets.fromLTRB(user ? 40 : 16, 6, user ? 16 : 28, 6),
                child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Icon(
                                    user
                                        ? Icons.person_outline_rounded
                                        : Icons.spa_outlined,
                                    size: 17,
                                    color: AppColors.primary),
                                const SizedBox(width: 7),
                                Text(user ? '你' : '同律助手',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold)),
                                if (row['pinned'] == true)
                                  const Padding(
                                      padding: EdgeInsets.only(left: 8),
                                      child: Icon(Icons.push_pin, size: 14)),
                                if (row['created_at'] is String)
                                  Text(
                                      '  ${(row['created_at'] as String).substring(0, 10)}',
                                      style: const TextStyle(
                                          color: Colors.grey, fontSize: 11)),
                                IconButton(
                                    tooltip: '消息操作',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _messageMenu(row),
                                    icon:
                                        const Icon(Icons.more_horiz, size: 18)),
                              ]),
                          const SizedBox(height: 6),
                          if (user)
                            SelectableText(row['content'] as String,
                                style:
                                    const TextStyle(fontSize: 15, height: 1.6))
                          else
                            AssistantText(row['content'] as String),
                          if (plan != null) ...[
                            const Divider(),
                            Text(plan['summary'] as String? ?? '训练计划'),
                            for (final day in (plan['plan'] as List))
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
                                  child: Text(
                                      '${day['date']} · ${(day['exercises'] as List).isEmpty ? '休息日' : (day['exercises'] as List).map((item) => '${item['name']} ${item['start_time']}–${item['end_time']}').join('；')}')),
                            TextButton.icon(
                                onPressed: () => _savePlan(row),
                                icon: const Icon(Icons.event_available),
                                label: const Text('保存到训练计划')),
                          ],
                          if (payload['saved_plan_id'] != null)
                            TextButton.icon(
                                onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => TrainingPlanPage(
                                            initialPlanId:
                                                payload['saved_plan_id']
                                                    as String))),
                                icon: const Icon(Icons.event_note),
                                label: const Text('查看已保存计划')),
                          if (!user &&
                              (row['kind'] as String? ?? '')
                                  .startsWith('report_'))
                            TextButton.icon(
                                onPressed: () =>
                                    _share(row['content'] as String),
                                icon: const Icon(Icons.share_outlined),
                                label: const Text('复制并分享报告')),
                          if (user &&
                              (row['status'] == 'failed' ||
                                  row['status'] == 'pending' &&
                                      !_busy &&
                                      !_serverBusy)) ...[
                            Text(row['error'] as String? ?? '请求尚未完成',
                                style: const TextStyle(color: Colors.red)),
                            TextButton(
                                onPressed: _busy || _serverBusy
                                    ? null
                                    : () => _retry(row),
                                child: const Text('重试这条消息')),
                          ],
                        ])),
              )),
        ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        key: _scaffold,
        appBar: AppBar(
            title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
            leading: IconButton(
                tooltip: '对话列表',
                icon: const Icon(Icons.chat_bubble_outline),
                onPressed:
                    _busy ? null : () => _scaffold.currentState?.openDrawer()),
            actions: [
              IconButton(
                  tooltip: '我的资料',
                  icon: const Icon(Icons.bookmark_border_rounded),
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const PersonalKnowledgePage()))),
              IconButton(
                  tooltip: '训练计划',
                  icon: const Icon(Icons.event_note),
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const TrainingPlanPage()))),
              IconButton(
                  tooltip: '刷新对话',
                  icon: const Icon(Icons.refresh),
                  onPressed: _busy
                      ? null
                      : () async {
                          try {
                            await _loadMessages();
                          } catch (error) {
                            _notice(error.toString());
                          }
                        })
            ]),
        drawer: Drawer(
            child: SafeArea(
                child: Column(children: [
          ListTile(
              title: const Text('我的对话',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              trailing: IconButton(
                  tooltip: '新建对话',
                  icon: const Icon(Icons.add),
                  onPressed: _busy
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await _newConversation();
                        })),
          SwitchListTile(
              title: const Text('查看已归档'),
              value: _archived,
              onChanged: _busy
                  ? null
                  : (value) async {
                      setState(() => _archived = value);
                      try {
                        await _loadConversations();
                      } catch (error) {
                        _notice(error.toString());
                      }
                    }),
          Expanded(
              child: ListView(children: [
            for (final row in _conversations)
              ListTile(
                  selected: row['id'] == _conversationId,
                  title: Text(row['title'] as String,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle:
                      Text((row['updated_at'] as String).substring(0, 10)),
                  onTap: _busy
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await _openConversation(row);
                        },
                  trailing: PopupMenuButton<String>(
                      onSelected: (action) => _manageConversation(row, action),
                      itemBuilder: (_) => [
                            const PopupMenuItem(
                                value: 'rename', child: Text('重命名')),
                            PopupMenuItem(
                                value: 'archive',
                                child: Text(
                                    row['archived'] == true ? '恢复对话' : '归档对话')),
                            const PopupMenuItem(
                                value: 'delete', child: Text('删除对话'))
                          ])),
            if (_moreConversations)
              TextButton(
                  onPressed: () async {
                    try {
                      await _loadConversations(more: true);
                    } catch (error) {
                      _notice(error.toString());
                    }
                  },
                  child: const Text('加载更多对话'))
          ])),
          const Padding(
              padding: EdgeInsets.all(16),
              child: Text('每段对话单独记录。你保存的资料和计划，助手都能参考。',
                  style: TextStyle(color: AppColors.muted, fontSize: 13))),
        ]))),
        body: !_api.session.authenticated && !_loading
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('登录后，与助手聊聊你的日常'),
                TextButton(
                    onPressed: () => Navigator.pushNamed(context, '/login'),
                    child: const Text('去登录'))
              ]))
            : Column(children: [
                if (_currentArchived)
                  const InfoBanner('这段对话已收起。在对话列表中恢复后，就能继续聊天。'),
                if (_configuration?['configured'] == false)
                  const InfoBanner('助手暂时无法回复，你仍可查看活动记录和已保存的资料。', warning: true),
                if (_error != null)
                  InfoBanner(_error!,
                      warning: true,
                      action: IconButton(
                          tooltip: '重新加载',
                          onPressed: _busy ? null : _initialize,
                          icon: const Icon(Icons.refresh))),
                Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _messages.isEmpty
                            ? ListView(
                                padding:
                                    const EdgeInsets.fromLTRB(18, 24, 18, 16),
                                children: [
                                    AppCard(
                                        color: AppColors.soft,
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Icon(Icons.spa_outlined,
                                                  size: 32,
                                                  color: AppColors.primary),
                                              const SizedBox(height: 16),
                                              const Text('今天想要小律怎么帮助你？',
                                                  style: TextStyle(
                                                      fontSize: 23,
                                                      height: 1.4,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: AppColors.deep)),
                                              const SizedBox(height: 10),
                                              const Text(
                                                  '聊聊训练、饮食和身体感受。\n一起找到适合你的日常节奏。',
                                                  style: TextStyle(
                                                      color: AppColors.deep,
                                                      height: 1.7)),
                                              const SizedBox(height: 18),
                                              OutlinedButton.icon(
                                                  onPressed: () => _submit(
                                                      '帮我安排一周的训练',
                                                      kind: 'training_plan'),
                                                  icon: const Icon(
                                                      Icons.event_note_outlined,
                                                      size: 18),
                                                  label:
                                                      const Text('帮我安排一周的训练')),
                                            ])),
                                    const Padding(
                                        padding: EdgeInsets.all(8),
                                        child: Text(
                                            '你可以在“我的资料”中保存习惯与目标，让建议更贴合你。',
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: AppColors.muted))),
                                  ])
                            : ListView(
                                controller: _scroll,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                children: [
                                    if (_moreMessages)
                                      TextButton(
                                          onPressed: () async {
                                            try {
                                              await _loadMessages(older: true);
                                            } catch (error) {
                                              _notice(error.toString());
                                            }
                                          },
                                          child: const Text('加载更早消息')),
                                    if (_digests.isNotEmpty)
                                      TextButton(
                                          onPressed: _showDigests,
                                          child: const Text('查看较早对话摘录')),
                                    ..._messages.map(_messageCard),
                                    if (_busy || _serverBusy)
                                      const Padding(
                                          padding: EdgeInsets.all(20),
                                          child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                            strokeWidth: 2)),
                                                SizedBox(width: 12),
                                                Text('正在生成回复…')
                                              ])),
                                  ])),
                SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      for (final action in const {
                        '安排训练': 'training_plan',
                        '健康建议': 'health',
                        '姿势建议': 'posture',
                        '今日小结': 'report_day',
                        '本周小结': 'report_week',
                        '本月小结': 'report_month'
                      }.entries)
                        Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                                label: Text(action.key),
                                onPressed: _busy || _serverBusy
                                    ? null
                                    : () => _submit(action.key,
                                        kind: action.value))),
                      ActionChip(
                          label: const Text('附近餐馆'),
                          onPressed: _busy || _serverBusy || _currentArchived
                              ? null
                              : _restaurant),
                    ])),
                SafeArea(
                    top: false,
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                  child: TextField(
                                      controller: _input,
                                      minLines: 1,
                                      maxLines: 5,
                                      maxLength: 4000,
                                      enabled: !_busy &&
                                          !_serverBusy &&
                                          !_currentArchived,
                                      decoration: const InputDecoration(
                                          hintText: '聊聊今天的状态…',
                                          counterText: ''),
                                      onSubmitted: _submit)),
                              const SizedBox(width: 8),
                              IconButton.filled(
                                  tooltip: '发送',
                                  style: IconButton.styleFrom(
                                      backgroundColor: AppColors.primary,
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size(48, 48)),
                                  onPressed: _busy || _serverBusy
                                      ? null
                                      : () => _submit(_input.text),
                                  icon: const Icon(Icons.send)),
                            ]))),
              ]),
      );
}
