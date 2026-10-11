import 'package:flutter/material.dart';

import 'data/api_client.dart';
import 'data/skill_agent.dart';
import 'skill_agent_workspace_pages.dart';
import 'skill_agent_widgets.dart';

const _skillSage = Color(0xff64765a);
const _skillSoft = Color(0xffe9eee4);
const _skillSurface = Color(0xfffffefa);
const _skillLine = Color(0xffe8e7df);
const _skillMuted = Color(0xff70756b);

class SkillAgentPage extends StatefulWidget {
  const SkillAgentPage({super.key});

  @override
  State<SkillAgentPage> createState() => _SkillAgentPageState();
}

class _SkillAgentPageState extends State<SkillAgentPage> {
  static const _sections = ['对话', '运行记录', '知识库', '评测中心', '系统诊断'];
  int _selected = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xfff6f5ef),
        appBar: AppBar(
          title: const Text('技能实验室'),
          backgroundColor: const Color(0xfff6f5ef),
          surfaceTintColor: Colors.transparent,
        ),
        body: Column(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Row(children: [
                for (var index = 0; index < _sections.length; index++) ...[
                  ChoiceChip(
                    label: Text(_sections[index]),
                    selected: _selected == index,
                    onSelected: (_) => setState(() => _selected = index),
                    selectedColor: _skillSoft,
                    side: BorderSide(
                        color: _selected == index ? _skillSage : _skillLine),
                    labelStyle: TextStyle(
                        color: _selected == index ? _skillSage : _skillMuted,
                        fontWeight: _selected == index
                            ? FontWeight.w600
                            : FontWeight.normal),
                    showCheckmark: false,
                  ),
                  const SizedBox(width: 8),
                ],
              ]),
            ),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1480),
                child: IndexedStack(index: _selected, children: const [
                  _SkillAgentChatView(),
                  SkillAgentRunsPage(),
                  SkillAgentKnowledgePage(),
                  SkillAgentEvaluationsPage(),
                  SkillAgentDiagnosticsPage(),
                ]),
              ),
            ),
          ),
        ]),
      );
}

class _ChatEntry {
  const _ChatEntry({
    required this.id,
    required this.role,
    required this.content,
    this.status = 'complete',
    this.error = '',
    this.latencyMs = 0,
  });

  final int id, latencyMs;
  final String role, content, status, error;

  _ChatEntry copyWith({
    int? id,
    String? content,
    String? status,
    String? error,
    int? latencyMs,
  }) =>
      _ChatEntry(
        id: id ?? this.id,
        role: role,
        content: content ?? this.content,
        status: status ?? this.status,
        error: error ?? this.error,
        latencyMs: latencyMs ?? this.latencyMs,
      );
}

class _SkillAgentChatView extends StatefulWidget {
  const _SkillAgentChatView();

  @override
  State<_SkillAgentChatView> createState() => _SkillAgentChatViewState();
}

