import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/semantics.dart' show SemanticsBinding;
import 'package:flutter/services.dart';

import 'data/app_database.dart';
import 'data/api_client.dart';
import 'account_pages.dart';
import 'update/app_updates_platform.dart';
import 'workout_page.dart';
import 'travel_planner_page.dart';
import 'female_health_page.dart';
import 'life_calendar.dart';
import 'couple_page.dart' show recoverCouplePhoto;
import 'navigation/app_location.dart';
import 'pomodoro_card.dart';
import 'widgets/app_logo.dart';

const paper = Color(0xfff6f5ef);
const surface = Color(0xfffffefa);
const ink = Color(0xff292c25);
const muted = Color(0xff70756b);
const line = Color(0xffe8e7df);
const sage = Color(0xff64765a);
const sageSoft = Color(0xffe9eee4);
const mealTypes = ['早餐', '午餐', '晚餐'];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    SemanticsBinding.instance.ensureSemantics();
  }
  await recoverCouplePhoto();
  runApp(const DailyConsumeApp());
}

class DailyConsumeApp extends StatelessWidget {
  const DailyConsumeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '日常',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
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
  late String selected;
  late final StreamSubscription<String?> _pageSubscription;
  final _pomodoroTimer = PomodoroTimerController();

  @override
  void initState() {
    super.initState();
    selected = initialAppPage;
    _pageSubscription = appPageChanges.listen((page) {
      if (page != null && mounted) setState(() => selected = page);
    });
  }

  @override
  void dispose() {
    _pageSubscription.cancel();
    _pomodoroTimer.dispose();
    super.dispose();
  }

  void _selectPage(String page) {
    if (page == selected) return;
    setState(() => selected = page);
    pushAppPage(page);
  }

