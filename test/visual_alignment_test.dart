import 'dart:io';
import 'dart:ui' as ui;

import 'package:daily_consume/account_pages.dart';
import 'package:daily_consume/data/api_client.dart';
import 'package:daily_consume/data/journal.dart';
import 'package:daily_consume/life_calendar.dart';
import 'package:daily_consume/main.dart';
import 'package:daily_consume/travel_planner_page.dart';
import 'package:daily_consume/widgets/app_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    final font = Platform.environment['ALIGNMENT_FONT'];
    if (font != null) {
      final bytes = ByteData.sublistView(await File(font).readAsBytes());
      for (final family in [
        'AlignmentPreview',
        'serif',
        'sans-serif',
        'Ahem',
        'Roboto'
      ]) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    }
  });

  Future<void> pumpPage(WidgetTester tester, Widget child,
      {required double width, double scale = 1, GlobalKey? previewKey}) async {
    tester.view.physicalSize = Size(width, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final app = const DailyConsumeApp()
        .build(tester.element(find.byType(SizedBox).first)) as MaterialApp;
    final theme = Platform.environment['ALIGNMENT_FONT'] == null
        ? app.theme!
        : app.theme!.copyWith(
            textTheme:
                app.theme!.textTheme.apply(fontFamily: 'AlignmentPreview'));
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
          body: RepaintBoundary(
              key: previewKey,
              child: ColoredBox(
                  color: theme.scaffoldBackgroundColor, child: child))),
    ));
    await tester.pumpAndSettle();
  }

  for (final scenario in [(320.0, 1.5), (390.0, 1.0), (1200.0, 1.0)]) {
    testWidgets('Form fields adapt and date remains centered at $scenario',
        (tester) async {
      await pumpPage(
          tester,
          AppPageList(children: [
            AppDateNavigator(
                title: '2026年10月15日',
                subtitle: '星期四 · 今天',
                onPrevious: () {},
                onNext: null,
                onChoose: () {},
                onToday: () {}),
            const SizedBox(height: 16),
            const AppFormRow(children: [
              TextField(
                  key: ValueKey('first'),
                  decoration: InputDecoration(labelText: '总预算（元，可不填）')),
              TextField(
                  key: ValueKey('second'),
                  decoration: InputDecoration(labelText: '预算档位')),
            ]),
            const SizedBox(height: 16),
            const AppMetricValue(
                value: '168.0',
                unit: 'cm',
                valueStyle: TextStyle(fontSize: 30),
                unitStyle: TextStyle(fontSize: 12)),
          ]),
          width: scenario.$1,
          scale: scenario.$2);
      expect(tester.takeException(), isNull);
      expect(tester.getCenter(find.text('2026年10月15日')).dx,
          closeTo(scenario.$1 / 2, 1));
      final first = tester.getRect(find.byKey(const ValueKey('first')));
      final second = tester.getRect(find.byKey(const ValueKey('second')));
      if (scenario.$1 < 600) {
        expect(second.top, greaterThan(first.bottom));
        expect(first.left, second.left);
        expect(first.width, second.width);
      } else {
        expect(first.top, second.top);
        expect(first.width, second.width);
      }
      double baseline(String value) {
        final box = tester.renderObject<RenderBox>(find.text(value));
        return tester.getTopLeft(find.text(value)).dy +
            box.getDryBaseline(box.constraints, TextBaseline.alphabetic)!;
      }

      expect(baseline('168.0'), closeTo(baseline('cm'), 0.1));
    });

    for (final name in ['travel', 'account', 'calendar']) {
      testWidgets('$name handles narrow screens and large text at $scenario',
          (tester) async {
        ApiClient.instance.account = Account(
            id: 1,
            username: 'alignment_user',
            nickname: '测试用户',
            gender: 'female',
            createdAt: DateTime(2026, 10, 10));
        addTearDown(() => ApiClient.instance.account = null);
        final api = JournalApi(
            request: (method, path, {body, query}) async =>
                path == 'journal/calendar'
                    ? {'days': []}
                    : {'items': [], 'total': 0, 'has_more': false});
        final child = switch (name) {
          'travel' => const TravelPlannerPage(),
          'account' => const MyPage(),
          _ => AppPageList(children: [LifeCalendar(api: api, embedded: true)]),
        };
        final previewKey = GlobalKey();
        await pumpPage(tester, child,
            width: scenario.$1, scale: scenario.$2, previewKey: previewKey);
        expect(tester.takeException(), isNull);
        final output = Platform.environment['ALIGNMENT_PREVIEW_DIR'];
        if (output != null && scenario.$1 == 390) {
          await tester.runAsync(() async {
            final image = await (previewKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(output).create(recursive: true);
            await File('$output/$name.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        for (var i = 0; i < 8; i++) {
          await tester.drag(
              find.byType(Scrollable).first, const Offset(0, -400));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
