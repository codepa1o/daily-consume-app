import 'dart:async';

import 'package:flutter/material.dart';

import 'data/api_client.dart';
import 'data/chatbot.dart';
import 'data/skill_agent_file.dart';
import 'data/skill_agent_file_picker.dart';
import 'skill_agent_widgets.dart';

const _chatSurface = Color(0xfffffefa);
const _chatLine = Color(0xffe8e7df);
const _chatSage = Color(0xff64765a);
const _chatSoft = Color(0xffe9eee4);
const _chatMuted = Color(0xff70756b);

class ChatbotPage extends StatefulWidget {
  const ChatbotPage({super.key});

  @override
  State<ChatbotPage> createState() => _ChatbotPageState();
}

class _ChatbotPageState extends State<ChatbotPage> {
  final _api = ChatbotApi.instance;
  final _question = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <ChatbotMessage>[];
  List<ChatbotConversation> _conversations = [];
  SkillAgentFile? _attachment;
  int? _selectedId;
  int? _owner;
  bool _loading = true;
  bool _busy = false;
  bool _streamFinished = false;
  bool _stopping = false;
  bool _useKnowledge = false;
  String _progress = '';
  String _error = '';
  StreamSubscription<Map<String, dynamic>>? _streamSubscription;
  Completer<void>? _streamDone;

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    ApiClient.instance.addListener(_accountChanged);
    _loadConversations();
  }

  @override
  void dispose() {
    ApiClient.instance.removeListener(_accountChanged);
    _streamSubscription?.cancel();
    final streamDone = _streamDone;
    if (streamDone != null && !streamDone.isCompleted) streamDone.complete();
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _accountChanged() {
    final nextOwner = ApiClient.instance.account?.id;
    if (nextOwner == _owner || !mounted) return;
    _owner = nextOwner;
    _stopping = true;
    _streamFinished = true;
    _streamSubscription?.cancel();
    final streamDone = _streamDone;
    if (streamDone != null && !streamDone.isCompleted) streamDone.complete();
    setState(() {
      _conversations = [];
      _messages.clear();
      _attachment = null;
      _selectedId = null;
      _loading = nextOwner != null;
      _busy = false;
      _streamFinished = false;
      _stopping = false;
      _progress = '';
      _error = '';
    });
    if (nextOwner != null) _loadConversations();
  }

  Future<void> _loadConversations({int? select}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final rows = await _api.conversations();
      if (!mounted || ApiClient.instance.account?.id != _owner) return;
      final nextId = select ??
          (_selectedId != null && rows.any((row) => row.id == _selectedId)
              ? _selectedId
              : rows.isNotEmpty
                  ? rows.first.id
                  : null);
      setState(() {
        _conversations = rows;
        _selectedId = nextId;
      });
      if (nextId != null) {
        await _loadConversation(nextId);
      } else {
        setState(() => _messages.clear());
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadConversation(int id) async {
    try {
      final detail = await _api.conversation(id);
      if (!mounted ||
          ApiClient.instance.account?.id != _owner ||
          id != _selectedId) {
        return;
      }
      setState(() {
        _messages
          ..clear()
          ..addAll(detail.messages);
        _progress = '';
        _error = '';
      });
      _scrollToEnd();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  void _newConversation() {
    if (_busy) return;
    setState(() {
      _selectedId = null;
      _messages.clear();
      _attachment = null;
      _progress = '';
      _error = '';
      _question.clear();
    });
  }

  Future<void> _selectConversation(int id) async {
    if (_busy) return;
    setState(() {
      _selectedId = id;
      _messages.clear();
      _attachment = null;
      _progress = '';
      _error = '';
    });
    await _loadConversation(id);
  }

  Future<void> _send() async {
    final question = _question.text.trim();
    final attachment = _attachment;
    if ((question.isEmpty && attachment == null) || _busy) return;
    final displayQuestion = question.isEmpty ? '请分析这个文件。' : question;
    setState(() {
      _busy = true;
      _error = '';
      _progress = '正在连接…';
    });
    _question.clear();

    var conversationId = _selectedId;
    try {
      if (conversationId == null) {
        final conversation = await _api.createConversation();
        if (!mounted || ApiClient.instance.account?.id != _owner) return;
        conversationId = conversation.id;
        setState(() {
          _selectedId = conversationId;
          _conversations = [conversation, ..._conversations];
        });
      }
      final activeConversationId = conversationId!;

      setState(() {
        _messages
          ..add(ChatbotMessage(
            id: -1,
            role: 'user',
            content: displayQuestion,
            status: 'complete',
            error: '',
            metadata: {
              'attachments': [
                if (attachment != null) {'name': attachment.name},
              ],
            },
          ))
          ..add(const ChatbotMessage(
            id: -2,
            role: 'assistant',
            content: '',
            status: 'streaming',
            error: '',
            metadata: {},
          ));
      });
      _scrollToEnd();

      final completed = Completer<void>();
      _streamDone = completed;
      _streamFinished = false;
      _stopping = false;
      _streamSubscription = _api
          .sendMessage(
            activeConversationId,
            displayQuestion,
            useKnowledge: _useKnowledge,
            attachment: attachment,
          )
          .listen(
        _handleEvent,
        onError: (Object error) {
          if (_stopping) {
            if (!completed.isCompleted) completed.complete();
            return;
          }
          _streamFinished = true;
          if (mounted) {
            _updateAssistant(
              (message) => message.copyWith(
                status: 'failed',
                error: _errorText(error),
              ),
            );
            setState(() => _error = _errorText(error));
          }
          if (!completed.isCompleted) completed.complete();
        },
        onDone: () {
          if (mounted && !_streamFinished && !_stopping) {
            _streamFinished = true;
            _updateAssistant(
              (message) => message.copyWith(
                status: 'failed',
                error: '连接已结束，回答可能没有完整保存。',
              ),
            );
            setState(() => _error = '连接已结束，回答可能没有完整保存。');
          }
          if (!completed.isCompleted) completed.complete();
        },
      );
      await completed.future;
      _streamSubscription = null;
      if (mounted &&
          ApiClient.instance.account?.id == _owner &&
          _selectedId == activeConversationId) {
        setState(() {
          _busy = false;
          _progress = '';
        });
        await _refreshConversationList(activeConversationId);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      _streamDone = null;
      _stopping = false;
      if (mounted && _busy) {
        setState(() {
          _busy = false;
          _progress = '';
        });
      }
    }
  }

  void _handleEvent(Map<String, dynamic> event) {
    if (!mounted || ApiClient.instance.account?.id != _owner) return;
    final kind = event['event'] as String? ?? '';
    if (kind == 'message') {
      final role = event['role'] as String? ?? '';
      final id = (event['id'] as num?)?.toInt() ?? 0;
      setState(() {
        final index = _messages.lastIndexWhere((message) => message.role == role);
        if (index >= 0) {
          _messages[index] = _messages[index].copyWith(
            id: id,
            content: event['content'] as String? ?? _messages[index].content,
            status: event['status'] as String? ?? _messages[index].status,
            metadata: _map(event['metadata']),
          );
        }
        if (role == 'user') _attachment = null;
      });
    } else if (kind == 'status') {
      setState(() => _progress = event['message'] as String? ?? '');
      if (event['warning'] == true) {
        setState(() => _error = event['message'] as String? ?? '');
      }
    } else if (kind == 'tool_start') {
      final activity = <String, dynamic>{
        'id': event['id'],
        'name': event['display_name'] ?? event['name'] ?? '工具',
        'status': 'running',
      };
      _updateAssistant((message) {
        final calls = _toolCalls(message.metadata)..add(activity);
        return message.copyWith(
          metadata: {...message.metadata, 'tool_calls': calls},
        );
      });
    } else if (kind == 'tool_result') {
      _updateAssistant((message) {
        final calls = _toolCalls(message.metadata);
        final index = calls.indexWhere((item) => item['id'] == event['id']);
        if (index >= 0) calls[index] = {...calls[index], 'status': 'complete'};
        return message.copyWith(
          metadata: {...message.metadata, 'tool_calls': calls},
        );
      });
    } else if (kind == 'delta') {
      final delta = event['content'] as String? ?? '';
      if (delta.isNotEmpty) {
        _updateAssistant(
          (message) => message.copyWith(content: message.content + delta),
        );
        _scrollToEnd();
      }
    } else if (kind == 'done') {
      _streamFinished = true;
      _updateAssistant(
        (message) => message.copyWith(
          id: (event['id'] as num?)?.toInt() ?? message.id,
          content: event['content'] as String? ?? message.content,
          status: 'complete',
          metadata: _map(event['metadata']),
        ),
      );
      setState(() => _progress = '');
      _streamDone?.complete();
    } else if (kind == 'error') {
      _streamFinished = true;
      final message = event['message'] as String? ?? '回答失败，请重试。';
      _updateAssistant(
        (item) => item.copyWith(
          id: (event['id'] as num?)?.toInt() ?? item.id,
          content: event['partial'] as String? ?? item.content,
          status: 'failed',
          error: message,
        ),
      );
      setState(() {
        _error = message;
        _progress = '';
      });
      _streamDone?.complete();
    }
  }

  List<Map<String, dynamic>> _toolCalls(Map<String, dynamic> metadata) {
    final value = metadata['tool_calls'];
    return value is List
        ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
        : <Map<String, dynamic>>[];
  }

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  void _updateAssistant(
      ChatbotMessage Function(ChatbotMessage message) update) {
    if (!mounted) return;
    setState(() {
      final index = _messages.lastIndexWhere((message) => message.role == 'assistant');
      if (index >= 0) _messages[index] = update(_messages[index]);
    });
  }

  Future<void> _refreshConversationList(int? id) async {
    try {
      final rows = await _api.conversations();
      if (mounted && ApiClient.instance.account?.id == _owner) {
        setState(() {
          _conversations = rows;
          if (id != null) _selectedId = id;
        });
      }
    } catch (_) {}
  }

  void _stop() {
    if (!_busy || _streamFinished) return;
    _stopping = true;
    _streamFinished = true;
    _streamSubscription?.cancel();
    _updateAssistant(
      (message) => message.copyWith(
        status: 'cancelled',
        error: '已停止生成。',
      ),
    );
    setState(() {
      _busy = false;
      _progress = '';
    });
    final done = _streamDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> _renameConversation(ChatbotConversation conversation) async {
    final controller = TextEditingController(text: conversation.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改对话标题'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty) return;
    try {
      await _api.renameConversation(conversation.id, title);
      await _loadConversations(select: conversation.id);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  Future<void> _deleteConversation(ChatbotConversation conversation) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除这段对话？'),
            content: const Text('对话和消息会一并删除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      await _api.deleteConversation(conversation.id);
      if (_selectedId == conversation.id) _newConversation();
      await _loadConversations();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  Future<void> _showHistory() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: _conversationPane(compact: true),
        ),
      ),
    );
  }

  Future<void> _pickAttachment() async {
    if (_busy) return;
    try {
      final file = await pickSkillAgentFile();
      if (!mounted || file == null) return;
      if (file.bytes.length > 10 * 1024 * 1024) {
        setState(() => _error = '附件不能超过 10 MB。');
        return;
      }
      setState(() {
        _attachment = file;
        _error = '';
      });
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          return Scaffold(
            backgroundColor: const Color(0xfff6f5ef),
            appBar: AppBar(
              title: const Text('聊天机器人'),
              backgroundColor: const Color(0xfff6f5ef),
              surfaceTintColor: Colors.transparent,
              leading: wide
                  ? null
                  : IconButton(
                      tooltip: '对话历史',
                      onPressed: _showHistory,
                      icon: const Icon(Icons.history_rounded),
                    ),
              actions: [
                IconButton(
                  tooltip: '新对话',
                  onPressed: _busy ? null : _newConversation,
                  icon: const Icon(Icons.add_comment_outlined),
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1480),
                child: Row(
                  children: [
                    if (wide) ...[
                      SizedBox(
                        width: 280,
                        child: _conversationPane(compact: false),
                      ),
                      const VerticalDivider(width: 1, color: _chatLine),
                    ],
                    Expanded(child: _chatPanel()),
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _conversationPane({required bool compact}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '最近对话',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '新对话',
                  onPressed: _busy ? null : _newConversation,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2)
          else if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error, style: const TextStyle(color: Colors.red)),
            )
          else if (_conversations.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('还没有对话', style: TextStyle(color: _chatMuted)),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: _conversations.length,
                itemBuilder: (context, index) {
                  final conversation = _conversations[index];
                  final selected = conversation.id == _selectedId;
                  return ListTile(
                    selected: selected,
                    selectedTileColor: _chatSoft,
                    title: Text(
                      conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      conversation.lastQuestion,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      _selectConversation(conversation.id);
                      if (compact) Navigator.pop(context);
                    },
                    trailing: PopupMenuButton<String>(
                      tooltip: '对话操作',
                      onSelected: (action) {
                        if (action == 'rename') {
                          _renameConversation(conversation);
                        } else {
                          _deleteConversation(conversation);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      );

  Widget _chatPanel() => Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.chat_bubble_outline_rounded,
                              size: 42, color: _chatSage),
                          SizedBox(height: 14),
                          Text(
                            '想聊点什么？',
                            style: TextStyle(
                                fontSize: 21, fontWeight: FontWeight.w700),
                          ),
                          SizedBox(height: 7),
                          Text(
                            '可以提问、整理思路，或让助手检索你的知识库。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _chatMuted),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) =>
                        _messageBubble(_messages[index]),
                  ),
          ),
          if (_progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      _progress,
                      style: const TextStyle(color: _chatMuted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error,
                  style: const TextStyle(color: Color(0xffa4513c)),
                ),
              ),
            ),
          _composer(),
        ],
      );

  Widget _composer() => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          decoration: const BoxDecoration(
            color: _chatSurface,
            border: Border(top: BorderSide(color: _chatLine)),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                children: [
                  Row(
                    children: [
                      Switch(
                        value: _useKnowledge,
                        onChanged: _busy
                            ? null
                            : (value) =>
                                setState(() => _useKnowledge = value),
                      ),
                      const Text('检索我的知识库'),
                      const Spacer(),
                      IconButton(
                        tooltip: '添加 TXT、Markdown 或 PDF',
                        onPressed: _busy ? null : _pickAttachment,
                        icon: const Icon(Icons.attach_file_rounded),
                      ),
                      Text(
                        '模型由服务端配置',
                        style: TextStyle(color: _chatMuted, fontSize: 11),
                      ),
                    ],
                  ),
                  if (_attachment != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: InputChip(
                          avatar: const Icon(
                            Icons.description_outlined,
                            size: 18,
                          ),
                          label: Text(_attachment!.name),
                          onDeleted: _busy
                              ? null
                              : () => setState(() => _attachment = null),
                        ),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _question,
                          minLines: 1,
                          maxLines: 6,
                          maxLength: 12000,
                          enabled: !_busy,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: '输入消息…',
                            counterText: '',
                            filled: true,
                            fillColor: const Color(0xfff6f5ef),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 13),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: _busy ? '停止生成' : '发送',
                        onPressed: _busy ? _stop : _send,
                        icon: Icon(
                          _busy
                              ? Icons.stop_rounded
                              : Icons.arrow_upward_rounded,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _messageBubble(ChatbotMessage message) {
    final isUser = message.role == 'user';
    final maxWidth = MediaQuery.sizeOf(context).width < 900
        ? MediaQuery.sizeOf(context).width * .82
        : 780.0;
    final calls = _toolCalls(message.metadata);
    final sources = _sourceList(message.metadata);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: isUser ? _chatSoft : _chatSurface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _chatLine),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUser ? '你' : '聊天助手',
                style: const TextStyle(
                  color: _chatSage,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              for (final name in _attachmentNames(message.metadata))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Chip(
                    avatar: const Icon(Icons.description_outlined, size: 16),
                    label: Text(name, overflow: TextOverflow.ellipsis),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              if (message.content.isNotEmpty) ...[
                const SizedBox(height: 6),
                SkillAgentRichText(
                  message.content,
                  style: const TextStyle(height: 1.55),
                ),
              ] else if (!isUser && message.status == 'streaming') ...[
                const SizedBox(height: 8),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 9),
                    Text('正在生成…', style: TextStyle(color: _chatMuted)),
                  ],
                ),
              ],
              for (final call in calls)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    (call['status'] == 'running' ? '正在调用 ' : '已调用 ') +
                        (call['name'] as String? ?? '工具'),
                    style: const TextStyle(color: _chatMuted, fontSize: 12),
                  ),
                ),
              for (final source in sources)
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(
                    _sourceTitle(source),
                    style: const TextStyle(color: _chatMuted, fontSize: 11),
                  ),
                ),
              if (message.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    message.error,
                    style: const TextStyle(
                        color: Color(0xffa4513c), fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _sourceList(Map<String, dynamic> metadata) {
    final value = metadata['sources'];
    return value is List
        ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
        : <Map<String, dynamic>>[];
  }

  List<String> _attachmentNames(Map<String, dynamic> metadata) {
    final value = metadata['attachments'];
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => item['name'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
  }

  String _sourceTitle(Map<String, dynamic> source) {
    final title = source['title'] as String? ?? '参考资料';
    final page = (source['page_number'] as num?)?.toInt() ?? 0;
    return page > 0 ? '$title，第$page页' : title;
  }

  String _errorText(Object error) {
    if (error is ApiException) return error.message;
    if (error is StateError) return error.message.toString();
    return '操作失败，请稍后重试。';
  }
}