  Widget _timerBanner() => AnimatedBuilder(
        animation: _pomodoroTimer,
        builder: (context, _) {
          final info = _pomodoroTimer.info;
          if (info == null) return const SizedBox.shrink();
          return Material(
            color: surface,
            child: InkWell(
              onTap: () => _selectPage('body'),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                child: Row(children: [
                  const Icon(Icons.timer_outlined, color: sage),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(info.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const Text('返回番茄钟',
                            style: TextStyle(color: muted, fontSize: 11)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(info.remaining,
                      style: const TextStyle(
                          color: sage,
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w600)),
                  if (info.paused) ...[
                    const SizedBox(width: 8),
                    const Text('已暂停',
                        style: TextStyle(color: muted, fontSize: 11)),
                  ],
                ]),
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: ApiClient.instance,
      builder: (context, _) {
        final female = ApiClient.instance.account?.isFemale == true;
        final tabs = [
          'body',
          'diary',
          'workout',
          'travel',
          if (female) 'female'
        ];
        if (!tabs.contains(selected)) selected = 'body';
        final pageStack = IndexedStack(
          index: tabs.indexOf(selected),
          children: [
            BodyPage(
                key: const ValueKey('body'), timerController: _pomodoroTimer),
            const DiaryPage(key: ValueKey('diary')),
            const WorkoutPage(key: ValueKey('workout')),
            const TravelPlannerPage(key: ValueKey('travel')),
            if (female) const FemaleHealthPage(key: ValueKey('female')),
          ],
        );
        return LayoutBuilder(builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 840;
          final extendedRail = constraints.maxWidth >= 1200;
          return Scaffold(
            drawer: const Drawer(
              backgroundColor: paper,
              child: MyPage(),
            ),
            body: desktop
                ? SafeArea(
                    child: Row(children: [
                      Container(
                        width: extendedRail ? 244 : 80,
                        color: surface,
                        child: Column(children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                                extendedRail ? 22 : 0, 22, 12, 18),
                            child: Row(
                              mainAxisAlignment: extendedRail
                                  ? MainAxisAlignment.start
                                  : MainAxisAlignment.center,
                              children: [
                                const AppLogo(),
                                if (extendedRail) ...[
                                  const SizedBox(width: 10),
                                  const Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('DAY BY DAY',
                                            style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 1.4)),
                                        SizedBox(height: 3),
                                        Text('日常记录',
                                            style: TextStyle(
                                                color: muted, fontSize: 11)),
                                      ]),
                                ],
                              ],
                            ),
                          ),
                          if (extendedRail)
                            const Padding(
                              padding: EdgeInsets.fromLTRB(22, 0, 12, 8),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text('工作区',
                                    style: TextStyle(
                                        color: muted,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600)),
                              ),
                            ),
                          Expanded(
                            child: NavigationRail(
                              selectedIndex: tabs.indexOf(selected),
                              onDestinationSelected: (index) =>
                                  _selectPage(tabs[index]),
                              extended: extendedRail,
                              labelType: extendedRail
                                  ? NavigationRailLabelType.none
                                  : NavigationRailLabelType.all,
                              minWidth: 80,
                              minExtendedWidth: 244,
                              groupAlignment: -1,
                              backgroundColor: surface,
                              indicatorColor: sageSoft,
                              destinations: [
                                const NavigationRailDestination(
                                    icon: Icon(Icons.show_chart_rounded),
                                    label: Text('身体')),
                                const NavigationRailDestination(
                                    icon: Icon(Icons.restaurant_menu_rounded),
                                    label: Text('饮食消费')),
                                const NavigationRailDestination(
                                    icon: Icon(Icons.fitness_center_rounded),
                                    label: Text('健身')),
                                const NavigationRailDestination(
                                    icon: Icon(Icons.travel_explore_rounded),
                                    label: Text('旅游规划')),
                                if (female)
                                  const NavigationRailDestination(
                                      icon: Icon(Icons.local_florist_outlined),
                                      label: Text('女性健康')),
                              ],
                            ),
                          ),
                          const Divider(height: 1, color: line),
                          Builder(builder: (scaffoldContext) {
                            final account = ApiClient.instance.account;
                            return Tooltip(
                              message: '我的账户与设置',
                              child: InkWell(
                                onTap: () =>
                                    Scaffold.of(scaffoldContext).openDrawer(),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: extendedRail ? 18 : 0,
                                      vertical: 14),
                                  child: Row(
                                    mainAxisAlignment: extendedRail
                                        ? MainAxisAlignment.start
                                        : MainAxisAlignment.center,
                                    children: [
                                      AccountAvatar(
                                          bytes: account?.avatarBytes,
                                          radius: 20),
                                      if (extendedRail) ...[
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(account?.nickname ?? '我的',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600)),
                                              const Text('账户与设置',
                                                  style: TextStyle(
                                                      color: muted,
                                                      fontSize: 11)),
                                            ],
                                          ),
                                        ),
                                        const Icon(Icons.chevron_right,
                                            color: muted, size: 18),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ]),
                      ),
                      const VerticalDivider(width: 1, color: line),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1480),
                            child: Column(children: [
                              Expanded(child: pageStack),
                              _timerBanner(),
                            ]),
                          ),
                        ),
                      ),
                    ]),
                  )
                : pageStack,
            bottomNavigationBar: desktop
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _timerBanner(),
                      NavigationBar(
                        selectedIndex: tabs.indexOf(selected),
                        onDestinationSelected: (index) =>
                            _selectPage(tabs[index]),
                        backgroundColor: surface,
                        indicatorColor: sageSoft,
                        destinations: [
                          const NavigationDestination(
                              icon: Icon(Icons.show_chart_rounded),
                              label: '身体'),
                          const NavigationDestination(
                              icon: Icon(Icons.restaurant_menu_rounded),
                              label: '饮食消费'),
                          const NavigationDestination(
                              icon: Icon(Icons.fitness_center_rounded),
                              label: '健身'),
                          const NavigationDestination(
                              icon: Icon(Icons.travel_explore_rounded),
                              label: '旅游规划'),
                          if (female)
                            const NavigationDestination(
                                icon: Icon(Icons.local_florist_outlined),
                                label: '女性健康'),
                        ],
                      ),
                    ],
                  ),
          );
        });
      });
}

class BodyPage extends StatefulWidget {
  const BodyPage({super.key, this.timerController});

  final PomodoroTimerController? timerController;

  @override
  State<BodyPage> createState() => _BodyPageState();
}

