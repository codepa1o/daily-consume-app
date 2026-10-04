import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'data/app_database.dart';
import 'data/api_client.dart';
import 'account_pages.dart';
import 'update/app_updates.dart';
import 'workout_page.dart';
import 'female_health_page.dart';
import 'widgets/app_logo.dart';
import 'life_calendar.dart';
import 'couple_page.dart' show recoverCouplePhoto;

const paper = Color(0xfff6f5ef);
const surface = Color(0xfffffefa);
const ink = Color(0xff292c25);
const muted = Color(0xff85877d);
const line = Color(0xffe8e7df);
const sage = Color(0xff64765a);
const sageSoft = Color(0xffe9eee4);
const mealTypes = ['早餐', '午餐', '晚餐'];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await recoverCouplePhoto();
  runApp(const DailyConsumeApp());
}

class DailyConsumeApp extends StatelessWidget {
  const DailyConsumeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '日常',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: paper,
          colorScheme: ColorScheme.fromSeed(seedColor: sage, surface: paper),
          fontFamily: 'sans-serif',
        ),
        home: UpdateHost(
            child: AuthGate(homeBuilder: (key) => AppShell(key: key))),
      );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String selected = 'body';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: ApiClient.instance,
      builder: (context, _) {
        final female = ApiClient.instance.account?.isFemale == true;
        final tabs = ['body', 'diary', 'workout', if (female) 'female', 'my'];
        if (!tabs.contains(selected)) selected = 'my';
        return Scaffold(
          body: IndexedStack(index: tabs.indexOf(selected), children: [
            const BodyPage(key: ValueKey('body')),
            const DiaryPage(key: ValueKey('diary')),
            const WorkoutPage(key: ValueKey('workout')),
            if (female) const FemaleHealthPage(key: ValueKey('female')),
            const MyPage(key: ValueKey('my')),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tabs.indexOf(selected),
            onDestinationSelected: (index) =>
                setState(() => selected = tabs[index]),
            backgroundColor: surface,
            indicatorColor: sageSoft,
            destinations: [
              const NavigationDestination(
                  icon: Icon(Icons.show_chart_rounded), label: '身体'),
              const NavigationDestination(
                  icon: Icon(Icons.restaurant_menu_rounded), label: '饮食消费'),
              const NavigationDestination(
                  icon: Icon(Icons.fitness_center_rounded), label: '健身'),
              if (female)
                const NavigationDestination(
                    icon: Icon(Icons.local_florist_outlined), label: '女性健康'),
              const NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded), label: '我的'),
            ],
          ),
        );
      });
}

class BodyPage extends StatefulWidget {
  const BodyPage({super.key});

  @override
  State<BodyPage> createState() => _BodyPageState();
}

