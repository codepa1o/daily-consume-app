import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_consume/couple_effects.dart';
import 'package:daily_consume/data/couple.dart';
import 'package:daily_consume/couple_page.dart';
import 'package:daily_consume/data/api_client.dart';

CoupleMemory memory(int id, int author,
        {bool photo = true, String day = '2024-02-29', String? publishedDay}) =>
    CoupleMemory(
        id: id,
        authorId: author,
        author: '用户$author',
        date: DateTime.parse(day),
        publishedDate: DateTime.parse(publishedDay ?? day),
        title: '回忆$id',
        content: '',
        mood: '',
        photoCount: photo ? 1 : 0,
        displayMode: 'grid');

void main() {
  setUpAll(() async {
    final font = Platform.environment['COUPLE_PREVIEW_FONT'];
    if (font != null) {
      await (FontLoader('CouplePreview')
            ..addFont(Future.value(
                ByteData.sublistView(await File(font).readAsBytes()))))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
      await (FontLoader('serif')
            ..addFont(Future.value(
                ByteData.sublistView(await File(font).readAsBytes()))))
          .load();
    }
  });

  testWidgets('text-only memories do not request nonexistent photos',
      (tester) async {
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      fail('Text-only memory requested $path');
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CouplePhoto(memory: memory(1, 1, photo: false), api: api))));
    await tester.pumpAndSettle();
    expect(find.text('回忆1'), findsOneWidget);
  });

  testWidgets(
      'failed save retains a draft and successful retry closes the editor',
      (tester) async {
    var failures = true;
    final ids = <String>[];
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      ids.add((body as Map)['client_request_id'] as String);
      if (failures) throw const ApiException('连接超时');
      return {};
    });
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => CoupleEditor(api: api))),
                    child: const Text('开始记录'))))));
    await tester.tap(find.text('开始记录'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '我们的周末');
    await tester.tap(find.text('保存').first);
    await tester.pumpAndSettle();
    expect(find.text('连接超时'), findsOneWidget);
    expect(find.text('我们的周末'), findsOneWidget);
    failures = false;
    await tester.tap(find.text('保存').first);
    await tester.pumpAndSettle();
    expect(find.text('开始记录'), findsOneWidget);
    expect(ids.toSet(), hasLength(1));
    expect(find.byType(CoupleEditor), findsNothing);
  });

  testWidgets('all six photo modes fit a narrow phone with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      if (path.endsWith('/photo') || path.contains('/photos/'))
        return File('assets/branding/rem_logo.png').readAsBytesSync();
      if (path == 'couple/pair')
        return {
          'items': [testRow(1, 1), testRow(2, 2)]
        };
      return {...testRow(1, 1), 'comments': [], 'reactions': []};
    });
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            useMaterial3: true,
            fontFamily: Platform.environment['COUPLE_PREVIEW_FONT'] == null
                ? null
                : 'CouplePreview',
            colorScheme: ColorScheme.fromSeed(seedColor: coupleRose)),
        home: RepaintBoundary(
            key: key,
            child: MediaQuery(
                data: const MediaQueryData(
                    size: Size(320, 900), textScaler: TextScaler.linear(1.6)),
                child: CoupleDetail(
                    memory: memory(1, 1),
                    memories: [memory(1, 1), memory(2, 2)],
                    api: api)))));
    await tester.pumpAndSettle();
    for (final effect in coupleEffects) {
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(effect).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: effect);
      if (effect == '惊喜刮刮卡') {
        expect(find.text('一起散步回家。'), findsNothing);
        await tester.tap(find.text('直接打开惊喜'));
        await tester.pumpAndSettle();
        expect(find.text('一起散步回家。'), findsOneWidget);
      }
      final directory = Platform.environment['COUPLE_PREVIEW_DIRECTORY'];
      if (directory != null) {
        await tester.runAsync(() => precacheImage(
            MemoryImage(File('assets/branding/rem_logo.png').readAsBytesSync()),
            tester.element(find.byType(CoupleDetail).first)));
        await tester.pumpAndSettle();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes =
              (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File('$directory/effect-${coupleEffects.indexOf(effect)}.png')
              .writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
    }
  });

  testWidgets('couple home opens a memory and exports the actual app layout',
      (tester) async {
    tester.view.physicalSize = const Size(360, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      if (path == 'couple/space')
        return {
          'id': 1,
          'title': '两个人的小窝',
          'since_date': '2024-02-29',
          'members': [
            {'id': 1, 'nickname': '我'},
            {'id': 2, 'nickname': '她'}
          ]
        };
      if (path == 'couple/memories')
        return {
          'items': [testRow(1, 1)],
          'has_more': false
        };
      if (path.endsWith('/photo') || path.contains('/photos/'))
        return File('assets/branding/rem_logo.png').readAsBytesSync();
      return {...testRow(1, 1), 'comments': [], 'reactions': []};
    });
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            useMaterial3: true,
            fontFamily: Platform.environment['COUPLE_PREVIEW_FONT'] == null
                ? null
                : 'CouplePreview',
            colorScheme: ColorScheme.fromSeed(seedColor: coupleRose)),
        home: RepaintBoundary(key: key, child: CouplePage(api: api))));
    await tester.pumpAndSettle();
    expect(find.text('一起散步回家'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final directory = Platform.environment['COUPLE_PREVIEW_DIRECTORY'];
    if (directory != null) {
      await tester.runAsync(() => precacheImage(
          MemoryImage(File('assets/branding/rem_logo.png').readAsBytesSync()),
          tester.element(find.byType(CouplePage))));
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$directory/couple-home.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('一起散步回家'));
    await tester.pumpAndSettle();
    expect(find.text('照片玩法'), findsOneWidget);
  });
  test(
      'same-day collage never duplicates one author or selects a text-only entry',
      () {
    final rows = [
      memory(1, 1),
      memory(2, 2),
      memory(3, 1),
      memory(4, 2, photo: false),
      memory(5, 3, day: '2024-03-01')
    ];
    expect(couplePair(rows, DateTime(2024, 2, 29)).map((m) => m.id), [3, 2]);
    expect(couplePair([memory(1, 1)], DateTime(2024, 2, 29)), hasLength(1));
  });

  test('couple binding and memory requests use current authenticated API paths',
      () async {
    final calls = <String>[];
    final api =
        CoupleApi(request: (method, path, {body, query, binary = false}) async {
      calls.add('$method $path');
      if (path == 'couple/space') return null;
      if (path == 'couple/pair') {
        expect(query!['date'], '2024-02-29');
        return {'items': <dynamic>[]};
      }
      if (path.endsWith('/reaction')) expect((body as Map)['emoji'], isNull);
      return <String, dynamic>{};
    });
    expect(await api.space(), isNull);
    expect(await api.pair(DateTime(2024, 2, 29)), isEmpty);
    await api.react(7, null);
    expect(calls, [
      'GET couple/space',
      'GET couple/pair',
      'PUT couple/memories/7/reaction'
    ]);
  });

  testWidgets('flipping reads the back and returns to the photograph',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 280,
                    child: CoupleFlip(
                        front: SizedBox(height: 260, child: Text('照片正面')),
                        back:
                            SizedBox(height: 260, child: Text('另一半的留言'))))))));
    expect(find.text('照片正面'), findsOneWidget);
    await tester.tap(find.text('翻到背面看留言'));
    await tester.pumpAndSettle();
    expect(find.text('另一半的留言'), findsOneWidget);
    await tester.tap(find.text('回到照片'));
    await tester.pumpAndSettle();
    expect(find.text('照片正面'), findsOneWidget);
  });

  testWidgets('scratch surprise has an accessible reveal and reset',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 280,
            child: CoupleScratch(
                child: SizedBox(
                    height: 260, child: ColoredBox(color: Colors.red))),
          ),
        ),
      ),
    ));
    await tester.drag(find.byType(CustomPaint).last, const Offset(100, 60));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('直接打开惊喜'));
    await tester.pump();
    expect(find.text('重新盖上'), findsOneWidget);
    await tester.tap(find.text('重新盖上'));
    await tester.pump();
    expect(find.text('直接打开惊喜'), findsOneWidget);
  });

  testWidgets('star memories remain tappable on a narrow screen',
      (tester) async {
    CoupleMemory? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 280,
                    child: CoupleSky(
                        memories: [memory(1, 1), memory(2, 2)],
                        onSelected: (m) => selected = m))))));
    await tester.tap(find.text('回忆2'));
    expect(selected?.id, 2);
    expect(tester.takeException(), isNull);
  });
}

Map<String, dynamic> testRow(int id, int author) => {
      'id': id,
      'author_id': author,
      'author_name': author == 1 ? '我' : '她',
      'memory_date': '2024-02-29',
      'published_date': '2024-02-29',
      'title': '一起散步回家',
      'content': '一起散步回家。',
      'mood': '开心',
      'photo_count': 1,
      'display_mode': 'grid',
    };
