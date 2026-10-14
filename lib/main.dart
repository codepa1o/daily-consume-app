import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show kIsWeb, LicenseEntryWithLineBreaks, LicenseRegistry;
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
import 'couple_page.dart' show CouplePage, recoverCouplePhoto;
import 'navigation/app_location.dart';
import 'pomodoro_card.dart';
import 'widgets/app_logo.dart';
import 'widgets/body_data_icon.dart';
import 'widgets/travel_planning_icon.dart';
import 'widgets/app_layout.dart';
import 'skill_agent_page.dart';
import 'research_tools_page.dart';
import 'chatbot_page.dart';

const paper = Color(0xfff6f5ef);
const surface = Color(0xfffffefa);
const ink = Color(0xff292c25);
const muted = Color(0xff70756b);
const line = Color(0xffe8e7df);
const sage = Color(0xff64765a);
const sageSoft = Color(0xffe9eee4);
const mealTypes = ['早餐', '午餐', '晚餐'];
const _dailyModules = [
  (id: 'body', label: '身体数据', icon: BodyDataIcon()),
  (id: 'diary', label: '饮食消费', icon: Icon(Icons.restaurant_menu_rounded)),
  (id: 'workout', label: '健身', icon: Icon(Icons.fitness_center_rounded)),
  (id: 'calendar', label: '生活日历', icon: Icon(Icons.calendar_month_outlined)),
  (id: 'focus', label: '专注时刻', icon: Icon(Icons.timer_outlined)),
  (id: 'female', label: '女性健康', icon: Icon(Icons.local_florist_outlined)),
  (id: 'couple', label: '情侣空间', icon: Icon(Icons.favorite_border)),
  (id: 'travel', label: '旅行规划', icon: TravelPlanningIcon()),
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['Lucide Icons'], lucideIconLicense);
  });
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
          appBarTheme: const AppBarTheme(
              centerTitle: false, titleSpacing: 20, toolbarHeight: 64),
          cardTheme: const CardThemeData(
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(18)),
                side: BorderSide(color: line)),
          ),
          filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12))),
          outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12))),
          textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10))),
          inputDecorationTheme: const InputDecorationTheme(
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
          listTileTheme: const ListTileThemeData(
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              horizontalTitleGap: 12,
              minLeadingWidth: 40),
          textTheme: const TextTheme(
              titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              bodyMedium: TextStyle(fontSize: 14, height: 1.45),
              bodySmall: TextStyle(fontSize: 12, height: 1.45),
              labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
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
  String _dailyModule = 'body';
  final _openedPages = <String>{'body'};
  late final StreamSubscription<String?> _pageSubscription;
  final _pomodoroTimer = PomodoroTimerController();

  @override
  void initState() {
    super.initState();
    final initial = initialAppPage;
    selected = initial == 'skill-agent' ||
            initial == 'research-tools' ||
            initial == 'chatbot' ||
            _dailyModules.any((module) => module.id == initial)
        ? initial
        : 'body';
    if (selected == 'female' && ApiClient.instance.account?.isFemale != true) {
      selected = 'body';
    }
    if (selected != 'skill-agent' &&
        selected != 'research-tools' &&
        selected != 'chatbot') {
      _dailyModule = selected;
    }
    _openedPages.add(selected);
    _pageSubscription = appPageChanges.listen((page) {
      if (page != null && mounted) _setPage(page, updateLocation: false);
    });
  }

  @override
  void dispose() {
    _pageSubscription.cancel();
    _pomodoroTimer.dispose();
    super.dispose();
  }

  void _setPage(String page, {bool updateLocation = true}) {
    if (page == 'female' && ApiClient.instance.account?.isFemale != true) {
      page = 'body';
    }
    if (page != 'skill-agent' &&
        page != 'research-tools' &&
        page != 'chatbot' &&
        !_dailyModules.any((module) => module.id == page)) return;
    setState(() {
      selected = page;
      _openedPages.add(page);
      if (page != 'skill-agent' &&
          page != 'research-tools' &&
          page != 'chatbot') {
        _dailyModule = page;
      }
    });
    if (updateLocation) pushAppPage(page);
  }

  void _selectTopLevel(int index) => _setPage(switch (index) {
        0 => _dailyModule,
        1 => 'research-tools',
        2 => 'skill-agent',
        _ => 'chatbot',
      });

  Widget _timerBanner() => AnimatedBuilder(
        animation: _pomodoroTimer,
        builder: (context, _) {
          final info = _pomodoroTimer.info;
          if (info == null) return const SizedBox.shrink();
          return Material(
            color: surface,
            child: InkWell(
              onTap: () => _setPage('focus'),
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
        final modules = _dailyModules
            .where((module) => module.id != 'female' || female)
            .toList();
        if (!female) {
          _openedPages.remove('female');
          if (_dailyModule == 'female') _dailyModule = 'body';
          if (selected == 'female') selected = 'body';
        }
        final selectedTopLevel = selected == 'research-tools'
            ? 1
            : selected == 'skill-agent'
                ? 2
                : selected == 'chatbot'
                    ? 3
                    : 0;
        final pageStack = IndexedStack(
          index: selectedTopLevel,
          children: [
            IndexedStack(
              index: modules.indexWhere((m) => m.id == _dailyModule),
              children: [
                for (final module in modules)
                  KeyedSubtree(
                    key: ValueKey('daily-content-${module.id}'),
                    child: !_openedPages.contains(module.id)
                        ? const SizedBox.shrink()
                        : SafeArea(
                            bottom: false,
                            child: NestedScrollView(
                              headerSliverBuilder:
                                  (context, innerBoxIsScrolled) => [
                                SliverToBoxAdapter(
                                  child: _DailyModuleSelector(
                                      modules: modules,
                                      selected: _dailyModule,
                                      onSelected: (page) => _setPage(page,
                                          updateLocation: false)),
                                ),
                              ],
                              body: switch (module.id) {
                                'body' => const BodyPage(),
                                'calendar' => const _DailySectionPage(
                                    title: '生活日历',
                                    subtitle: '日记与备忘录',
                                    child: LifeCalendar(embedded: true)),
                                'focus' => _DailySectionPage(
                                    title: '专注时刻',
                                    subtitle: '番茄钟',
                                    child: PomodoroCard(
                                        timerController: _pomodoroTimer)),
                                'diary' => const DiaryPage(),
                                'female' => const FemaleHealthPage(),
                                'couple' => const CouplePage(embedded: true),
                                'workout' => const WorkoutPage(),
                                'travel' => const TravelPlannerPage(),
                                _ => const SizedBox.shrink(),
                              },
                            ),
                          ),
                  ),
              ],
            ),
            if (_openedPages.contains('research-tools'))
              const ResearchToolsPage(key: ValueKey('research-tools'))
            else
              const SizedBox.shrink(),
            if (_openedPages.contains('skill-agent'))
              const SkillAgentPage(key: ValueKey('skill-agent'))
            else
              const SizedBox.shrink(),
            if (_openedPages.contains('chatbot'))
              const ChatbotPage(key: ValueKey('chatbot'))
            else
              const SizedBox.shrink(),
          ],
        );
        return LayoutBuilder(builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 840;
          final extendedRail = constraints.maxWidth >= 1200;
          return Scaffold(
            drawer: Drawer(
              backgroundColor: paper,
              child: const MyPage(),
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
                              selectedIndex: selectedTopLevel,
                              onDestinationSelected: _selectTopLevel,
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
                                    icon: Icon(Icons.home_outlined),
                                    label: Text('日常')),
                                const NavigationRailDestination(
                                    icon: Icon(Icons.science_outlined),
                                    label: Text('科研工具')),
                                const NavigationRailDestination(
                                    icon: Icon(Icons.psychology_alt_rounded),
                                    label: Text('技能实验室')),
                                const NavigationRailDestination(
                                    icon:
                                        Icon(Icons.chat_bubble_outline_rounded),
                                    label: Text('聊天机器人')),
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
                        selectedIndex: selectedTopLevel,
                        onDestinationSelected: _selectTopLevel,
                        backgroundColor: surface,
                        indicatorColor: sageSoft,
                        destinations: [
                          const NavigationDestination(
                              icon: Icon(Icons.home_outlined), label: '日常'),
                          const NavigationDestination(
                              icon: Icon(Icons.science_outlined),
                              label: '科研工具'),
                          const NavigationDestination(
                              icon: Icon(Icons.psychology_alt_rounded),
                              label: '技能'),
                          const NavigationDestination(
                              icon: Icon(Icons.chat_bubble_outline_rounded),
                              label: '聊天'),
                        ],
                      ),
                    ],
                  ),
          );
        });
      });
}

