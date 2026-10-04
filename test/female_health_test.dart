import 'dart:io';
import 'dart:ui' as ui;

import 'package:daily_consume/data/api_client.dart';
import 'package:daily_consume/data/female_health.dart';
import 'package:daily_consume/female_health_page.dart';
import 'package:daily_consume/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime d(String date) => parseHealthDate(date);
MenstrualPeriod p(String start, String end, {int id = 1}) => MenstrualPeriod(
    id: id,
    start: d(start),
    end: d(end),
    dates: healthDateRange(d(start), d(end)));

void main() {
  setUpAll(() async {
    final path = Platform.environment['HEALTH_PREVIEW_FONT'];
    if (path != null) {
      final loader = FontLoader('HealthPreview')
        ..addFont(
            Future.value(ByteData.sublistView(await File(path).readAsBytes())));
      await loader.load();
      await (FontLoader('serif')
            ..addFont(Future.value(
                ByteData.sublistView(await File(path).readAsBytes()))))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    }
  });

  test('Missing dates and unconfirmed example values do not create predictions',
      () {
    final prediction = HealthPrediction(const HealthData(), d('2026-10-03'));
    expect(prediction.nextStart, isNull);
    expect(prediction.cycleLength, isNull);
    expect(prediction.typeAt(d('2026-10-28')), HealthDateType.ordinary);
    expect(
        Account.fromJson({
          'id': 1,
          'username': 'old',
          'nickname': '旧账号',
          'created_at': '2026-01-01T00:00:00Z'
        }).isFemale,
        isFalse);
  });

  test(
      'Calendar predicts from the actual first day, distinguishes ovulation and actual records',
      () {
    final data = HealthData(
        settings: const HealthSettings(cycleLength: 28, periodLength: 5),
        periods: [p('2026-09-29', '2026-10-03')]);
    final prediction = HealthPrediction(data, d('2026-10-03'));
    expect(prediction.nextStart, d('2026-10-27'));
    expect(prediction.nextEnd, d('2026-10-31'));
    expect(prediction.fertileStart, d('2026-10-08'));
    expect(prediction.ovulation, d('2026-10-13'));
    expect(prediction.typeAt(d('2026-10-03')), HealthDateType.period);
    expect(prediction.typeAt(d('2026-10-09')), HealthDateType.fertile);
    expect(prediction.typeAt(d('2026-10-13')), HealthDateType.ovulation);
    expect(prediction.typeAt(d('2026-10-28')), HealthDateType.predictedPeriod);
    final changed = HealthPrediction(
        HealthData(settings: data.settings, periods: [
          p('2026-09-29', '2026-10-03'),
          p('2026-10-27', '2026-10-28', id: 2)
        ]),
        d('2026-10-28'));
    expect(changed.typeAt(d('2026-10-28')), HealthDateType.period);
    expect(changed.nextStart, d('2026-11-24'));
    expect(HealthPrediction(data, d('2026-11-30')).nextStart, d('2026-10-27'));
    expect(HealthPrediction(data, d('2026-11-30')).typeAt(d('2026-11-24')),
        HealthDateType.ordinary);
  });

  test(
      'Three complete intervals switch to recent medians and pause preserves history',
      () {
    final periods = [
      p('2026-06-01', '2026-06-05'),
      p('2026-06-29', '2026-07-02', id: 2),
      p('2026-07-29', '2026-08-02', id: 3),
      p('2026-08-27', '2026-08-31', id: 4)
    ];
    final data = HealthData(
        settings: const HealthSettings(cycleLength: 40, periodLength: 9),
        periods: periods);
    expect(data.cycleLengths, [28, 30, 29]);
    final prediction = HealthPrediction(data, d('2026-09-01'));
    expect(prediction.cycleLength, 29);
    expect(prediction.periodLength, 5);
    expect(prediction.nextStart, d('2026-09-25'));
    final paused = HealthPrediction(
        HealthData(
            settings: const HealthSettings(paused: true), periods: periods),
        d('2026-08-30'));
    expect(paused.nextStart, isNull);
    expect(paused.typeAt(d('2026-08-30')), HealthDateType.period);
    expect(typicalLength([365, 28, 29, 30, 28, 29, 30]), 29);
  });

  test(
      'Spotting and ongoing periods do not fabricate bleeding or complete cycles',
      () {
    final data = HealthData(periods: [
      MenstrualPeriod(id: 1, start: d('2026-10-01'), dates: [d('2026-10-01')])
    ], days: [
      HealthDay(date: d('2026-10-02'), spotting: true)
    ]);
    expect(data.periodAt(d('2026-10-02')), isNull);
    expect(data.cycleLengths, isEmpty);
    expect(data.periodLengths, isEmpty);
    expect(data.dayAt(d('2026-10-02'))!.spotting, isTrue);
  });

  test('Date arithmetic handles leap years, year boundaries and clock offsets',
      () {
    expect(healthDateRange(d('2024-02-28'), d('2024-03-01')).length, 3);
    expect(healthDateRange(d('2025-12-30'), d('2026-01-03')).length, 5);
    expect(
        healthDate(DateTime(2026, 10, 3, 23))
            .difference(d('2026-10-01'))
            .inDays,
        2);
    final prediction = HealthPrediction(
        HealthData(
            settings: const HealthSettings(cycleLength: 28),
            periods: [p('2025-12-20', '2025-12-24')]),
        d('2026-01-01'));
    expect(prediction.nextStart, d('2026-01-17'));
  });

  testWidgets(
      'Month calendar aligns weekdays, selects dates and exposes labels',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var selected = d('2024-02-29');
    final data = HealthData(periods: [p('2024-02-28', '2024-03-01')]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HealthCalendar(
                month: d('2024-02-01'),
                selected: selected,
                data: data,
                today: d('2024-02-29'),
                onSelected: (date) => selected = date))));
    expect(find.text('29'), findsOneWidget);
    expect(find.text('30'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('2024-02-28')));
    expect(selected, d('2024-02-28'));
    expect(find.bySemanticsLabel('2024-02-29 已记录经期，今天'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('My page drawer and female navigation follow account gender',
      (tester) async {
    final api = ApiClient.instance;
    Account account(String gender) => Account(
        id: 1,
        username: 'test',
        nickname: '测试',
        createdAt: d('2026-01-01'),
        gender: gender);
    api.account = account('unset');
    await tester.pumpWidget(const MaterialApp(home: AppShell()));
    await tester.pumpAndSettle();
    NavigationBar bar() =>
        tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar().destinations.length, 3);
    await tester.tap(find.byTooltip('打开我的'));
    await tester.pumpAndSettle();
    expect(find.text('个人资料'), findsOneWidget);
    api.account = account('female');
    api.dataImported();
    await tester.pumpAndSettle();
    expect(bar().destinations.length, 4);
    expect(bar().selectedIndex, 0);
    expect(find.text('个人资料'), findsOneWidget);
    final screenWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(screenWidth - 1, 20));
    await tester.pumpAndSettle();
    await tester.tap(find.text('女性健康').last);
    await tester.pump();
    api.account = account('male');
    api.dataImported();
    await tester.pumpAndSettle();
    expect(bar().destinations.length, 3);
    expect(bar().selectedIndex, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.account = null;
  });

  testWidgets(
      'Health page fits narrow phones, validates settings and keeps failed forms',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: FemaleHealthPage(initialData: const HealthData()))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('周期设置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '0');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('请输入 1～365 的整数，或留空'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '28');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请先登录'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '28'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('经期开始 / 补录'));
    await tester.pumpAndSettle();
    expect(find.text('只记录已发生的出血，之后的日期不会自动记为经期。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Calendar page preview shows actual and predicted dates without layout overflow',
      (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final today = healthToday();
    final start = today.subtract(const Duration(days: 4));
    final data = HealthData(
        settings: const HealthSettings(cycleLength: 28, periodLength: 5),
        periods: [
          MenstrualPeriod(
              id: 1,
              start: start,
              end: today,
              dates: healthDateRange(start, today))
        ],
        days: [
          HealthDay(
              date: today,
              flow: 'medium',
              pain: 1,
              symptoms: const ['疲劳'],
              mood: '平静')
        ]);
    final boundary = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            useMaterial3: true,
            fontFamily: Platform.environment.containsKey('HEALTH_PREVIEW_FONT')
                ? 'HealthPreview'
                : null,
            scaffoldBackgroundColor: const Color(0xfff6f5ef),
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xff64765a))),
        home: RepaintBoundary(
            key: boundary,
            child: Scaffold(body: FemaleHealthPage(initialData: data)))));
    await tester.pumpAndSettle();
    expect(find.text('预计易孕期'), findsOneWidget);
    expect(find.text('估计排卵日'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final directory = Platform.environment['HEALTH_PREVIEW_DIR'];
    if (directory != null) {
      Future<void> capture(String name) async {
        await tester.runAsync(() async {
          final render = boundary.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File('$directory/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('calendar');
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      await capture('history');
    }
  });
}
