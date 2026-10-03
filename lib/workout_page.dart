import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/app_database.dart';
import 'data/api_client.dart';
import 'account_pages.dart';
import 'workout_check_in_button.dart';
import 'widgets/app_logo.dart';

const _paper = Color(0xfff6f5ef);
const _surface = Color(0xfffffefa);
const _ink = Color(0xff292c25);
const _muted = Color(0xff85877d);
const _line = Color(0xffe8e7df);
const _sage = Color(0xff64765a);
const _sageSoft = Color(0xffe9eee4);
const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];
const _muscleColors = [
  Color(0xffc87962),
  Color(0xff6d8fa4),
  Color(0xffc59c4d),
  Color(0xff718665),
  Color(0xff9b7ca0),
  Color(0xffd2768c),
  Color(0xff548d86),
  Color(0xff8f7961),
];

enum _WorkoutPeriod { day, week, month }

class WorkoutPage extends StatefulWidget {
  const WorkoutPage({super.key});

  @override
  State<WorkoutPage> createState() => _WorkoutPageState();
}

class _WorkoutPageState extends State<WorkoutPage> {
  final _db = AppDatabase.instance;
  DateTime _selectedDate = _dateOnly(DateTime.now());
  _WorkoutPeriod _period = _WorkoutPeriod.week;
  List<WorkoutMuscle> _muscles = [];
  List<WorkoutLog> _logs = [];
  Map<int, WorkoutDayPlan> _plans = {};
  Set<String> _selectedMuscles = {};
  int _weeklyGoal = 3;
  bool _loading = true;
  String? _loadError;
  bool _saving = false;
  bool _showReward = false;
  Timer? _rewardTimer;
  int _loadVersion = 0;

  DateTime get _weekStart =>
      _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
  DateTime get _monthStart => DateTime(_selectedDate.year, _selectedDate.month);
  DateTime get _monthEnd =>
      DateTime(_selectedDate.year, _selectedDate.month + 1, 0);
  DateTime get _periodStart => switch (_period) {
        _WorkoutPeriod.day => _selectedDate,
        _WorkoutPeriod.week => _weekStart,
        _WorkoutPeriod.month => _monthStart,
      };
  DateTime get _periodEnd => switch (_period) {
        _WorkoutPeriod.day => _selectedDate,
        _WorkoutPeriod.week => _weekStart.add(const Duration(days: 6)),
        _WorkoutPeriod.month => _monthEnd,
      };
  bool get _isToday => _sameDate(_selectedDate, DateTime.now());
  WorkoutDayPlan? get _selectedPlan => _plans[_selectedDate.weekday];
  WorkoutLog? get _selectedLog => _logFor(_selectedDate);
  bool get _isRestDay => _selectedPlan?.isRest ?? false;
  List<WorkoutLog> get _weekLogs =>
      _logs.where((log) => _sameWeek(log.date, _selectedDate)).toList();
  List<WorkoutLog> get _monthLogs => _logs
      .where((log) =>
          log.date.year == _selectedDate.year &&
          log.date.month == _selectedDate.month)
      .toList();

  @override
  void initState() {
    super.initState();
    _load(resetSelection: true);
  }

