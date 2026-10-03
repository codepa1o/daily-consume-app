import 'package:daily_consume/account_pages.dart';
import 'package:daily_consume/data/app_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Login screen has no guest entry and validates credentials',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    expect(find.text('登录'), findsOneWidget);
    expect(find.textContaining('游客'), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.text('登录'));
    await tester.pump();
    expect(find.text('请输入有效用户名（3–32 位）'), findsOneWidget);
    expect(find.text('密码长度为 8–128 位'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Registration requires matching passwords', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.tap(find.text('还没有账号？注册'));
    await tester.pump();
    final inputs = find.byType(TextFormField);
    await tester.enterText(inputs.at(0), 'hkl_user');
    await tester.enterText(inputs.at(1), 'password123');
    await tester.enterText(inputs.at(2), 'different123');
    await tester.ensureVisible(find.text('注册并登录'));
    await tester.tap(find.text('注册并登录'));
    await tester.pump();
    expect(find.text('两次密码不一致'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('Server JSON preserves workout snapshot colors and plans', () {
    final log = WorkoutLog.fromMap({
      'date': '2026-10-03',
      'muscles': [
        {'name': '核心', 'color': 0xffc87962}
      ]
    });
    expect(log.muscles.single.colorValue, 0xffc87962);
    expect(log.muscles.single.name, '核心');
    final plan = WorkoutDayPlan.fromMap({
      'muscles': ['胸', '背'],
      'is_rest': 0
    });
    expect(plan.muscles, ['胸', '背']);
    expect(plan.isRest, isFalse);
    final old = WorkoutLog.fromMap({
      'date': '2026-10-03',
      'muscles': '[{"name":"核心","color":4291328354}]'
    });
    expect(old.muscles.single.colorValue, 4291328354);
  });
}
