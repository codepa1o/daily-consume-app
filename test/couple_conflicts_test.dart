import 'package:daily_consume/couple_conflicts_page.dart';
import 'package:daily_consume/data/api_client.dart';
import 'package:daily_consume/data/app_database.dart' show dateKey;
import 'package:daily_consume/data/couple.dart';
import 'package:daily_consume/data/journal.dart' show journalToday;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _record() => {
      'id': 3,
      'conflict_date': dateKey(journalToday()),
      'title': '周末安排',
      'summary': '没有约好时间',
      'created_by': 1,
      'status': 'reflecting',
      'agreement': '',
      'follow_up_date': null,
      'agreement_version': 0,
      'agreement_confirmed_by': <int>[],
      'reflections': <Map<String, dynamic>>[],
      'comments': <Map<String, dynamic>>[],
    };

Finder _field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label);

void main() {
  setUp(() {
    ApiClient.instance.account = Account(
        id: 1,
        username: 'test',
        nickname: '我',
        gender: 'male',
        createdAt: DateTime(2026));
  });
  tearDown(() => ApiClient.instance.account = null);

  testWidgets('创建失败保留内容，重试复用请求编号后进入反思页', (tester) async {
    var failSave = true;
    final ids = <String>[];
    final record = _record();
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      if (path == 'couple/space')
        return {
          'id': 1,
          'title': '我们的小窝',
          'since_date': '2024-02-29',
          'members': [
            {'id': 1, 'nickname': '我'},
            {'id': 2, 'nickname': '你'}
          ],
        };
      if (method == 'GET' && path == 'couple/conflicts') return [];
      if (method == 'POST' && path == 'couple/conflicts') {
        final payload = body as Map;
        ids.add(payload['client_request_id'] as String);
        expect(payload['title'], '周末安排');
        if (failSave) throw const ApiException('连接超时');
        return {'id': 3};
      }
      if (path == 'couple/conflicts/3') return record;
      fail('Unexpected request: $method $path');
    });
    await tester
        .pumpWidget(MaterialApp(home: CoupleConflictCalendarPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('记录这一天'));
    await tester.pumpAndSettle();
    await tester.enterText(_field('争执主题'), '周末安排');
    await tester.enterText(_field('起因或经过（选填）'), '没有约好时间');
    await tester.tap(find.text('创建记录'));
    await tester.pumpAndSettle();
    expect(find.text('连接超时'), findsOneWidget);
    expect(tester.widget<TextField>(_field('争执主题')).controller!.text, '周末安排');
    failSave = false;
    await tester.tap(find.text('创建记录'));
    await tester.pumpAndSettle();
    expect(find.byType(CoupleConflictDetailPage), findsOneWidget);
    expect(ids, hasLength(2));
    expect(ids.toSet(), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('个人草稿发布及过期共同约定保护', (tester) async {
    Future<void> tap(String label) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final finder = find.text(label);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    final record = _record();
    final partner = {
      'author_id': 2,
      'author_name': '你',
      'observations': '没有约好时间',
      'feelings': '担心',
      'needs': '提前安排',
      'my_part': '',
      'request': '一起确认',
      'published': true,
    };
    record['reflections'] = [partner];
    final publication = <bool>[];
    final versions = <int>[];
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      if (method == 'GET') return record;
      final payload = Map<String, dynamic>.from(body as Map);
      if (path.endsWith('/reflection')) {
        publication.add(payload['published'] as bool);
        record['reflections'] = [
          partner,
          {
            ...payload,
            'author_id': 1,
            'author_name': '我',
          }
        ];
        return {'saved': true};
      }
      if (method == 'GET' && path.endsWith('/comments'))
        return record['comments'];
      if (method == 'POST' && path.endsWith('/comments')) {
        record['agreement'] = '每周五晚一起确认安排';
        record['agreement_version'] = 1;
        record['agreement_confirmed_by'] = [2];
        return {'id': 8};
      }
      if (path.endsWith('/agreement')) {
        versions.add(payload['expected_version'] as int);
        if (payload['expected_version'] != record['agreement_version']) {
          throw const ApiException('共同约定已更新，请载入最新约定后再确认', statusCode: 409);
        }
        expect(payload['agreement'], '每周五晚一起确认安排');
        record['status'] = 'agreed';
        record['agreement_confirmed_by'] = [1, 2];
        return record;
      }
      fail('Unexpected request: $method $path');
    });
    await tester.pumpWidget(MaterialApp(
        home: CoupleConflictDetailPage(
            id: 3, api: api, memberNames: const {1: '我', 2: '你'})));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_field('当时的感受')).maxLength, 1000);
    await tester.enterText(_field('当时的感受'), '有点失望');
    await tap('保存草稿');
    await tap('发布给另一半');
    expect(publication, [false, true]);
    await tester.ensureVisible(_field('下次我们可以怎么做'));
    await tester.enterText(_field('下次我们可以怎么做'), '旧的本地约定');
    final comment = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.hintText == '写一句评论…');
    await tester.ensureVisible(comment);
    await tester.enterText(comment, '一起讨论一下');
    await tap('发送');
    await tap('保存约定并确认');
    expect(versions, [0]);
    await tap('载入最新约定');
    expect(tester.widget<TextField>(_field('下次我们可以怎么做')).controller!.text,
        '每周五晚一起确认安排');
    await tap('保存约定并确认');
    expect(versions, [0, 1]);
    expect(find.text('你们都确认了这条约定。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
