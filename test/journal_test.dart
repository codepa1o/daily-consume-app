import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:daily_consume/data/api_client.dart';
import 'package:daily_consume/data/app_database.dart';
import 'package:daily_consume/data/journal.dart';
import 'package:daily_consume/journal_editor_page.dart';
import 'package:daily_consume/journal_records_page.dart';
import 'package:daily_consume/life_calendar.dart';
import 'package:daily_consume/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> row(
        {int id = 1,
        String content = '今天散步了。',
        String? date,
        String kind = 'diary',
        bool todo = false,
        bool completed = false,
        int version = 1}) =>
    {
      'id': id,
      'entry_date': date ?? dateKey(journalToday()),
      'kind': kind,
      'title': '',
      'content': content,
      'is_todo': todo,
      'completed': completed,
      'version': version,
    };
Map<String, dynamic> page(List<Map<String, dynamic>> rows) =>
    {'items': rows, 'total': rows.length, 'has_more': false};

Widget app(Widget child) => MaterialApp(
    theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: paper,
        colorScheme: ColorScheme.fromSeed(seedColor: sage, surface: surface)),
    home: child);

void main() {
  setUpAll(() async {
    final font = Platform.environment['JOURNAL_PREVIEW_FONT'];
    if (font != null) {
      await (FontLoader('JournalPreview')
            ..addFont(Future.value(
                ByteData.sublistView(await File(font).readAsBytes()))))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    }
  });
  tearDown(() {
    ApiClient.instance.account = null;
    ApiClient.instance.status = AuthStatus.signedOut;
  });

  test(
      'Month alignment handles leap days and year boundaries without elapsed-time shifts',
      () {
    final cells = journalMonthCells(DateTime.utc(2024, 2));
    expect(cells.take(3), everyElement(isNull));
    expect(cells.whereType<DateTime>().length, 29);
    expect(
        cells.last,
        DateTime.utc(2024, 2, 29).weekday == 7
            ? DateTime.utc(2024, 2, 29)
            : null);
    expect(cells.length % 7, 0);
    expect(
        journalMonthCells(DateTime.utc(2025, 2)).whereType<DateTime>().length,
        28);
    expect(journalDate(DateTime(2026, 1, 1, 23)), DateTime.utc(2026, 1, 1));
    expect(journalMonthKey(DateTime.utc(2025, 13)), '2026-01');
    expect(journalRequestId(), matches(RegExp(r'^[a-f0-9]{32}$')));
  });

  test('Completing a todo fetches full content and refuses stale versions',
      () async {
    final longText = List.filled(1000, '长').join();
    Map? written;
    var version = 1;
    final api = JournalApi(request: (method, path, {body, query}) async {
      if (method == 'GET')
        return row(
            kind: 'memo', todo: true, content: longText, version: version);
      written = body as Map;
      return row(
          kind: 'memo',
          todo: true,
          content: longText,
          completed: true,
          version: 2);
    });
    final entry = JournalEntry.fromJson(
        row(kind: 'memo', todo: true, content: longText.substring(0, 160)));
    await api.setCompleted(entry, true);
    expect(written!['content'], longText);
    expect(written!['completed'], true);
    version = 2;
    await expectLater(
        api.setCompleted(entry, false), throwsA(isA<ApiException>()));
  });

  testWidgets('Calendar date switch ignores earlier pending day responses',
      (tester) async {
    final first = Completer<dynamic>();
    var dayRequests = 0;
    final api = JournalApi(request: (method, path, {body, query}) async {
      if (path == 'journal/calendar') return {'days': []};
      dayRequests++;
      if (dayRequests == 1) return first.future;
      return page([row(content: '所选日期的记录', date: query!['date'])]);
    });
    await tester.pumpWidget(app(
        Scaffold(body: SingleChildScrollView(child: LifeCalendar(api: api)))));
    await tester.pump();
    await tester.tap(find.byTooltip('上一月'));
    await tester.pumpAndSettle();
    expect(find.text('所选日期的记录'), findsOneWidget);
    first.complete(page([row(content: '过期响应')]));
    await tester.pumpAndSettle();
    expect(find.text('过期响应'), findsNothing);
    expect(find.text('所选日期的记录'), findsOneWidget);
  });

  testWidgets('Failed editor save retains input and confirms leaving',
      (tester) async {
    final api = JournalApi(
        request: (method, path, {body, query}) async =>
            throw const ApiException('服务器拒绝', statusCode: 422));
    await tester
        .pumpWidget(app(JournalEditorPage(date: journalToday(), api: api)));
    await tester.enterText(find.byType(TextFormField).last, '未保存的正文');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('未保存的正文'), findsOneWidget);
    expect(find.text('服务器拒绝'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('内容还没有确认保存'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('未保存的正文'), findsOneWidget);
  });

  testWidgets('Uncertain create retries the same snapshot and request id',
      (tester) async {
    final submitted = <Map<String, dynamic>>[];
    final api = JournalApi(request: (method, path, {body, query}) async {
      final input = body as Map;
      submitted.add(Map<String, dynamic>.from(input));
      if (submitted.length == 1) throw const ApiException('超时');
      return row(content: input['content'] as String);
    });
    await tester.pumpWidget(app(Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            JournalEditorPage(date: journalToday(), api: api))),
                child: const Text('打开编辑'))))));
    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '提交快照');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
        (tester.widget<TextFormField>(find.byType(TextFormField).last)).enabled,
        false);
    await tester.ensureVisible(find.text('重试本次提交'));
    await tester.tap(find.text('重试本次提交'));
    await tester.pumpAndSettle();
    expect(submitted.length, 2);
    expect(submitted[0], submitted[1]);
    expect(find.text('打开编辑'), findsOneWidget);
  });

  testWidgets(
      'Conflict does not silently replace input; latest version requires explicit choice',
      (tester) async {
    var gets = 0;
    Map? latestAttempt;
    final api = JournalApi(request: (method, path, {body, query}) async {
      if (method == 'GET')
        return row(
            content: ++gets == 1 ? '原内容' : '其他设备修改',
            version: gets == 1 ? 1 : 2);
      latestAttempt = body as Map;
      if (latestAttempt!['expected_version'] == 2) {
        throw const ApiException('测试保留页面', statusCode: 422);
      }
      throw const ApiException('记录已修改', statusCode: 409);
    });
    await tester.pumpWidget(
        app(JournalEditorPage(date: journalToday(), id: 1, api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '我的修改');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('我的修改'), findsOneWidget);
    await tester.ensureVisible(find.text('查看服务器最新内容'));
    await tester.tap(find.text('查看服务器最新内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留我的输入'));
    await tester.pumpAndSettle();
    expect(find.text('我的修改'), findsOneWidget);
    await tester.tap(find.text('查看服务器最新内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用我的输入继续'));
    await tester.pumpAndSettle();
    expect(find.text('我的修改'), findsOneWidget);
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(latestAttempt!['expected_version'], 2);
    expect(latestAttempt!['content'], '我的修改');
  });

  testWidgets(
      'Search covers all dates and clears stale results during debounce',
      (tester) async {
    final calls = <Map<String, String>>[];
    final api = JournalApi(request: (method, path, {body, query}) async {
      calls.add(query!);
      return page([
        row(content: query['q']!.isEmpty ? '原列表' : '搜索命中', date: '2024-02-29')
      ]);
    });
    await tester.pumpWidget(app(JournalRecordsPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('原列表'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '中文');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('原列表'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(calls.last['q'], '中文');
    expect(calls.last.containsKey('date'), false);
    expect(find.text('搜索命中'), findsOneWidget);
  });

  testWidgets('Switching accounts clears editor contents and hides old records',
      (tester) async {
    ApiClient.instance.account =
        Account(id: 1, username: 'a', nickname: 'a', createdAt: nullDate);
    final api = JournalApi(
        request: (method, path, {body, query}) async =>
            row(content: '账号一私密内容'));
    await tester.pumpWidget(
        app(JournalEditorPage(date: journalToday(), id: 1, api: api)));
    await tester.pumpAndSettle();
    expect(find.text('账号一私密内容'), findsOneWidget);
    ApiClient.instance.account =
        Account(id: 2, username: 'b', nickname: 'b', createdAt: nullDate);
    ApiClient.instance.dataImported();
    await tester.pumpAndSettle();
    expect(find.text('账号一私密内容'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets('Body failure leaves the life calendar mounted', (tester) async {
    await tester.pumpWidget(app(const Scaffold(body: BodyPage())));
    await tester.pumpAndSettle();
    expect(find.byType(LifeCalendar), findsOneWidget);
    expect(find.text('身体记录'), findsOneWidget);
  });

  testWidgets(
      'Narrow calendar at large text has no layout overflow and exports a preview',
      (tester) async {
    tester.view.physicalSize = const Size(360, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final today = journalToday();
    final api = JournalApi(request: (method, path, {body, query}) async {
      if (path == 'journal/calendar')
        return {
          'days': [
            {
              'entry_date': dateKey(today),
              'diaries': 1,
              'memos': 1,
              'pending': 1,
              'completed': 0
            }
          ]
        };
      return page([
        row(content: '训练后的晚上，散步回家。'),
        row(id: 2, kind: 'memo', todo: true, content: '明天买新的训练弹力带')
      ]);
    });
    final key = GlobalKey();
    final font = Platform.environment['JOURNAL_PREVIEW_FONT'];
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            useMaterial3: true,
            fontFamily: font == null ? null : 'JournalPreview',
            scaffoldBackgroundColor: paper,
            colorScheme:
                ColorScheme.fromSeed(seedColor: sage, surface: surface)),
        home: RepaintBoundary(
            key: key,
            child: MediaQuery(
                data: const MediaQueryData(
                    size: Size(360, 960), textScaler: TextScaler.linear(1.6)),
                child: Scaffold(
                    body: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: LifeCalendar(api: api)))))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final output = Platform.environment['JOURNAL_PREVIEW_PATH'];
    if (output != null) {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File(output).writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}

final nullDate = DateTime.utc(2024);
