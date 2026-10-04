import 'package:flutter/material.dart';

import 'data/api_client.dart';
import 'data/app_database.dart' show dateKey;
import 'data/journal.dart';

class JournalEditorPage extends StatefulWidget {
  const JournalEditorPage(
      {super.key, required this.date, this.kind = 'diary', this.id, this.api});
  final DateTime date;
  final String kind;
  final int? id;
  final JournalApi? api;
  @override
  State<JournalEditorPage> createState() => _JournalEditorPageState();
}

class _JournalEditorPageState extends State<JournalEditorPage> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  final _form = GlobalKey<FormState>();
  late final _api = widget.api ?? JournalApi.instance;
  late final int? _owner;
  late DateTime _date = journalDate(widget.date);
  late String _kind = widget.kind;
  final _requestId = journalRequestId();
  JournalEntry? _original;
  Map<String, dynamic>? _submitted;
  bool _todo = false, _completed = false, _loading = false, _saving = false;
  bool _allowPop = false, _uncertain = false, _sessionChanged = false;
  String? _error;

  Map<String, dynamic> get _input => {
        'entry_date': dateKey(_date),
        'kind': _kind,
        'title': _title.text.trim(),
        'content': _content.text.trim(),
        'is_todo': _todo,
        'completed': _todo && _completed,
      };
  bool get _dirty => _original == null
      ? _title.text.isNotEmpty || _content.text.isNotEmpty || _todo
      : !_original!.matches(_input);
  bool get _editable =>
      !_loading && !_saving && !_uncertain && !_sessionChanged;

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    _title.addListener(_edited);
    _content.addListener(_edited);
    ApiClient.instance.addListener(_accountChanged);
    if (widget.id != null) _load();
  }

  void _edited() {
    if (mounted) setState(() {});
  }

  void _accountChanged() {
    if (ApiClient.instance.account?.id == _owner || !mounted) return;
    _title.clear();
    _content.clear();
    setState(() {
      _original = null;
      _submitted = null;
      _uncertain = false;
      _sessionChanged = true;
      _error = '账号已切换，请返回后重新打开';
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entry = await _api.detail(widget.id!);
      if (!mounted || _sessionChanged) return;
      _apply(entry);
    } catch (error) {
      if (mounted && !_sessionChanged)
        setState(() => _error = journalError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _apply(JournalEntry entry) {
    _title.text = entry.title;
    _content.text = entry.content;
    setState(() {
      _original = entry;
      _date = entry.date;
      _kind = entry.kind;
      _todo = entry.isTodo;
      _completed = entry.completed;
      _error = null;
      _uncertain = false;
      _submitted = null;
    });
  }

  void _finish(DateTime? date) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, date);
    });
  }

  Future<void> _save() async {
    if (_saving || _sessionChanged || (widget.id != null && _original == null))
      return;
    if (!_uncertain && !_form.currentState!.validate()) return;
    final input = _uncertain ? _submitted! : _input;
    _submitted = Map<String, dynamic>.from(input);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entry =
          await _api.save(input, original: _original, requestId: _requestId);
      if (mounted && !_sessionChanged) _finish(entry.date);
    } catch (error) {
      // A prior update may have committed before its response was lost.
      if (_original != null &&
          error is ApiException &&
          error.statusCode == 409) {
        try {
          final latest = await _api.detail(_original!.id);
          if (latest.matches(input) && mounted && !_sessionChanged) {
            _finish(latest.date);
            return;
          }
        } catch (_) {/* Keep the user's text when reconciliation fails. */}
      }
      if (mounted && !_sessionChanged) {
        setState(() {
          _uncertain = error is! ApiException ||
              error.statusCode == 0 ||
              error.statusCode >= 500;
          _error = _uncertain
              ? '提交结果暂未确认，内容已保留。请重试同一次提交，确认后再修改。'
              : journalError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _leave() async {
    if (_saving) return;
    if (!_dirty && !_uncertain) {
      _finish(null);
      return;
    }
    final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('内容还没有确认保存'),
              content: Text(_uncertain
                  ? '上次提交可能已保存。放弃只会关闭本页，不会撤销服务器上的记录。'
                  : '保存后退出，或继续编辑。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, 'edit'),
                    child: const Text('继续编辑')),
                TextButton(
                    onPressed: () => Navigator.pop(context, 'discard'),
                    child: const Text('放弃并退出')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, 'save'),
                    child: Text(_uncertain ? '重试保存' : '保存')),
              ],
            ));
    if (!mounted) return;
    if (choice == 'discard') _finish(_uncertain ? _date : null);
    if (choice == 'save') await _save();
  }

  Future<void> _latest() async {
    try {
      final entry = await _api.detail(widget.id!);
      if (!mounted || _sessionChanged) return;
      final use = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('服务器最新内容'),
                content: SingleChildScrollView(
                    child: SelectableText(
                        '${dateKey(entry.date)}\n${entry.title}\n\n${entry.content}\n\n选择「用我的输入继续」后，再次保存会用本页内容更新这个版本。')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, 'cancel'),
                      child: const Text('保留我的输入')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, 'continue'),
                      child: const Text('用我的输入继续')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, 'replace'),
                      child: const Text('使用最新内容')),
                ],
              ));
      if (!mounted || _sessionChanged) return;
      if (use == 'replace') _apply(entry);
      if (use == 'continue')
        setState(() {
          _original = entry;
          _error = null;
        });
    } catch (error) {
      if (mounted && !_sessionChanged)
        setState(() => _error = journalError(error));
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('删除这条记录？'),
              content: const Text('删除后无法恢复。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除')),
              ],
            ));
    if (confirmed != true || !mounted || _sessionChanged) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.delete(_original!);
      if (mounted && !_sessionChanged) _finish(_original!.date);
    } catch (error) {
      if (mounted && !_sessionChanged)
        setState(() => _error = journalError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    ApiClient.instance.removeListener(_accountChanged);
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<DateTime?>(
        canPop: _allowPop || (!_dirty && !_saving && !_uncertain),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
                onPressed: _saving ? null : _leave,
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回'),
            title: Text(_kind == 'diary' ? '写日记' : '记备忘'),
            actions: [
              if (_original != null)
                IconButton(
                    onPressed: _editable ? _delete : null,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '删除记录')
            ],
          ),
          body: _sessionChanged
              ? const Center(child: Text('账号已切换，请返回后重新打开'))
              : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : widget.id != null && _original == null
                      ? Center(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(_error ?? '加载失败'),
                          TextButton(onPressed: _load, child: const Text('重试'))
                        ]))
                      : Form(
                          key: _form,
                          child: ListView(
                              padding: const EdgeInsets.all(20),
                              children: [
                                Text(
                                    _kind == 'diary'
                                        ? '给这一天，留一点文字。'
                                        : '把想法和安排，先记下来。',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall),
                                const SizedBox(height: 18),
                                ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(
                                        Icons.calendar_today_outlined),
                                    title: Text(dateKey(_date)),
                                    trailing: const Text('修改日期'),
                                    onTap: !_editable
                                        ? null
                                        : () async {
                                            final selected =
                                                await showDatePicker(
                                                    context: context,
                                                    initialDate: _date,
                                                    firstDate:
                                                        DateTime.utc(2000),
                                                    lastDate: _kind == 'diary'
                                                        ? journalToday()
                                                        : journalLastDate());
                                            if (selected != null &&
                                                mounted &&
                                                !_sessionChanged)
                                              setState(() => _date =
                                                  journalDate(selected));
                                          }),
                                TextFormField(
                                    controller: _title,
                                    enabled: _editable,
                                    decoration: const InputDecoration(
                                        labelText: '标题（可选）'),
                                    validator: (text) =>
                                        (text ?? '').runes.length > 100
                                            ? '标题最多 100 个字符'
                                            : null),
                                const SizedBox(height: 18),
                                TextFormField(
                                    controller: _content,
                                    enabled: _editable,
                                    minLines: 10,
                                    maxLines: null,
                                    keyboardType: TextInputType.multiline,
                                    decoration: InputDecoration(
                                        labelText: _kind == 'diary'
                                            ? '今天发生了什么？'
                                            : '备忘内容',
                                        alignLabelWithHint: true,
                                        border: const OutlineInputBorder()),
                                    validator: (text) {
                                      if ((text ?? '').runes.length > 20000)
                                        return '正文最多 20,000 个字符';
                                      if ((text ?? '').trim().isEmpty &&
                                          (_kind == 'diary' ||
                                              _title.text.trim().isEmpty))
                                        return _kind == 'diary'
                                            ? '请填写日记正文'
                                            : '标题或正文至少填写一项';
                                      return null;
                                    }),
                                if (_kind == 'memo') ...[
                                  SwitchListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('作为待办'),
                                      subtitle: const Text('可以勾选完成；设置日期不会触发通知'),
                                      value: _todo,
                                      onChanged: !_editable
                                          ? null
                                          : (value) => setState(() {
                                                _todo = value;
                                                if (!value) _completed = false;
                                              })),
                                  if (_todo)
                                    CheckboxListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('已完成'),
                                        value: _completed,
                                        onChanged: !_editable
                                            ? null
                                            : (value) => setState(
                                                () => _completed = value!)),
                                ],
                                if (_error != null) ...[
                                  const SizedBox(height: 14),
                                  Text(_error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                  if (widget.id != null && !_uncertain)
                                    Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton(
                                            onPressed: _saving ? null : _latest,
                                            child: const Text('查看服务器最新内容'))),
                                ],
                                const SizedBox(height: 20),
                                FilledButton(
                                    onPressed: _saving ? null : _save,
                                    child: Text(_saving
                                        ? '保存中…'
                                        : _uncertain
                                            ? '重试本次提交'
                                            : '保存')),
                                const SizedBox(height: 20),
                              ])),
        ),
      );
}
