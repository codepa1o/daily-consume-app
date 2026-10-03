import 'package:daily_consume/workout_check_in_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _subject(Future<void> Function() onCheckIn, {bool enabled = true}) =>
    MaterialApp(
        home: Scaffold(
            body: Center(
                child: WorkoutCheckInButton(
                    enabled: enabled, onCheckIn: onCheckIn))));

void main() {
  testWidgets('a full two-second hold checks in exactly once', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_subject(() async {
      calls++;
    }));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(WorkoutCheckInButton)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(
        tester
            .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator))
            .value,
        closeTo(.5, .01));
    await tester.pump(const Duration(milliseconds: 999));
    expect(calls, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('releasing early cancels and the next hold starts from zero',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_subject(() async {
      calls++;
    }));
    final position = tester.getCenter(find.byType(WorkoutCheckInButton));
    final first = await tester.startGesture(position);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await first.up();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 0);
    expect(
        tester
            .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator))
            .value,
        0);
    final second = await tester.startGesture(position);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 1);
    await second.up();
    await tester.pump();
  });

  testWidgets('dragging off the button cancels the hold', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_subject(() async {
      calls++;
    }));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(WorkoutCheckInButton)));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 0);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('a disabled button does not check in', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_subject(() async {
      calls++;
    }, enabled: false));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(WorkoutCheckInButton)));
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 0);
    await gesture.up();
    await tester.pump();
  });
}