  @override
  void dispose() {
    _rewardTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool resetSelection = false}) async {
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final weekEnd = _weekStart.add(const Duration(days: 6));
      final start =
          _periodStart.isBefore(_weekStart) ? _periodStart : _weekStart;
      final end = _periodEnd.isAfter(weekEnd) ? _periodEnd : weekEnd;
      final data = await Future.wait<Object>([
        _db.getWorkoutMuscles(),
        _db.getWorkoutPlans(),
        _db.getWorkoutGoal(),
        _db.getWorkoutLogsBetween(start, end),
      ]);
      if (!mounted || version != _loadVersion) return;
      final muscles = data[0] as List<WorkoutMuscle>;
      final plans = data[1] as Map<int, WorkoutDayPlan>;
      final logs = data[3] as List<WorkoutLog>;
      setState(() {
        _muscles = muscles;
        _plans = plans;
        _weeklyGoal = data[2] as int;
        _logs = logs;
        _loading = false;
        if (resetSelection) {
          final log = _logFor(_selectedDate, logs);
          final plan = plans[_selectedDate.weekday];
          _selectedMuscles = log != null
              ? log.muscles.map((muscle) => muscle.name).toSet()
              : (_sameDate(_selectedDate, DateTime.now()) &&
                      !(plan?.isRest ?? false)
                  ? (plan?.muscles.toSet() ?? <String>{})
                  : <String>{});
        }
      });
    } catch (error) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loading = false;
        _loadError = error is ApiException ? error.message : '加载失败，请重试';
      });
    }
  }

  WorkoutLog? _logFor(DateTime date, [List<WorkoutLog>? source]) {
    for (final log in source ?? _logs) {
      if (_sameDate(log.date, date)) return log;
    }
    return null;
  }

  Future<void> _selectDate(DateTime date) async {
    if (date.isBefore(DateTime(2000)) ||
        date.isAfter(_dateOnly(DateTime.now()))) return;
    setState(() {
      _selectedDate = _dateOnly(date);
      _loading = true;
    });
    await _load(resetSelection: true);
  }

  Future<void> _chooseDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (date != null) await _selectDate(date);
  }

  Future<void> _checkIn() async {
    if (_selectedMuscles.isEmpty || _isRestDay || !_isToday) return;
    setState(() => _saving = true);
    final selected = _muscles
        .where((muscle) => _selectedMuscles.contains(muscle.name))
        .toList();
    try {
      await _db.saveWorkoutLog(_selectedDate, selected);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('打卡失败，请重试')));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _showReward = true;
    });
    await _load(resetSelection: true);
    await HapticFeedback.mediumImpact();
    _rewardTimer?.cancel();
    _rewardTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _showReward = false);
    });
  }

  Future<void> _undoCheckIn() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销这天的打卡？'),
        content: const Text('撤销后会恢复为未打卡状态。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('撤销打卡')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!await serverAction(context, () => _db.deleteWorkoutLog(_selectedDate)))
      return;
    if (!mounted) return;
    setState(() => _selectedMuscles = {});
    await _load();
  }

  Future<void> _openPlanEditor() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _paper,
      builder: (context) => _WorkoutPlanEditor(
        goal: _weeklyGoal,
        plans: _plans,
        muscles: _muscles,
      ),
    );
    if (saved == true) await _load(resetSelection: true);
  }

  Future<void> _addMuscle() async {
    final name = TextEditingController();
    var color = _muscleColors[0];
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('新增训练部位'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                maxLength: 12,
                autofocus: true,
                decoration:
                    InputDecoration(labelText: '部位名称', errorText: error),
                onChanged: (_) => setDialogState(() => error = null),
              ),
              const SizedBox(height: 12),
              const Text('标记颜色', style: TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(height: 8),
              _ColorChoices(
                  selected: color,
                  onChanged: (value) => setDialogState(() => color = value)),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final value = name.text.trim();
                if (value.isEmpty ||
                    _muscles.any((muscle) =>
                        muscle.name.toLowerCase() == value.toLowerCase())) {
                  setDialogState(
                      () => error = value.isEmpty ? '请填写部位名称' : '该部位已存在');
                  return;
                }
                if (!await serverAction(dialogContext,
                    () => _db.addWorkoutMuscle(value, color.toARGB32())))
                  return;
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                await _load();
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
  }

  Future<void> _editMuscleColor(WorkoutMuscle muscle) async {
    var color = Color(muscle.colorValue);
    final result = await showDialog<Color>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('修改「${muscle.name}」颜色'),
          content: _ColorChoices(
              selected: color,
              onChanged: (value) => setDialogState(() => color = value)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, color),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (result == null) return;
    if (!mounted ||
        !await serverAction(context,
            () => _db.setWorkoutMuscleColor(muscle.name, result.toARGB32())))
      return;
    await _load();
  }

  Future<void> _manageMuscles() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final custom = _muscles.where((muscle) => !muscle.builtIn).toList();
          return AlertDialog(
            title: const Text('自定义训练部位'),
            scrollable: true,
            content: SizedBox(
              width: 320,
              child: custom.isEmpty
                  ? const Text('还没有自定义部位。')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: custom
                          .map((muscle) => Row(
                                children: [
                                  Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                          color: Color(muscle.colorValue),
                                          shape: BoxShape.circle)),
                                  const SizedBox(width: 9),
                                  Expanded(child: Text(muscle.name)),
                                  IconButton(
                                    tooltip: '修改颜色',
                                    onPressed: () async {
                                      await _editMuscleColor(muscle);
                                      if (dialogContext.mounted)
                                        setDialogState(() {});
                                    },
                                    icon: const Icon(Icons.palette_outlined,
                                        size: 19),
                                  ),
                                  IconButton(
                                    tooltip: '删除部位',
                                    onPressed: () async {
                                      final confirmed = await showDialog<bool>(
                                        context: dialogContext,
                                        builder: (context) => AlertDialog(
                                          title: Text('删除「${muscle.name}」？'),
                                          content: const Text(
                                              '历史打卡会保留，计划中的该部位会一并移除。'),
                                          actions: [
                                            TextButton(
                                                onPressed: () => Navigator.pop(
                                                    context, false),
                                                child: const Text('取消')),
                                            FilledButton(
                                                onPressed: () => Navigator.pop(
                                                    context, true),
                                                child: const Text('删除')),
                                          ],
                                        ),
                                      );
                                      if (confirmed != true) return;
                                      if (!await serverAction(
                                          dialogContext,
                                          () => _db.deleteWorkoutMuscle(
                                              muscle.name))) return;
                                      if (_selectedMuscles
                                              .remove(muscle.name) &&
                                          mounted) setState(() {});
                                      await _load();
                                      if (dialogContext.mounted)
                                        setDialogState(() {});
                                    },
                                    icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 19),
                                  ),
                                ],
                              ))
                          .toList(),
                    ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('完成'))
            ],
          );
        },
      ),
    );
  }

  Future<void> _setPeriod(_WorkoutPeriod period) async {
    setState(() => _period = period);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null)
      return NetworkFailure(
          message: _loadError!, onRetry: () => _load(resetSelection: true));
    if (_loading)
      return const SafeArea(
          child: Center(child: CircularProgressIndicator(color: _sage)));
    final selectedLog = _selectedLog;
    final weekLogs = _weekLogs;
    final plannedRest = _isRestDay;
    final canCheckIn = _isToday &&
        !plannedRest &&
        selectedLog == null &&
        _selectedMuscles.isNotEmpty;
    return Stack(
      children: [
        SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
            children: [
              const _WorkoutTopLine(),
              const SizedBox(height: 22),
              const Text('训练记录',
                  style: TextStyle(
                      color: _sage,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.8)),
              const SizedBox(height: 7),
              const Text('练得有序，\n也记得开心。',
                  style: TextStyle(
                      color: _ink,
                      fontFamily: 'serif',
                      fontSize: 32,
                      height: 1.12,
                      letterSpacing: -1.1)),
              const SizedBox(height: 7),
              const Text('每一次坚持，都值得被好好记录。',
                  style: TextStyle(color: _muted, fontSize: 13)),
              const SizedBox(height: 20),
              _weekCard(),
              const SizedBox(height: 12),
              _goalCard(weekLogs.length),
              const SizedBox(height: 18),
              _selectedDateHeader(),
              const SizedBox(height: 10),
              _musclePicker(selectedLog),
              const SizedBox(height: 14),
              if (selectedLog != null)
                _checkedInPanel(selectedLog)
              else
                _checkInPanel(canCheckIn),
              const SizedBox(height: 18),
              _statisticsCard(),
            ],
          ),
        ),
        if (_showReward) const _FlowerReward(),
      ],
    );
  }

  Widget _weekCard() => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                    child: Text('本周训练',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600))),
                Text(
                    '${_weekStart.month}月${_weekStart.day}日 — ${_weekStart.add(const Duration(days: 6)).month}月${_weekStart.add(const Duration(days: 6)).day}日',
                    style: const TextStyle(color: _muted, fontSize: 10)),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: List.generate(7, (index) {
                final date = _weekStart.add(Duration(days: index));
                final log = _logFor(date);
                final selected = _sameDate(date, _selectedDate);
                final today = _sameDate(date, DateTime.now());
                final plan = _plans[date.weekday];
                final colors = log?.muscles
                        .map((muscle) => Color(muscle.colorValue))
                        .toList() ??
                    (plan?.isRest ?? false
                        ? <Color>[]
                        : (plan?.muscles ?? <String>[])
                            .map((name) => _muscleColor(name))
                            .whereType<Color>()
                            .toList());
                return Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(13),
                    onTap: () => _selectDate(date),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      padding: const EdgeInsets.fromLTRB(1, 8, 1, 7),
                      decoration: BoxDecoration(
                        color: selected ? _sageSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(13),
                        border: today && !selected
                            ? Border.all(color: _sage.withValues(alpha: .35))
                            : null,
                      ),
                      child: Column(
                        children: [
                          Text(_weekdays[index],
                              style: TextStyle(
                                  color: selected ? _sage : _muted,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Container(
                            width: 31,
                            height: 31,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                                color: log != null ? _sage : Colors.transparent,
                                shape: BoxShape.circle),
                            child: Text('${date.day}',
                                style: TextStyle(
                                    color: log != null ? Colors.white : _ink,
                                    fontSize: 12,
                                    fontWeight: selected || log != null
                                        ? FontWeight.w700
                                        : FontWeight.normal)),
                          ),
                          const SizedBox(height: 7),
                          SizedBox(
                            height: 5,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: colors
                                  .take(3)
                                  .map((color) => Container(
                                        width: 4,
                                        height: 4,
                                        margin: const EdgeInsets.symmetric(
                                            horizontal: 1),
                                        decoration: BoxDecoration(
                                            color: color,
                                            shape: BoxShape.circle),
                                      ))
                                  .toList(),
                            ),
                          ),
                          if (log == null && (plan?.isRest ?? false))
                            const Text('休',
                                style: TextStyle(color: _muted, fontSize: 8))
                          else
                            const SizedBox(height: 10),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      );

  Color? _muscleColor(String name) {
    for (final muscle in _muscles) {
      if (muscle.name == name) return Color(muscle.colorValue);
    }
    return null;
  }

  Widget _goalCard(int count) => Container(
        padding: const EdgeInsets.fromLTRB(15, 13, 14, 13),
        decoration: BoxDecoration(
            color: _sageSoft, borderRadius: BorderRadius.circular(17)),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.flag_outlined, color: _sage, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                    child: Text('本周目标',
                        style: TextStyle(
                            color: _sage,
                            fontSize: 12,
                            fontWeight: FontWeight.w600))),
                Text('$count / $_weeklyGoal 天',
                    style: const TextStyle(
                        color: _sage, fontFamily: 'serif', fontSize: 19)),
                const SizedBox(width: 3),
                IconButton(
                  onPressed: _openPlanEditor,
                  tooltip: '设置每周目标和训练计划',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.tune_rounded, color: _sage, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: (count / _weeklyGoal).clamp(0.0, 1.0).toDouble(),
                minHeight: 5,
                backgroundColor: Colors.white,
                color: _sage,
              ),
            ),
          ],
        ),
      );

  Widget _selectedDateHeader() => Row(
        children: [
          IconButton(
            onPressed: () =>
                _selectDate(_selectedDate.subtract(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_left_rounded),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _chooseDate,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    Text(_formatDate(_selectedDate),
                        style:
                            const TextStyle(fontFamily: 'serif', fontSize: 17)),
                    const SizedBox(height: 3),
                    Text(
                        '${_weekdayName(_selectedDate.weekday)} · ${_isToday ? '今天' : '训练记录'}',
                        style: const TextStyle(color: _muted, fontSize: 10)),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: _isToday
                ? null
                : () => _selectDate(_selectedDate.add(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_right_rounded),
            visualDensity: VisualDensity.compact,
          ),
          TextButton(
              onPressed: () => _selectDate(DateTime.now()),
              child: const Text('今天')),
        ],
      );

  Widget _musclePicker(WorkoutLog? log) {
    final displayed = log?.muscles ??
        _muscles
            .where((muscle) => _selectedMuscles.contains(muscle.name))
            .toList();
    final availableMuscles = log == null ? _muscles : displayed;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                  child: Text('训练部位',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600))),
              TextButton.icon(
                onPressed: _addMuscle,
                icon: const Icon(Icons.add_rounded, size: 15),
                label: const Text('新增'),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: _sage),
              ),
              IconButton(
                onPressed: _manageMuscles,
                tooltip: '管理自定义部位',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_horiz_rounded, size: 19),
              ),
            ],
          ),
          const SizedBox(height: 7),
          if (_isRestDay && log == null)
            Text(_isToday ? '今天安排了休息，无法打卡。' : '这一天安排了休息，无法打卡。',
                style: const TextStyle(color: _muted, fontSize: 11))
          else if (availableMuscles.isEmpty || (!_isToday && log == null))
            Text(_isToday ? '选择今天训练的部位，可多选。' : '这天没有训练记录。',
                style: const TextStyle(color: _muted, fontSize: 11))
          else
            Wrap(
              spacing: 7,
              runSpacing: 3,
              children: availableMuscles.map((muscle) {
                final checked =
                    log != null || _selectedMuscles.contains(muscle.name);
                if (log != null) {
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: Color(muscle.colorValue).withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                          color:
                              Color(muscle.colorValue).withValues(alpha: .45)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: Color(muscle.colorValue),
                                shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(muscle.name,
                            style: const TextStyle(
                                color: _ink,
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  );
                }
                return FilterChip(
                  selected: checked,
                  showCheckmark: false,
                  onSelected: log != null || !_isToday || _isRestDay
                      ? null
                      : (value) => setState(() {
                            if (value) {
                              _selectedMuscles.add(muscle.name);
                            } else {
                              _selectedMuscles.remove(muscle.name);
                            }
                          }),
                  label: Text(muscle.name),
                  avatar: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: Color(muscle.colorValue),
                          shape: BoxShape.circle)),
                  selectedColor:
                      Color(muscle.colorValue).withValues(alpha: .14),
                  backgroundColor: _paper,
                  side: BorderSide(
                      color: checked
                          ? Color(muscle.colorValue).withValues(alpha: .45)
                          : _line),
                  labelStyle: TextStyle(
                      color: checked ? _ink : _muted,
                      fontSize: 11,
                      fontWeight:
                          checked ? FontWeight.w600 : FontWeight.normal),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                );
              }).toList(),
            ),
          if (log == null &&
              !_isRestDay &&
              _isToday &&
              _selectedMuscles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text('${_selectedMuscles.length} 个训练部位已选择',
                  style: const TextStyle(color: _sage, fontSize: 10)),
            ),
        ],
      ),
    );
  }

  Widget _checkedInPanel(WorkoutLog log) => _Card(
        child: Row(
          children: [
            Container(
              width: 39,
              height: 39,
              decoration:
                  const BoxDecoration(color: _sageSoft, shape: BoxShape.circle),
              child: const Icon(Icons.check_rounded, color: _sage),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_isToday ? '今天已完成训练' : '该日已完成训练',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(log.muscles.map((muscle) => muscle.name).join(' · '),
                      style: const TextStyle(color: _muted, fontSize: 10)),
                ],
              ),
            ),
            TextButton(onPressed: _undoCheckIn, child: const Text('撤销')),
          ],
        ),
      );

  Widget _checkInPanel(bool canCheckIn) => Column(
        children: [
          WorkoutCheckInButton(
              enabled: canCheckIn && !_saving, onCheckIn: _checkIn),
          const SizedBox(height: 9),
          Text(
            _isRestDay
                ? '这一天是休息日'
                : !_isToday
                    ? '只能为今天打卡'
                    : _selectedMuscles.isEmpty
                        ? '先选择今天训练的部位'
                        : '训练完成后，长按按钮打卡',
            style: const TextStyle(color: _muted, fontSize: 10),
          ),
        ],
      );
  Widget _statisticsCard() => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                    child: Text('打卡统计',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600))),
                _WorkoutPeriodSelector(period: _period, onChanged: _setPeriod),
              ],
            ),
            const SizedBox(height: 13),
            if (_period == _WorkoutPeriod.day)
              _daySummary()
            else if (_period == _WorkoutPeriod.week)
              _rangeSummary(_weekLogs, _weekStart,
                  _weekStart.add(const Duration(days: 6)), '本周')
            else ...[
              _rangeSummary(_monthLogs, _monthStart, _monthEnd,
                  '${_selectedDate.month}月'),
              const SizedBox(height: 12),
              _monthCalendar(),
            ],
          ],
        ),
      );

  Widget _daySummary() {
    final log = _selectedLog;
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
              color: log != null ? _sageSoft : _paper, shape: BoxShape.circle),
          child: Icon(
              log != null
                  ? Icons.check_rounded
                  : (_isRestDay
                      ? Icons.hotel_rounded
                      : Icons.more_horiz_rounded),
              color: log != null ? _sage : _muted,
              size: 19),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  log != null
                      ? '已完成打卡'
                      : _isRestDay
                          ? '计划休息'
                          : '尚未打卡',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                  log?.muscles.map((muscle) => muscle.name).join(' · ') ??
                      _weekdayName(_selectedDate.weekday),
                  style: const TextStyle(color: _muted, fontSize: 10)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rangeSummary(
      List<WorkoutLog> logs, DateTime start, DateTime end, String label) {
    final muscleCounts = <String, int>{};
    for (final log in logs) {
      for (final muscle in log.muscles) {
        muscleCounts.update(muscle.name, (count) => count + 1,
            ifAbsent: () => 1);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${logs.length}',
                style: const TextStyle(
                    color: _ink, fontFamily: 'serif', fontSize: 27)),
            const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 4),
                child: Text('天已打卡',
                    style: TextStyle(color: _muted, fontSize: 10))),
            const Spacer(),
            Text('$label · ${_formatShort(start)} — ${_formatShort(end)}',
                style: const TextStyle(color: _muted, fontSize: 9)),
          ],
        ),
        if (muscleCounts.isNotEmpty) ...[
          const SizedBox(height: 9),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: muscleCounts.entries.map((entry) {
              var color = _sage;
              for (final log in logs) {
                for (final muscle in log.muscles) {
                  if (muscle.name == entry.key)
                    color = Color(muscle.colorValue);
                }
              }
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(30)),
                child: Text('${entry.key} ${entry.value}次',
                    style: TextStyle(
                        color: color,
                        fontSize: 9,
                        fontWeight: FontWeight.w600)),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  Widget _monthCalendar() {
    final firstWeekday = _monthStart.weekday;
    final days = _monthEnd.day;
    final cells = ((firstWeekday - 1 + days + 6) ~/ 7) * 7;
    return Column(
      children: [
        Row(
            children: _weekdays
                .map((day) => Expanded(
                    child: Center(
                        child: Text(day,
                            style:
                                const TextStyle(color: _muted, fontSize: 9)))))
                .toList()),
        const SizedBox(height: 6),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: cells,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 3,
              crossAxisSpacing: 2,
              childAspectRatio: .85),
          itemBuilder: (context, index) {
            final day = index - firstWeekday + 2;
            if (day < 1 || day > days) return const SizedBox.shrink();
            final date = DateTime(_selectedDate.year, _selectedDate.month, day);
            final log = _logFor(date);
            final selected = _sameDate(date, _selectedDate);
            final future = date.isAfter(_dateOnly(DateTime.now()));
            return InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: future ? null : () => _selectDate(date),
              child: Container(
                decoration: BoxDecoration(
                    color: selected ? _sageSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    border: _sameDate(date, DateTime.now())
                        ? Border.all(color: _sage.withValues(alpha: .35))
                        : null),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('$day',
                        style: TextStyle(
                            color: future
                                ? _line
                                : log != null
                                    ? _sage
                                    : _ink,
                            fontSize: 10,
                            fontWeight: log != null
                                ? FontWeight.w700
                                : FontWeight.normal)),
                    const SizedBox(height: 3),
                    SizedBox(
                      height: 4,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: (log?.muscles ?? const <WorkoutMuscle>[])
                            .take(3)
                            .map((muscle) => Container(
                                width: 3,
                                height: 3,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: .5),
                                decoration: BoxDecoration(
                                    color: Color(muscle.colorValue),
                                    shape: BoxShape.circle)))
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _WorkoutPlanEditor extends StatefulWidget {
  const _WorkoutPlanEditor(
      {required this.goal, required this.plans, required this.muscles});
  final int goal;
  final Map<int, WorkoutDayPlan> plans;
  final List<WorkoutMuscle> muscles;

  @override
  State<_WorkoutPlanEditor> createState() => _WorkoutPlanEditorState();
}

class _WorkoutPlanEditorState extends State<_WorkoutPlanEditor> {
  final _db = AppDatabase.instance;
  late int _goal = widget.goal;
  int _weekday = DateTime.now().weekday;
  late final _parts = {
    for (var day = 1; day <= 7; day++)
      day: (widget.plans[day]?.muscles ?? <String>[]).toSet(),
  };
  late final _restDays = {
    for (var day = 1; day <= 7; day++) day: widget.plans[day]?.isRest ?? false,
  };
  bool _saving = false;

  int get _plannedDays => _restDays.entries
      .where(
          (entry) => !entry.value && (_parts[entry.key]?.isNotEmpty ?? false))
      .length;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
        heightFactor: .86,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                20, 13, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: SingleChildScrollView(
                        child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                        child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                                color: _line,
                                borderRadius: BorderRadius.circular(4)))),
                    const SizedBox(height: 17),
                    const Text('每周训练计划',
                        style: TextStyle(
                            fontFamily: 'serif', fontSize: 23, color: _ink)),
                    const SizedBox(height: 4),
                    const Text('安排各日训练部位，休息日不会开放打卡。',
                        style: TextStyle(color: _muted, fontSize: 11)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Expanded(
                            child: Text('每周训练目标',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600))),
                        DropdownButton<int>(
                          value: _goal,
                          underline: const SizedBox.shrink(),
                          items: List.generate(
                              7,
                              (index) => DropdownMenuItem(
                                  value: index + 1,
                                  child: Text('${index + 1} 天'))),
                          onChanged: (value) =>
                              setState(() => _goal = value ?? _goal),
                        ),
                      ],
                    ),
                    Text('已安排 $_plannedDays 个训练日',
                        style: const TextStyle(color: _muted, fontSize: 10)),
                    const SizedBox(height: 12),
                    Row(
                      children: List.generate(7, (index) {
                        final day = index + 1;
                        final selected = day == _weekday;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(11),
                              onTap: () => setState(() => _weekday = day),
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                    color: selected ? _sage : _surface,
                                    borderRadius: BorderRadius.circular(11),
                                    border: Border.all(
                                        color: selected ? _sage : _line)),
                                child: Column(
                                  children: [
                                    Text(_weekdays[index],
                                        style: TextStyle(
                                            color:
                                                selected ? Colors.white : _ink,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 4),
                                    Icon(
                                        _restDays[day]!
                                            ? Icons.hotel_rounded
                                            : _parts[day]!.isNotEmpty
                                                ? Icons.fitness_center_rounded
                                                : Icons.remove_rounded,
                                        color:
                                            selected ? Colors.white70 : _muted,
                                        size: 12),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title:
                          const Text('设为休息日', style: TextStyle(fontSize: 12)),
                      value: _restDays[_weekday]!,
                      activeThumbColor: _sage,
                      onChanged: (value) => setState(() {
                        _restDays[_weekday] = value;
                        if (value) _parts[_weekday]!.clear();
                      }),
                    ),
                    if (!_restDays[_weekday]!) ...[
                      const SizedBox(height: 5),
                      const Text('训练部位（可多选）',
                          style: TextStyle(color: _muted, fontSize: 10)),
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 6,
                        runSpacing: 3,
                        children: widget.muscles.map((muscle) {
                          final color = Color(muscle.colorValue);
                          final selected =
                              _parts[_weekday]!.contains(muscle.name);
                          return FilterChip(
                            selected: selected,
                            showCheckmark: false,
                            avatar: Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                    color: color, shape: BoxShape.circle)),
                            label: Text(muscle.name),
                            selectedColor: color.withValues(alpha: .14),
                            backgroundColor: _surface,
                            side: BorderSide(
                                color: selected
                                    ? color.withValues(alpha: .4)
                                    : _line),
                            labelStyle: TextStyle(
                                fontSize: 10, color: selected ? _ink : _muted),
                            visualDensity: VisualDensity.compact,
                            onSelected: (value) => setState(() {
                              if (value) {
                                _parts[_weekday]!.add(muscle.name);
                              } else {
                                _parts[_weekday]!.remove(muscle.name);
                              }
                            }),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ))),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                        backgroundColor: _sage,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13)),
                    child: Text(_saving ? '保存中…' : '保存计划'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _db.saveWorkoutSchedule(_goal, {
        for (var day = 1; day <= 7; day++)
          day: WorkoutDayPlan(
              muscles: _parts[day]!.toList(), isRest: _restDays[day]!),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('计划保存失败，请重试')));
      }
    }
  }
}

class _ColorChoices extends StatelessWidget {
  const _ColorChoices({required this.selected, required this.onChanged});
  final Color selected;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 10,
        runSpacing: 8,
        children: _muscleColors
            .map((color) => InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => onChanged(color),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: selected.toARGB32() == color.toARGB32()
                            ? Border.all(color: _ink, width: 2)
                            : null),
                    child: selected.toARGB32() == color.toARGB32()
                        ? const Icon(Icons.check_rounded,
                            color: Colors.white, size: 16)
                        : null,
                  ),
                ))
            .toList(),
      );
}

