import 'package:daily_consume/travel_planning_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('长时间规划保留进度余量，收到结果后补满，窄屏大字体不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget page({bool complete = false}) => MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: Center(child: TravelPlanningLoading(complete: complete)),
            ),
          ),
        );
    double progress() => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value!;
    CustomPainter painter() => tester
        .widget<CustomPaint>(
            find.byKey(const ValueKey('travel-running-person')))
        .painter!;

    await tester.pumpWidget(page());
    expect(find.text('预估进度'), findsOneWidget);
    final before = painter();
    await tester.pump(const Duration(milliseconds: 100));
    expect(painter().shouldRepaint(before), isTrue);
    final start = progress();
    await tester.pump(const Duration(seconds: 1));
    expect(progress(), greaterThan(start));
    expect(progress() - start, lessThan(.02));
    await tester.pump(const Duration(minutes: 9));
    expect(progress(), closeTo(.94, .0001));
    expect(find.text('100%'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(page(complete: true));
    expect(progress(), lessThan(1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(progress(), greaterThan(.94));
    expect(progress(), lessThan(1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(progress(), 1);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('行程已生成，即将展示…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动画设置下小人保持静止，关闭弹窗释放动画', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Scaffold(body: Center(child: TravelPlanningLoading())),
      ),
    ));
    final finder = find.byKey(const ValueKey('travel-running-person'));
    final before = tester.widget<CustomPaint>(finder).painter!;
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<CustomPaint>(finder).painter!.shouldRepaint(before),
        isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
