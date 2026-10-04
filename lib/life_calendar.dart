import 'package:flutter/material.dart';

import 'data/api_client.dart';
import 'data/app_database.dart' show dateKey;
import 'data/journal.dart';
import 'journal_editor_page.dart';
import 'journal_records_page.dart';

class LifeCalendar extends StatefulWidget {
  const LifeCalendar({super.key, this.api});
  final JournalApi? api;
  @override
  State<LifeCalendar> createState() => _LifeCalendarState();
}

class _LifeCalendarState extends State<LifeCalendar> {
  late final _api = widget.api ?? JournalApi.instance;
  late final int? _owner;
  DateTime _selected = journalToday();
  Map<DateTime, JournalDaySummary> _days = {};
  final _items = <JournalEntry>[];
  final _busy = <int>{};
  int _monthVersion = 0, _dayVersion = 0, _total = 0;
  bool _monthLoading = true,
      _dayLoading = true,
      _more = false,
      _sessionChanged = false;
  String? _monthError, _dayError;
  DateTime get _month => DateTime.utc(_selected.year, _selected.month);

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    ApiClient.instance.addListener(_accountChanged);
    _refresh();
  }

  void _accountChanged() {
    if (ApiClient.instance.account?.id == _owner || !mounted) return;
    setState(() {
      _monthVersion++;
      _dayVersion++;
      _days.clear();
      _items.clear();
      _busy.clear();
      _sessionChanged = true;
    });
  }

  Future<void> _refresh() async {
    await Future.wait([_loadMonth(), _loadDay()]);
  }

  Future<void> _loadMonth() async {
    if (_sessionChanged) return;
    final version = ++_monthVersion;
    final month = _month;
    setState(() {
      _monthLoading = true;
      _monthError = null;
      _days = {};
    });
    try {
      final days = await _api.calendar(month);
      if (mounted && !_sessionChanged && version == _monthVersion)
        setState(() => _days = days);
    } catch (error) {
      if (mounted && !_sessionChanged && version == _monthVersion)
        setState(() => _monthError = journalError(error));
    } finally {
      if (mounted && version == _monthVersion)
        setState(() => _monthLoading = false);
    }
  }

  Future<void> _loadDay({bool append = false}) async {
    if (_sessionChanged) return;
    final version = ++_dayVersion;
    final selected = _selected;
    final offset = append ? _items.length : 0;
    setState(() {
      _dayLoading = true;
      _dayError = null;
      if (!append) {
        _items.clear();
        _more = false;
        _total = 0;
      }
    });
    try {
      final page = await _api.entries(date: selected, offset: offset);
      if (mounted && !_sessionChanged && version == _dayVersion)
        setState(() {
          _items.addAll(page.items);
          _more = page.hasMore;
          _total = page.total;
        });
    } catch (error) {
      if (mounted && !_sessionChanged && version == _dayVersion)
        setState(() => _dayError = journalError(error));
    } finally {
      if (mounted && version == _dayVersion)
        setState(() => _dayLoading = false);
    }
  }

  void _select(DateTime date) {
    final changedMonth = journalMonthKey(date) != journalMonthKey(_selected);
    setState(() => _selected = journalDate(date));
    if (changedMonth) _loadMonth();
    _loadDay();
  }

  Future<void> _chooseMonth() async {
    var year = _month.year;
    var month = _month.month;
    final chosen = await showDialog<DateTime>(
        context: context,
        builder: (context) => StatefulBuilder(
              builder: (context, setDialog) => AlertDialog(
                  title: const Text('跳转年月'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    DropdownButtonFormField<int>(
                        initialValue: year,
                        decoration: const InputDecoration(labelText: '年份'),
                        items: [
                          for (var y = 2000; y <= journalLastDate().year; y++)
                            DropdownMenuItem(value: y, child: Text('$y 年'))
                        ],
                        onChanged: (value) => setDialog(() => year = value!)),
                    DropdownButtonFormField<int>(
                        initialValue: month,
                        decoration: const InputDecoration(labelText: '月份'),
                        items: [
                          for (var m = 1; m <= 12; m++)
                            DropdownMenuItem(value: m, child: Text('$m 月'))
                        ],
                        onChanged: (value) => setDialog(() => month = value!)),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () =>
                            Navigator.pop(context, DateTime.utc(year, month)),
                        child: const Text('跳转'))
                  ]),
            ));
    if (chosen != null && mounted && !_sessionChanged) _select(chosen);
  }

  Future<void> _edit({JournalEntry? entry, String kind = 'diary'}) async {
    final result = await Navigator.push<DateTime>(
        context,
        MaterialPageRoute(
            builder: (_) => JournalEditorPage(
                date: entry?.date ?? _selected,
                kind: kind,
                id: entry?.id,
                api: _api)));
    if (!mounted || _sessionChanged) return;
    // Even a cancelled editor may have encountered a concurrent change.
    if (result != null) setState(() => _selected = journalDate(result));
    await _refresh();
  }

  Future<void> _complete(JournalEntry entry, bool value) async {
    setState(() => _busy.add(entry.id));
    try {
      await _api.setCompleted(entry, value);
    } catch (error) {
      if (mounted && !_sessionChanged)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(journalError(error))));
    } finally {
      if (mounted && !_sessionChanged) {
        setState(() => _busy.remove(entry.id));
        await _refresh();
      }
    }
  }

  @override
  void dispose() {
    ApiClient.instance.removeListener(_accountChanged);
    super.dispose();
  }

  Widget _failure(String message, VoidCallback retry) => Column(children: [
        Text(message, textAlign: TextAlign.center),
        TextButton(onPressed: retry, child: const Text('重试')),
      ]);

  @override
  Widget build(BuildContext context) {
    if (_sessionChanged) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final completed = _items.where((item) => item.completed).toList();
    final previous = DateTime.utc(_month.year, _month.month - 1);
    final next = DateTime.utc(_month.year, _month.month + 1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 28),
      Row(children: [
        Expanded(
            child: Text('生活日历', style: Theme.of(context).textTheme.titleLarge)),
        TextButton(
            onPressed: () async {
              final result = await Navigator.push<DateTime>(
                  context,
                  MaterialPageRoute(
                      builder: (_) => JournalRecordsPage(api: _api)));
              if (!mounted || _sessionChanged) return;
              if (result != null)
                setState(() => _selected = journalDate(result));
              await _refresh();
            },
            child: const Text('全部记录'))
      ]),
      const Text('留住日常，也记得接下来的小事。'),
      const SizedBox(height: 16),
      Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: scheme.surface,
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Row(children: [
                  IconButton(
                      onPressed:
                          previous.year < 2000 ? null : () => _select(previous),
                      icon: const Icon(Icons.chevron_left),
                      tooltip: '上一月'),
                  Expanded(
                      child: TextButton(
                          onPressed: _chooseMonth,
                          child: Text('${_month.year} 年 ${_month.month} 月'))),
                  IconButton(
                      onPressed: next.isAfter(journalLastDate())
                          ? null
                          : () => _select(next),
                      icon: const Icon(Icons.chevron_right),
                      tooltip: '下一月'),
                ]),
                Row(children: [
                  for (final day in ['一', '二', '三', '四', '五', '六', '日'])
                    Expanded(
                        child: Center(
                            child: Text(day,
                                style:
                                    Theme.of(context).textTheme.labelMedium)))
                ]),
                const SizedBox(height: 8),
                GridView.count(
                    crossAxisCount: 7,
                    mainAxisSpacing: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio:
                        MediaQuery.textScalerOf(context).scale(1) > 1.3
                            ? 0.55
                            : 0.72,
                    children: [
                      for (final date in journalMonthCells(_month))
                        if (date == null)
                          const SizedBox.shrink()
                        else
                          _dayCell(date, scheme)
                    ]),
                if (_monthLoading) const LinearProgressIndicator(minHeight: 2),
                if (_monthError != null) _failure(_monthError!, _loadMonth),
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 8, children: [
                  _legend(Icons.menu_book_outlined, '日记'),
                  _legend(Icons.notes_outlined, '备忘'),
                  _legend(Icons.check_box_outline_blank, '待办'),
                  _legend(Icons.task_alt, '已完成'),
                ]),
                TextButton(
                    onPressed: () => _select(journalToday()),
                    child: const Text('回到今天')),
              ]))),
      const SizedBox(height: 18),
      Text('${dateKey(_selected)} · $_total 条记录',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 8, children: [
        FilledButton.icon(
            onPressed: _selected.isAfter(journalToday()) ? null : () => _edit(),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('写日记')),
        OutlinedButton.icon(
            onPressed: () => _edit(kind: 'memo'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('记备忘')),
      ]),
      if (_selected.isAfter(journalToday()))
        const Padding(
            padding: EdgeInsets.only(top: 8), child: Text('未来的安排可以记在备忘里。')),
      for (final item in _items.where((item) => !item.completed))
        JournalRecordTile(
            entry: item,
            onTap: () => _edit(entry: item),
            busy: _busy.contains(item.id),
            onComplete: (value) => _complete(item, value)),
      if (completed.isNotEmpty)
        ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('已完成（${completed.length}）'),
            children: [
              for (final item in completed)
                JournalRecordTile(
                    entry: item,
                    onTap: () => _edit(entry: item),
                    busy: _busy.contains(item.id),
                    onComplete: (value) => _complete(item, value))
            ]),
      if (_dayLoading)
        const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator())),
      if (_dayError != null)
        _failure(_dayError!, () => _loadDay(append: _items.isNotEmpty)),
      if (!_dayLoading && _dayError == null && _items.isEmpty)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Text('这一天还没有记录。\n写一点日记，或记下一件小事。',
                style: TextStyle(height: 1.7))),
      if (_more && !_dayLoading && _dayError == null)
        TextButton(
            onPressed: () => _loadDay(append: true), child: const Text('加载更多')),
    ]);
  }

  Widget _legend(IconData icon, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(fontSize: 11))
      ]);

  Widget _dayCell(DateTime date, ColorScheme scheme) {
    final summary = _days[date];
    final today = date == journalToday();
    final selected = date == _selected;
    final icons = <IconData>[
      if ((summary?.diaries ?? 0) > 0) Icons.menu_book_outlined,
      if ((summary?.memos ?? 0) > 0) Icons.notes_outlined,
      if ((summary?.pending ?? 0) > 0) Icons.check_box_outline_blank,
      if ((summary?.completed ?? 0) > 0) Icons.task_alt,
    ];
    final label =
        '${dateKey(date)}${today ? '，今天' : ''}，日记 ${summary?.diaries ?? 0}，备忘 ${summary?.memos ?? 0}，未完成待办 ${summary?.pending ?? 0}，已完成 ${summary?.completed ?? 0}';
    return Semantics(
      label: label,
      selected: selected,
      button: true,
      excludeSemantics: true,
      child: InkWell(
          onTap: () => _select(date),
          borderRadius: BorderRadius.circular(12),
          child: Container(
              decoration: BoxDecoration(
                  color: selected ? scheme.primaryContainer : null,
                  borderRadius: BorderRadius.circular(12),
                  border: today ? Border.all(color: scheme.primary) : null),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${date.day}',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: today || selected
                                ? FontWeight.bold
                                : FontWeight.normal)),
                    const SizedBox(height: 6),
                    Wrap(
                        spacing: 1,
                        runSpacing: 1,
                        alignment: WrapAlignment.center,
                        children: [
                          for (final icon in icons)
                            Icon(icon, size: 9, color: scheme.primary)
                        ]),
                  ]))),
    );
  }
}
