import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:daily_consume/account_pages.dart';
import 'package:daily_consume/data/api_client.dart';
import 'package:daily_consume/update/app_updates.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const channel = MethodChannel('daily_consume/updates');
late int installedCode;
late String installedVersion;
late String nextVersion;

class TestHeaders extends Fake implements HttpHeaders {
  final Map<String, String> values = {};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = '$value';
  @override
  String? value(String name) => values[name];
}

class TestResponse extends Stream<List<int>> implements HttpClientResponse {
  TestResponse(this.body,
      {this.statusCode = 200,
      this.contentLength = -1,
      String? location,
      this.onAbort}) {
    if (location != null) headers.set(HttpHeaders.locationHeader, location);
  }
  final Stream<List<int>> body;
  final VoidCallback? onAbort;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final HttpHeaders headers = TestHeaders();
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      body.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestRequest extends Fake implements HttpClientRequest {
  TestRequest(this.uri, this.reply);
  final Uri uri;
  final Future<TestResponse> Function(Uri) reply;
  final Completer<HttpClientResponse> _done = Completer();
  TestResponse? response;
  @override
  bool followRedirects = true;
  @override
  final HttpHeaders headers = TestHeaders();
  @override
  Future<HttpClientResponse> close() {
    reply(uri).then((value) {
      if (_done.isCompleted) return;
      response = value;
      _done.complete(value);
    }, onError: (Object error, StackTrace stack) {
      if (!_done.isCompleted) _done.completeError(error, stack);
    });
    return _done.future;
  }

  void stop() {
    if (!_done.isCompleted)
      _done.completeError(const SocketException('cancelled'));
    response?.onAbort?.call();
  }
}

class TestClient extends Fake implements HttpClient {
  TestClient(this.reply);
  final Future<TestResponse> Function(Uri) reply;
  final List<TestRequest> requests = [];
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final request = TestRequest(uri, reply);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    for (final request in requests) {
      request.stop();
    }
  }
}

Map<String, dynamic> manifest(List<int> bytes,
    {int? code, String? hash, int? size}) {
  final targetCode = code ?? installedCode + 1;
  final version = targetCode == installedCode ? installedVersion : nextVersion;
  return {
    'versionCode': targetCode,
    'versionName': version,
    'packageName': 'com.example.daily_consume',
    'apkUrl':
        'https://github.com/codepa1o/daily-consume-app/releases/download/v$version%2B$targetCode/app-release.apk',
    'size': size ?? bytes.length,
    'sha256': hash ?? sha256.convert(bytes).toString(),
    'releaseNotes': ['更新过程改为居中弹窗，实时显示下载大小和进度。', '“我的”新增检查更新。'],
  };
}

