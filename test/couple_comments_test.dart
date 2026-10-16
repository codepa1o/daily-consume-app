import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:daily_consume/data/api_client.dart';
import 'package:daily_consume/data/couple.dart';
import 'package:daily_consume/widgets/couple_comments.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> comment(int id,
        {int? parent, int? target, bool liked = false, int likes = 0}) =>
    {
      'id': id,
      'author_id': id.isEven ? 2 : 1,
      'author_name': id.isEven ? '对方' : '我',
      'content': '留言正文$id',
      'created_at': '2026-10-15T16:00:09Z',
      'parent_id': parent,
      'reply_to_id': target,
      'reply_to_author': target == null
          ? null
          : target.isEven
              ? '对方'
              : '我',
      'avatar_base64': null,
      'like_count': likes,
      'liked_by_me': liked,
    };

void main() {
  setUpAll(() async {
    final path = Platform.environment['COUPLE_COMMENTS_FONT'];
    if (path != null) {
      await (FontLoader('CommentsPreview')
            ..addFont(Future.value(
                ByteData.sublistView(await File(path).readAsBytes()))))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    }
  });
  setUp(() {
    ApiClient.instance.account = Account(
        id: 1, username: 'test', nickname: '我', createdAt: DateTime(2026));
  });
  tearDown(() => ApiClient.instance.account = null);

  Future<void> pump(WidgetTester tester, CoupleApi api, List<dynamic> rows,
      {bool conflict = false,
      double scale = 1,
      GlobalKey? boundary,
      Future<void> Function()? changed}) async {
    tester.view.physicalSize = const Size(320, 980);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xfff6f0e6),
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff64765a)),
          cardTheme: const CardThemeData(
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(18)),
                  side: BorderSide(color: Color(0xffe8e7df)))),
          fontFamily: Platform.environment['COUPLE_COMMENTS_FONT'] == null
              ? null
              : 'CommentsPreview'),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(
          body: RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                  color: const Color(0xfff6f0e6),
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: CoupleComments(
                          api: api,
                          resourceId: 7,
                          initialComments: rows,
                          conflict: conflict,
                          onChanged: changed))))),
    ));
    await tester.pumpAndSettle();
  }

  test('时间固定为北京时间并保留秒，兼容旧评论缺省互动字段', () {
    expect(coupleCommentTime(DateTime.parse('2026-10-15T16:00:09Z')),
        '2026-10-16 00:00:09');
    expect(coupleCommentTime(DateTime.parse('2026-10-16T01:02:03+09:00')),
        '2026-10-16 00:02:03');
    final old = Map<String, dynamic>.from(comment(1))
      ..remove('like_count')
      ..remove('liked_by_me');
    expect(CoupleComment.fromJson(old).likeCount, 0);
    expect(CoupleComment.fromJson(old).likedByMe, isFalse);
  });

  testWidgets('两级回复可展开，大字号与秒级时间不溢出', (tester) async {
    final rows = [
      comment(1),
      comment(2, parent: 1, target: 1),
      comment(3, parent: 1, target: 2),
      comment(4, parent: 1, target: 3)
    ];
    final api = CoupleApi(
        request: (method, path, {body, query, binary = false}) async => rows);
    final boundary = GlobalKey();
    await pump(tester, api, rows, scale: 1.5, boundary: boundary);
    expect(find.text('2026-10-16 00:00:09'), findsNWidgets(3));
    expect(find.byKey(const ValueKey('comment-4')), findsNothing);
    final output = Platform.environment['COUPLE_COMMENTS_PREVIEW_PATH'];
    if (output != null)
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    final expand = find.byKey(const ValueKey('expand-comment-1'));
    await tester.ensureVisible(expand);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comment-4')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('comment-2'))).dx,
        tester.getTopLeft(find.byKey(const ValueKey('comment-4'))).dx);
    expect(tester.takeException(), isNull);
    if (output != null) {
      final normal = GlobalKey();
      await pump(tester, api, rows, boundary: normal);
      await tester.runAsync(() async {
        final image = await (normal.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(output.replaceFirst(RegExp(r'\.png$'), '-normal.png'))
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  testWidgets('旧刷新结果不覆盖已确认的点赞', (tester) async {
    final stale = Completer<List<dynamic>>();
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      if (method == 'PUT') return {'liked': true, 'like_count': 1};
      return stale.future;
    });
    await pump(tester, api, [comment(1)]);
    await tester.tap(find.byTooltip('刷新评论'));
    await tester.pump();
    final like = find.byKey(const ValueKey('like-comment-1'));
    await tester.tap(like);
    await tester.pumpAndSettle();
    expect(find.descendant(of: like, matching: find.text('1')), findsOneWidget);
    stale.complete([comment(1)]);
    await tester.pumpAndSettle();
    expect(find.descendant(of: like, matching: find.text('1')), findsOneWidget);
  });

  testWidgets('发送已成功时刷新失败不重复发送，账号切换清空旧草稿', (tester) async {
    final rows = [comment(1)];
    var sends = 0;
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      if (method == 'POST') {
        sends++;
        return {'id': 2};
      }
      return rows;
    });
    await pump(tester, api, rows, changed: () async {
      throw const ApiException('刷新失败', statusCode: 503);
    });
    await tester.enterText(find.byType(TextField), '确定发出的留言');
    await tester.pumpAndSettle();
    final send = find.byType(FilledButton);
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(find.text('重试发送'), findsNothing);
    await tester.enterText(find.byType(TextField), '账号一的草稿');
    ApiClient.instance.account = Account(
        id: 2, username: 'other', nickname: '其他账号', createdAt: DateTime(2026));
    ApiClient.instance.dataImported();
    await tester.pumpAndSettle();
    expect(find.text('账号已切换，请返回后重新打开'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('留言正文1'), findsNothing);
  });

  testWidgets('点赞即时显示、防止重复提交并支持取消', (tester) async {
    var row = comment(1);
    final requests = <bool>[];
    final first = Completer<Map<String, dynamic>>();
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      if (method == 'PUT') {
        final liked = (body as Map)['liked'] as bool;
        requests.add(liked);
        row = comment(1, liked: liked, likes: liked ? 1 : 0);
        if (requests.length == 1) return first.future;
        return {'liked': liked, 'like_count': liked ? 1 : 0};
      }
      return [row];
    });
    await pump(tester, api, [row]);
    final like = find.byKey(const ValueKey('like-comment-1'));
    await tester.tap(like);
    await tester.pump();
    expect(find.descendant(of: like, matching: find.text('1')), findsOneWidget);
    expect(tester.widget<TextButton>(like).onPressed, isNull);
    expect(requests, [true]);
    first.complete({'liked': true, 'like_count': 1});
    await tester.pumpAndSettle();
    await tester.tap(like);
    await tester.pumpAndSettle();
    expect(requests, [true, false]);
    expect(
        find.descendant(of: like, matching: find.text('点赞')), findsOneWidget);
  });

  for (final conflict in [false, true]) {
    testWidgets('回复失败保留草稿和对象，同一次重试不重复创建：$conflict', (tester) async {
      final rows = [comment(1), comment(2, parent: 1, target: 1)];
      final sent = <Map<String, dynamic>>[];
      var changes = 0;
      final api = CoupleApi(
          request: (method, path, {body, query, binary = false}) async {
        expect(
            path.startsWith('couple/${conflict ? 'conflicts' : 'memories'}/7/'),
            isTrue);
        if (method == 'POST') {
          sent.add(Map<String, dynamic>.from(body as Map));
          if (sent.length == 1) throw const ApiException('连接中断', statusCode: 0);
          rows.add(comment(3, parent: 1, target: 2));
          return {'id': 3};
        }
        return rows;
      });
      await pump(tester, api, rows, conflict: conflict, changed: () async {
        changes++;
      });
      final reply = find.byKey(const ValueKey('reply-comment-2'));
      await tester.ensureVisible(reply);
      await tester.tap(reply);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '想和你继续交流');
      await tester.pumpAndSettle();
      final send = find.byType(FilledButton);
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(sent.length, 1);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '想和你继续交流');
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.text('重试发送'), findsOneWidget);
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(sent.length, 2);
      expect(sent[0], sent[1]);
      expect(sent[1]['reply_to_id'], 2);
      expect(changes, 1);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(find.byKey(const ValueKey('comment-3')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('前台自动刷新同步互动且保留输入，点赞失败恢复原显示', (tester) async {
    var row = comment(1);
    var failLike = true;
    var refreshes = 0;
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      if (method == 'PUT') {
        if (failLike) throw const ApiException('点赞失败', statusCode: 503);
        return {'liked': true, 'like_count': 2};
      }
      refreshes++;
      return [row];
    });
    await pump(tester, api, [row]);
    final like = find.byKey(const ValueKey('like-comment-1'));
    await tester.tap(like);
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: like, matching: find.text('点赞')), findsOneWidget);
    await tester.enterText(find.byType(TextField), '尚未发送的草稿');
    row = comment(1, likes: 1);
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(refreshes, greaterThan(0));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '尚未发送的草稿');
    expect(find.descendant(of: like, matching: find.text('1')), findsOneWidget);
    failLike = false;
    await tester.ensureVisible(like);
    await tester.tap(like);
    await tester.pumpAndSettle();
    expect(find.descendant(of: like, matching: find.text('2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