class _BodyPageState extends State<BodyPage> {
  final db = AppDatabase.instance;
  List<BodyEntry> weights = [];
  List<BodyEntry> heights = [];
  bool loading = true;
  String? loadError;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final version = ++_loadVersion;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final data = await Future.wait([db.getWeights(), db.getHeights()]);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        weights = data[0];
        heights = data[1];
        loading = false;
      });
    } catch (error) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        loading = false;
        loadError = error is ApiException ? error.message : '加载失败，请重试';
      });
    }
  }

  Future<void> editValue({required bool weight}) async {
    final entries = weight ? weights : heights;
    final latest = entries.isEmpty ? null : entries.last;
    final input =
        TextEditingController(text: latest?.value.toStringAsFixed(1) ?? '');
    final formKey = GlobalKey<FormState>();
    var date = DateTime.now();
    var saving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(weight ? '记录体重' : '记录身高',
              style: const TextStyle(fontFamily: 'serif', fontSize: 24)),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: input,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: weight ? '体重（kg）' : '身高（cm）',
                    filled: true,
                    fillColor: paper,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none),
                  ),
                  validator: (raw) {
                    final value = double.tryParse(raw ?? '');
                    if (value == null || !value.isFinite || value <= 0)
                      return '请输入有效数值';
                    if (weight && (value < 20 || value > 300))
                      return '体重范围为 20–300 kg';
                    if (!weight && (value < 80 || value > 250))
                      return '身高范围为 80–250 cm';
                    return null;
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_outlined, size: 18),
                  title: Text('日期　' + formatDate(date, year: true)),
                  onTap: () async {
                    final chosen = await showDatePicker(
                      context: dialogContext,
                      initialDate: date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (chosen != null) setDialogState(() => date = chosen);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      final value = double.parse(input.text);
                      setDialogState(() => saving = true);
                      final success =
                          await serverAction(dialogContext, () async {
                        if (weight) {
                          await db.saveWeight(date, value);
                        } else {
                          await db.saveHeight(date, value);
                        }
                      });
                      if (!dialogContext.mounted) return;
                      if (!success) {
                        setDialogState(() => saving = false);
                        return;
                      }
                      Navigator.pop(dialogContext);
                      await reload();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text(weight ? '体重记录已保存' : '身高记录已保存')),
                        );
                      }
                    },
              child: Text(saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final latestWeight = weights.isEmpty ? null : weights.last;
    final latestHeight = heights.isEmpty ? null : heights.last;
    final series = weights;
    const unit = 'kg';

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        children: [
          const _TopLine(),
          const SizedBox(height: 22),
          const _Kicker('身体记录'),
          const SizedBox(height: 7),
          const Text(
            '慢一点，\n也看得见变化。',
            style: TextStyle(
                color: ink,
                fontFamily: 'serif',
                fontSize: 32,
                height: 1.12,
                letterSpacing: -1.1),
          ),
          const SizedBox(height: 7),
          const Text('持续记录，让身体的状态有迹可循。',
              style: TextStyle(color: muted, fontSize: 13)),
          const SizedBox(height: 22),
          if (loading)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(color: sage)))
          else if (loadError != null)
            NetworkFailure(message: loadError!, onRetry: reload)
          else ...[
            Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    label: '当前身高',
                    value: latestHeight?.value.toStringAsFixed(1) ?? '—',
                    unit: 'cm',
                    caption: latestHeight == null
                        ? '添加一次身高记录'
                        : '最近更新 · ' + formatDate(latestHeight.date),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: _MetricCard(
                    label: '最近体重',
                    value: latestWeight?.value.toStringAsFixed(1) ?? '—',
                    unit: 'kg',
                    caption: latestWeight == null
                        ? '记录今天的体重'
                        : '最近记录 · ' + formatDate(latestWeight.date),
                    emphasized: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 17),
            _SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('体重趋势',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        series.isEmpty
                            ? '—'
                            : series.last.value.toStringAsFixed(1) + ' ' + unit,
                        style: const TextStyle(
                            fontFamily: 'serif', fontSize: 25, color: ink),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(series.length.toString() + ' 条记录',
                            style: const TextStyle(color: muted, fontSize: 10)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (series.isEmpty)
                    const _EmptyChart()
                  else
                    SizedBox(
                      height: 150,
                      child: CustomPaint(
                        painter: _TrendPainter(
                            values: series.map((entry) => entry.value).toList(),
                            color: sage),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  if (series.isNotEmpty)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(formatDate(series.first.date),
                            style: const TextStyle(color: muted, fontSize: 9)),
                        Text(formatDate(series.last.date),
                            style: const TextStyle(color: muted, fontSize: 9)),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _ActionPanel(
              title: '今天称过体重了吗？',
              subtitle: '记录或修改某一天的体重',
              buttonLabel: '记录体重',
              onPressed: () => editValue(weight: true),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => editValue(weight: false),
              icon: const Icon(Icons.add, size: 17),
              label: Text(latestHeight == null ? '添加身高记录' : '更新身高记录'),
              style: OutlinedButton.styleFrom(
                foregroundColor: sage,
                side: const BorderSide(color: Color(0xffd9ded3)),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ],
          const LifeCalendar(),
        ],
      ),
    );
  }
}

class DiaryPage extends StatefulWidget {
  const DiaryPage({super.key});

  @override
  State<DiaryPage> createState() => _DiaryPageState();
}

enum _Period { day, week, month }

class _DiaryPageState extends State<DiaryPage> {
  final db = AppDatabase.instance;
  DateTime selectedDate = DateTime.now();
  _Period period = _Period.day;
  List<MealEntry> dayMeals = [];
  List<MealEntry> periodMeals = [];
  bool loading = true;
  String? loadError;
  int _loadVersion = 0;

  DateTime get rangeStart {
    if (period == _Period.day) return selectedDate;
    if (period == _Period.week)
      return selectedDate.subtract(Duration(days: selectedDate.weekday - 1));
    return DateTime(selectedDate.year, selectedDate.month, 1);
  }

  DateTime get rangeEnd {
    if (period == _Period.day) return selectedDate;
    if (period == _Period.week) return rangeStart.add(const Duration(days: 6));
    return DateTime(selectedDate.year, selectedDate.month + 1, 0);
  }

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final version = ++_loadVersion;
    final date = selectedDate, start = rangeStart, end = rangeEnd;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final data = await Future.wait(
          [db.getMealsForDate(date), db.getMealsBetween(start, end)]);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        dayMeals = data[0];
        periodMeals = data[1];
        loading = false;
      });
    } catch (error) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        loading = false;
        loadError = error is ApiException ? error.message : '加载失败，请重试';
      });
    }
  }

  Future<void> setDate(DateTime date) async {
    if (date.isAfter(DateTime.now())) return;
    setState(() {
      selectedDate = DateTime(date.year, date.month, date.day);
      loading = true;
    });
    await reload();
  }

  Future<void> chooseDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (date != null) await setDate(date);
  }

  Future<void> setPeriod(_Period next) async {
    setState(() {
      period = next;
      loading = true;
    });
    await reload();
  }

  Future<void> editMeal(String type, {MealEntry? existing}) async {
    final foods = TextEditingController(text: existing?.foods ?? '');
    final amount = TextEditingController(
      text: existing == null
          ? ''
          : (existing.expenseCents / 100).toStringAsFixed(2),
    );
    final formKey = GlobalKey<FormState>();
    var saving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(existing == null ? '记录$type' : '编辑$type',
              style: const TextStyle(fontFamily: 'serif', fontSize: 24)),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: foods,
                  autofocus: true,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: '吃了什么',
                    hintText: '例如：米饭、青菜、番茄炒蛋',
                    filled: true,
                    fillColor: paper,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none),
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请填写餐食内容' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: '这顿饭花了多少（元）',
                    prefixText: '¥ ',
                    filled: true,
                    fillColor: paper,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none),
                  ),
                  validator: (value) {
                    final parsed = double.tryParse(value ?? '');
                    return parsed == null || !parsed.isFinite || parsed < 0
                        ? '请输入有效金额'
                        : null;
                  },
                ),
                const SizedBox(height: 5),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('记录日期：' + formatDate(selectedDate, year: true),
                      style: const TextStyle(color: muted, fontSize: 11)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      final cents = (double.parse(amount.text) * 100).round();
                      setDialogState(() => saving = true);
                      final success = await serverAction(
                          dialogContext,
                          () => db.saveMeal(
                                MealEntry(
                                    date: selectedDate,
                                    mealType: type,
                                    foods: foods.text.trim(),
                                    expenseCents: cents),
                              ));
                      if (!dialogContext.mounted) return;
                      if (!success) {
                        setDialogState(() => saving = false);
                        return;
                      }
                      Navigator.pop(dialogContext);
                      setState(() => loading = true);
                      await reload();
                      if (mounted)
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('$type已保存')));
                    },
              child: Text(saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ),
    );
    foods.dispose();
    amount.dispose();
  }

  Future<void> deleteMeal(String type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除$type记录？'),
        content: const Text('这条餐食和消费记录会从当前账号的服务器数据中删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!await serverAction(context, () => db.deleteMeal(selectedDate, type)) ||
        !mounted) return;
    setState(() => loading = true);
    await reload();
  }

  int get dayTotal => dayMeals.fold(0, (sum, item) => sum + item.expenseCents);
  int get periodTotal =>
      periodMeals.fold(0, (sum, item) => sum + item.expenseCents);

  int mealTotal(String type) => periodMeals
      .where((meal) => meal.mealType == type)
      .fold(0, (sum, meal) => sum + meal.expenseCents);

  List<_ChartValue> chartValues() {
    if (period == _Period.day) {
      return mealTypes
          .map((type) => _ChartValue(
                type.substring(0, 1),
                dayMeals
                    .where((meal) => meal.mealType == type)
                    .fold(0, (sum, meal) => sum + meal.expenseCents),
              ))
          .toList();
    }
    if (period == _Period.week) {
      const labels = ['一', '二', '三', '四', '五', '六', '日'];
      return List.generate(7, (index) {
        final date = rangeStart.add(Duration(days: index));
        final cents = periodMeals
            .where((meal) => dateKey(meal.date) == dateKey(date))
            .fold(0, (sum, meal) => sum + meal.expenseCents);
        return _ChartValue(labels[index], cents);
      });
    }
    final days = rangeEnd.day;
    final weekCount = ((days + 6) / 7).floor();
    return List.generate(weekCount, (index) {
      final firstDay = index * 7 + 1;
      final lastDay = math.min(firstDay + 6, days).toInt();
      final cents = periodMeals
          .where(
              (meal) => meal.date.day >= firstDay && meal.date.day <= lastDay)
          .fold(0, (sum, meal) => sum + meal.expenseCents);
      return _ChartValue((index + 1).toString() + '周', cents);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (loading)
      return const SafeArea(
          child: Center(child: CircularProgressIndicator(color: sage)));
    if (loadError != null)
      return NetworkFailure(message: loadError!, onRetry: reload);
    final mealByType = {for (final meal in dayMeals) meal.mealType: meal};
    final isToday = dateKey(selectedDate) == dateKey(DateTime.now());

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        children: [
          const _TopLine(),
          const SizedBox(height: 22),
          const _Kicker('饮食日记'),
          const SizedBox(height: 7),
          const Text('今天吃了什么？',
              style: TextStyle(
                  color: ink,
                  fontFamily: 'serif',
                  fontSize: 31,
                  letterSpacing: -1)),
          const SizedBox(height: 10),
          Row(
            children: [
              IconButton(
                onPressed: () =>
                    setDate(selectedDate.subtract(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_left_rounded),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: chooseDate,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Column(
                      children: [
                        Text(formatDate(selectedDate, year: true),
                            style: const TextStyle(
                                fontFamily: 'serif', fontSize: 17)),
                        const SizedBox(height: 3),
                        Text(
                          weekdayName(selectedDate.weekday) +
                              ' · ' +
                              (isToday ? '今天' : '历史记录'),
                          style: const TextStyle(color: muted, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: isToday
                    ? null
                    : () => setDate(selectedDate.add(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_right_rounded),
                visualDensity: VisualDensity.compact,
              ),
              TextButton(
                onPressed: () => setDate(DateTime.now()),
                child: const Text('今天'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _DailySpendCard(totalCents: dayTotal, mealCount: dayMeals.length),
          const SizedBox(height: 19),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('三餐记录',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text('餐费按餐次汇总', style: TextStyle(fontSize: 10, color: muted)),
            ],
          ),
          const SizedBox(height: 10),
          ...mealTypes.map((type) {
            final meal = mealByType[type];
            return Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: _MealCard(
                mealType: type,
                meal: meal,
                onEdit: () => editMeal(type, existing: meal),
                onDelete: meal == null ? null : () => deleteMeal(type),
              ),
            );
          }),
          const SizedBox(height: 10),
          _StatisticsCard(
            period: period,
            totalCents: periodTotal,
            breakfastCents: mealTotal('早餐'),
            lunchCents: mealTotal('午餐'),
            dinnerCents: mealTotal('晚餐'),
            chartValues: chartValues(),
            onPeriodChanged: setPeriod,
          ),
        ],
      ),
    );
  }
}

class _TopLine extends StatelessWidget {
  const _TopLine();

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
              Text('身体 · 饮食 · 日常消费',
                  style: TextStyle(fontSize: 9, color: muted)),
            ],
          ),
          const Spacer(),
          const Icon(Icons.cloud_done_outlined, color: sage, size: 16),
          const SizedBox(width: 4),
          const Text('账号记录', style: TextStyle(fontSize: 10, color: sage)),
        ],
      );
}

class _Kicker extends StatelessWidget {
  const _Kicker(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            color: sage,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.8),
      );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.caption,
    this.emphasized = false,
  });
  final String label;
  final String value;
  final String unit;
  final String caption;
  final bool emphasized;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 13),
        decoration: BoxDecoration(
          color: emphasized ? sageSoft : const Color(0xfff0efe8),
          borderRadius: BorderRadius.circular(17),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: muted, fontSize: 10)),
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Text(value,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: 'serif', fontSize: 27, height: 1)),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(unit,
                      style: const TextStyle(color: muted, fontSize: 10)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 9)),
          ],
        ),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: line),
        ),
        child: child,
      );
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart();

  @override
  Widget build(BuildContext context) => Container(
        height: 145,
        alignment: Alignment.center,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.show_chart_rounded, color: Color(0xffbdc5b6), size: 30),
            SizedBox(height: 6),
            Text('记录几次数据后，这里会出现趋势',
                style: TextStyle(color: muted, fontSize: 11)),
          ],
        ),
      );
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 3.0;
    const right = 3.0;
    const top = 12.0;
    const bottom = 11.0;
    final chart =
        Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    final grid = Paint()
      ..color = line
      ..strokeWidth = 1;
    for (var row = 0; row < 3; row++) {
      final y = chart.top + chart.height * row / 2;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
    }
    if (values.isEmpty) return;
    final minValue = values.reduce((a, b) => a < b ? a : b);
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    final spread = math.max(maxValue - minValue, 0.4);
    final low = minValue - spread * .22;
    final high = maxValue + spread * .22;
    final points = List.generate(values.length, (index) {
      final x = values.length == 1
          ? chart.center.dx
          : chart.left + chart.width * index / (values.length - 1);
      final y =
          chart.bottom - (values[index] - low) / (high - low) * chart.height;
      return Offset(x, y);
    });
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    final fill = Path.from(path)
      ..lineTo(points.last.dx, chart.bottom)
      ..lineTo(points.first.dx, chart.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .18), color.withValues(alpha: 0)],
        ).createShader(chart),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(points.last, 4.3, Paint()..color = surface);
    canvas.drawCircle(
      points.last,
      4.3,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7,
    );
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.color != color || !_sameValues(oldDelegate.values, values);
}