class _WorkoutPeriodSelector extends StatelessWidget {
  const _WorkoutPeriodSelector({required this.period, required this.onChanged});
  final _WorkoutPeriod period;
  final ValueChanged<_WorkoutPeriod> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: const Color(0xffe7e6de),
            borderRadius: BorderRadius.circular(99)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: _WorkoutPeriod.values.map((value) {
            final selected = value == period;
            final label = switch (value) {
              _WorkoutPeriod.day => '日',
              _WorkoutPeriod.week => '周',
              _WorkoutPeriod.month => '月',
            };
            return InkWell(
              borderRadius: BorderRadius.circular(99),
              onTap: () => onChanged(value),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: selected ? _sage : Colors.transparent,
                    borderRadius: BorderRadius.circular(99)),
                child: Text(label,
                    style: TextStyle(
                        color: selected ? Colors.white : _muted, fontSize: 9)),
              ),
            );
          }).toList(),
        ),
      );
}

class _WorkoutTopLine extends StatelessWidget {
  const _WorkoutTopLine();

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const AppLogo(),
          const SizedBox(width: 10),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('DAY BY DAY',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.8)),
              SizedBox(height: 2),
              Text('身体 · 饮食 · 健身',
                  style: TextStyle(fontSize: 9, color: _muted)),
            ],
          ),
          const Spacer(),
          const Icon(Icons.cloud_done_outlined, color: _sage, size: 16),
          const SizedBox(width: 4),
          const Text('账号记录', style: TextStyle(fontSize: 10, color: _sage)),
        ],
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _line)),
        child: child,
      );
}