class _DailyModuleSelector extends StatelessWidget {
  const _DailyModuleSelector(
      {required this.modules,
      required this.selected,
      required this.onSelected});
  final List<({String id, String label, Widget icon})> modules;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => SafeArea(
          bottom: false,
          child: Container(
            padding: EdgeInsets.fromLTRB(
                appPagePadding(constraints.maxWidth).left,
                12,
                appPagePadding(constraints.maxWidth).right,
                12),
            decoration: const BoxDecoration(
                color: surface,
                border: Border(bottom: BorderSide(color: line))),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                IconButton(
                  tooltip: '我的账户与设置',
                  onPressed: () => Scaffold.of(context).openDrawer(),
                  icon: AccountAvatar(
                      bytes: ApiClient.instance.account?.avatarBytes,
                      radius: 17),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('日常',
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 8),
              LayoutBuilder(builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
                final wide =
                    constraints.maxWidth >= modules.length * 80 * scale;
                final minEntryWidth = math.max(60.0, 52 * scale + 8);
                final columns = wide
                    ? modules.length
                    : ((constraints.maxWidth + 8) / (minEntryWidth + 8))
                        .floor()
                        .clamp(2, 4);
                final entryWidth =
                    (constraints.maxWidth - (columns - 1) * 8) / columns;
                final circleSize = wide ? 64.0 : 56.0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Wrap(spacing: 8, runSpacing: 20, children: [
                    for (final module in modules)
                      SizedBox(
                        width: entryWidth,
                        child: Semantics(
                          key: ValueKey('daily-module-${module.id}'),
                          button: true,
                          selected: selected == module.id,
                          label: module.label,
                          excludeSemantics: true,
                          onTap: () => onSelected(module.id),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => onSelected(module.id),
                              borderRadius: BorderRadius.circular(12),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AnimatedContainer(
                                      key:
                                          ValueKey('daily-circle-${module.id}'),
                                      duration: MediaQuery.disableAnimationsOf(
                                              context)
                                          ? Duration.zero
                                          : const Duration(milliseconds: 160),
                                      width: circleSize,
                                      height: circleSize,
                                      decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: selected == module.id
                                              ? sage
                                              : sageSoft),
                                      child: IconTheme(
                                          data: IconThemeData(
                                              size: 26,
                                              color: selected == module.id
                                                  ? Colors.white
                                                  : sage),
                                          child: Center(child: module.icon)),
                                    ),
                                    const SizedBox(height: 9),
                                    SizedBox(
                                        height: MediaQuery.textScalerOf(context)
                                                .scale(13) *
                                            2.6,
                                        child: Text(module.label,
                                            maxLines: 2,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: selected == module.id
                                                    ? sage
                                                    : muted,
                                                fontWeight:
                                                    selected == module.id
                                                        ? FontWeight.w600
                                                        : FontWeight.w400))),
                                  ]),
                            ),
                          ),
                        ),
                      ),
                  ]),
                );
              }),
            ]),
          ),
        ),
      );
}