bool _sameValues(List<double> first, List<double> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

class _ActionPanel extends StatelessWidget {
  const _ActionPanel({
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onPressed,
  });
  final String title;
  final String subtitle;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 13, 13),
        decoration: BoxDecoration(
            color: const Color(0xffebece4),
            borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 10, color: muted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: sage,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                textStyle:
                    const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
              ),
              child: Text(buttonLabel),
            ),
          ],
        ),
      );
}

class _DailySpendCard extends StatelessWidget {
  const _DailySpendCard({required this.totalCents, required this.mealCount});
  final int totalCents;
  final int mealCount;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
            color: sageSoft, borderRadius: BorderRadius.circular(17)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('今日饮食消费',
                      style: TextStyle(color: sage, fontSize: 10)),
                  const SizedBox(height: 5),
                  Text(formatMoney(totalCents),
                      style: const TextStyle(
                          color: Color(0xff35412f),
                          fontFamily: 'serif',
                          fontSize: 28)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('$mealCount 餐 · 已记录',
                  style: const TextStyle(color: sage, fontSize: 10)),
            ),
          ],
        ),
      );
}

class _MealCard extends StatelessWidget {
  const _MealCard({
    required this.mealType,
    required this.meal,
    required this.onEdit,
    required this.onDelete,
  });
  final String mealType;
  final MealEntry? meal;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final dotColor = switch (mealType) {
      '早餐' => const Color(0xffb4775d),
      '午餐' => sage,
      _ => const Color(0xff8b8294),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 10, 9),
      decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: dotColor, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(mealType,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(meal == null ? '—' : formatMoney(meal!.expenseCents),
                  style: const TextStyle(fontFamily: 'serif', fontSize: 16)),
              if (onDelete != null)
                IconButton(
                  onPressed: onDelete,
                  tooltip: '删除餐食',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 17, color: muted),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 2),
            child: Text(
              meal?.foods ?? '还没有记录这顿饭',
              style: TextStyle(
                  color: meal == null ? muted : const Color(0xff65685e),
                  fontSize: 11,
                  height: 1.45),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 2),
            child: TextButton.icon(
              onPressed: onEdit,
              icon: Icon(meal == null ? Icons.add : Icons.edit_outlined,
                  size: 14),
              label: Text(meal == null ? '添加$mealType' : '编辑$mealType'),
              style: TextButton.styleFrom(
                foregroundColor: sage,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                textStyle: const TextStyle(fontSize: 10),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartValue {
  const _ChartValue(this.label, this.cents);
  final String label;
  final int cents;
}

class _StatisticsCard extends StatelessWidget {
  const _StatisticsCard({
    required this.period,
    required this.totalCents,
    required this.breakfastCents,
    required this.lunchCents,
    required this.dinnerCents,
    required this.chartValues,
    required this.onPeriodChanged,
  });
  final _Period period;
  final int totalCents;
  final int breakfastCents;
  final int lunchCents;
  final int dinnerCents;
  final List<_ChartValue> chartValues;
  final ValueChanged<_Period> onPeriodChanged;

  @override
  Widget build(BuildContext context) {
    final label = switch (period) {
      _Period.day => '当日',
      _Period.week => '本周',
      _Period.month => '本月',
    };
    final maximum = chartValues.fold<int>(
        0, (current, point) => math.max(current, point.cents).toInt());
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      decoration: BoxDecoration(
          color: const Color(0xfff0efe8),
          borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                  child: Text('消费统计',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600))),
              _PeriodSelector(period: period, onChanged: onPeriodChanged),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatMoney(totalCents),
                  style: const TextStyle(fontFamily: 'serif', fontSize: 23)),
              const SizedBox(width: 7),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(label,
                    style: const TextStyle(color: muted, fontSize: 9)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 85,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: chartValues.map((point) {
                final ratio = maximum == 0 ? 0.0 : point.cents / maximum;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 18,
                              height: 6 + 46 * ratio,
                              decoration: BoxDecoration(
                                color: point.cents == maximum && maximum > 0
                                    ? sage
                                    : const Color(0xffbdc7b4),
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(5)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(point.label,
                            style: const TextStyle(color: muted, fontSize: 8)),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 9),
            child: Divider(height: 1, color: Color(0xffe2e0d7)),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Breakdown(label: '早餐', cents: breakfastCents),
              _Breakdown(label: '午餐', cents: lunchCents),
              _Breakdown(label: '晚餐', cents: dinnerCents),
            ],
          ),
        ],
      ),
    );
  }
}

class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.label, required this.cents});
  final String label;
  final int cents;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: muted, fontSize: 9)),
          const SizedBox(height: 3),
          Text(formatMoney(cents),
              style:
                  const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
        ],
      );
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.period, required this.onChanged});
  final _Period period;
  final ValueChanged<_Period> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: const Color(0xffe7e6de),
            borderRadius: BorderRadius.circular(99)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: _Period.values.map((value) {
            final selected = value == period;
            final label = switch (value) {
              _Period.day => '日',
              _Period.week => '周',
              _Period.month => '月',
            };
            return InkWell(
              borderRadius: BorderRadius.circular(99),
              onTap: () => onChanged(value),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: selected ? sage : Colors.transparent,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(label,
                    style: TextStyle(
                        color: selected ? Colors.white : muted, fontSize: 9)),
              ),
            );
          }).toList(),
        ),
      );
}

String formatMoney(int cents) => '¥ ' + (cents / 100).toStringAsFixed(2);

String formatDate(DateTime date, {bool year = false}) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return year
      ? date.year.toString() + '年' + month + '月' + day + '日'
      : month + '月' + day + '日';
}

String weekdayName(int weekday) =>
    const ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][weekday - 1];
