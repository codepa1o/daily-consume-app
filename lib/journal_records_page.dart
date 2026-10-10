import 'dart:async';

import 'package:flutter/material.dart';

import 'data/api_client.dart';
import 'data/app_database.dart' show dateKey;
import 'data/journal.dart';
import 'journal_editor_page.dart';

class JournalRecordTile extends StatelessWidget {
  const JournalRecordTile(
      {super.key,
      required this.entry,
      required this.onTap,
      this.onComplete,
      this.busy = false,
      this.showDate = false,
      this.onLocate});
  final JournalEntry entry;
  final VoidCallback onTap;
  final ValueChanged<bool>? onComplete;
  final bool busy, showDate;
  final VoidCallback? onLocate;
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        leading: entry.isTodo && onComplete != null
            ? Checkbox(
                value: entry.completed,
                onChanged: busy ? null : (value) => onComplete!(value!),
                semanticLabel: entry.completed
                    ? '取消完成 ${entry.heading}'
                    : '完成 ${entry.heading}')
            : Icon(entry.isTodo
                ? (entry.completed
                    ? Icons.task_alt
                    : Icons.check_box_outline_blank)
                : entry.kind == 'diary'
                    ? Icons.menu_book_outlined
                    : Icons.notes_outlined),
        title: Text(entry.heading,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                decoration:
                    entry.completed ? TextDecoration.lineThrough : null)),
        subtitle: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text:
                      '${showDate ? '${dateKey(entry.date)} · ' : ''}${entry.label}${entry.overdue ? ' · 已逾期' : ''}'),
              if (entry.title.isNotEmpty && entry.content.isNotEmpty)
                TextSpan(
                    text: '\n${entry.content}',
                    style: TextStyle(
                        decoration: entry.completed
                            ? TextDecoration.lineThrough
                            : null)),
            ]),
            maxLines: 3,
            overflow: TextOverflow.ellipsis),
        trailing: onLocate == null
            ? const Icon(Icons.chevron_right, size: 18)
            : IconButton(
                onPressed: onLocate,
                tooltip: '在日历中查看',
                icon: const Icon(Icons.calendar_month_outlined)),
        onTap: busy ? null : onTap,
      );
}

class JournalRecordsPage extends StatefulWidget {
  const JournalRecordsPage({super.key, this.api});
  final JournalApi? api;
  @override
  State<JournalRecordsPage> createState() => _JournalRecordsPageState();
}

class _JournalRecordsPageState extends State<JournalRecordsPage> {
  late final _api = widget.api ?? JournalApi.instance;
  late final int? _owner;
  final _search = TextEditingController();
  final _items = <JournalEntry>[];
  Timer? _debounce;
  String? _kind, _error;
  bool _loading = true, _more = false, _sessionChanged = false;
  int _version = 0, _total = 0;

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    ApiClient.instance.addListener(_accountChanged);
    _load();
  }

  void _accountChanged() {
    if (ApiClient.instance.account?.id == _owner || !mounted) return;
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _version++;
      _items.clear();
      _total = 0;
      _sessionChanged = true;
    });
  }

  Future<void> _load({bool append = false}) async {
    if (_sessionChanged) return;
    final version = ++_version;
    final offset = append ? _items.length : 0;
    setState(() {
      _loading = true;
      _error = null;
      if (!append) {
        _items.clear();
        _total = 0;
        _more = false;
      }
    });
    try {
      final page = await _api.entries(
          q: _search.text.trim(), kind: _kind, offset: offset);
      if (!mounted || _sessionChanged || version != _version) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _more = page.hasMore;
      });
    } catch (error) {
      if (mounted && !_sessionChanged && version == _version)
        setState(() => _error = journalError(error));
    } finally {
      if (mounted && version == _version) setState(() => _loading = false);
    }
  }

  void _searchChanged(String _) {
    _debounce?.cancel();
    // Invalidate the old result immediately, before the new request is sent.
    setState(() {
      _version++;
      _items.clear();
      _error = null;
      _more = false;
      _total = 0;
      _loading = true;
    });
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _edit(JournalEntry entry) async {
    await Navigator.push<DateTime>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                JournalEditorPage(date: entry.date, id: entry.id, api: _api)));
    if (mounted && !_sessionChanged) await _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    ApiClient.instance.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('全部记录')),
        body: _sessionChanged
            ? const Center(child: Text('账号已切换，请返回后重新打开'))
            : RefreshIndicator(
                onRefresh: _load,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: ListView(
                        padding: const EdgeInsets.all(20),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          TextField(
                              controller: _search,
                              onChanged: _searchChanged,
                              maxLength: 100,
                              decoration: const InputDecoration(
                                  hintText: '搜索所有日期的标题和正文',
                                  prefixIcon: Icon(Icons.search),
                                  counterText: '',
                                  border: OutlineInputBorder()),
                              onSubmitted: (_) {
                                _debounce?.cancel();
                                _load();
                              }),
                          const SizedBox(height: 12),
                          Wrap(spacing: 8, children: [
                            for (final option in <String?, String>{
                              null: '全部',
                              'diary': '日记',
                              'memo': '备忘'
                            }.entries)
                              ChoiceChip(
                                  label: Text(option.value),
                                  selected: _kind == option.key,
                                  onSelected: (_) {
                                    _debounce?.cancel();
                                    setState(() => _kind = option.key);
                                    _load();
                                  }),
                          ]),
                          const SizedBox(height: 18),
                          Text('$_total 条记录',
                              style: Theme.of(context).textTheme.labelLarge),
                          for (final entry in _items)
                            JournalRecordTile(
                                entry: entry,
                                showDate: true,
                                onTap: () => _edit(entry),
                                onLocate: () =>
                                    Navigator.pop(context, entry.date)),
                          if (_loading)
                            const Padding(
                                padding: EdgeInsets.all(24),
                                child:
                                    Center(child: CircularProgressIndicator())),
                          if (!_loading && _error == null && _items.isEmpty)
                            const Padding(
                                padding: EdgeInsets.symmetric(vertical: 36),
                                child: Text('没有找到记录，试试其他关键词。',
                                    textAlign: TextAlign.center)),
                          if (_error != null) ...[
                            Text(_error!, textAlign: TextAlign.center),
                            TextButton(
                                onPressed: () =>
                                    _load(append: _items.isNotEmpty),
                                child: const Text('重试')),
                          ],
                          if (_more && !_loading && _error == null)
                            TextButton(
                                onPressed: () => _load(append: true),
                                child: const Text('加载更多')),
                        ]),
                  ),
                ),
              ),
      );
}