class _BodyPageState extends State<BodyPage> {
  final db = AppDatabase.instance;
  List<BodyEntry> weights = [];
  List<BodyEntry> heights = [];
  double? goalWeight;
  bool loading = true;
  bool _aiBusy = false;
  String? loadError;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload({bool showLoading = true}) async {
    final version = ++_loadVersion;
    if (showLoading) {
      setState(() {
        loading = true;
        loadError = null;
      });
    }
    try {
      final data = await Future.wait<Object?>([
        db.getWeights(),
        db.getHeights(),
        db.getGoalWeight(),
      ]);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        weights = data[0] as List<BodyEntry>;
        heights = data[1] as List<BodyEntry>;
        goalWeight = data[2] as double?;
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

  Future<Map<String, dynamic>> _loadAiReport(bool daily) async =>
      await ApiClient.instance.request(
              'POST', daily ? 'ai/daily-summary' : 'ai/profile-analysis',
              body: daily ? {'date': dateKey(DateTime.now())} : null)
          as Map<String, dynamic>;

  Future<void> _generateAi(bool daily) async {
    if (_aiBusy) return;
    setState(() => _aiBusy = true);
    try {
      final report = await _loadAiReport(daily);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _AiReportDialog(
            report: report, initialDaily: daily, loadReport: _loadAiReport),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(error is ApiException ? error.message : 'AI 生成失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  Widget _aiPanel() => _SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('AI 生活助手',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 5),
          const Text('看看近期身体状态，也回顾今天的记录。',
              style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 13),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _aiBusy ? null : () => _generateAi(false),
                icon: const Icon(Icons.insights_outlined, size: 18),
                label: const Text('个人分析'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _aiBusy ? null : () => _generateAi(true),
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('今日总结'),
              ),
            ),
          ]),
          if (_aiBusy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ]),
      );

