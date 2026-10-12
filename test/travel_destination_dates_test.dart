import 'package:daily_consume/data/travel_cities.dart';
import 'package:daily_consume/travel_city_field.dart';
import 'package:daily_consume/travel_planner_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('城市目录去重且按拼音排列，中文、拼音和多音字首字母均可搜索', () async {
    final cities = await loadTravelCities();
    expect(cities.length, greaterThan(700));
    expect(cities.map((c) => '${c.name}|${c.province}').toSet().length,
        cities.length);
    final pinyin = cities.map((c) => c.pinyin).toList();
    expect(pinyin, [...pinyin]..sort());
    for (final name in travelHotCityNames) {
      expect(cities.where((c) => c.name == name), isNotEmpty);
    }
    for (final entry in {
      '杭州': ['杭', '杭州市', 'HANG ZHOU', 'hz'],
      '重庆': ['chongqing', 'CQ'],
      '厦门': ['xiamen', 'xm'],
      '六安': ['luan', 'la'],
      '乐清': ['yueqing', 'yq'],
      '义乌': ['yiwu', 'yw'],
    }.entries) {
      final city = cities.firstWhere((c) => c.name == entry.key);
      for (final query in entry.value) {
        expect(city.matches(query), isTrue, reason: '${entry.key}: $query');
      }
    }
    expect(cities.any((c) => c.matches('不存在的目的地zzzz')), isFalse);
  });

  testWidgets('窄屏城市下拉支持热门回填、字母筛选、拼音搜索和无匹配提示', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final cities = await tester.runAsync(loadTravelCities);
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
            size: Size(320, 900), textScaler: TextScaler.linear(1.6)),
        child: Scaffold(
            body: Padding(
          padding: const EdgeInsets.all(20),
          child: Form(child: TravelCityField(controller: controller)),
        )),
      ),
    ));
    final input = find.byKey(const ValueKey('travel-city-input'));
    await tester.tap(input);
    await tester.pumpAndSettle();
    expect(find.text('热门城市'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(FutureBuilder<List<TravelCity>>)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(input).dy),
    );
    final hot = find.byKey(const ValueKey('travel-hot-杭州'));
    await tester.ensureVisible(hot);
    await tester.tap(hot);
    await tester.pumpAndSettle();
    expect(controller.text, '杭州');
    expect(find.text('热门城市'), findsNothing);

    await tester.tap(find.byTooltip('展开城市列表'));
    await tester.pumpAndSettle();
    final letter = find.byKey(const ValueKey('travel-city-letter-C'));
    await tester.ensureVisible(letter);
    await tester.tap(letter);
    await tester.pumpAndSettle();
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile));
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      final code =
          (tile.key as ValueKey<String>).value.replaceFirst('travel-city-', '');
      expect(cities!.firstWhere((c) => c.code == code).letter, 'C');
    }
    await tester.enterText(input, 'XIA MEN');
    await tester.pumpAndSettle();
    final result = find.widgetWithText(ListTile, '厦门');
    expect(result, findsOneWidget);
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(controller.text, '厦门');

    await tester.tap(input);
    await tester.enterText(input, '没有这个城市zzzz');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的城市，可直接输入目的地名称。'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的城市，可直接输入目的地名称。'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('键盘弹出后城市菜单保持可见且不覆盖输入框', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.runAsync(loadTravelCities);
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 160, 20, 0),
        child: Form(child: TravelCityField(controller: controller)),
      )),
    ));
    final input = find.byKey(const ValueKey('travel-city-input'));
    await tester.tap(input);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final panel = find.byType(FutureBuilder<List<TravelCity>>);
    expect(panel, findsOneWidget);
    expect(tester.getTopLeft(panel).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(input).dy));
    expect(tester.getBottomRight(panel).dy, lessThanOrEqualTo(600));
    await tester.enterText(input, 'hangzhou');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '杭州'));
    await tester.pumpAndSettle();
    expect(controller.text, '杭州');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final width in [320.0, 1440.0]) {
    testWidgets('日期范围在宽度 $width 支持更早重选、确认、取消和同日往返', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
        locale: Locale('zh', 'CN'),
        supportedLocales: [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: TravelPlannerPage(),
      ));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('travel-date-range'));
      Future<void> open() async {
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byType(DateRangePickerDialog), findsOneWidget);
      }

      Future<void> day(int value) async {
        await tester.tap(find.text('$value').hitTestable().first);
        await tester.pumpAndSettle();
      }

      await open();
      final picker = tester
          .widget<DateRangePickerDialog>(find.byType(DateRangePickerDialog));
      final start = DateTime(2026, 10, 1);
      final allows = picker.selectableDayPredicate!;
      expect(allows(start.add(const Duration(days: 29)), start, null), isTrue);
      expect(allows(start.add(const Duration(days: 30)), start, null), isFalse);
      expect(
          allows(start.subtract(const Duration(days: 1)), start, null), isTrue);
      await day(10);
      await day(5);
      await day(7);
      await tester.tap(find.text('确认日期'));
      await tester.pumpAndSettle();
      expect(find.textContaining('共3天'), findsOneWidget);
      final previous = tester.widget<Text>(find.textContaining('共3天')).data;

      await open();
      await day(8);
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.text(previous!), findsOneWidget);

      await open();
      await day(8);
      await day(8);
      await tester.tap(find.text('确认日期'));
      await tester.pumpAndSettle();
      expect(find.textContaining('共1天'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