class _SkillAgentChatViewState extends State<_SkillAgentChatView> {
  final _api = SkillAgentApi.instance;
  final _skill = TextEditingController(text: defaultSkillAgentSkillUrl);
  final _title = TextEditingController();
  final _question = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <_ChatEntry>[];
  List<SkillAgentConversation> _conversations = [];
  int? _selectedId;
  int? _owner;
  String _error = '';
  bool _loading = true, _busy = false, _sessionChanged = false;

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    ApiClient.instance.addListener(_accountChanged);
    _loadConversations();
  }

  void _accountChanged() {
    final nextOwner = ApiClient.instance.account?.id;
    if (nextOwner == _owner || !mounted) return;
    _owner = nextOwner;
    setState(() {
      _sessionChanged = nextOwner == null;
      _conversations = [];
      _messages.clear();
      _selectedId = null;
      _loading = nextOwner != null;
      _error = '';
    });
    if (nextOwner != null) _loadConversations();
  }

  Future<void> _loadConversations({int? select}) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final rows = await _api.conversations();
      if (!mounted || _sessionChanged) return;
      setState(() {
        _conversations = rows;
        _selectedId = select ??
            (_selectedId != null && rows.any((row) => row.id == _selectedId)
                ? _selectedId
                : null);
      });
      if (_selectedId != null) await _loadConversation(_selectedId!);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadConversation(int id) async {
    try {
      final detail = await _api.conversation(id);
      if (!mounted || _sessionChanged || id != _selectedId) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(detail.messages.map((item) => _ChatEntry(
                id: item.id,
                role: item.role,
                content: item.content,
                status: item.status,
                error: item.error,
                latencyMs: item.latencyMs,
              )));
        _skill.text = _string(detail.conversation, 'skill_url');
        _title.text = _string(detail.conversation, 'title');
        _error = '';
      });
      _scrollToEnd();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  Future<void> _newConversation() async {
    if (_busy) return;
    setState(() {
      _selectedId = null;
      _messages.clear();
      _error = '';
      _title.clear();
      _skill.text = defaultSkillAgentSkillUrl;
      _question.clear();
    });
  }

  Future<void> _startConversation() async {
    final question = _question.text.trim();
    final skill = _skill.text.trim();
    if (question.isEmpty || skill.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final conversation = await _api.createConversation(skill, _title.text.trim());
      if (!mounted || _sessionChanged) return;
      setState(() => _selectedId = conversation.id);
      await _send(question);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCurrent() async {
    final question = _question.text.trim();
    final id = _selectedId;
    if (id == null || question.isEmpty || _busy) return;
    await _send(question);
  }

  Future<void> _send(String question) async {
    final id = _selectedId;
    if (id == null) return;
    _question.clear();
    setState(() {
      _busy = true;
      _error = '';
      _messages.add(_ChatEntry(id: -1, role: 'user', content: question));
      _messages.add(const _ChatEntry(
          id: -2, role: 'assistant', content: '', status: 'streaming'));
    });
    _scrollToEnd();
    var finished = false;
    try {
      await for (final event in _api.sendMessage(id, question)) {
        if (!mounted || _sessionChanged) return;
        final kind = event['event'] as String? ?? '';
        if (kind == 'message') {
          final role = event['role'] as String? ?? '';
          final serverId = (event['id'] as num?)?.toInt() ?? 0;
          final index = _messages.lastIndexWhere((item) => item.role == role);
          if (index >= 0) {
            setState(() => _messages[index] = _messages[index].copyWith(
                  id: serverId,
                  content: event['content'] as String? ?? _messages[index].content,
                  status: event['status'] as String? ?? _messages[index].status,
                ));
          }
        } else if (kind == 'delta') {
          final text = event['content'] as String? ?? '';
          if (text.isNotEmpty && _messages.isNotEmpty) {
            final index = _messages.length - 1;
            setState(() => _messages[index] = _messages[index].copyWith(
                content: _messages[index].content + text));
            _scrollToEnd();
          }
        } else if (kind == 'done') {
          final index = _messages.length - 1;
          if (index >= 0) {
            setState(() => _messages[index] = _messages[index].copyWith(
                  content: event['content'] as String? ?? _messages[index].content,
                  status: 'complete',
                  latencyMs: (event['latency_ms'] as num?)?.toInt() ?? 0,
                ));
          }
          finished = true;
        } else if (kind == 'error') {
          final index = _messages.length - 1;
          final message = event['message'] as String? ?? '回答失败，请重试。';
          if (index >= 0) {
            setState(() => _messages[index] = _messages[index].copyWith(
                  content: event['partial'] as String? ?? _messages[index].content,
                  status: 'failed',
                  error: message,
                ));
          }
          setState(() => _error = message);
          finished = true;
        }
      }
      if (!finished && mounted) {
        setState(() => _error = '连接已结束，回答可能没有完整保存。');
      }
    } catch (error) {
      if (mounted) {
        final index = _messages.length - 1;
        if (index >= 0) {
          setState(() => _messages[index] = _messages[index].copyWith(
                status: 'failed',
                error: _errorText(error),
              ));
        }
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _loadConversations(select: id);
      }
    }
  }

  Future<void> _renameConversation() async {
    final id = _selectedId;
    if (id == null || _busy) return;
    final controller = TextEditingController(text: _title.text);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改对话标题'),
        content: TextField(controller: controller, maxLength: 80, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty) return;
    try {
      await _api.renameConversation(id, title);
      if (mounted) await _loadConversations(select: id);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  Future<void> _deleteConversation() async {
    final id = _selectedId;
    if (id == null || _busy) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除这段对话？'),
            content: const Text('对话消息和关联运行记录会一并删除。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      await _api.deleteConversation(id);
      await _newConversation();
      await _loadConversations();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    ApiClient.instance.removeListener(_accountChanged);
    _skill.dispose();
    _title.dispose();
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_sessionChanged) return const Center(child: Text('账号已切换，请返回后重新打开技能实验室'));
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      final panel = _chatPanel(context);
      if (!wide) {
        return Column(children: [
          if (_conversations.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(children: [
                Expanded(child: _conversationDropdown()),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '新建对话',
                  onPressed: _busy ? null : _newConversation,
                  icon: const Icon(Icons.add),
                ),
              ]),
            ),
          Expanded(child: panel),
        ]);
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: 290, child: _conversationList()),
          const SizedBox(width: 14),
          Expanded(child: panel),
        ]),
      );
    });
  }

  Widget _conversationDropdown() => DropdownButtonFormField<int>(
        initialValue: _selectedId,
        decoration: const InputDecoration(
            labelText: '最近对话', border: OutlineInputBorder(), isDense: true),
        items: [
          for (final conversation in _conversations)
            DropdownMenuItem(
              value: conversation.id,
              child: Text(conversation.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: _busy ? null : (id) {
          if (id == null) return;
          setState(() {
            _selectedId = id;
            _messages.clear();
          });
          _loadConversation(id);
        },
      );

  Widget _conversationList() => Container(
        decoration: BoxDecoration(
          color: _skillSurface,
          border: Border.all(color: _skillLine),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
            child: Row(children: [
              const Expanded(child: Text('对话列表', style: TextStyle(fontWeight: FontWeight.w700))),
              IconButton(
                tooltip: '新建对话',
                onPressed: _busy ? null : _newConversation,
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ]),
          ),
          const Divider(height: 1, color: _skillLine),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _conversations.isEmpty
                    ? const Center(child: Text('还没有对话', style: TextStyle(color: _skillMuted)))
                    : ListView.builder(
                        itemCount: _conversations.length,
                        itemBuilder: (context, index) {
                          final item = _conversations[index];
                          return ListTile(
                            selected: item.id == _selectedId,
                            selectedTileColor: _skillSoft,
                            leading: const Icon(Icons.chat_bubble_outline_rounded, size: 19),
                            title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(item.lastQuestion.isEmpty ? item.skillUrl : item.lastQuestion,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: _busy ? null : () {
                              setState(() {
                                _selectedId = item.id;
                                _messages.clear();
                              });
                              _loadConversation(item.id);
                            },
                          );
                        },
                      ),
          ),
          if (_error.isNotEmpty) _errorBanner(_error),
        ]),
      );

  Widget _chatPanel(BuildContext context) => Container(
        margin: EdgeInsets.fromLTRB(
            MediaQuery.sizeOf(context).width >= 900 ? 0 : 16,
            0,
            MediaQuery.sizeOf(context).width >= 900 ? 20 : 16,
            18),
        decoration: BoxDecoration(
          color: _skillSurface,
          border: Border.all(color: _skillLine),
          borderRadius: BorderRadius.circular(24),
        ),
        child: _selectedId == null ? _newChatForm() : _chatConversation(),
      );

  Widget _newChatForm() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              const Icon(Icons.psychology_alt_rounded,
                  color: _skillSage, size: 34),
              const SizedBox(height: 12),
              Text('从一个 Skill 开始',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text('输入 GitHub 上的 SKILL.md 链接，创建独立的多轮对话。',
                  style: TextStyle(color: _skillMuted)),
              const SizedBox(height: 22),
              TextField(
                controller: _skill,
                maxLength: 2000,
                decoration: const InputDecoration(
                    labelText: 'Skill 链接',
                    hintText:
                        'https://github.com/owner/repo/blob/main/SKILL.md',
                    prefixIcon: Icon(Icons.link_rounded),
                    border: OutlineInputBorder()),
              ),
              TextField(
                controller: _title,
                maxLength: 80,
                decoration: const InputDecoration(
                    labelText: '对话标题（可选）', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _question,
                minLines: 3,
                maxLines: 6,
                maxLength: 12000,
                decoration: const InputDecoration(
                    labelText: '想要咨询或测试的问题',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder()),
                onSubmitted: (_) => _startConversation(),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _startConversation,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_rounded),
                  label: Text(_busy ? '正在连接…' : '开始对话'),
                ),
              ),
              if (_error.isNotEmpty) _errorBanner(_error),
            ],
          ),
        ),
      );

  Widget _chatConversation() {
    final matches = _conversations.where((item) => item.id == _selectedId).toList();
    final selected = matches.isEmpty ? null : matches.first;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(selected?.title ?? _title.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(selected?.skillUrl ?? _skill.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _skillMuted, fontSize: 11)),
            ]),
          ),
          IconButton(tooltip: '重命名', onPressed: _busy ? null : _renameConversation, icon: const Icon(Icons.edit_outlined)),
          IconButton(tooltip: '删除对话', onPressed: _busy ? null : _deleteConversation, icon: const Icon(Icons.delete_outline)),
        ]),
      ),
      const Divider(height: 1, color: _skillLine),
      if (_error.isNotEmpty) _errorBanner(_error),
      Expanded(
        child: _messages.isEmpty
            ? const Center(child: Text('发送一条消息，开始测试这个 Skill', style: TextStyle(color: _skillMuted)))
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                itemCount: _messages.length,
                itemBuilder: (context, index) => _messageBubble(_messages[index]),
              ),
      ),
      const Divider(height: 1, color: _skillLine),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              controller: _question,
              minLines: 1,
              maxLines: 5,
              maxLength: 12000,
              enabled: !_busy,
              decoration: const InputDecoration(
                  hintText: '输入追问内容…',
                  counterText: '',
                  border: OutlineInputBorder(),
                  isDense: true),
              onSubmitted: (_) => _sendCurrent(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: '发送',
            onPressed: _busy ? null : _sendCurrent,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.arrow_upward_rounded),
          ),
        ]),
      ),
    ]);
  }

  Widget _messageBubble(_ChatEntry item) {
    final user = item.role == 'user';
    final screenWidth = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: screenWidth < 900 ? screenWidth * .78 : 760),
        child: Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: user ? _skillSoft : const Color(0xfff7f6f0),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _skillLine),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(user ? '你' : 'Skill 助手',
                style: const TextStyle(color: _skillSage, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (item.content.isNotEmpty)
          SkillAgentRichText(item.content, style: const TextStyle(height: 1.55))
            else if (item.status == 'streaming')
              const Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 9),
                Text('正在生成…', style: TextStyle(color: _skillMuted)),
              ]),
            if (item.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(item.error, style: const TextStyle(color: Color(0xffa4513c), fontSize: 12)),
              ),
            if (!user && item.latencyMs > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('${(item.latencyMs / 1000).toStringAsFixed(1)} 秒',
                    style: const TextStyle(color: _skillMuted, fontSize: 11)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _errorBanner(String message) => Padding(
        padding: const EdgeInsets.all(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: const Color(0xfffff0eb),
              border: Border.all(color: const Color(0xffedc3b4)),
              borderRadius: BorderRadius.circular(14)),
          child: Text(message, style: const TextStyle(color: Color(0xff914d39))),
        ),
      );
}

String _string(Map<String, dynamic> row, String key) => row[key] as String? ?? '';

String _errorText(Object error) => error is ApiException ? error.message : '操作失败，请重试';