  Future<void> editValue({required bool weight}) async {
    final entries = weight ? weights : heights;
    final latest = entries.isEmpty ? null : entries.last;
    final formKey = GlobalKey<FormState>();
    double? inputValue;
    var date = DateTime.now();
    var saving = false;

    final saved = await showDialog<bool>(
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
                  initialValue: latest?.value.toStringAsFixed(1) ?? '',
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
                  onSaved: (raw) => inputValue = double.tryParse(raw ?? ''),
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
                      formKey.currentState!.save();
                      final value = inputValue!;
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
                      Navigator.pop(dialogContext, true);
                    },
              child: Text(saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      await reload(showLoading: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(weight ? '体重记录已保存' : '身高记录已保存')),
        );
      }
    }
  }

  Future<void> editGoalWeight() async {
    final formKey = GlobalKey<FormState>();
    double? inputValue;
    var saving = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> persist(double? value) async {
            setDialogState(() => saving = true);
            final success = await serverAction(
                dialogContext, () => db.saveGoalWeight(value));
            if (!dialogContext.mounted) return;
            if (!success) {
              setDialogState(() => saving = false);
              return;
            }
            Navigator.pop(dialogContext, true);
          }

          return AlertDialog(
            title: const Text('设置目标体重',
                style: TextStyle(fontFamily: 'serif', fontSize: 24)),
            content: Form(
              key: formKey,
              child: TextFormField(
                initialValue: goalWeight?.toStringAsFixed(1) ?? '',
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: '目标体重（kg）',
                  filled: true,
                  fillColor: paper,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none),
                ),
                validator: (raw) {
                  final value = double.tryParse(raw ?? '');
                  if (value == null || !value.isFinite) return '请输入有效数值';
                  if (value < 20 || value > 300) return '体重范围为 20–300 kg';
                  return null;
                },
                onSaved: (raw) => inputValue = double.tryParse(raw ?? ''),
              ),
            ),
            actions: [
              if (goalWeight != null)
                TextButton(
                  onPressed: saving ? null : () => persist(null),
                  child: const Text('清除目标'),
                ),
              TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('取消')),
              FilledButton(
                onPressed: saving
                    ? null
                    : () {
                        if (!formKey.currentState!.validate()) return;
                        formKey.currentState!.save();
                        persist(inputValue);
                      },
                child: Text(saving ? '保存中…' : '保存'),
              ),
            ],
          );
        },
      ),
    );
    if (saved == true && mounted) {
      await reload(showLoading: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('目标体重已更新')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final latestWeight = weights.isEmpty ? null : weights.last;
    final latestHeight = heights.isEmpty ? null : heights.last;
    final series = weights;
    const unit = 'kg';
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1080;
      final chart = _SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
                child: Text('体重趋势',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            Text('${series.length} 条记录',
                style: const TextStyle(color: muted, fontSize: 12)),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: editGoalWeight,
              icon: const Icon(Icons.flag_outlined, size: 15),
              label: Text(goalWeight == null
                  ? '设置目标'
                  : '目标 ${goalWeight!.toStringAsFixed(1)} kg'),
              style: TextButton.styleFrom(
                foregroundColor: sage,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                minimumSize: const Size(0, 34),
                textStyle: const TextStyle(fontSize: 11),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(
              series.isEmpty
                  ? '—'
                  : '${series.last.value.toStringAsFixed(1)} $unit',
              style: const TextStyle(
                  fontFamily: 'serif', fontSize: 27, color: ink),
            ),
            if (series.isNotEmpty) ...[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(formatDate(series.last.date),
                    style: const TextStyle(color: muted, fontSize: 11)),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          if (series.isEmpty)
            const _EmptyChart()
          else
            _InteractiveWeightChart(entries: series, goalWeight: goalWeight),
          if (series.isNotEmpty)
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(formatDate(series.first.date),
                  style: const TextStyle(color: muted, fontSize: 11)),
              Text(formatDate(series.last.date),
                  style: const TextStyle(color: muted, fontSize: 11)),
            ]),
        ]),
      );
      final heightSection = Row(children: [
        Expanded(
          child: _MetricCard(
            label: '当前身高',
            value: latestHeight?.value.toStringAsFixed(1) ?? '—',
            unit: 'cm',
            caption: latestHeight == null
                ? '添加一次身高记录'
                : '最近更新 · ${formatDate(latestHeight.date)}',
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 136,
          child: OutlinedButton.icon(
            onPressed: () => editValue(weight: false),
            icon: const Icon(Icons.add, size: 17),
            label: Text(latestHeight == null ? '添加身高记录' : '更新身高记录'),
            style: OutlinedButton.styleFrom(
              foregroundColor: sage,
              side: const BorderSide(color: Color(0xffd9ded3)),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
              textStyle: const TextStyle(fontSize: 11),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ]);
      final weightSection = Row(children: [
        Expanded(
          child: _MetricCard(
            label: '最近体重',
            value: latestWeight?.value.toStringAsFixed(1) ?? '—',
            unit: 'kg',
            caption: latestWeight == null
                ? '记录今天的体重'
                : '最近记录 · ${formatDate(latestWeight.date)}',
            emphasized: true,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 152,
          child: _ActionPanel(
            title: '今天称过体重了吗？',
            subtitle: '记录或修改某一天的体重',
            buttonLabel: '记录体重',
            onPressed: () => editValue(weight: true),
          ),
        ),
      ]);
      final metrics = constraints.maxWidth >= 640
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: heightSection),
              const SizedBox(width: 14),
              Expanded(child: weightSection),
            ])
          : Column(children: [
              heightSection,
              const SizedBox(height: 14),
              weightSection,
            ]);
      final aiPanel = _aiPanel();

      return SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(wide ? 36 : 20, 22, wide ? 36 : 20, 32),
          children: [
            const _TopLine(),
            const SizedBox(height: 24),
            const _Kicker('身体记录'),
            const SizedBox(height: 7),
            Text(
              wide ? '慢一点，也看得见变化。' : '慢一点，\n也看得见变化。',
              style: TextStyle(
                  color: ink,
                  fontFamily: 'serif',
                  fontSize: wide ? 36 : 32,
                  height: 1.12,
                  letterSpacing: -1.1),
            ),
            const SizedBox(height: 7),
            const Text('持续记录，让身体的状态有迹可循。',
                style: TextStyle(color: muted, fontSize: 14)),
            const SizedBox(height: 24),
            if (loading)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator(color: sage)))
            else if (loadError != null)
              NetworkFailure(message: loadError!, onRetry: reload)
            else ...[
              metrics,
              const SizedBox(height: 18),
              if (wide)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 7, child: chart),
                  const SizedBox(width: 18),
                  Expanded(flex: 4, child: aiPanel),
                ])
              else ...[
                chart,
                const SizedBox(height: 14),
                aiPanel,
              ],
            ],
            const SizedBox(height: 10),
            const LifeCalendar(),
            const SizedBox(height: 16),
            PomodoroCard(timerController: widget.timerController),
          ],
        ),
      );
    });
  }
}

class _AiReportDialog extends StatefulWidget {
  const _AiReportDialog({
    required this.report,
    required this.initialDaily,
    required this.loadReport,
  });

  final Map<String, dynamic> report;
  final bool initialDaily;
  final Future<Map<String, dynamic>> Function(bool daily) loadReport;

  @override
  State<_AiReportDialog> createState() => _AiReportDialogState();
}