class _DailySectionPage extends StatelessWidget {
  const _DailySectionPage(
      {required this.title, required this.subtitle, required this.child});
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: appPagePadding(constraints.maxWidth),
          children: [
            Text(title,
                style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: constraints.maxWidth >= 1050 ? 36 : 32,
                    height: 1.2)),
            const SizedBox(height: 7),
            Text(subtitle, style: const TextStyle(color: muted, fontSize: 13)),
            const SizedBox(height: 20),
            child,
          ],
        ),
      );
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
  double? goalWeight;
  bool _weightInJin = false;
  bool loading = true;
  bool _aiBusy = false;
  String? loadError;
  int _loadVersion = 0;

  String get _weightUnit => _weightInJin ? '斤' : 'kg';

  double _displayWeight(double kilograms) =>
      _weightInJin ? kilograms * 2 : kilograms;

  double _kilogramsFromInput(double value) => _weightInJin ? value / 2 : value;

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
                  initialValue: latest == null
                      ? ''
                      : (weight ? _displayWeight(latest.value) : latest.value)
                          .toStringAsFixed(1),
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: weight ? '体重（$_weightUnit）' : '身高（cm）',
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
                    if (weight) {
                      final kilograms = _kilogramsFromInput(value);
                      if (kilograms < 20 || kilograms > 300) {
                        return _weightInJin
                            ? '体重范围为 40–600 斤'
                            : '体重范围为 20–300 kg';
                      }
                    }
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
                          await db.saveWeight(date, _kilogramsFromInput(value));
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
                initialValue: goalWeight == null
                    ? ''
                    : _displayWeight(goalWeight!).toStringAsFixed(1),
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: '目标体重（$_weightUnit）',
                  filled: true,
                  fillColor: paper,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none),
                ),
                validator: (raw) {
                  final value = double.tryParse(raw ?? '');
                  if (value == null || !value.isFinite) return '请输入有效数值';
                  final kilograms = _kilogramsFromInput(value);
                  if (kilograms < 20 || kilograms > 300) {
                    return _weightInJin
                        ? '目标体重范围为 40–600 斤'
                        : '目标体重范围为 20–300 kg';
                  }
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
                        persist(_kilogramsFromInput(inputValue!));
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
    final series = weights
        .map((entry) =>
            BodyEntry(date: entry.date, value: _displayWeight(entry.value)))
        .toList();
    final displayGoalWeight =
        goalWeight == null ? null : _displayWeight(goalWeight!);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1080;
      final chart = _SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              overflowAlignment: OverflowBarAlignment.start,
              spacing: 12,
              overflowSpacing: 8,
              children: [
                const Text('体重趋势',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      Text('${series.length} 条记录',
                          style: const TextStyle(color: muted, fontSize: 12)),
                      TextButton.icon(
                        onPressed: editGoalWeight,
                        icon: const Icon(Icons.flag_outlined, size: 15),
                        label: Text(goalWeight == null
                            ? '设置目标'
                            : '目标 ${displayGoalWeight!.toStringAsFixed(1)} $_weightUnit'),
                        style: TextButton.styleFrom(
                          foregroundColor: sage,
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          minimumSize: const Size(0, 34),
                          textStyle: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(fontSize: 11),
                        ),
                      ),
                    ]),
              ]),
          const SizedBox(height: 12),
          AppMetricValue(
            value: series.isEmpty
                ? '—'
                : '${series.last.value.toStringAsFixed(1)} $_weightUnit',
            valueStyle:
                const TextStyle(fontFamily: 'serif', fontSize: 27, color: ink),
            unit: series.isEmpty ? '' : formatDate(series.last.date),
            unitStyle: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (series.isEmpty)
            const _EmptyChart()
          else
            _InteractiveWeightChart(
                entries: series,
                goalWeight: displayGoalWeight,
                unit: _weightUnit),
        ]),
      );
      final heightSection = _MetricCard(
        label: '当前身高',
        value: latestHeight?.value.toStringAsFixed(1) ?? '—',
        unit: 'cm',
        caption: latestHeight == null
            ? '添加一次身高记录'
            : '最近更新 · ${formatDate(latestHeight.date)}',
        action: SizedBox(
          width: 152,
          child: FilledButton(
            onPressed: () => editValue(weight: false),
            style: FilledButton.styleFrom(
              backgroundColor: sage,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              textStyle: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontSize: 12),
            ),
            child: Text(latestHeight == null ? '添加身高记录' : '更新身高记录'),
          ),
        ),
      );
      final weightSection = _MetricCard(
        label: '最近体重',
        value: latestWeight == null
            ? '—'
            : _displayWeight(latestWeight.value).toStringAsFixed(1),
        unit: _weightUnit,
        caption: latestWeight == null
            ? '记录今天的体重'
            : '最近记录 · ${formatDate(latestWeight.date)}',
        emphasized: true,
        labelTrailing: SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('kg')),
            ButtonSegment(value: true, label: Text('斤')),
          ],
          selected: {_weightInJin},
          onSelectionChanged: (selection) =>
              setState(() => _weightInJin = selection.first),
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 9)),
            minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
            textStyle: WidgetStatePropertyAll(Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(fontSize: 10, fontWeight: FontWeight.w600)),
          ),
        ),
        action: SizedBox(
          width: 152,
          child: FilledButton(
            onPressed: () => editValue(weight: true),
            style: FilledButton.styleFrom(
              backgroundColor: sage,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              textStyle: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontSize: 12),
            ),
            child: const Text('记录今日体重'),
          ),
        ),
      );
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
          padding: appPagePadding(constraints.maxWidth),
          children: [
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
  List<OtherExpenseEntry> dayOtherExpenses = [];
  List<OtherExpenseEntry> periodOtherExpenses = [];
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
      final data = await Future.wait<dynamic>([
        db.getMealsForDate(date),
        db.getMealsBetween(start, end),
        db.getOtherExpensesBetween(date, date),
        db.getOtherExpensesBetween(start, end),
      ]);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        dayMeals = data[0] as List<MealEntry>;
        periodMeals = data[1] as List<MealEntry>;
        dayOtherExpenses = data[2] as List<OtherExpenseEntry>;
        periodOtherExpenses = data[3] as List<OtherExpenseEntry>;
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
    final mealItems = existing == null
        ? <_MealItemDraft>[_MealItemDraft()]
        : existing.items
            .map((item) => _MealItemDraft(
                name: item.name,
                amount: (item.expenseCents / 100).toStringAsFixed(2)))
            .toList();
    final formKey = GlobalKey<FormState>();
    var saving = false;
    int totalCents() =>
        mealItems.fold(0, (sum, item) => sum + (item.cents ?? 0));

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(existing == null ? '记录$type' : '编辑$type',
              style: const TextStyle(fontFamily: 'serif', fontSize: 24)),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: math.min(440.0, MediaQuery.sizeOf(context).width - 80),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .56),
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (var index = 0; index < mealItems.length; index++) ...[
                      if (index > 0) const SizedBox(height: 10),
                      _MealItemFields(
                        key: ObjectKey(mealItems[index]),
                        index: index,
                        item: mealItems[index],
                        canRemove: mealItems.length > 1,
                        saving: saving,
                        totalCents: totalCents,
                        onChanged: () => setDialogState(() {}),
                        onRemove: () {
                          final removed = mealItems.removeAt(index);
                          setDialogState(() {});
                          removed.dispose();
                        },
                      ),
                    ],
                    const SizedBox(height: 5),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: saving || mealItems.length >= 20
                            ? null
                            : () => setDialogState(
                                  () => mealItems.add(_MealItemDraft()),
                                ),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('添加一项'),
                      ),
                    ),
                    Row(children: [
                      const Text('本餐合计',
                          style: TextStyle(
                              color: muted, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(formatMoney(totalCents()),
                          style: const TextStyle(
                              fontFamily: 'serif',
                              fontSize: 18,
                              fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 5),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                          '记录日期：${formatDate(selectedDate, year: true)}',
                          style: const TextStyle(color: muted, fontSize: 11)),
                    ),
                  ]),
                ),
              ),
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
                      final items = [
                        for (final item in mealItems)
                          MealItem(
                              name: item.name.text.trim(),
                              expenseCents: item.cents!),
                      ];
                      setDialogState(() => saving = true);
                      final success = await serverAction(
                          dialogContext,
                          () => db.saveMeal(
                                MealEntry(
                                    date: selectedDate,
                                    mealType: type,
                                    foods: items
                                        .map((item) => item.name)
                                        .join('、'),
                                    expenseCents: items.fold<int>(0,
                                        (sum, item) => sum + item.expenseCents),
                                    items: items),
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
    for (final item in mealItems) {
      item.dispose();
    }
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

  Future<void> editOtherExpense({OtherExpenseEntry? existing}) async {
    final category = TextEditingController(text: existing?.category ?? '');
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
          title: Text(existing == null ? '添加其他消费' : '编辑其他消费',
              style: const TextStyle(fontFamily: 'serif', fontSize: 24)),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: category,
                  autofocus: true,
                  maxLength: 80,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: '消费类别',
                    hintText: '例如：购物、乘车',
                    filled: true,
                    fillColor: paper,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none),
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请填写消费类别' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: '消费金额（元）',
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
                      setDialogState(() => saving = true);
                      final success = await serverAction(
                        dialogContext,
                        () => db.saveOtherExpense(
                          id: existing?.id,
                          date: selectedDate,
                          category: category.text.trim(),
                          expenseCents:
                              (double.parse(amount.text) * 100).round(),
                        ),
                      );
                      if (!dialogContext.mounted) return;
                      if (!success) {
                        setDialogState(() => saving = false);
                        return;
                      }
                      Navigator.pop(dialogContext);
                      setState(() => loading = true);
                      await reload();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('其他消费已保存')),
                        );
                      }
                    },
              child: Text(saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ),
    );
    category.dispose();
    amount.dispose();
  }

  Future<void> deleteOtherExpense(OtherExpenseEntry expense) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这笔消费？'),
        content:
            Text('${expense.category} · ${formatMoney(expense.expenseCents)}'),
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
    if (!await serverAction(context, () => db.deleteOtherExpense(expense.id)) ||
        !mounted) return;
    setState(() => loading = true);
    await reload();
  }

  int get dayTotal =>
      dayMeals.fold(0, (sum, item) => sum + item.expenseCents) +
      dayOtherExpenses.fold(0, (sum, item) => sum + item.expenseCents);
  int get periodTotal =>
      periodMeals.fold(0, (sum, item) => sum + item.expenseCents) +
      periodOtherExpenses.fold(0, (sum, item) => sum + item.expenseCents);

  int get periodOtherExpenseTotal =>
      periodOtherExpenses.fold(0, (sum, item) => sum + item.expenseCents);

  List<_PieSlice> get dailyPieSlices {
    final totals = <String, int>{};
    for (final meal in dayMeals) {
      totals.update(meal.mealType, (value) => value + meal.expenseCents,
          ifAbsent: () => meal.expenseCents);
    }
    for (final expense in dayOtherExpenses) {
      totals.update(expense.category, (value) => value + expense.expenseCents,
          ifAbsent: () => expense.expenseCents);
    }
    final entries = totals.entries.where((entry) => entry.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (var index = 0; index < entries.length; index++)
        _PieSlice(
          label: entries[index].key,
          cents: entries[index].value,
          color: _pieColors[index % _pieColors.length],
        ),
    ];
  }

  int mealTotal(String type) => periodMeals
      .where((meal) => meal.mealType == type)
      .fold(0, (sum, meal) => sum + meal.expenseCents);

  List<_ChartValue> chartValues() {
    if (period == _Period.day) {
      return dailyPieSlices
          .map((slice) => _ChartValue(
                slice.label.length > 2
                    ? slice.label.substring(0, 2)
                    : slice.label,
                slice.cents,
              ))
          .toList();
    }
    if (period == _Period.week) {
      const labels = ['一', '二', '三', '四', '五', '六', '日'];
      return List.generate(7, (index) {
        final date = rangeStart.add(Duration(days: index));
        final cents = periodMeals
                .where((meal) => dateKey(meal.date) == dateKey(date))
                .fold<int>(0, (sum, meal) => sum + meal.expenseCents) +
            periodOtherExpenses
                .where((expense) => dateKey(expense.date) == dateKey(date))
                .fold<int>(0, (sum, expense) => sum + expense.expenseCents);
        return _ChartValue(labels[index], cents);
      });
    }
    final days = rangeEnd.day;
    final weekCount = ((days + 6) / 7).floor();
    return List.generate(weekCount, (index) {
      final firstDay = index * 7 + 1;
      final lastDay = math.min(firstDay + 6, days).toInt();
      final cents = periodMeals
              .where((meal) =>
                  meal.date.day >= firstDay && meal.date.day <= lastDay)
              .fold<int>(0, (sum, meal) => sum + meal.expenseCents) +
          periodOtherExpenses
              .where((expense) =>
                  expense.date.day >= firstDay && expense.date.day <= lastDay)
              .fold<int>(0, (sum, expense) => sum + expense.expenseCents);
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
          AppDateNavigator(
            title: formatDate(selectedDate, year: true),
            isToday: isToday,
            subtitle:
                '${weekdayName(selectedDate.weekday)} · ${isToday ? '今天' : '历史记录'}',
            onPrevious: () =>
                setDate(selectedDate.subtract(const Duration(days: 1))),
            onNext: isToday
                ? null
                : () => setDate(selectedDate.add(const Duration(days: 1))),
            onChoose: chooseDate,
            onToday: () => setDate(DateTime.now()),
          ),
          const SizedBox(height: 8),
          _DailySpendCard(
            totalCents: dayTotal,
            mealCount: dayMeals.length,
            otherExpenseCount: dayOtherExpenses.length,
          ),
          const SizedBox(height: 10),
          _DailyExpensePieCard(
            title: isToday ? '今日消费构成' : '当天消费构成',
            totalCents: dayTotal,
            slices: dailyPieSlices,
          ),
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
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('其他消费',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              TextButton.icon(
                onPressed: () => editOtherExpense(),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('添加'),
                style: TextButton.styleFrom(
                  foregroundColor: sage,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          if (dayOtherExpenses.isEmpty)
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: line),
              ),
              child: const Text('还没有记录其他消费',
                  style: TextStyle(color: muted, fontSize: 11)),
            )
          else
            ...dayOtherExpenses.map((expense) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _OtherExpenseCard(
                    expense: expense,
                    onEdit: () => editOtherExpense(existing: expense),
                    onDelete: () => deleteOtherExpense(expense),
                  ),
                )),
        ],
      );
      final statistics = _StatisticsCard(
        period: period,
        totalCents: periodTotal,
        breakfastCents: mealTotal('早餐'),
        lunchCents: mealTotal('午餐'),
        dinnerCents: mealTotal('晚餐'),
        otherExpenseCents: periodOtherExpenseTotal,
        chartValues: chartValues(),
        onPeriodChanged: setPeriod,
      );

      return SafeArea(
        child: ListView(
          padding: appPagePadding(constraints.maxWidth),
          children: [
            const _Kicker('饮食日记'),
            const SizedBox(height: 7),
            Text('今天吃了什么？',
                style: TextStyle(
                    color: ink,
                    fontFamily: 'serif',
                    fontSize: wide ? 36 : 32,
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
    required this.action,
    this.labelTrailing,
    this.emphasized = false,
  });
  final String label;
  final String value;
  final String unit;
  final String caption;
  final Widget action;
  final Widget? labelTrailing;
  final bool emphasized;

  @override
  Widget build(BuildContext context) => Container(
        padding: appCardPadding,
        decoration: BoxDecoration(
          color: emphasized ? sageSoft : const Color(0xfff0efe8),
          borderRadius: BorderRadius.circular(18),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppMetricValue(
                  value: value,
                  unit: unit,
                  valueStyle: const TextStyle(
                      fontFamily: 'serif', fontSize: 30, height: 1.1),
                  unitStyle: const TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Text(caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 11)),
              ],
            );
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(children: [
                    Expanded(
                        child: Text(label,
                            style:
                                const TextStyle(color: muted, fontSize: 12))),
                    if (labelTrailing != null) labelTrailing!,
                  ]),
                ),
                const SizedBox(height: 8),
                if (constraints.maxWidth < 300 * scale)
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        details,
                        const SizedBox(height: 16),
                        Align(alignment: Alignment.centerRight, child: action),
                      ])
                else
                  Row(children: [
                    Expanded(child: details),
                    const SizedBox(width: 16),
                    action,
                  ]),
              ],
            );
          },
        ),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: appCardPadding,
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
      {required this.entries, required this.goalWeight, required this.unit});

  final List<BodyEntry> entries;
  final double? goalWeight;
  final String unit;

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
    final selectedIndex = _selectedIndex == null || entries.isEmpty
        ? null
        : _selectedIndex!.clamp(0, entries.length - 1).toInt();
    final selected = selectedIndex == null ? null : entries[selectedIndex];
    final rangeLabel = _rangeDays == 0 ? '全部' : '近 $_rangeDays 天';
    final semanticsValue = [
      selected == null
          ? '$rangeLabel，共 ${entries.length} 条记录'
          : '${formatDate(selected.date)}，${selected.value.toStringAsFixed(1)} ${widget.unit}',
      if (widget.goalWeight != null)
        '目标 ${widget.goalWeight!.toStringAsFixed(1)} ${widget.unit}',
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
        hint: '左右滑动、悬停或点击图表查看记录，也可使用左右方向键浏览',
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
            height: 200,
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
                  onHorizontalDragStart: (event) =>
                      _selectAt(event.localPosition, constraints.maxWidth),
                  onHorizontalDragUpdate: (event) =>
                      _selectAt(event.localPosition, constraints.maxWidth),
                  child: entries.isEmpty
                      ? const Center(child: Text('此时间范围内没有体重记录'))
                      : CustomPaint(
                          painter: _TrendPainter(
                            values:
                                entries.map((entry) => entry.value).toList(),
                            dates: entries.map((entry) => entry.date).toList(),
                            color: sage,
                            goalWeight: widget.goalWeight,
                            unit: widget.unit,
                            fontFamily: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.fontFamily,
                            selectedIndex: selectedIndex,
                          ),
                          child: const SizedBox.expand(),
                        ),
                ),
              );
            }),
          ),
          SizedBox(
            width: double.infinity,
            child: Text(
              widget.goalWeight == null
                  ? '悬停或左右滑动查看记录'
                  : '虚线表示目标体重 · 悬停或左右滑动查看记录',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: sage, fontSize: 12, fontWeight: FontWeight.w600),
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
      required this.dates,
      required this.color,
      required this.unit,
      this.fontFamily,
      this.goalWeight,
      this.selectedIndex});
  final List<double> values;
  final List<DateTime> dates;
  final Color color;
  final String unit;
  final String? fontFamily;
  final double? goalWeight;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 42.0;
    const bottom = 30.0;
    final chart = Rect.fromLTRB(_weightChartLeft, top,
        size.width - _weightChartRight, size.height - bottom);
    final axisTextStyle =
        TextStyle(color: muted, fontSize: 10, fontFamily: fontFamily);
    final unitLabel = TextPainter(
      text: TextSpan(text: unit, style: axisTextStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    unitLabel.paint(canvas, const Offset(0, 7));
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
    _paintDateLabels(canvas, chart, dates, selectedIndex);
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
      _paintWeightTooltip(canvas, size, point,
          '${values[selectedIndex!].toStringAsFixed(1)} $unit');
    }
  }

  void _paintDateLabels(
      Canvas canvas, Rect chart, List<DateTime> dates, int? selectedIndex) {
    if (dates.isEmpty) return;
    final maxLabels = math.max(2, (chart.width / 52).floor());
    final interval = math.max(1, (dates.length / maxLabels).ceil());
    final indices = <int>{
      if (selectedIndex != null) selectedIndex,
      0,
      for (var index = interval; index < dates.length - 1; index += interval)
        index,
      dates.length - 1,
    };
    final showYear = dates.first.year != dates.last.year;
    final textPainters = <int, TextPainter>{};
    for (final index in indices) {
      final selected = index == selectedIndex;
      textPainters[index] = TextPainter(
        text: TextSpan(
          text: formatDate(dates[index], year: showYear),
          style: TextStyle(
            color: selected ? sage : muted,
            fontSize: selected ? 11 : 10,
            fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    double centerFor(int index) => dates.length == 1
        ? chart.center.dx
        : chart.left + chart.width * index / (dates.length - 1);
    double leftFor(int index, TextPainter painter) {
      if (dates.length == 1) return chart.center.dx - painter.width / 2;
      if (index == 0) return chart.left;
      if (index == dates.length - 1) {
        return math.max(chart.left, chart.right - painter.width).toDouble();
      }
      final maxLeft = math.max(chart.left, chart.right - painter.width);
      return (centerFor(index) - painter.width / 2)
          .clamp(chart.left, maxLeft)
          .toDouble();
    }

    final priority = [
      if (selectedIndex != null && indices.contains(selectedIndex))
        selectedIndex,
      0,
      dates.length - 1,
      ...indices.where((index) =>
          index != 0 && index != dates.length - 1 && index != selectedIndex),
    ];
    final visible = <int>[];
    for (final index in priority.toSet()) {
      final painter = textPainters[index]!;
      final left = leftFor(index, painter);
      final overlaps = visible.any((other) {
        final otherPainter = textPainters[other]!;
        final otherLeft = leftFor(other, otherPainter);
        return left < otherLeft + otherPainter.width + 5 &&
            left + painter.width + 5 > otherLeft;
      });
      if (!overlaps) visible.add(index);
    }
    for (final index in visible) {
      final painter = textPainters[index]!;
      final left = leftFor(index, painter);
      painter.paint(canvas, Offset(left, chart.bottom + 7));
    }
  }

  void _paintWeightTooltip(
      Canvas canvas, Size size, Offset point, String value) {
    final text = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
            color: ink,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const horizontalPadding = 8.0;
    const verticalPadding = 4.0;
    const gap = 6.0;
    final width = text.width + horizontalPadding * 2;
    final height = text.height + verticalPadding * 2;
    final maxLeft = math.max(4.0, size.width - width - 4).toDouble();
    final left = (point.dx - width / 2).clamp(4.0, maxLeft).toDouble();
    final top = math.max(0.0, point.dy - height - gap).toDouble();
    final bubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, width, height),
      const Radius.circular(8),
    );
    canvas.drawRRect(bubble, Paint()..color = surface);
    canvas.drawRRect(
      bubble,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    text.paint(canvas, Offset(left + horizontalPadding, top + verticalPadding));
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.fontFamily != fontFamily ||
      !_sameDates(oldDelegate.dates, dates) ||
      oldDelegate.unit != unit ||
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

bool _sameDates(List<DateTime> first, List<DateTime> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

class _DailySpendCard extends StatelessWidget {
  const _DailySpendCard({
    required this.totalCents,
    required this.mealCount,
    required this.otherExpenseCount,
  });
  final int totalCents;
  final int mealCount;
  final int otherExpenseCount;

  @override
  Widget build(BuildContext context) => Container(
        padding: appCardPadding,
        decoration: BoxDecoration(
            color: sageSoft, borderRadius: BorderRadius.circular(18)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('当天总消费',
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
              child: Text('$mealCount 餐 · $otherExpenseCount 笔其他消费',
                  style: const TextStyle(color: sage, fontSize: 10)),
            ),
          ],
        ),
      );
}

class _OtherExpenseCard extends StatelessWidget {
  const _OtherExpenseCard({
    required this.expense,
    required this.onEdit,
    required this.onDelete,
  });

  final OtherExpenseEntry expense;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(13, 9, 5, 9),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: line),
        ),
        child: Row(
          children: [
            const Icon(Icons.sell_outlined, size: 16, color: sage),
            const SizedBox(width: 9),
            Expanded(
              child: Text(expense.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
            ),
            Text(formatMoney(expense.expenseCents),
                style: const TextStyle(fontFamily: 'serif', fontSize: 15)),
            IconButton(
              onPressed: onEdit,
              tooltip: '编辑消费',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined, size: 16, color: muted),
            ),
            IconButton(
              onPressed: onDelete,
              tooltip: '删除消费',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 17, color: muted),
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
          borderRadius: BorderRadius.circular(18),
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
                textStyle: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontSize: 10),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MealItemDraft {
  _MealItemDraft({String name = '', String amount = ''})
      : name = TextEditingController(text: name),
        amount = TextEditingController(text: amount);

  final TextEditingController name;
  final TextEditingController amount;

  int? get cents {
    final value = double.tryParse(amount.text.trim());
    if (value == null || !value.isFinite || value < 0 || value > 100000000) {
      return null;
    }
    return (value * 100).round();
  }

  void dispose() {
    name.dispose();
    amount.dispose();
  }
}

class _MealItemFields extends StatelessWidget {
  const _MealItemFields({
    super.key,
    required this.index,
    required this.item,
    required this.canRemove,
    required this.saving,
    required this.totalCents,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final _MealItemDraft item;
  final bool canRemove;
  final bool saving;
  final int Function() totalCents;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: paper, borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: Text('第${index + 1}项',
                  style: const TextStyle(
                      color: muted, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
            if (canRemove)
              IconButton(
                onPressed: saving ? null : onRemove,
                tooltip: '删除这一项',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
          ]),
          LayoutBuilder(builder: (context, constraints) {
            final nameField = TextFormField(
              controller: item.name,
              enabled: !saving,
              autofocus: index == 0,
              maxLength: 80,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '吃了什么',
                hintText: '例如：米饭',
                counterText: '',
                filled: true,
                fillColor: surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请填写食物名称' : null,
              onChanged: (_) => onChanged(),
            );
            final amountField = TextFormField(
              controller: item.amount,
              enabled: !saving,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '金额（元）',
                prefixText: '¥ ',
                filled: true,
                fillColor: surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
              validator: (value) {
                final cents = item.cents;
                if (cents == null) return '请输入有效金额';
                return totalCents() > 10000000000 ? '本餐金额超出范围' : null;
              },
              onChanged: (_) => onChanged(),
            );

            if (constraints.maxWidth < 340) {
              return Column(children: [
                nameField,
                const SizedBox(height: 8),
                amountField,
              ]);
            }
            return Row(children: [
              Expanded(child: nameField),
              const SizedBox(width: 8),
              SizedBox(width: 128, child: amountField),
            ]);
          }),
        ]),
      );
}

class _ChartValue {
  const _ChartValue(this.label, this.cents);
  final String label;
  final int cents;
}

class _PieSlice {
  const _PieSlice({
    required this.label,
    required this.cents,
    required this.color,
  });

  final String label;
  final int cents;
  final Color color;
}

const _pieColors = [
  Color(0xffb4775d),
  sage,
  Color(0xff8b8294),
  Color(0xffc59c4d),
  Color(0xff6d8fa4),
  Color(0xff9b7ca0),
  Color(0xffc87962),
];

class _DailyExpensePieCard extends StatelessWidget {
  const _DailyExpensePieCard({
    required this.title,
    required this.totalCents,
    required this.slices,
  });

  final String title;
  final int totalCents;
  final List<_PieSlice> slices;

  @override
  Widget build(BuildContext context) => Container(
        padding: appCardPadding,
        decoration: BoxDecoration(
          color: const Color(0xfff0efe8),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                Text(formatMoney(totalCents),
                    style: const TextStyle(fontFamily: 'serif', fontSize: 16)),
              ],
            ),
            const SizedBox(height: 11),
            if (slices.isEmpty)
              const SizedBox(
                height: 112,
                child: Center(
                  child: Text('当天暂无消费金额',
                      style: TextStyle(color: muted, fontSize: 11)),
                ),
              )
            else
              AppFormRow(
                breakpoint: 420,
                children: [
                  Center(
                      child: SizedBox(
                    width: 116,
                    height: 116,
                    child: CustomPaint(
                      painter: _ExpensePiePainter(slices),
                    ),
                  )),
                  Column(
                    children: [
                      for (final slice in slices)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                    color: slice.color, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(slice.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: muted, fontSize: 10)),
                              ),
                              const SizedBox(width: 5),
                              Text(formatMoney(slice.cents),
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      );
}

class _ExpensePiePainter extends CustomPainter {
  const _ExpensePiePainter(this.slices);

  final List<_PieSlice> slices;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<int>(0, (sum, slice) => sum + slice.cents);
    if (total == 0) return;

    final bounds = Offset.zero & size;
    var startAngle = -math.pi / 2;
    for (final slice in slices) {
      final sweepAngle = math.pi * 2 * slice.cents / total;
      canvas.drawArc(
        bounds,
        startAngle,
        sweepAngle,
        true,
        Paint()..color = slice.color,
      );
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _ExpensePiePainter oldDelegate) =>
      oldDelegate.slices != slices;
}

class _StatisticsCard extends StatefulWidget {
  const _StatisticsCard({
    required this.period,
    required this.totalCents,
    required this.breakfastCents,
    required this.lunchCents,
    required this.dinnerCents,
    required this.otherExpenseCents,
    required this.chartValues,
    required this.onPeriodChanged,
  });

  final _Period period;
  final int totalCents;
  final int breakfastCents;
  final int lunchCents;
  final int dinnerCents;
  final int otherExpenseCents;
  final List<_ChartValue> chartValues;
  final ValueChanged<_Period> onPeriodChanged;

  @override
  State<_StatisticsCard> createState() => _StatisticsCardState();
}

class _StatisticsCardState extends State<_StatisticsCard> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.chartValues.isEmpty || widget.period == _Period.day
        ? 0
        : widget.chartValues.length - 1;
  }

  @override
  void didUpdateWidget(covariant _StatisticsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.chartValues.isEmpty) {
      _selectedIndex = 0;
    } else if (oldWidget.period != widget.period) {
      _selectedIndex =
          widget.period == _Period.day ? 0 : widget.chartValues.length - 1;
    } else {
      _selectedIndex =
          _selectedIndex.clamp(0, widget.chartValues.length - 1).toInt();
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = switch (widget.period) {
      _Period.day => '当日',
      _Period.week => '本周',
      _Period.month => '本月',
    };
    final maximum = widget.chartValues.fold<int>(
        0, (current, point) => math.max(current, point.cents).toInt());
    final selected = widget.chartValues.isEmpty
        ? null
        : widget.chartValues[
            _selectedIndex.clamp(0, widget.chartValues.length - 1).toInt()];
    return Container(
      padding: appCardPadding,
      decoration: BoxDecoration(
          color: const Color(0xfff0efe8),
          borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                  child: Text('消费统计',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600))),
              _PeriodSelector(
                  period: widget.period, onChanged: widget.onPeriodChanged),
            ],
          ),
          const SizedBox(height: 10),
          AppMetricValue(
            value: formatMoney(widget.totalCents),
            unit: label,
            valueStyle: const TextStyle(fontFamily: 'serif', fontSize: 23),
            unitStyle: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, constraints) {
            final showEveryValue = widget.chartValues.isNotEmpty &&
                constraints.maxWidth / widget.chartValues.length >= 76;
            return Column(children: [
              if (!showEveryValue && selected != null) ...[
                Row(children: [
                  Text('${selected.label}消费',
                      style: const TextStyle(color: muted, fontSize: 12)),
                  const SizedBox(width: 8),
                  Text(formatMoney(selected.cents),
                      style: const TextStyle(
                          fontFamily: 'serif',
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  const Text('点柱查看',
                      style: TextStyle(color: muted, fontSize: 11)),
                ]),
                const SizedBox(height: 4),
              ],
              SizedBox(
                height: 110,
                child: widget.chartValues.isEmpty
                    ? const Center(
                        child: Text('当天暂无消费金额',
                            style: TextStyle(color: muted, fontSize: 12)))
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var index = 0;
                              index < widget.chartValues.length;
                              index++)
                            Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 2),
                                child: _spendBar(
                                  context,
                                  widget.chartValues[index],
                                  index,
                                  maximum,
                                  showValue: showEveryValue,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ]);
          }),
          const Padding(
            padding: EdgeInsets.only(top: 9),
            child: Divider(height: 1, color: Color(0xffe2e0d7)),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final columns = constraints.maxWidth >= 360 * scale ? 4 : 2;
            final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
            return Wrap(spacing: 16, runSpacing: 16, children: [
              for (final item in [
                ('早餐', widget.breakfastCents),
                ('午餐', widget.lunchCents),
                ('晚餐', widget.dinnerCents),
                ('其他', widget.otherExpenseCents),
              ])
                SizedBox(
                    width: width,
                    child: _Breakdown(label: item.$1, cents: item.$2)),
            ]);
          }),
        ],
      ),
    );
  }

  Widget _spendBar(
      BuildContext context, _ChartValue point, int index, int maximum,
      {required bool showValue}) {
    final ratio = maximum == 0 ? 0.0 : point.cents / maximum;
    final selected = index == _selectedIndex;
    void select() => setState(() => _selectedIndex = index);
    return Semantics(
      button: true,
      selected: selected,
      label: '${point.label}，消费${formatMoney(point.cents)}',
      onTap: select,
      excludeSemantics: true,
      child: InkWell(
        onTap: select,
        borderRadius: BorderRadius.circular(5),
        child: Column(
          children: [
            if (showValue)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(formatMoney(point.cents),
                      style: TextStyle(
                        color: selected ? sage : muted,
                        fontSize: 11,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      )),
                ),
              ),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 18,
                  height: 6 + 46 * ratio,
                  decoration: BoxDecoration(
                    color: selected || (point.cents == maximum && maximum > 0)
                        ? sage
                        : const Color(0xffbdc7b4),
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(5)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(point.label,
                style: const TextStyle(color: muted, fontSize: 9)),
          ],
        ),
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
