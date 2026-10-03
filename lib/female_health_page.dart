import 'package:flutter/material.dart';

import 'account_pages.dart';
import 'data/api_client.dart';
import 'data/app_database.dart' show dateKey;
import 'data/female_health.dart';
import 'widgets/app_logo.dart';

const _rose = Color(0xffa34f68);
const _roseSoft = Color(0xfff7e6ec);
const _violet = Color(0xff765b95);
const _violetSoft = Color(0xffeee7f4);
const _ink = Color(0xff292c25);
const _muted = Color(0xff72756c);

String healthDateLabel(DateTime date) =>
    '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
String healthTypeLabel(HealthDateType type) => switch (type) {
      HealthDateType.period => '已记录经期',
      HealthDateType.predictedPeriod => '预计经期',
      HealthDateType.fertile => '预计易孕期',
      HealthDateType.ovulation => '估计排卵日',
      HealthDateType.ordinary => '暂无经期记录',
    };

class FemaleHealthPage extends StatefulWidget {
  const FemaleHealthPage({super.key, this.initialData});
  final HealthData? initialData;
  @override
  State<FemaleHealthPage> createState() => _FemaleHealthPageState();
}

class _FemaleHealthPageState extends State<FemaleHealthPage> {
  final _store = FemaleHealthStore();
  HealthData? _data;
  String? _error;
  bool _loading = false;
  DateTime _selected = healthToday();
  late DateTime _month = DateTime.utc(_selected.year, _selected.month);
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    _data = widget.initialData;
    if (_data == null) _reload();
  }

  Future<void> _reload() async {
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _store.load();
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _data = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _error = error is ApiException ? error.message : '读取失败，请重试';
        _loading = false;
      });
    }
  }

  Future<void> _settings() async {
    final data = _data!;
    final cycle = TextEditingController(
        text: data.settings.cycleLength?.toString() ?? '');
    final period = TextEditingController(
        text: data.settings.periodLength?.toString() ?? '');
    var paused = data.settings.paused;
    await _editDialog(
        title: '周期设置',
        build: (update, busy) => [
              const Text('填写你通常的周期。不确定时可以留空，记录更多经期后再估计。'),
              const SizedBox(height: 14),
              TextFormField(
                  controller: cycle,
                  enabled: !busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: '周期长度（天）', hintText: '例如 28，两次经期首日之间的天数'),
                  validator: (value) => _validateDays(value, 365)),
              const SizedBox(height: 12),
              TextFormField(
                  controller: period,
                  enabled: !busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: '经期长度（天）', hintText: '例如 5，通常有经期出血的天数'),
                  validator: (value) => _validateDays(value, 90)),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('暂停预测'),
                  subtitle: const Text('孕期、哺乳期、用药或暂时不需要预测时开启'),
                  value: paused,
                  onChanged:
                      busy ? null : (value) => update(() => paused = value)),
            ],
        save: () => _store.saveSettings(HealthSettings(
            cycleLength: int.tryParse(cycle.text.trim()),
            periodLength: int.tryParse(period.text.trim()),
            paused: paused)));
    cycle.dispose();
    period.dispose();
  }

  String? _validateDays(String? raw, int max) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = int.tryParse(raw.trim());
    return value == null || value < 1 || value > max
        ? '请输入 1～$max 的整数，或留空'
        : null;
  }

  Future<DateTime?> _pickDate(DateTime initial, {DateTime? first}) async {
    final value = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: first ?? DateTime(2000),
        lastDate: healthToday(),
        currentDate: healthToday(),
        helpText: '选择实际出血日期');
    return value == null ? null : healthDate(value);
  }

  Future<void> _editPeriod(
      {MenstrualPeriod? existing, bool finish = false}) async {
    var start = existing?.start ??
        (_selected.isAfter(healthToday()) ? healthToday() : _selected);
    var through = existing?.dates.last ?? start;
    var ended = finish || (existing != null && !existing.ongoing);
    var confirmed = through == start;
    var rangeChanged = false;
    await _editDialog(
        title: existing == null
            ? '记录经期'
            : finish
                ? '经期结束'
                : '编辑经期',
        build: (update, busy) => [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('经期开始日期'),
                  subtitle: Text(dateKey(start)),
                  trailing: const Icon(Icons.calendar_today_outlined),
                  onTap: busy
                      ? null
                      : () async {
                          final value = await _pickDate(start);
                          if (value != null && mounted)
                            update(() {
                              start = value;
                              rangeChanged = true;
                              if (through.isBefore(start)) through = start;
                              confirmed = through == start;
                            });
                        }),
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(ended ? '最后一天出血' : '已确认出血至'),
                  subtitle: Text(dateKey(through)),
                  trailing: const Icon(Icons.calendar_today_outlined),
                  onTap: busy
                      ? null
                      : () async {
                          final value = await _pickDate(through, first: start);
                          if (value != null && mounted)
                            update(() {
                              through = value;
                              rangeChanged = true;
                              confirmed = through == start;
                            });
                        }),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('本次经期已结束'),
                  subtitle: const Text('结束日期是最后出血日，不是点击结束的日期'),
                  value: ended,
                  onChanged:
                      busy ? null : (value) => update(() => ended = value)),
              if (through != start && (existing == null || rangeChanged))
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('确认选定区间每天都有经期出血'),
                    subtitle: existing == null
                        ? null
                        : const Text('保存将替换本次经期的出血日期；不连续的日期可在月历中单独修改'),
                    value: confirmed,
                    onChanged: busy
                        ? null
                        : (value) => update(() => confirmed = value!)),
              const Text('只记录已发生的出血，之后的日期不会自动记为经期。',
                  style: TextStyle(color: _muted, fontSize: 12)),
            ],
        save: () async {
          if (!confirmed && (existing == null || rangeChanged))
            throw const ApiException('请确认实际出血日期，或缩小日期范围');
          if (through.difference(start).inDays > 365)
            throw const ApiException('一次记录的日期跨度不能超过一年');
          await _store.savePeriod(MenstrualPeriod(
              id: existing?.id,
              start: start,
              end: ended ? through : null,
              dates: existing != null && !rangeChanged
                  ? existing.dates
                  : healthDateRange(start, through)));
        });
  }

  Future<void> _recordDay() async {
    final date = _selected;
    if (date.isAfter(healthToday())) return;
    final existing = _data!.dayAt(date);
    var flow = existing?.flow ?? 'none';
    var pain = existing?.pain ?? 0;
    var mood = existing?.mood ?? '';
    var spotting = existing?.spotting ?? false;
    final symptoms = {...?existing?.symptoms};
    final notes = TextEditingController(text: existing?.notes ?? '');
    await _editDialog(
        title: '${dateKey(date)} · 每日记录',
        build: (update, busy) => [
              const Text('症状和点滴出血独立保存，不会自动创建经期。',
                  style: TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                  initialValue: flow,
                  decoration: const InputDecoration(labelText: '经量'),
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('未记录')),
                    DropdownMenuItem(value: 'light', child: Text('少')),
                    DropdownMenuItem(value: 'medium', child: Text('中')),
                    DropdownMenuItem(value: 'heavy', child: Text('多'))
                  ],
                  onChanged:
                      busy ? null : (value) => update(() => flow = value!)),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                  initialValue: pain,
                  decoration: const InputDecoration(labelText: '痛经程度'),
                  items: [
                    for (var i = 0; i < 4; i++)
                      DropdownMenuItem(
                          value: i, child: Text(['无', '轻', '中', '重'][i]))
                  ],
                  onChanged:
                      busy ? null : (value) => update(() => pain = value!)),
              const SizedBox(height: 12),
              Wrap(spacing: 6, children: [
                for (final name in ['腹胀', '头痛', '腰酸', '疲劳', '乳房胀痛', '恶心', '失眠'])
                  FilterChip(
                      label: Text(name),
                      selected: symptoms.contains(name),
                      onSelected: busy
                          ? null
                          : (selected) => update(() {
                                selected
                                    ? symptoms.add(name)
                                    : symptoms.remove(name);
                              }))
              ]),
              DropdownButtonFormField<String>(
                  initialValue: mood,
                  decoration: const InputDecoration(labelText: '心情'),
                  items: [
                    for (final name in ['', '平静', '开心', '低落', '烦躁', '焦虑'])
                      DropdownMenuItem(
                          value: name, child: Text(name.isEmpty ? '未记录' : name))
                  ],
                  onChanged:
                      busy ? null : (value) => update(() => mood = value!)),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('点滴出血'),
                  value: spotting,
                  onChanged:
                      busy ? null : (value) => update(() => spotting = value)),
              TextFormField(
                  controller: notes,
                  enabled: !busy,
                  maxLength: 2000,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '备注（选填）')),
            ],
        save: () => _store.saveDay(HealthDay(
            date: date,
            flow: flow,
            pain: pain,
            symptoms: symptoms.toList(),
            mood: mood,
            spotting: spotting,
            notes: notes.text.trim())));
    notes.dispose();
  }

  Future<void> _editDialog(
      {required String title,
      required List<Widget> Function(void Function(VoidCallback), bool) build,
      required Future<void> Function() save}) async {
    final form = GlobalKey<FormState>();
    var busy = false;
    String? error;
    final route = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, update) => PopScope(
                  canPop: !busy,
                  child: AlertDialog(
                    title: Text(title),
                    content: SizedBox(
                        width: 400,
                        child: SingleChildScrollView(
                            child: Form(
                                key: form,
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ...build(update, busy),
                                      if (error != null)
                                        Padding(
                                            padding:
                                                const EdgeInsets.only(top: 12),
                                            child: Text(error!,
                                                style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .error)))
                                    ])))),
                    actions: [
                      TextButton(
                          onPressed: busy
                              ? null
                              : () => Navigator.pop(dialogContext, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  if (!form.currentState!.validate()) return;
                                  update(() {
                                    busy = true;
                                    error = null;
                                  });
                                  try {
                                    await save();
                                    if (dialogContext.mounted)
                                      Navigator.pop(dialogContext, true);
                                  } catch (failure) {
                                    if (dialogContext.mounted)
                                      update(() {
                                        busy = false;
                                        error = failure is ApiException
                                            ? failure.message
                                            : '保存失败，请重试';
                                      });
                                  }
                                },
                          child: Text(busy ? '保存中…' : '保存'))
                    ],
                  ),
                )));
    final saved = await Navigator.of(context, rootNavigator: true).push(route);
    // Dispose the caller's controllers only after the closing animation ends.
    await route.completed;
    if (saved == true && mounted) await _reload();
  }

  Future<void> _confirmDelete(
      String message, Future<void> Function() action) async {
    var busy = false;
    String? error;
    final removed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, update) => PopScope(
                  canPop: !busy,
                  child: AlertDialog(
                    title: const Text('删除健康记录'),
                    content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(message),
                          if (error != null)
                            Text(error!,
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.error))
                        ]),
                    actions: [
                      TextButton(
                          onPressed: busy
                              ? null
                              : () => Navigator.pop(dialogContext, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  update(() {
                                    busy = true;
                                    error = null;
                                  });
                                  try {
                                    await action();
                                    if (dialogContext.mounted)
                                      Navigator.pop(dialogContext, true);
                                  } catch (failure) {
                                    if (dialogContext.mounted)
                                      update(() {
                                        busy = false;
                                        error = failure is ApiException
                                            ? failure.message
                                            : '删除失败，请重试';
                                      });
                                  }
                                },
                          child: Text(busy ? '删除中…' : '确认删除'))
                    ],
                  ),
                )));
    if (removed == true && mounted) await _reload();
  }

  Future<void> _toggleBleeding() async {
    final data = _data!;
    final period = data.cycleAt(_selected);
    if (period == null) {
      await _editPeriod();
      return;
    }
    final dates = [...period.dates];
    if (dates.contains(_selected)) {
      if (_selected == period.start || _selected == period.end) {
        await _editPeriod(existing: period);
        return;
      }
      dates.remove(_selected);
    } else {
      dates.add(_selected);
      dates.sort();
    }
    await _editDialog(
        title: '修改经期日期',
        build: (update, busy) => [
              Text(
                  '${dateKey(_selected)} 将${period.hasDate(_selected) ? '移除' : '标记为'}实际经期。其他日期保持原记录。'),
            ],
        save: () => _store.savePeriod(MenstrualPeriod(
            id: period.id,
            start: period.start,
            end: period.end,
            dates: dates)));
  }

  String _summary(HealthPrediction prediction) {
    final data = _data!;
    final today = healthToday();
    if (data.periodAt(today) case final period?)
      return '今天是经期记录第 ${today.difference(period.start).inDays + 1} 天';
    if (data.ongoing != null) return '经期仍标记为进行中，请确认今天或结束日期';
    if (prediction.nextStart == null)
      return data.settings.paused ? '预测已暂停' : '记录你的周期，了解自己的节奏';
    final delta = prediction.nextStart!.difference(today).inDays;
    if (delta < 0) return '已超过预计开始日 ${-delta} 天，请确认是否需要补录';
    return delta == 0 ? '下次经期预计今天开始' : '距离预计下次经期还有 $delta 天';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const SafeArea(
          child: Center(child: CircularProgressIndicator(color: _rose)));
    if (_error != null)
      return NetworkFailure(message: _error!, onRetry: _reload);
    if (_data == null) return const SizedBox.shrink();
    final data = _data!;
    final prediction = HealthPrediction(data, healthToday());
    return SafeArea(
        child: RefreshIndicator(
            onRefresh: _reload,
            color: _rose,
            child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  Row(children: [
                    const AppLogo(),
                    const SizedBox(width: 10),
                    const Text('DAY BY DAY',
                        style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.8,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    IconButton(
                        tooltip: '周期设置',
                        onPressed: _settings,
                        icon: const Icon(Icons.tune_rounded, color: _rose))
                  ]),
                  const SizedBox(height: 16),
                  const Text('女性健康',
                      style: TextStyle(
                          fontFamily: 'serif', fontSize: 32, color: _ink)),
                  const SizedBox(height: 6),
                  const Text('记录身体的节奏，也照顾每一天的感受。',
                      style: TextStyle(fontSize: 13, color: _muted)),
                  const SizedBox(height: 20),
                  Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                          color: _roseSoft,
                          borderRadius: BorderRadius.circular(18)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('你的周期',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: _rose,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 10),
                            Text(_summary(prediction),
                                style: const TextStyle(
                                    fontSize: 20, height: 1.35, color: _ink)),
                            if (prediction.nextStart != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                  '预计开始 ${dateKey(prediction.nextStart!)}${prediction.nextEnd == null ? '' : ' · 预计持续至 ${healthDateLabel(prediction.nextEnd!)}'}',
                                  style: const TextStyle(
                                      fontSize: 12, color: _rose)),
                              const SizedBox(height: 8),
                              Text(prediction.basis,
                                  style: const TextStyle(
                                      fontSize: 11, color: _muted)),
                            ] else ...[
                              const SizedBox(height: 8),
                              Text(
                                  data.settings.paused
                                      ? '实际记录和历史仍会保留。'
                                      : '先记录最近一次经期，再填写通常的周期长度。',
                                  style: const TextStyle(
                                      fontSize: 12, color: _muted)),
                            ],
                            const SizedBox(height: 16),
                            Wrap(spacing: 10, runSpacing: 8, children: [
                              FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: _rose),
                                  onPressed: () => _editPeriod(),
                                  icon: const Icon(Icons.add, size: 18),
                                  label: const Text('经期开始 / 补录')),
                              if (data.ongoing != null)
                                OutlinedButton(
                                    onPressed: () => _editPeriod(
                                        existing: data.ongoing, finish: true),
                                    child: const Text('经期结束')),
                              if (data.periods.isEmpty ||
                                  prediction.nextStart == null)
                                TextButton(
                                    onPressed: _settings,
                                    child: const Text('设置周期')),
                            ]),
                          ])),
                  const SizedBox(height: 20),
                  _calendar(prediction),
                  const SizedBox(height: 16),
                  _dayDetails(prediction),
                  const SizedBox(height: 24),
                  _history(prediction),
                  const SizedBox(height: 20),
                  const Text('经期、易孕期和排卵日为估计，仅供日常记录参考，不能作为避孕或诊断依据。漏记会影响预测。',
                      style:
                          TextStyle(fontSize: 12, height: 1.6, color: _muted)),
                  const SizedBox(height: 10),
                  const Text('健康记录随账号保存在服务器。更改性别只隐藏入口；可在下方独立删除数据。',
                      style:
                          TextStyle(fontSize: 12, height: 1.6, color: _muted)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, children: [
                    TextButton(
                        onPressed: () => _confirmDelete(
                            '删除全部经期和每日记录，保留周期设置。此操作无法撤销。',
                            () => _store.clear(resetSettings: false)),
                        child: const Text('删除全部记录')),
                    TextButton(
                        onPressed: () => _confirmDelete(
                            '删除全部女性健康记录，并重置周期设置。此操作无法撤销。',
                            () => _store.clear(resetSettings: true)),
                        child: const Text('删除数据并重置')),
                  ]),
                ])));
  }

  Widget _calendar(HealthPrediction prediction) => Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      decoration: BoxDecoration(
          color: const Color(0xfffffefa),
          borderRadius: BorderRadius.circular(18)),
      child: Column(children: [
        Row(children: [
          IconButton(
              tooltip: '上个月',
              onPressed: _month.year == 2000 && _month.month == 1
                  ? null
                  : () => setState(() =>
                      _month = DateTime.utc(_month.year, _month.month - 1)),
              icon: const Icon(Icons.chevron_left)),
          Expanded(
              child: TextButton(
                  onPressed: _chooseMonth,
                  child: Text('${_month.year} 年 ${_month.month} 月',
                      style: const TextStyle(color: _ink, fontSize: 16)))),
          IconButton(
              tooltip: '下个月',
              onPressed:
                  _month.year >= healthToday().year + 5 && _month.month == 12
                      ? null
                      : () => setState(() =>
                          _month = DateTime.utc(_month.year, _month.month + 1)),
              icon: const Icon(Icons.chevron_right)),
          TextButton(
              onPressed: () => setState(() {
                    _selected = healthToday();
                    _month = DateTime.utc(_selected.year, _selected.month);
                  }),
              child: const Text('今天')),
        ]),
        HealthCalendar(
            month: _month,
            selected: _selected,
            data: _data!,
            today: healthToday(),
            onSelected: (day) => setState(() => _selected = day)),
        const SizedBox(height: 14),
        const Wrap(spacing: 14, runSpacing: 8, children: [
          _Legend(color: _rose, label: '已记录经期'),
          _Legend(color: _roseSoft, label: '预计经期', predicted: true),
          _Legend(color: _violetSoft, label: '预计易孕期'),
          _Legend(color: _violet, label: '估计排卵日', ring: true),
          _Legend(color: _muted, label: '有每日记录', dot: true),
        ]),
      ]));

  Future<void> _chooseMonth() async {
    var year = _month.year;
    var month = _month.month;
    final chosen = await showDialog<DateTime>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('选择年月'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    DropdownButtonFormField<int>(
                        initialValue: year,
                        decoration: const InputDecoration(labelText: '年份'),
                        items: [
                          for (var i = 2000; i <= healthToday().year + 5; i++)
                            DropdownMenuItem(value: i, child: Text('$i 年'))
                        ],
                        onChanged: (value) => update(() => year = value!)),
                    DropdownButtonFormField<int>(
                        initialValue: month,
                        decoration: const InputDecoration(labelText: '月份'),
                        items: [
                          for (var i = 1; i <= 12; i++)
                            DropdownMenuItem(value: i, child: Text('$i 月'))
                        ],
                        onChanged: (value) => update(() => month = value!)),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () =>
                            Navigator.pop(context, DateTime.utc(year, month)),
                        child: const Text('查看'))
                  ],
                )));
    if (chosen != null && mounted) setState(() => _month = chosen);
  }

  Widget _dayDetails(HealthPrediction prediction) {
    final data = _data!;
    final day = data.dayAt(_selected);
    final period = data.periodAt(_selected);
    final type = prediction.typeAt(_selected);
    final past = !_selected.isAfter(healthToday());
    return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: const Color(0xfffffefa),
            borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${dateKey(_selected)} · ${healthTypeLabel(type)}',
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (period != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    '本周期第 ${_selected.difference(period.start).inDays + 1} 天 · ${period.ongoing ? '进行中' : '已结束'}',
                    style: const TextStyle(color: _rose, fontSize: 12))),
          if (day != null) ...[
            const SizedBox(height: 10),
            Text(
                '经量：${{
                  'none': '未记录',
                  'light': '少',
                  'medium': '中',
                  'heavy': '多'
                }[day.flow]}　痛经：${['无', '轻', '中', '重'][day.pain]}',
                style: const TextStyle(fontSize: 13)),
            if (day.spotting)
              const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('点滴出血（独立记录）', style: TextStyle(fontSize: 13))),
            if (day.symptoms.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(day.symptoms.join(' · '),
                      style: const TextStyle(fontSize: 13))),
            if (day.mood.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('心情：${day.mood}',
                      style: const TextStyle(fontSize: 13))),
            if (day.notes.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(day.notes,
                      style: const TextStyle(fontSize: 13, height: 1.5))),
          ] else
            const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('暂无每日记录。',
                    style: TextStyle(color: _muted, fontSize: 12))),
          if (past)
            Wrap(spacing: 4, children: [
              TextButton(
                  onPressed: _recordDay,
                  child: Text(day == null ? '记录当天感受' : '编辑每日记录')),
              TextButton(
                  onPressed: _toggleBleeding,
                  child: Text(period != null ? '修改经期日期' : '标记为经期')),
              if (day != null)
                TextButton(
                    onPressed: () => _confirmDelete(
                        '删除 ${dateKey(_selected)} 的症状与备注，不删除经期日期。',
                        () => _store.deleteDay(_selected)),
                    child: const Text('删除每日记录')),
            ])
          else
            const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('未来日期只展示估计，不能记录实际出血。',
                    style: TextStyle(color: _muted, fontSize: 12))),
        ]));
  }

  Widget _history(HealthPrediction prediction) {
    final data = _data!;
    final periods = data.sortedPeriods.reversed.toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('周期回顾', style: TextStyle(fontFamily: 'serif', fontSize: 23)),
      const SizedBox(height: 12),
      Wrap(spacing: 18, runSpacing: 8, children: [
        Text(
            '典型周期 ${prediction.cycleLength == null ? '待记录' : '${prediction.cycleLength} 天'}',
            style: const TextStyle(color: _muted, fontSize: 13)),
        Text(
            '典型经期 ${prediction.periodLength == null ? '待记录' : '${prediction.periodLength} 天'}',
            style: const TextStyle(color: _muted, fontSize: 13)),
        Text('${periods.length} 次记录',
            style: const TextStyle(color: _muted, fontSize: 13)),
      ]),
      if (data.cycleLengths.isNotEmpty) ...[
        const SizedBox(height: 14),
        const Text('最近周期长度（按记录顺序）',
            style: TextStyle(fontSize: 12, color: _muted)),
        const SizedBox(height: 8),
        SizedBox(
            height: 70,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final length
                  in data.cycleLengths.reversed.take(12).toList().reversed)
                Expanded(
                    child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text('$length',
                                  style: const TextStyle(
                                      fontSize: 11, color: _rose)),
                              const SizedBox(height: 4),
                              Container(
                                  height: (length /
                                          (data.cycleLengths.reduce(
                                              (a, b) => a > b ? a : b)) *
                                          45)
                                      .clamp(3, 45),
                                  decoration: BoxDecoration(
                                      color: _roseSoft,
                                      borderRadius: BorderRadius.circular(3))),
                            ]))),
            ])),
      ],
      if (data.periodLengths.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(
            '最近经期出血天数：${data.periodLengths.reversed.take(12).toList().reversed.join(' → ')}',
            style: const TextStyle(fontSize: 12, color: _muted)),
      ],
      const SizedBox(height: 12),
      if (periods.isEmpty)
        const Text('还没有经期记录，可以从最近一次开始。',
            style: TextStyle(color: _muted, fontSize: 13)),
      ...periods.map((period) {
        final chronological = data.sortedPeriods;
        final index = chronological.indexOf(period);
        final interval = index > 0
            ? period.start.difference(chronological[index - 1].start).inDays
            : null;
        return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                    '${dateKey(period.start)} — ${period.end == null ? '进行中' : healthDateLabel(period.end!)}',
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                    '已记录出血 ${period.dates.length} 天${interval == null ? '' : ' · 首日间隔 $interval 天'}',
                    style: const TextStyle(fontSize: 12, color: _muted)),
                onTap: () => _editPeriod(existing: period),
                trailing: IconButton(
                    tooltip: '删除本次经期',
                    icon: const Icon(Icons.delete_outline, size: 19),
                    onPressed: () => _confirmDelete(
                        '删除 ${dateKey(period.start)} 开始的经期，保留独立的每日症状记录。',
                        () => _store.deletePeriod(period.id!)))));
      }),
    ]);
  }
}