class _AiReportDialogState extends State<_AiReportDialog> {
  late bool _daily;
  late Map<String, dynamic> _report;
  Map<String, dynamic>? _profileReport;
  Map<String, dynamic>? _dailyReport;
  bool _loading = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _daily = widget.initialDaily;
    _report = widget.report;
    if (_daily) {
      _dailyReport = widget.report;
    } else {
      _profileReport = widget.report;
    }
  }

  Future<void> _selectTab(bool daily) async {
    if (_loading) return;
    if (_daily == daily && _loadError == null) return;
    final cached = daily ? _dailyReport : _profileReport;
    if (cached != null) {
      setState(() {
        _daily = daily;
        _report = cached;
        _loadError = null;
      });
      return;
    }
    setState(() {
      _daily = daily;
      _report = const <String, dynamic>{};
      _loadError = null;
      _loading = true;
    });
    try {
      final loaded = await widget.loadReport(daily);
      if (!mounted) return;
      setState(() {
        _report = loaded;
        if (daily) {
          _dailyReport = loaded;
        } else {
          _profileReport = loaded;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() =>
          _loadError = error is ApiException ? error.message : 'AI 生成失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _tabButton(bool daily, String label) {
    final selected = _daily == daily;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: _loading ? null : () => _selectTab(daily),
            child: Container(
              alignment: Alignment.center,
              constraints: const BoxConstraints(minHeight: 42),
              decoration: BoxDecoration(
                color: selected ? surface : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(label,
                  style: TextStyle(
                      color: selected ? ink : muted,
                      fontSize: 12,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500)),
            ),
          ),
        ),
      ),
    );
  }

  String _text(dynamic value) => value is String ? value : '';

  List<Map<String, dynamic>> _rows(dynamic value) => value is List
      ? value
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
      : const <Map<String, dynamic>>[];

  List<String> _strings(dynamic value) =>
      value is List ? value.whereType<String>().toList() : const <String>[];

  Widget _highlight(Map<String, dynamic> metric, bool emphasized) {
    final unit = _text(metric['unit']);
    final caption = _text(metric['caption']);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 10),
      decoration: BoxDecoration(
        color: emphasized ? sageSoft : const Color(0xfff0efe8),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_text(metric['label']),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: muted, fontSize: 10)),
        const SizedBox(height: 5),
        Text.rich(TextSpan(
          style: const TextStyle(
              color: ink, fontFamily: 'serif', fontSize: 22, height: 1),
          children: [
            TextSpan(text: _text(metric['value'])),
            if (unit.isNotEmpty)
              TextSpan(
                  text: ' $unit',
                  style: const TextStyle(
                      color: muted, fontFamily: 'sans-serif', fontSize: 10)),
          ],
        )),
        if (caption.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: muted, fontSize: 9)),
        ],
      ]),
    );
  }

  Widget _section(Map<String, dynamic> section) {
    final items = _rows(section['items']);
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_text(section['title']),
              style: const TextStyle(fontWeight: FontWeight.w600, color: ink)),
          const SizedBox(height: 9),
          ...items.map((item) {
            final label = _text(item['label']);
            final value = _text(item['value']);
            final detail = _text(item['detail']);
            return Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (label.isNotEmpty)
                    Text(label,
                        style: const TextStyle(
                            color: sage,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  if (value.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: label.isEmpty ? 0 : 3),
                      child: Text(value,
                          style: const TextStyle(color: ink, height: 1.4)),
                    ),
                  if (detail.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(detail,
                          style: const TextStyle(color: muted, fontSize: 10)),
                    ),
                ],
              ),
            );
          }),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _text(_report['subtitle']);
    final summary = _text(_report['summary']);
    final highlights = _rows(_report['highlights']);
    final sections = _rows(_report['sections']);
    final suggestions = _strings(_report['suggestions']);
    final notice = _text(_report['notice']);
    final screen = MediaQuery.sizeOf(context);
    final contentWidth = math.min(screen.width - 112, 480.0).toDouble();

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(22, 19, 22, 5),
      contentPadding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('生活记录 · AI 回顾',
            style: TextStyle(color: sage, fontSize: 10, letterSpacing: 1.2)),
        const SizedBox(height: 4),
        const Text('把记录，变成\n看得见的回顾。',
            style:
                const TextStyle(color: ink, fontFamily: 'serif', fontSize: 23)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
              color: const Color(0xfff0efe8),
              borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            _tabButton(false, '个人分析'),
            _tabButton(true, '今日总结'),
          ]),
        ),
      ]),
      content: SizedBox(
        width: contentWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: screen.height * 0.64),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_loading) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child:
                        Center(child: CircularProgressIndicator(color: sage)),
                  ),
                  const Center(
                      child: Text('正在整理记录…',
                          style: TextStyle(color: muted, fontSize: 12))),
                ],
                if (_loadError != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(_loadError!,
                        style: const TextStyle(color: muted, height: 1.4)),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _selectTab(_daily),
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('重试'),
                    ),
                  ),
                ],
                if (!_loading && _loadError == null) ...[
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: Text(subtitle,
                          style: const TextStyle(color: sage, fontSize: 11)),
                    ),
                  if (summary.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(summary,
                          style: const TextStyle(color: ink, height: 1.5)),
                    ),
                  if (highlights.isNotEmpty)
                    GridView.count(
                      crossAxisCount: screen.width < 380 ? 1 : 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      mainAxisExtent: 86,
                      children: [
                        for (var i = 0; i < highlights.length; i++)
                          _highlight(highlights[i], i == 0),
                      ],
                    ),
                  for (final section in sections) _section(section),
                  if (suggestions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                            color: sageSoft,
                            borderRadius: BorderRadius.circular(16)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(children: [
                              Icon(Icons.lightbulb_outline_rounded,
                                  color: sage, size: 17),
                              SizedBox(width: 7),
                              Text('给你的建议',
                                  style: TextStyle(
                                      color: sage,
                                      fontWeight: FontWeight.w600)),
                            ]),
                            const SizedBox(height: 8),
                            for (var i = 0; i < suggestions.length; i++)
                              Padding(
                                padding: EdgeInsets.only(
                                    bottom:
                                        i == suggestions.length - 1 ? 0 : 7),
                                child: Text(suggestions[i],
                                    style: const TextStyle(
                                        color: ink, height: 1.4)),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (notice.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(notice,
                          style: const TextStyle(color: muted, fontSize: 10)),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
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
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1050;
      final dailyRecords = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            IconButton(
              tooltip: '前一天',
              onPressed: () =>
                  setDate(selectedDate.subtract(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: chooseDate,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Column(children: [
                    Text(formatDate(selectedDate, year: true),
                        style:
                            const TextStyle(fontFamily: 'serif', fontSize: 18)),
                    const SizedBox(height: 3),
                    Text(
                        '${weekdayName(selectedDate.weekday)} · ${isToday ? '今天' : '历史记录'}',
                        style: const TextStyle(color: muted, fontSize: 12)),
                  ]),
                ),
              ),
            ),
            IconButton(
              tooltip: '后一天',
              onPressed: isToday
                  ? null
                  : () => setDate(selectedDate.add(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
            TextButton(
                onPressed: () => setDate(DateTime.now()),
                child: const Text('今天')),
          ]),
          const SizedBox(height: 8),
          _DailySpendCard(totalCents: dayTotal, mealCount: dayMeals.length),
          const SizedBox(height: 19),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('三餐记录',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              Text('餐费按餐次汇总', style: TextStyle(fontSize: 11, color: muted)),
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
        ],
      );
      final statistics = _StatisticsCard(
        period: period,
        totalCents: periodTotal,
        breakfastCents: mealTotal('早餐'),
        lunchCents: mealTotal('午餐'),
        dinnerCents: mealTotal('晚餐'),
        chartValues: chartValues(),
        onPeriodChanged: setPeriod,
      );

      return SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(wide ? 36 : 20, 22, wide ? 36 : 20, 32),
          children: [
            const _TopLine(),
            const SizedBox(height: 24),
            const _Kicker('饮食日记'),
            const SizedBox(height: 7),
            Text('今天吃了什么？',
                style: TextStyle(
                    color: ink,
                    fontFamily: 'serif',
                    fontSize: wide ? 36 : 31,
                    letterSpacing: -1)),
            const SizedBox(height: 16),
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 6, child: dailyRecords),
                const SizedBox(width: 20),
                Expanded(flex: 4, child: statistics),
              ])
            else ...[
              dailyRecords,
              const SizedBox(height: 14),
              statistics,
            ],
          ],
        ),
      );
    });
  }
}