TestResponse jsonResponse(Map<String, dynamic> data) =>
    TestResponse(Stream.value(utf8.encode(jsonEncode(data))));

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue,
      reason: 'Update did not reach the expected state');
}

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue,
      reason: 'Widget update did not reach the expected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;
  late List<MethodCall> nativeCalls;
  var installResult = 'started';
  var seen = 0;
  setUpAll(() async {
    final bundled =
        jsonDecode(await rootBundle.loadString('assets/release_notes.json'))
            as Map<String, dynamic>;
    installedCode = bundled['versionCode'] as int;
    installedVersion = bundled['versionName'] as String;
    final parts = installedVersion.split('.').map(int.parse).toList();
    nextVersion = '${parts[0]}.${parts[1]}.${parts[2] + 1}';
  });
  setUp(() async {
    cache = await Directory.systemTemp.createTemp('daily-consume-update-test-');
    nativeCalls = [];
    seen = installedCode;
    installResult = 'started';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return switch (call.method) {
        'state' => {
            'cacheDirectory': cache.path,
            'versionCode': installedCode,
            'versionName': installedVersion,
            'packageName': 'com.example.daily_consume',
            'seenVersion': seen,
            'installError': false
          },
        'install' => installResult,
        'canInstall' => true,
        _ => null,
      };
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final root = Directory.systemTemp.absolute.path;
    expect(cache.absolute.path.startsWith(root), isTrue);
    expect(cache.path.contains('daily-consume-update-test-'), isTrue);
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  test(
      'Real bytes refresh within a percent; duplicate checks share one task and cache is verified',
      () async {
    final bytes = List<int>.generate(1000000, (i) => i % 251);
    final body = StreamController<List<int>>();
    final urls = <Uri>[];
    final phases = <UpdatePhase>[];
    Future<TestResponse> reply(Uri uri) async {
      urls.add(uri);
      if (uri.path.endsWith('latest.json'))
        return jsonResponse(manifest(bytes));
      return TestResponse(body.stream, contentLength: bytes.length,
          onAbort: () {
        if (!body.isClosed) {
          body.addError(const SocketException('cancelled'));
          unawaited(body.close());
        }
      });
    }

    final c = UpdateController(createClient: () => TestClient(reply));
    c.addListener(() => phases.add(c.phase));
    final task = c.check();
    expect(identical(task, c.check()), isTrue);
    await until(() => c.phase == UpdatePhase.downloading);
    body.add(bytes.sublist(0, 5000));
    await until(() => c.receivedBytes == 5000);
    final events = phases.length;
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(phases.length, greaterThan(events));
    expect(c.progress, 0.005);
    expect(urls.length, 2);
    body.add(bytes.sublist(5000));
    await body.close();
    await task;
    expect(c.phase, UpdatePhase.ready);
    expect(phases, contains(UpdatePhase.verifying));
    expect(c.receivedBytes, bytes.length);
    expect(await c.apk!.readAsBytes(), bytes);
    expect(File('${cache.path}/update-${installedCode + 1}.part').existsSync(),
        isFalse);
    await c.check();
    expect(urls.length, 3,
        reason: 'A fresh manifest is checked, but cached APK is reused');
    expect(c.phase, UpdatePhase.ready);
    c.dispose();
  });

  test('Cancel aborts download, removes partial file and permits a clean retry',
      () async {
    final bytes = List<int>.filled(1000, 42);
    final body = StreamController<List<int>>();
    var attempt = 0;
    final c = UpdateController(
        createClient: () => TestClient((uri) async {
              if (uri.path.endsWith('latest.json'))
                return jsonResponse(manifest(bytes));
              attempt++;
              return attempt > 1
                  ? TestResponse(Stream.value(bytes),
                      contentLength: bytes.length)
                  : TestResponse(body.stream, contentLength: bytes.length,
                      onAbort: () {
                      if (!body.isClosed) {
                        body.addError(const SocketException('cancelled'));
                        unawaited(body.close());
                      }
                    });
            }));
    final task = c.check();
    await until(() => c.phase == UpdatePhase.downloading);
    body.add(bytes.sublist(0, 300));
    await until(() => c.receivedBytes == 300);
    await c.cancel();
    await task;
    expect(c.phase, UpdatePhase.idle);
    expect(c.busy, isFalse);
    expect(File('${cache.path}/update-${installedCode + 1}.part').existsSync(),
        isFalse);
    await c.check();
    expect(c.phase, UpdatePhase.ready);
    expect(c.receivedBytes, 1000);
    c.dispose();
  });

  test('Cancelled check ignores a late response and can check again', () async {
    final delayed = Completer<TestResponse>();
    var calls = 0;
    final c = UpdateController(
        createClient: () => TestClient((_) {
              calls++;
              return calls == 1
                  ? delayed.future
                  : Future.value(
                      jsonResponse(manifest([1], code: installedCode)));
            }));
    final task = c.check();
    await until(() => calls == 1);
    await c.cancel();
    await task;
    delayed.complete(jsonResponse(manifest([1], code: installedCode)));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.phase, UpdatePhase.idle);
    expect(c.release, isNull);
    await c.check();
    expect(c.phase, UpdatePhase.latest);
    c.dispose();
  });

  test('404, malformed data and network timeout are not reported as latest',
      () async {
    final replies = <Future<TestResponse> Function(Uri)>[
      (_) async => TestResponse(const Stream.empty(), statusCode: 404),
      (_) async => jsonResponse({
            ...manifest([1]),
            'apkUrl': 'https://untrusted.example/app.apk'
          }),
      (_) async => throw TimeoutException('test timeout'),
    ];
    for (final reply in replies) {
      final c = UpdateController(createClient: () => TestClient(reply));
      await c.check();
      expect(c.phase, UpdatePhase.failed);
      expect(c.failedPhase, UpdatePhase.checking);
      expect(c.apk, isNull);
      expect(c.failure, isNot(contains('最新版本')));
      c.dispose();
    }
  });

  test(
      'Wrong SHA and truncated bytes remain download errors and cannot install',
      () async {
    final bytes = [1, 2, 3, 4];
    for (final wrongHash in [true, false]) {
      final c = UpdateController(
          createClient: () => TestClient((uri) async => uri.path
                  .endsWith('latest.json')
              ? jsonResponse(manifest(bytes, hash: wrongHash ? 'a' * 64 : null))
              : TestResponse(
                  Stream.value(wrongHash ? bytes : bytes.sublist(0, 2)))));
      await c.check();
      expect(c.phase, UpdatePhase.failed);
      expect(c.failure, contains(wrongHash ? '校验未通过' : '下载未完成'));
      expect(c.apk, isNull);
      await c.install();
      expect(nativeCalls.where((call) => call.method == 'install'), isEmpty);
      expect(
          File('${cache.path}/update-${installedCode + 1}.part').existsSync(),
          isFalse);
      c.dispose();
    }
  });

  test(
      'Permission and native cancellation retain a validated APK for installation retry',
      () async {
    final bytes = [1, 2, 3];
    final c = UpdateController(
        createClient: () => TestClient((uri) async =>
            uri.path.endsWith('latest.json')
                ? jsonResponse(manifest(bytes))
                : TestResponse(Stream.value(bytes))));
    await c.check();
    installResult = 'permissionRequired';
    await c.install();
    expect(c.phase, UpdatePhase.permission);
    await c.openInstallSettings();
    expect(nativeCalls.last.method, 'openInstallSettings');
    installResult = 'started';
    await c.install();
    c.installationFailed();
    expect(c.phase, UpdatePhase.failed);
    expect(c.failedPhase, UpdatePhase.installing);
    expect(c.apk!.existsSync(), isTrue);
    await c.install();
    expect(c.phase, UpdatePhase.ready);
    expect(nativeCalls.where((call) => call.method == 'install').length, 3);
    c.dispose();
  });

  testWidgets(
      'My page manual check shows a centered latest dialog and installed version',
      (tester) async {
    final c = UpdateController(
        createClient: () => TestClient(
            (_) async => jsonResponse(manifest([1], code: installedCode))));
    ApiClient.instance.account = Account(
        id: 1, username: 'tester', nickname: '测试', createdAt: DateTime(2026));
    await tester.runAsync(c.initialize);
    await tester.pumpWidget(MaterialApp(
        home: UpdateHost(
            controller: c,
            autoCheck: false,
            child: const Scaffold(body: MyPage()))));
    await tester.pumpAndSettle();
    expect(find.text('当前版本 $installedVersion'), findsOneWidget);
    await tester.ensureVisible(find.text('检查更新'));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await pumpUntil(tester, () => c.phase == UpdatePhase.latest && !c.busy);
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(find.text('当前已是最新版本'), findsOneWidget);
    final screen = tester.getSize(find.byType(Scaffold));
    final center = tester.getCenter(find.byType(AlertDialog));
    expect((center.dy - screen.height / 2).abs(), lessThan(1));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    ApiClient.instance.account = null;
    c.dispose();
  });

  testWidgets(
      'Startup notes close before download dialog; automatic task is unique',
      (tester) async {
    seen = 0;
    final bytes = [1, 2, 3];
    var requests = 0;
    final c = UpdateController(
        createClient: () => TestClient((uri) async {
              requests++;
              return uri.path.endsWith('latest.json')
                  ? jsonResponse(manifest(bytes))
                  : TestResponse(Stream.value(bytes));
            }));
    await tester.runAsync(c.initialize);
    await tester.pumpWidget(MaterialApp(
        home: UpdateHost(
            controller: c, child: const Scaffold(body: Text('主页')))));
    await pumpUntil(tester,
        () => find.text('已更新至 $installedVersion').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('已更新至 $installedVersion'), findsOneWidget);
    expect(requests, 0);
    expect(find.byType(UpdateDialog), findsNothing);
    await tester.tap(find.text('知道了'));
    await pumpUntil(tester, () => c.phase == UpdatePhase.ready && !c.busy);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(requests, 2);
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.text('稍后安装'));
    await tester.pumpAndSettle();
    expect(c.apk!.existsSync(), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets(
      'Returning from permission settings continues the same validated installation',
      (tester) async {
    final bytes = [1, 2, 3];
    final c = UpdateController(
        createClient: () => TestClient((uri) async =>
            uri.path.endsWith('latest.json')
                ? jsonResponse(manifest(bytes))
                : TestResponse(Stream.value(bytes))));
    await tester.runAsync(c.initialize);
    await tester.pumpWidget(MaterialApp(
        home: UpdateHost(
            controller: c,
            autoCheck: false,
            child: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => checkForAppUpdates(context),
                        child: const Text('检查更新')))))));
    await tester.tap(find.text('检查更新'));
    await pumpUntil(tester, () => c.phase == UpdatePhase.ready && !c.busy);
    await tester.pumpAndSettle();
    installResult = 'permissionRequired';
    await tester.tap(find.text('安装更新'));
    await pumpUntil(tester, () => c.phase == UpdatePhase.permission && !c.busy);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '允许安装更新'));
    await pumpUntil(tester, () => !c.busy);
    installResult = 'started';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntil(tester, () => c.phase == UpdatePhase.ready && !c.busy);
    await tester.pumpAndSettle();
    expect(nativeCalls.where((call) => call.method == 'install').length, 2);
    expect(nativeCalls.where((call) => call.method == 'canInstall').length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets(
      'Download numbers, indeterminate verification and explicit cancel fit narrow screens',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = UpdateController();
    c.currentVersion = installedVersion;
    c.release = AppRelease.fromJson(manifest([1], size: 56000000));
    c.phase = UpdatePhase.downloading;
    c.receivedBytes = 18600000;
    var closed = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: UpdateDialog(controller: c, onClose: () => closed = true))));
    expect(find.text('已下载 18.6 MB / 共 56.0 MB'), findsOneWidget);
    expect(find.text('33%'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byKey(const ValueKey('update-progress')))
            .value,
        closeTo(0.332, 0.001));
    await tester.tap(find.text('取消下载'));
    await tester.pump();
    expect(find.text('确认取消'), findsOneWidget);
    expect(closed, isFalse);
    await tester.tap(find.text('确认取消'));
    await tester.pump();
    expect(closed, isTrue);
    c.phase = UpdatePhase.verifying;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: UpdateDialog(
                key: const ValueKey('verify'),
                controller: c,
                onClose: () {}))));
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byKey(const ValueKey('update-progress')))
            .value,
        isNull);
    expect(find.text('安装更新'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('Large text and long notes remain scrollable without overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = UpdateController();
    c.currentVersion = installedVersion;
    c.release = AppRelease.fromJson({
      ...manifest([1], size: 56000000),
      'releaseNotes':
          List.generate(20, (_) => '这是一条较长的更新内容，需要在小屏幕和大字体下正常显示与滚动。')
    });
    c.phase = UpdatePhase.downloading;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child:
                Scaffold(body: UpdateDialog(controller: c, onClose: () {})))));
    await tester.tap(find.text('更新内容'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('Export centered dialog preview', (tester) async {
    final path = Platform.environment['UPDATE_PREVIEW_DIR'];
    if (path == null) return;
    final font = Platform.environment['HEALTH_PREVIEW_FONT'];
    if (font != null) {
      await tester.runAsync(() async {
        await (FontLoader('UpdatePreview')
              ..addFont(Future.value(
                  ByteData.sublistView(await File(font).readAsBytes()))))
            .load();
        await (FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
            .load();
      });
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = UpdateController();
    c.currentVersion = installedVersion;
    c.phase = UpdatePhase.downloading;
    c.release = AppRelease.fromJson(manifest([1], size: 56000000));
    c.message = '正在下载更新';
    c.receivedBytes = 18600000;
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                useMaterial3: true,
                fontFamily: font == null ? null : 'UpdatePreview',
                scaffoldBackgroundColor: const Color(0xfff6f5ef),
                colorScheme:
                    ColorScheme.fromSeed(seedColor: const Color(0xff64765a))),
            home: Scaffold(
                body: Builder(
                    builder: (context) => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text('我的',
                                      style: TextStyle(fontSize: 32))),
                              ListTile(
                                  title: const Text('检查更新'),
                                  subtitle: Text('当前版本 $installedVersion')),
                              TextButton(
                                  onPressed: () => showDialog<void>(
                                      context: context,
                                      barrierDismissible: false,
                                      builder: (_) => UpdateDialog(
                                          controller: c, onClose: () {})),
                                  child: const Text('显示更新'))
                            ]))))));
    await tester.tap(find.text('显示更新'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(path).create(recursive: true);
      await File('$path/update-dialog.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
