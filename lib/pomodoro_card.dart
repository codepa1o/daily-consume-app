import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/api_client.dart';
import 'data/app_database.dart';

const _pomodoroAlerts = MethodChannel('daily_consume/pomodoro');

class PomodoroTimerInfo {
  const PomodoroTimerInfo({
    required this.label,
    required this.remaining,
    required this.paused,
  });

  final String label;
  final String remaining;
  final bool paused;
}

class PomodoroTimerController extends ChangeNotifier {
  PomodoroTimerInfo? info;

  void update(PomodoroTimerInfo value) {
    info = value;
    notifyListeners();
  }

  void clear() {
    if (info == null) return;
    info = null;
    notifyListeners();
  }
}

class PomodoroCard extends StatefulWidget {
  const PomodoroCard({super.key, this.timerController});

  final PomodoroTimerController? timerController;

  @override
  State<PomodoroCard> createState() => _PomodoroCardState();
}

enum _PomodoroStep {
  idle,
  focus,
  shortBreak,
  longBreak,
  focusComplete,
  breakComplete,
  saving,
  saveFailed,
}

class _PomodoroCardState extends State<PomodoroCard>
    with WidgetsBindingObserver {
  final _db = AppDatabase.instance;
  List<PomodoroTask> _tasks = [];
  List<PomodoroSession> _todaySessions = [];
  PomodoroSettings _settings = const PomodoroSettings();
  int? _selectedTaskId;
  int _nextBreakMinutes = 5;
  bool _nextLongBreak = false;
  bool _loading = true;
  String? _loadError;
  String? _actionError;
  _PomodoroStep _step = _PomodoroStep.idle;
  Duration _remaining = const Duration(minutes: 25);
  DateTime? _deadline;
  DateTime? _focusStartedAt;
  DateTime? _focusCompletedAt;
  String? _focusRequestId;
  PomodoroTask? _focusTask;
  Timer? _ticker;

  bool get _active => [
        _PomodoroStep.focus,
        _PomodoroStep.shortBreak,
        _PomodoroStep.longBreak,
      ].contains(_step);

  bool get _locked =>
      _active ||
      _step == _PomodoroStep.saving ||
      _step == _PomodoroStep.saveFailed;

  PomodoroTask? _taskById(int? id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final today = _dateOnly(DateTime.now());
      final data = await Future.wait<Object>([
        _db.getPomodoroSettings(),
        _db.getPomodoroTasks(),
        _db.getPomodoroSessions(today, today),
      ]);
      if (!mounted) return;
      final tasks = data[1] as List<PomodoroTask>;
      final sessions = data[2] as List<PomodoroSession>;
      setState(() {
        _settings = data[0] as PomodoroSettings;
        _tasks = tasks;
        _todaySessions = sessions;
        _selectedTaskId = tasks.isEmpty ? null : tasks.first.id;
        _remaining = Duration(minutes: _settings.focusMinutes);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = _errorMessage(error);
        _loading = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _updateTimer();
  }

  Future<bool> _ensureReminderPermissions() async {
    try {
      var allowed = await _pomodoroAlerts
              .invokeMethod<bool>('hasNotificationPermission') ??
          false;
      if (!allowed) {
        final explain = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('开启后台提醒'),
            content: const Text('允许通知后，番茄钟才能在后台和锁屏时响铃、振动。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('暂不')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('继续')),
            ],
          ),
        );
        if (explain != true || !mounted) return false;
        allowed = await _pomodoroAlerts
                .invokeMethod<bool>('requestNotificationPermission') ??
            false;
        if (!allowed) {
          final openSettings = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('通知权限未开启'),
              content: const Text('请在系统设置中允许“日常”发送通知，再开始番茄钟。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('打开设置')),
              ],
            ),
          );
          if (openSettings == true) {
            await _pomodoroAlerts
                .invokeMethod<void>('openNotificationSettings');
          }
          return false;
        }
      }

      final exactAlarmAllowed =
          await _pomodoroAlerts.invokeMethod<bool>('canScheduleExactAlarms') ??
              false;
      if (!exactAlarmAllowed) {
        final openSettings = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('允许准时提醒'),
            content: const Text('请允许“日常”使用闹钟和提醒，确保锁屏时能按时提示。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('暂不')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('打开设置')),
            ],
          ),
        );
        if (openSettings == true) {
          await _pomodoroAlerts.invokeMethod<void>('openExactAlarmSettings');
          if (mounted) _showMessage('允许后返回，再点一次开始。');
        }
        return false;
      }
      return true;
    } on MissingPluginException catch (_) {
      _showMessage('当前版本不支持后台提醒，请更新应用后重试。');
      return false;
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '无法开启后台提醒，请重试。');
      return false;
    }
  }

  Future<void> _scheduleBackgroundReminder(
      DateTime deadline, _PomodoroStep phase) async {
    final name = switch (phase) {
      _PomodoroStep.focus => 'focus',
      _PomodoroStep.shortBreak => 'shortBreak',
      _PomodoroStep.longBreak => 'longBreak',
      _ => throw StateError('Only timer phases can schedule reminders'),
    };
    await _pomodoroAlerts.invokeMethod<void>('scheduleReminder', {
      'triggerAtMillis': deadline.millisecondsSinceEpoch,
      'phase': name,
    });
  }

  Future<void> _cancelBackgroundReminder() async {
    try {
      await _pomodoroAlerts.invokeMethod<void>('cancelReminder');
    } on MissingPluginException catch (_) {
      // No native reminder is installed in widget-only contexts.
    } on PlatformException catch (_) {
      // The active timer still updates in the foreground.
    }
  }

  Future<void> _startFocus() async {
    final task = _taskById(_selectedTaskId);
    if (task == null) {
      _showMessage('请先添加并选择一项专注事项');
      return;
    }
    if (!await _ensureReminderPermissions() || !mounted) return;
    final now = DateTime.now();
    final duration = Duration(minutes: _settings.focusMinutes);
    final deadline = now.add(duration);
    try {
      await _scheduleBackgroundReminder(deadline, _PomodoroStep.focus);
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '无法设置后台提醒，请检查系统设置。');
      return;
    }
    if (!mounted) {
      await _cancelBackgroundReminder();
      return;
    }
    setState(() {
      _step = _PomodoroStep.focus;
      _focusTask = task;
      _focusStartedAt = now;
      _focusCompletedAt = null;
      _focusRequestId =
          now.microsecondsSinceEpoch.toRadixString(16).padLeft(32, '0');
      _remaining = duration;
      _deadline = deadline;
      _actionError = null;
    });
    _startTicker();
    _syncTimerStatus();
  }

  Future<void> _startBreak() async {
    if (!await _ensureReminderPermissions() || !mounted) return;
    final duration = Duration(minutes: _nextBreakMinutes);
    final phase =
        _nextLongBreak ? _PomodoroStep.longBreak : _PomodoroStep.shortBreak;
    final deadline = DateTime.now().add(duration);
    try {
      await _scheduleBackgroundReminder(deadline, phase);
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '无法设置后台提醒，请检查系统设置。');
      return;
    }
    if (!mounted) {
      await _cancelBackgroundReminder();
      return;
    }
    setState(() {
      _step = phase;
      _remaining = duration;
      _deadline = deadline;
      _actionError = null;
    });
    _startTicker();
    _syncTimerStatus();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _updateTimer());
  }

  void _updateTimer() {
    final deadline = _deadline;
    if (deadline == null) return;
    final seconds = deadline.difference(DateTime.now()).inSeconds;
    if (seconds <= 0) {
      _ticker?.cancel();
      _ticker = null;
      _deadline = null;
      widget.timerController?.clear();
      if (_step == _PomodoroStep.focus) {
        _focusCompletedAt = DateTime.now();
        unawaited(_saveCompletedFocus());
      } else if (mounted) {
        setState(() {
          _remaining = Duration.zero;
          _step = _PomodoroStep.breakComplete;
        });
      }
      return;
    }
    if (mounted && seconds != _remaining.inSeconds) {
      setState(() => _remaining = Duration(seconds: seconds));
      _syncTimerStatus();
    }
  }

  Future<void> _togglePause() async {
    if (_deadline != null) {
      final seconds = _deadline!.difference(DateTime.now()).inSeconds;
      await _cancelBackgroundReminder();
      if (!mounted) return;
      _ticker?.cancel();
      _ticker = null;
      setState(() {
        _remaining = Duration(seconds: seconds > 0 ? seconds : 0);
        _deadline = null;
      });
      _syncTimerStatus();
      return;
    }
    if (!await _ensureReminderPermissions() || !mounted) return;
    final duration = _remaining;
    final deadline = DateTime.now().add(duration);
    try {
      await _scheduleBackgroundReminder(deadline, _step);
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '无法设置后台提醒，请检查系统设置。');
      return;
    }
    if (!mounted) {
      await _cancelBackgroundReminder();
      return;
    }
    setState(() => _deadline = deadline);
    _startTicker();
    _syncTimerStatus();
  }

  Future<void> _saveCompletedFocus() async {
    final task = _focusTask;
    final startedAt = _focusStartedAt;
    final completedAt = _focusCompletedAt;
    final requestId = _focusRequestId;
    if (task == null ||
        startedAt == null ||
        completedAt == null ||
        requestId == null) return;
    setState(() {
      _step = _PomodoroStep.saving;
      _actionError = null;
    });
    widget.timerController?.clear();
    try {
      await _db.savePomodoroSession(
        requestId: requestId,
        taskId: task.id,
        taskTitle: task.title,
        durationMinutes: _settings.focusMinutes,
        startedAt: startedAt,
        completedAt: completedAt,
      );
      if (!mounted) return;
      setState(() {
        _todaySessions = [
          PomodoroSession(
            taskTitle: task.title,
            durationMinutes: _settings.focusMinutes,
            startedAt: startedAt,
          ),
          ..._todaySessions,
        ];
        _nextBreakMinutes =
            _todaySessions.length % _settings.roundsPerLongBreak == 0
                ? _settings.longBreakMinutes
                : _settings.shortBreakMinutes;
        _nextLongBreak =
            _todaySessions.length % _settings.roundsPerLongBreak == 0;
        _step = _PomodoroStep.focusComplete;
        _remaining = Duration.zero;
        _focusStartedAt = null;
        _focusCompletedAt = null;
        _focusRequestId = null;
        _focusTask = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _step = _PomodoroStep.saveFailed;
        _actionError = _errorMessage(error);
      });
    }
  }

  Future<void> _endFocus() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束本轮专注？'),
        content: const Text('未完成的专注时段不会计入记录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续专注')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('结束')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _cancelBackgroundReminder();
    if (!mounted) return;
    _ticker?.cancel();
    setState(() {
      _step = _PomodoroStep.idle;
      _remaining = Duration(minutes: _settings.focusMinutes);
      _deadline = null;
      _focusStartedAt = null;
      _focusCompletedAt = null;
      _focusRequestId = null;
      _focusTask = null;
    });
    widget.timerController?.clear();
  }

  Future<void> _endBreak() async {
    await _cancelBackgroundReminder();
    if (!mounted) return;
    _ticker?.cancel();
    setState(() {
      _step = _PomodoroStep.breakComplete;
      _remaining = Duration.zero;
      _deadline = null;
    });
    widget.timerController?.clear();
  }

  Future<void> _addTask() async {
    final input = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增专注事项'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(hintText: '例如：阅读、写报告'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, input.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    input.dispose();
    if (title == null || title.trim().isEmpty || !mounted) return;
    try {
      final task = await _db.savePomodoroTask(title.trim());
      if (!mounted) return;
      setState(() {
        if (!_tasks.any((item) => item.id == task.id)) _tasks.insert(0, task);
        _selectedTaskId = task.id;
        _actionError = null;
      });
    } catch (error) {
      _showMessage(_errorMessage(error));
    }
  }

  Future<void> _deleteSelectedTask() async {
    final task = _taskById(_selectedTaskId);
    if (task == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除专注事项？'),
        content: Text('“${task.title}”将从已保存事项中移除，历史记录会保留。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _db.deletePomodoroTask(task.id);
      if (!mounted) return;
      setState(() {
        _tasks.removeWhere((item) => item.id == task.id);
        _selectedTaskId = _tasks.isEmpty ? null : _tasks.first.id;
        _actionError = null;
      });
    } catch (error) {
      _showMessage(_errorMessage(error));
    }
  }

  Future<void> _editSettings() async {
    final controllers = [
      TextEditingController(text: '${_settings.focusMinutes}'),
      TextEditingController(text: '${_settings.shortBreakMinutes}'),
      TextEditingController(text: '${_settings.longBreakMinutes}'),
      TextEditingController(text: '${_settings.roundsPerLongBreak}'),
    ];
    final formKey = GlobalKey<FormState>();
    final values = await showDialog<PomodoroSettings>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('计时设置'),
        content: SizedBox(
          width: 360,
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _minutesField(controllers[0], '专注时长（分钟）', 1, 120),
                _minutesField(controllers[1], '短休息（分钟）', 1, 60),
                _minutesField(controllers[2], '长休息（分钟）', 1, 120),
                _minutesField(controllers[3], '每几轮长休息', 2, 12, unit: '轮'),
              ]),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                PomodoroSettings(
                  focusMinutes: int.parse(controllers[0].text),
                  shortBreakMinutes: int.parse(controllers[1].text),
                  longBreakMinutes: int.parse(controllers[2].text),
                  roundsPerLongBreak: int.parse(controllers[3].text),
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    for (final controller in controllers) {
      controller.dispose();
    }
    if (values == null || !mounted) return;
    try {
      await _db.savePomodoroSettings(values);
      if (!mounted) return;
      setState(() {
        _settings = values;
        _remaining = Duration(minutes: values.focusMinutes);
        final round = _todaySessions.length +
            (_step == _PomodoroStep.focusComplete ? 0 : 1);
        _nextLongBreak = round > 0 && round % values.roundsPerLongBreak == 0;
        _nextBreakMinutes =
            _nextLongBreak ? values.longBreakMinutes : values.shortBreakMinutes;
        _actionError = null;
      });
    } catch (error) {
      _showMessage(_errorMessage(error));
    }
  }

  Widget _minutesField(
          TextEditingController controller, String label, int min, int max,
          {String unit = '分钟'}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label, suffixText: unit),
          validator: (raw) {
            final value = int.tryParse(raw ?? '');
            if (value == null || value < min || value > max) {
              return '请输入 $min–$max 之间的整数';
            }
            return null;
          },
        ),
      );

  Widget _taskPicker() {
    final colors = Theme.of(context).colorScheme;
    return Row(children: [
      Expanded(
        child: _tasks.isEmpty
            ? Text('先添加一项专注事项',
                style: TextStyle(color: colors.onSurfaceVariant))
            : DropdownButton<int>(
                value: _selectedTaskId,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final task in _tasks)
                    DropdownMenuItem(value: task.id, child: Text(task.title))
                ],
                onChanged: _locked
                    ? null
                    : (value) => setState(() => _selectedTaskId = value),
              ),
      ),
      IconButton(
        tooltip: '新增事项',
        onPressed: _locked ? null : _addTask,
        icon: const Icon(Icons.add_circle_outline),
      ),
      IconButton(
        tooltip: '删除所选事项',
        onPressed:
            _locked || _selectedTaskId == null ? null : _deleteSelectedTask,
        icon: const Icon(Icons.delete_outline),
      ),
    ]);
  }

  Widget _controls() {
    switch (_step) {
      case _PomodoroStep.idle:
        return FilledButton.icon(
          onPressed: _loading || _loadError != null || _tasks.isEmpty
              ? null
              : _startFocus,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('开始专注'),
        );
      case _PomodoroStep.focus:
      case _PomodoroStep.shortBreak:
      case _PomodoroStep.longBreak:
        return Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _togglePause,
              icon: Icon(_deadline == null
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded),
              label: Text(_deadline == null ? '继续' : '暂停'),
            ),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: _step == _PomodoroStep.focus ? _endFocus : _endBreak,
            icon: const Icon(Icons.stop_rounded),
            label: Text(_step == _PomodoroStep.focus ? '结束' : '结束休息'),
          ),
        ]);
      case _PomodoroStep.focusComplete:
        return Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _startBreak,
              icon: const Icon(Icons.coffee_outlined),
              label: Text('开始 $_nextBreakMinutes 分钟休息'),
            ),
          ),
          TextButton(onPressed: _startFocus, child: const Text('跳过')),
        ]);
      case _PomodoroStep.breakComplete:
        return FilledButton.icon(
          onPressed: _startFocus,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('开始下一轮专注'),
        );
      case _PomodoroStep.saving:
        return FilledButton.icon(
          onPressed: null,
          icon: SizedBox.square(
              dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          label: Text('正在同步专注记录'),
        );
      case _PomodoroStep.saveFailed:
        return Column(children: [
          Text(_actionError ?? '专注记录同步失败'),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _saveCompletedFocus,
            icon: const Icon(Icons.sync),
            label: const Text('重试保存'),
          ),
        ]);
    }
  }

  String _stepLabel() {
    switch (_step) {
      case _PomodoroStep.idle:
        return '准备好后，开始一段专注时间';
      case _PomodoroStep.focus:
        return '专注中 · ${_focusTask?.title ?? ''}';
      case _PomodoroStep.shortBreak:
        return '短休息';
      case _PomodoroStep.longBreak:
        return '长休息';
      case _PomodoroStep.focusComplete:
        return '本轮完成，记录已同步';
      case _PomodoroStep.breakComplete:
        return '休息结束';
      case _PomodoroStep.saving:
        return '专注完成，正在保存';
      case _PomodoroStep.saveFailed:
        return '专注完成，但记录尚未同步';
    }
  }

  void _syncTimerStatus() {
    final controller = widget.timerController;
    if (controller == null) return;
    if (!_active) {
      controller.clear();
      return;
    }
    controller.update(PomodoroTimerInfo(
      label: _stepLabel(),
      remaining: _timerText,
      paused: _deadline == null,
    ));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openReminderSettings() async {
    try {
      await _pomodoroAlerts.invokeMethod<void>('openNotificationSettings');
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '无法打开系统提醒设置。');
    }
  }

  String _errorMessage(Object error) =>
      error is ApiException ? error.message : '操作失败，请重试';

  DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  String get _timerText {
    final seconds = _remaining.inSeconds;
    final minutesText = (seconds ~/ 60).toString().padLeft(2, '0');
    final secondsText = (seconds % 60).toString().padLeft(2, '0');
    return '$minutesText:$secondsText';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final focusedMinutes = _todaySessions.fold<int>(
        0, (sum, session) => sum + session.durationMinutes);
    return Card(
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.timer_outlined, color: colors.primary),
            const SizedBox(width: 9),
            Expanded(
              child: Text('番茄钟',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onSurface, fontWeight: FontWeight.w600)),
            ),
            IconButton(
              tooltip: '系统提醒设置',
              onPressed: _loading ? null : _openReminderSettings,
              icon: const Icon(Icons.notifications_active_outlined),
            ),
            IconButton(
              tooltip: '计时设置',
              onPressed: _locked || _loading ? null : _editSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          ]),
          if (_loadError != null) ...[
            Text(_loadError!, style: TextStyle(color: colors.error)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _load, child: const Text('重试')),
            ),
          ] else if (_loading)
            const LinearProgressIndicator()
          else ...[
            _taskPicker(),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _timerText,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: colors.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w500),
              ),
            ),
            Center(
              child: Text(_stepLabel(),
                  style: TextStyle(color: colors.onSurfaceVariant)),
            ),
            const SizedBox(height: 16),
            Center(child: _controls()),
            const SizedBox(height: 14),
            Divider(color: colors.outlineVariant),
            Row(children: [
              Expanded(
                child: Text('今日完成 ${_todaySessions.length} 轮',
                    style: TextStyle(color: colors.onSurfaceVariant)),
              ),
              Text('$focusedMinutes 分钟',
                  style: TextStyle(
                      color: colors.onSurface, fontWeight: FontWeight.w600)),
            ]),
          ],
        ]),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    widget.timerController?.clear();
    super.dispose();
  }
}