class _TopLine extends StatelessWidget {
  const _TopLine();

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        return Row(
          children: [
            ListenableBuilder(
              listenable: ApiClient.instance,
              builder: (context, _) => IconButton(
                tooltip: '打开我的',
                onPressed: () => Scaffold.of(context).openDrawer(),
                padding: EdgeInsets.zero,
                icon: AccountAvatar(
                  bytes: ApiClient.instance.account?.avatarBytes,
                  radius: 21,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('DAY BY DAY',
                    style: TextStyle(
                        fontSize: wide ? 12 : 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.8)),
                SizedBox(height: wide ? 4 : 2),
                Text('身体 · 饮食 · 日常消费',
                    style: TextStyle(fontSize: wide ? 11 : 10, color: muted)),
              ],
            ),
            const Spacer(),
            Icon(Icons.cloud_done_outlined, color: sage, size: wide ? 19 : 16),
            const SizedBox(width: 4),
            Text('账号记录',
                style: TextStyle(fontSize: wide ? 12 : 10, color: sage)),
          ],
        );
      });
}

class _Kicker extends StatelessWidget {
  const _Kicker(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            color: sage,
            fontSize: 11,
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
            Text(label, style: const TextStyle(color: muted, fontSize: 12)),
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Text(value,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: 'serif', fontSize: 30, height: 1)),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(unit,
                      style: const TextStyle(color: muted, fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 11)),
          ],
        ),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding:
            EdgeInsets.all(MediaQuery.sizeOf(context).width >= 1100 ? 20 : 15),
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