class _FlowerReward extends StatelessWidget {
  const _FlowerReward();

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: AbsorbPointer(
          child: Container(
            color: _surface.withValues(alpha: .94),
            child: Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: .72, end: 1),
                duration: const Duration(milliseconds: 380),
                curve: Curves.elasticOut,
                builder: (context, value, child) =>
                    Transform.scale(scale: value, child: child),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 150,
                      height: 130,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          const Positioned(
                              right: 46,
                              top: 36,
                              child: SizedBox(
                                  width: 3,
                                  height: 52,
                                  child: DecoratedBox(
                                      decoration:
                                          BoxDecoration(color: _sage)))),
                          const Icon(Icons.back_hand_rounded,
                              size: 94, color: Color(0xffc88769)),
                          Positioned(
                              right: 24,
                              top: 4,
                              child: Icon(Icons.local_florist_rounded,
                                  size: 48,
                                  color: Color(0xffcf4e55),
                                  shadows: [
                                    Shadow(
                                        color: Color(0x448b3035),
                                        blurRadius: 6,
                                        offset: Offset(0, 2))
                                  ])),
                          const Positioned(
                              left: 8,
                              top: 20,
                              child: Icon(Icons.auto_awesome_rounded,
                                  size: 17, color: Color(0xffd6ad58))),
                          const Positioned(
                              right: 2,
                              bottom: 17,
                              child: Icon(Icons.auto_awesome_rounded,
                                  size: 13, color: Color(0xffd6ad58))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text('打卡成功',
                        style: TextStyle(
                            color: _ink,
                            fontFamily: 'serif',
                            fontSize: 25,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 5),
                    const Text('送你一朵小红花，明天继续加油',
                        style: TextStyle(color: _muted, fontSize: 11)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

DateTime _dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);
bool _sameDate(DateTime first, DateTime second) =>
    first.year == second.year &&
    first.month == second.month &&
    first.day == second.day;
bool _sameWeek(DateTime date, DateTime selected) =>
    !date.isBefore(selected.subtract(Duration(days: selected.weekday - 1))) &&
    !date.isAfter(selected
        .subtract(Duration(days: selected.weekday - 1))
        .add(const Duration(days: 6)));
String _weekdayName(int weekday) =>
    const ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][weekday - 1];
String _formatDate(DateTime date) =>
    '${date.year}年${date.month.toString().padLeft(2, '0')}月${date.day.toString().padLeft(2, '0')}日';
String _formatShort(DateTime date) =>
    '${date.month}.${date.day.toString().padLeft(2, '0')}';