class HealthCalendar extends StatelessWidget {
  const HealthCalendar(
      {super.key,
      required this.month,
      required this.selected,
      required this.data,
      required this.today,
      required this.onSelected});
  final DateTime month;
  final DateTime selected;
  final HealthData data;
  final DateTime today;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final first = DateTime.utc(month.year, month.month);
    final count = DateTime.utc(month.year, month.month + 1, 0).day;
    final offset = first.weekday - 1;
    final cells = ((count + offset + 6) ~/ 7) * 7;
    final prediction = HealthPrediction(data, today);
    return Column(children: [
      Row(children: [
        for (final label in ['一', '二', '三', '四', '五', '六', '日'])
          Expanded(
              child: Center(
                  child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(label,
                          style:
                              const TextStyle(fontSize: 12, color: _muted)))))
      ]),
      GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 4,
              crossAxisSpacing: 3,
              mainAxisExtent: 46),
          itemCount: cells,
          itemBuilder: (context, index) {
            final day = index - offset + 1;
            if (day < 1 || day > count) return const SizedBox.shrink();
            final date = DateTime.utc(month.year, month.month, day);
            final type = prediction.typeAt(date);
            final recorded = type == HealthDateType.period;
            final isSelected = date == healthDate(selected);
            final isToday = date == healthDate(today);
            final info = data.dayAt(date) != null;
            final color = switch (type) {
              HealthDateType.period => _rose,
              HealthDateType.predictedPeriod => _roseSoft,
              HealthDateType.fertile => _violetSoft,
              _ => Colors.transparent,
            };
            return Semantics(
                excludeSemantics: true,
                onTap: () => onSelected(date),
                label:
                    '${dateKey(date)} ${healthTypeLabel(type)}${info ? '，有每日记录' : ''}${isToday ? '，今天' : ''}',
                selected: isSelected,
                button: true,
                child: InkWell(
                  key: ValueKey(dateKey(date)),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelected(date),
                  child: Container(
                      foregroundDecoration:
                          type == HealthDateType.predictedPeriod
                              ? const _DashedDecoration()
                              : null,
                      decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: isSelected
                                  ? _ink
                                  : type == HealthDateType.ovulation
                                      ? _violet
                                      : isToday
                                          ? _rose
                                          : Colors.transparent,
                              width: isSelected ? 2 : 1.5)),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('$day',
                                style: TextStyle(
                                    fontSize: 14,
                                    color: recorded
                                        ? Colors.white
                                        : type == HealthDateType.ovulation
                                            ? _violet
                                            : _ink,
                                    fontWeight: isToday
                                        ? FontWeight.w700
                                        : FontWeight.w500)),
                            SizedBox(
                                height: 9,
                                child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (type ==
                                          HealthDateType.predictedPeriod)
                                        Text('┄',
                                            style: TextStyle(
                                                height: 0.8,
                                                fontSize: 12,
                                                color: _rose)),
                                      if (type == HealthDateType.ovulation)
                                        const Text('◇',
                                            style: TextStyle(
                                                height: 0.8,
                                                fontSize: 10,
                                                color: _violet)),
                                      if (info)
                                        Container(
                                            width: 4,
                                            height: 4,
                                            margin:
                                                const EdgeInsets.only(left: 2),
                                            decoration: BoxDecoration(
                                                color: recorded
                                                    ? Colors.white
                                                    : _muted,
                                                shape: BoxShape.circle)),
                                    ])),
                          ])),
                ));
          }),
    ]);
  }
}

class _DashedDecoration extends Decoration {
  const _DashedDecoration();
  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _DashedPainter();
}

class _DashedPainter extends BoxPainter {
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = (offset & configuration.size!).deflate(3);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(9)));
    final paint = Paint()
      ..color = _rose
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      for (double distance = 0; distance < metric.length; distance += 7) {
        canvas.drawPath(metric.extractPath(distance, distance + 4), paint);
      }
    }
  }
}

class _Legend extends StatelessWidget {
  const _Legend(
      {required this.color,
      required this.label,
      this.predicted = false,
      this.ring = false,
      this.dot = false});
  final Color color;
  final String label;
  final bool predicted;
  final bool ring;
  final bool dot;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: dot ? 5 : 12,
            height: dot ? 5 : 12,
            decoration: BoxDecoration(
                color: ring ? Colors.transparent : color,
                shape: BoxShape.circle,
                border: ring || predicted
                    ? Border.all(color: ring ? color : _rose)
                    : null),
            child: predicted
                ? const Center(
                    child: Text('┄',
                        style:
                            TextStyle(height: 0.8, color: _rose, fontSize: 8)))
                : null),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 10, color: _muted)),
      ]);
}