const _weightChartLeft = 48.0;
const _weightChartRight = 4.0;

class _InteractiveWeightChart extends StatefulWidget {
  const _InteractiveWeightChart(
      {required this.entries, required this.goalWeight});

  final List<BodyEntry> entries;
  final double? goalWeight;

  @override
  State<_InteractiveWeightChart> createState() =>
      _InteractiveWeightChartState();
}

class _InteractiveWeightChartState extends State<_InteractiveWeightChart> {
  int? _selectedIndex;
  int _rangeDays = 0;

  List<BodyEntry> get _visibleEntries {
    if (_rangeDays == 0 || widget.entries.isEmpty) return widget.entries;
    final firstDate =
        widget.entries.last.date.subtract(Duration(days: _rangeDays - 1));
    return widget.entries
        .where((entry) => !entry.date.isBefore(firstDate))
        .toList();
  }

  int _indexAt(double x, double width) {
    final entries = _visibleEntries;
    final plotWidth = width - _weightChartLeft - _weightChartRight;
    if (entries.length < 2 || plotWidth <= 0) return 0;
    final plotX = (x - _weightChartLeft).clamp(0.0, plotWidth).toDouble();
    return (plotX / plotWidth * (entries.length - 1))
        .round()
        .clamp(0, entries.length - 1)
        .toInt();
  }

