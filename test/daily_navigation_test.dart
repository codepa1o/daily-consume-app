import 'package:daily_consume/couple_page.dart';
import 'package:daily_consume/data/api_client.dart';
import 'package:daily_consume/female_health_page.dart';
import 'package:daily_consume/life_calendar.dart';
import 'package:daily_consume/main.dart';
import 'package:daily_consume/pomodoro_card.dart';
import 'package:daily_consume/travel_planner_page.dart';
import 'package:daily_consume/workout_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RouteObserver extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

void main() {
  for (final width in [320.0, 390.0, 1440.0]) {
    for (final gender in ['male', 'female']) {
      testWidgets('Daily modules switch inline at width $width for $gender',
          (tester) async {
        tester.view.physicalSize = Size(width, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        ApiClient.instance.account = Account(
            id: 1,
            username: 'test',
            nickname: '测试',
            gender: gender,
            createdAt: DateTime(2026));
        addTearDown(() => ApiClient.instance.account = null);
        final observer = _RouteObserver();
        await tester.pumpWidget(MaterialApp(
            navigatorObservers: [observer], home: const AppShell()));
        await tester.pumpAndSettle();

        expect(find.byType(BodyPage), findsOneWidget);
        expect(find.byType(LifeCalendar, skipOffstage: false), findsNothing);
        expect(find.byType(PomodoroCard, skipOffstage: false), findsNothing);
        final ids = [
          'body',
          'calendar',
          'focus',
          'diary',
          if (gender == 'female') 'female',
          'couple',
          'workout',
          'travel'
        ];
        expect(
            ids.map((id) => tester
                .widget<Semantics>(find.byKey(ValueKey('daily-module-$id')))
                .properties
                .label),
            [
              '身体数据',
              '生活日历',
              '专注时刻',
              '饮食消费',
              if (gender == 'female') '女性健康',
              '情侣空间',
              '健身',
              '旅游规划'
            ]);
        if (gender == 'male') {
          expect(
              find.byKey(const ValueKey('daily-module-female')), findsNothing);
        }
        final first = find.byKey(const ValueKey('daily-module-body'));
        final fourth = find.byKey(const ValueKey('daily-module-diary'));
        final fifth = find.byKey(ValueKey('daily-module-${ids[4]}'));
        expect(tester.getTopLeft(first).dy, tester.getTopLeft(fourth).dy);
        if (width < 600) {
          expect(tester.getTopLeft(fifth).dy,
              greaterThan(tester.getTopLeft(first).dy));
          expect(
              tester.getSize(find.byKey(const ValueKey('daily-circle-body'))),
              const Size(56, 56));
        } else {
          expect(tester.getTopLeft(first).dy, tester.getTopLeft(fifth).dy);
          expect(
              tester.getSize(find.byKey(const ValueKey('daily-circle-body'))),
              const Size(64, 64));
        }
        final initialPushes = observer.pushes;

        Future<void> open(String id) async {
          final entry = find.byKey(ValueKey('daily-module-$id'));
          await tester.ensureVisible(entry);
          await tester.tap(entry);
          await tester.pumpAndSettle();
          expect(tester.widget<Semantics>(entry).properties.selected, isTrue);
          expect(observer.pushes, initialPushes);
          expect(tester.takeException(), isNull);
        }

        await open('calendar');
        expect(find.byType(LifeCalendar), findsOneWidget);
        final calendar = tester.state(find.byType(LifeCalendar));
        await open('focus');
        final timer = tester.state(find.byType(PomodoroCard));
        await open('diary');
        expect(find.byType(DiaryPage), findsOneWidget);
        if (gender == 'female') {
          await open('female');
          expect(find.byType(FemaleHealthPage), findsOneWidget);
        }
        await open('couple');
        expect(find.byType(CouplePage), findsOneWidget);
        expect(find.byType(BackButton), findsNothing);
        await open('workout');
        expect(find.byType(WorkoutPage), findsOneWidget);
        await open('travel');
        expect(find.byType(TravelPlannerPage), findsOneWidget);
        await open('focus');
        expect(tester.state(find.byType(PomodoroCard)), same(timer));
        await open('calendar');
        expect(tester.state(find.byType(LifeCalendar)), same(calendar));
        await open('body');
        expect(find.byType(BodyPage), findsOneWidget);
        expect(find.byType(PomodoroCard), findsNothing);
        expect(find.byType(LifeCalendar), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
