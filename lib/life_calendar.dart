import 'package:flutter/material.dart';
import 'package:tyme/tyme.dart';

import 'data/api_client.dart';
import 'data/app_database.dart' show dateKey;
import 'data/journal.dart';
import 'journal_editor_page.dart';
import 'journal_records_page.dart';

const _lunarMonths = [
  '',
  '正',
  '二',
  '三',
  '四',
  '五',
  '六',
  '七',
  '八',
  '九',
  '十',
  '冬',
  '腊',
];

const _lunarDays = [
  '',
  '初一',
  '初二',
  '初三',
  '初四',
  '初五',
  '初六',
  '初七',
  '初八',
  '初九',
  '初十',
  '十一',
  '十二',
  '十三',
  '十四',
  '十五',
  '十六',
  '十七',
  '十八',
  '十九',
  '二十',
  '廿一',
  '廿二',
  '廿三',
  '廿四',
  '廿五',
  '廿六',
  '廿七',
  '廿八',
  '廿九',
  '三十',
];

String _lunarLabel(LunarDay day) {
  if (day.getDay() != 1) return _lunarDays[day.getDay()];
  final month = day.getMonth();
  return '${month < 0 ? '闰' : ''}${_lunarMonths[month.abs()]}月';
}

LegalHoliday? _officialHoliday(DateTime date) {
  // Tyme 的官方调休数据覆盖 2001-12-29 至 2026-12-31。
  if (date.isBefore(DateTime.utc(2001, 12, 29)) ||
      date.isAfter(DateTime.utc(2026, 12, 31))) {
    return null;
  }
  return SolarDay.fromYmd(date.year, date.month, date.day).getLegalHoliday();
}

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
    final previous = DateTime.utc(_month.year, _month.month - 1);
    final next = DateTime.utc(_month.year, _month.month + 1);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      final calendar = Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: scheme.surfaceContainerLow,
          child: Padding(
              padding: const EdgeInsets.all(14),
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
                    mainAxisSpacing: 3,
                    crossAxisSpacing: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio:
                        MediaQuery.textScalerOf(context).scale(1) > 1.3
                            ? 0.55
                            : wide
                                ? 1.2
                                : 0.72,
                    children: [
                      for (final date in journalMonthCells(_month))
                        if (date == null)
                          const SizedBox.shrink()
                        else
                          _dayCell(date, scheme,
                              compact: constraints.maxWidth < 480)
                    ]),
                if (_monthLoading) const LinearProgressIndicator(minHeight: 2),
                if (_monthError != null) _failure(_monthError!, _loadMonth),
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 8, children: [
                  _legend(Icons.menu_book_outlined, '日记'),
                  _legend(Icons.notes_outlined, '备忘'),
                  _legend(Icons.check_box_outline_blank, '待办'),
                  _legend(Icons.task_alt, '已完成'),
                  _holidayLegend(scheme, work: false),
                  _holidayLegend(scheme, work: true),
                ]),
                TextButton(
                    onPressed: () => _select(journalToday()),
                    child: const Text('回到今天')),
              ])));
      final selectedDay =
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${dateKey(_selected)} · $_total 条记录',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed:
                  _selected.isAfter(journalToday()) ? null : () => _edit(),
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
        for (final item in _items)
          JournalRecordTile(
              entry: item,
              onTap: () => _edit(entry: item),
              busy: _busy.contains(item.id),
              onComplete: (value) => _complete(item, value)),
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
              onPressed: () => _loadDay(append: true),
              child: const Text('加载更多')),
      ]);

      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 28),
        Row(children: [
          Expanded(
              child:
                  Text('生活日历', style: Theme.of(context).textTheme.titleLarge)),
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
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 6, child: calendar),
            const SizedBox(width: 18),
            Expanded(flex: 5, child: selectedDay),
          ])
        else ...[
          calendar,
          const SizedBox(height: 18),
          selectedDay,
        ],
      ]);
    });
  }

  Widget _legend(IconData icon, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(fontSize: 11))
      ]);

  Widget _holidayLegend(ColorScheme scheme, {required bool work}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        _statusBadge(scheme, work, size: 14),
        const SizedBox(width: 3),
        Text(work ? '补班' : '休息', style: const TextStyle(fontSize: 11)),
      ]);

  Widget _statusBadge(ColorScheme scheme, bool work, {required double size}) =>
      Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: work ? scheme.error : const Color(0xfff2d9dc),
          shape: BoxShape.circle,
        ),
        child: Text(
          work ? '班' : '休',
          style: TextStyle(
            color: work ? scheme.onError : const Color(0xffb9616d),
            fontSize: size < 16 ? 8 : 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  Widget _dayCell(DateTime date, ColorScheme scheme,
      {required bool compact}) {
    final summary = _days[date];
    final today = date == journalToday();
    final selected = date == _selected;
    final solarDay = SolarDay.fromYmd(date.year, date.month, date.day);
    final lunarDay = solarDay.getLunarDay();
    final holiday = _officialHoliday(date);
    final previousHoliday = _officialHoliday(DateTime.utc(
        date.year, date.month, date.day - 1));
    final holidayLabel = holiday != null &&
            !holiday.isWork() &&
            (previousHoliday == null ||
                previousHoliday.isWork() ||
                previousHoliday.getName() != holiday.getName())
        ? holiday.getName()
        : null;
    final solarFestival = solarDay.getFestival()?.getName();
    final lunarFestival = lunarDay.getFestival()?.getName();
    final solarTerm = solarDay.getTermDay().getDayIndex() == 0
        ? solarDay.getTerm().getName()
        : null;
    final secondaryLabel = solarFestival ??
        lunarFestival ??
        solarTerm ??
        holidayLabel ??
        _lunarLabel(lunarDay);
    final isFestival = solarFestival != null ||
        lunarFestival != null ||
        solarTerm != null ||
        holidayLabel != null;
    final icons = <IconData>[
      if ((summary?.diaries ?? 0) > 0) Icons.menu_book_outlined,
      if ((summary?.memos ?? 0) > 0) Icons.notes_outlined,
      if ((summary?.pending ?? 0) > 0) Icons.check_box_outline_blank,
      if ((summary?.completed ?? 0) > 0) Icons.task_alt,
    ];
    final holidayDescription = holiday == null
        ? ''
        : holiday.isWork()
            ? '，补班'
            : '，休息';
    final dateDescription = isFestival ? secondaryLabel : '农历$secondaryLabel';
    final label = '${dateKey(date)}${today ? '，今天' : ''}，$dateDescription'
        '$holidayDescription，日记 ${summary?.diaries ?? 0}，备忘 ${summary?.memos ?? 0}，未完成待办 ${summary?.pending ?? 0}，已完成 ${summary?.completed ?? 0}';
    return Semantics(
      label: label,
      selected: selected,
      button: true,
      excludeSemantics: true,
      child: InkWell(
          onTap: () => _select(date),
          borderRadius: BorderRadius.circular(12),
          child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 3),
              decoration: BoxDecoration(
                  color: selected ? scheme.surface : null,
                  borderRadius: BorderRadius.circular(12),
                  border: today && !selected
                      ? Border.all(color: scheme.primary)
                      : null),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('${date.day}',
                          style: TextStyle(
                              color: selected || holiday?.isWork() == true
                                  ? scheme.onSurface
                                  : holiday != null
                                      ? scheme.onSurfaceVariant
                                      : scheme.onSurface,
                              fontSize: compact ? 18 : 24,
                              fontWeight: today || selected
                                  ? FontWeight.bold
                                  : FontWeight.w500)),
                      if (holiday != null) ...[
                        const SizedBox(width: 2),
                        _statusBadge(scheme, holiday.isWork(),
                            size: compact ? 14 : 18),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(secondaryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: isFestival
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                            fontSize: 10,
                            fontWeight: isFestival
                                ? FontWeight.w600
                                : FontWeight.normal)),
                    if (icons.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Wrap(
                          spacing: 1,
                          runSpacing: 1,
                          alignment: WrapAlignment.center,
                          children: [
                            for (final icon in icons)
                              Icon(icon, size: 9, color: scheme.primary)
                          ]),
                    ],
                    if (selected) ...[
                      const SizedBox(height: 3),
                      Container(
                          width: 26,
                          height: 3,
                          decoration: BoxDecoration(
                              color: scheme.error,
                              borderRadius: BorderRadius.circular(3))),
                    ],
                  ]))),
    );
  }
}