  void _selectAt(Offset position, double width) {
    if (_visibleEntries.isEmpty) return;
    final next = _indexAt(position.dx, width);
    if (_selectedIndex != next) setState(() => _selectedIndex = next);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _visibleEntries;
    final selected = _selectedIndex == null
        ? null
        : entries.isEmpty
            ? null
            : entries[_selectedIndex!.clamp(0, entries.length - 1).toInt()];
    final rangeLabel = _rangeDays == 0 ? '全部' : '近 $_rangeDays 天';
    final semanticsValue = [
      selected == null
          ? '$rangeLabel，共 ${entries.length} 条记录'
          : '${formatDate(selected.date)}，${selected.value.toStringAsFixed(1)} 千克',
      if (widget.goalWeight != null)
        '目标 ${widget.goalWeight!.toStringAsFixed(1)} 千克',
    ].join('，');
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (entries.isEmpty) return KeyEventResult.ignored;
        final current = _selectedIndex ?? entries.length - 1;
        final next = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowLeft =>
            (current - 1).clamp(0, entries.length - 1).toInt(),
          LogicalKeyboardKey.arrowRight =>
            (current + 1).clamp(0, entries.length - 1).toInt(),
          _ => null,
        };
        if (next == null) return KeyEventResult.ignored;
        setState(() => _selectedIndex = next);
        return KeyEventResult.handled;
      },
      child: Semantics(
        button: true,
        label: '体重趋势图',
        value: semanticsValue,
        hint: '点击数据点，或聚焦后使用左右方向键浏览记录',
        child: Column(children: [
          Row(children: [
            Text('$rangeLabel · ${entries.length} 条',
                style: const TextStyle(color: muted, fontSize: 12)),
            const Spacer(),
            PopupMenuButton<int>(
              tooltip: '选择趋势时间范围',
              initialValue: _rangeDays,
              onSelected: (value) => setState(() {
                _rangeDays = value;
                _selectedIndex = null;
              }),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 7, child: Text('最近 7 天')),
                PopupMenuItem(value: 30, child: Text('最近 30 天')),
                PopupMenuItem(value: 90, child: Text('最近 90 天')),
                PopupMenuItem(value: 0, child: Text('全部记录')),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.calendar_month_outlined,
                      size: 16, color: sage),
                  const SizedBox(width: 5),
                  Text(rangeLabel,
                      style: const TextStyle(
                          color: sage,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const Icon(Icons.expand_more, size: 18, color: sage),
                ]),
              ),
            ),
          ]),
          SizedBox(
            height: 180,
            child: LayoutBuilder(builder: (context, constraints) {
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (event) =>
                    _selectAt(event.localPosition, constraints.maxWidth),
                onExit: (_) => setState(() => _selectedIndex = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (event) =>
                      _selectAt(event.localPosition, constraints.maxWidth),
                  child: entries.isEmpty
                      ? const Center(child: Text('此时间范围内没有体重记录'))
                      : CustomPaint(
                          painter: _TrendPainter(
                            values:
                                entries.map((entry) => entry.value).toList(),
                            color: sage,
                            goalWeight: widget.goalWeight,
                            selectedIndex: _selectedIndex,
                          ),
                          child: const SizedBox.expand(),
                        ),
                ),
              );
            }),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 140),
            child: SizedBox(
              key: ValueKey(selected?.date),
              width: double.infinity,
              child: Text(
                selected == null
                    ? widget.goalWeight == null
                        ? '悬停或点击图表查看记录'
                        : '虚线表示目标体重 · 悬停或点击查看记录'
                    : '${formatDate(selected.date)}　${selected.value.toStringAsFixed(1)} kg',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: sage, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter(
      {required this.values,
      required this.color,
      this.goalWeight,
      this.selectedIndex});
  final List<double> values;
  final Color color;
  final double? goalWeight;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 12.0;
    const bottom = 11.0;
    final chart = Rect.fromLTRB(_weightChartLeft, top,
        size.width - _weightChartRight, size.height - bottom);
    final axisTextStyle = const TextStyle(color: muted, fontSize: 10);
    final unit = TextPainter(
      text: TextSpan(text: 'kg', style: axisTextStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    unit.paint(canvas, Offset(0, 0));
    if (values.isEmpty) return;

    final allValues = [
      ...values,
      if (goalWeight != null) goalWeight!,
    ];
    final minValue = allValues.reduce((a, b) => a < b ? a : b);
    final maxValue = allValues.reduce((a, b) => a > b ? a : b);
    final step = _niceWeightStep(math.max((maxValue - minValue) / 3, .1));
    var low = (minValue / step).floor() * step;
    var high = (maxValue / step).ceil() * step;
    if ((minValue - low).abs() < .000001) low -= step;
    if ((high - maxValue).abs() < .000001) high += step;
    if (high <= low) high = low + step;
    var tickCount = ((high - low) / step).round();
    if (tickCount < 2) {
      low -= step;
      high += step;
      tickCount = ((high - low) / step).round();
    }
    final grid = Paint()
      ..color = line
      ..strokeWidth = 1;
    for (var row = 0; row <= tickCount; row++) {
      final y = chart.top + chart.height * row / tickCount;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
      final tick = TextPainter(
        text: TextSpan(
          text: (high - step * row).toStringAsFixed(step < 1 ? 1 : 0),
          style: axisTextStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: _weightChartLeft - 9);
      tick.paint(canvas,
          Offset(_weightChartLeft - 7 - tick.width, y - tick.height / 2));
    }
    canvas.drawLine(
        Offset(chart.left, chart.top), Offset(chart.left, chart.bottom), grid);
    if (goalWeight != null) {
      final targetY =
          chart.bottom - (goalWeight! - low) / (high - low) * chart.height;
      final targetPaint = Paint()
        ..color = const Color(0xffb4775d)
        ..strokeWidth = 1.6;
      var x = chart.left;
      while (x < chart.right) {
        canvas.drawLine(Offset(x, targetY),
            Offset(math.min(x + 5, chart.right), targetY), targetPaint);
        x += 9;
      }
    }
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
    if (selectedIndex != null && selectedIndex! < points.length) {
      final point = points[selectedIndex!];
      canvas.drawLine(
          Offset(point.dx, chart.top),
          Offset(point.dx, chart.bottom),
          Paint()
            ..color = color.withValues(alpha: .28)
            ..strokeWidth = 1);
      canvas.drawCircle(point, 6, Paint()..color = surface);
      canvas.drawCircle(point, 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.goalWeight != goalWeight ||
      oldDelegate.selectedIndex != selectedIndex ||
      !_sameValues(oldDelegate.values, values);
}

double _niceWeightStep(double target) {
  final exponent = (math.log(target) / math.ln10).floor();
  final scale = math.pow(10.0, exponent).toDouble();
  final fraction = target / scale;
  if (fraction <= 1) return scale;
  if (fraction <= 2) return 2 * scale;
  if (fraction <= 5) return 5 * scale;
  return 10 * scale;
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(fontSize: 12, color: muted)),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: sage,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  textStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
                child: Text(buttonLabel),
              ),
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
