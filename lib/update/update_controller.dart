import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const updateManifestUrl = String.fromEnvironment('UPDATE_MANIFEST_URL',
    defaultValue:
        'https://github.com/codepa1o/daily-consume-app/releases/latest/download/latest.json');
const updateChannel = MethodChannel('daily_consume/updates');

bool _trustedDownloadUri(Uri uri) {
  final origin = Uri.parse(updateManifestUrl);
  const githubAssetHosts = {
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
    'github-releases.githubusercontent.com'
  };
  return uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      (uri.host == origin.host ||
          (origin.host == 'github.com' && githubAssetHosts.contains(uri.host)));
}

Future<HttpClientResponse> _openDownload(HttpClient http, Uri uri) async {
  for (var redirects = 0; redirects <= 5; redirects++) {
    if (!_trustedDownloadUri(uri)) throw const FormatException('下载域名不受信任');
    final request = await http.getUrl(uri).timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (![301, 302, 303, 307, 308].contains(response.statusCode))
      return response;
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || redirects == 5)
      throw const FormatException('下载跳转不正确');
    await response.drain<void>().timeout(const Duration(seconds: 10));
    uri = uri.resolve(location);
  }
  throw const FormatException('下载跳转过多');
}

class AppRelease {
  AppRelease.fromJson(Map<String, dynamic> json)
      : versionCode = json['versionCode'] as int,
        versionName = json['versionName'] as String,
        packageName = json['packageName'] as String,
        apkUrl = Uri.parse(json['apkUrl'] as String),
        size = json['size'] as int,
        hash = json['sha256'] as String,
        notes = List<String>.from(json['releaseNotes'] as List) {
    final origin = Uri.parse(updateManifestUrl);
    if (origin.scheme != 'https' ||
        apkUrl.scheme != 'https' ||
        apkUrl.host != origin.host ||
        apkUrl.userInfo.isNotEmpty ||
        apkUrl.port != origin.port ||
        (origin.host == 'github.com' &&
            !apkUrl.path.startsWith(
                '/${origin.pathSegments.take(2).join('/')}/releases/download/')) ||
        versionCode <= 0 ||
        versionName.isEmpty ||
        versionName.length > 64 ||
        size <= 0 ||
        size > 512 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        notes.isEmpty ||
        notes.any((note) => note.trim().isEmpty) ||
        notes.join().length > 32000) {
      throw const FormatException('更新信息格式不正确');
    }
  }
  final int versionCode;
  final String versionName;
  final String packageName;
  final Uri apkUrl;
  final int size;
  final String hash;
  final List<String> notes;
}

enum UpdatePhase {
  idle,
  checking,
  connecting,
  downloading,
  verifying,
  ready,
  permission,
  installing,
  latest,
  failed
}

String updateSizeLabel(int bytes) =>
    '${(bytes / 1000000).toStringAsFixed(1)} MB';

/// One task owns the network request, temporary file and native installer.
class UpdateController extends ChangeNotifier {
  UpdateController(
      {this.channel = updateChannel, HttpClient Function()? createClient})
      : _createClient = createClient ?? (() => HttpClient());
  final MethodChannel channel;
  final HttpClient Function() _createClient;
  UpdatePhase phase = UpdatePhase.idle;
  UpdatePhase? failedPhase;
  AppRelease? release;
  File? apk;
  Map<String, dynamic>? installedNotes;
  String currentVersion = '';
  String message = '';
  String failure = '';
  int receivedBytes = 0;
  int seenVersion = 0;
  bool previousInstallError = false;
  String _package = '';
  String _cache = '';
  int _installedCode = 0;
  int _generation = 0;
  bool _disposed = false;
  HttpClient? _client;
  Future<void>? _initialization;
  Future<void>? _task;

  bool get busy => _task != null;
  int get currentVersionCode => _installedCode;
  bool get canCancel => [
        UpdatePhase.checking,
        UpdatePhase.connecting,
        UpdatePhase.downloading
      ].contains(phase);
  double? get progress => phase == UpdatePhase.verifying ||
          phase == UpdatePhase.checking ||
          phase == UpdatePhase.installing
      ? null
      : release == null
          ? null
          : (receivedBytes / release!.size).clamp(0, 1);
  bool _current(int id) => !_disposed && id == _generation;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _phase(UpdatePhase value, String text) {
    phase = value;
    message = text;
    failure = '';
    _emit();
  }

  Future<void> initialize() =>
      _initialization ??= _initialize().catchError((Object error) {
        _initialization = null;
        throw error;
      });

  Future<void> _initialize() async {
    final state =
        Map<String, dynamic>.from(await channel.invokeMethod('state') as Map);
    final notes =
        jsonDecode(await rootBundle.loadString('assets/release_notes.json'))
            as Map<String, dynamic>;
    if (_disposed) return;
    _cache = state['cacheDirectory'] as String;
    _installedCode = state['versionCode'] as int;
    _package = state['packageName'] as String;
    currentVersion = state['versionName'] as String;
    seenVersion = state['seenVersion'] as int;
    previousInstallError = state['installError'] == true;
    installedNotes = notes;
    try {
      await for (final file in Directory(_cache).list()) {
        final match = RegExp(r'^update-(\d+)\.(apk|part)$')
            .firstMatch(file.uri.pathSegments.last);
        if (file is File &&
            match != null &&
            (match[2] == 'part' || int.parse(match[1]!) <= _installedCode)) {
          await file.delete();
        }
      }
    } on FileSystemException catch (_) {
      /* Cleanup can retry at the next launch. */
    }
    _emit();
  }

  Future<void> _run(Future<void> Function(int) action) {
    if (_task != null) return _task!;
    final done = Completer<void>();
    _task = done.future;
    final id = ++_generation;
    Future<void>(() async {
      try {
        await action(id);
      } catch (error) {
        if (_current(id)) _fail(error);
      } finally {
        _task = null;
        _emit();
        done.complete();
      }
    });
    return done.future;
  }

  void _fail(Object error) {
    failedPhase = phase;
    final checking = phase == UpdatePhase.checking;
    if (error is TimeoutException || error is SocketException) {
      failure = '${checking ? '检查更新' : '下载连接'}超时或不可用，请切换网络或检查代理设置后重试。';
    } else if (error is HandshakeException) {
      failure = '更新服务器安全连接失败，请检查设备时间或切换网络后重试。';
    } else if (error is FileSystemException) {
      failure = '无法读取或保存安装包，请检查剩余存储空间后重试。';
    } else if (error is FormatException) {
      failure = checking ? '更新信息格式不正确，请稍后重试。' : error.message;
    } else if (error is HttpException) {
      failure = error.message;
    } else if (error is PlatformException) {
      failure = error.message ?? '系统更新组件不可用，请重试。';
    } else if (error is IOException) {
      failure = '下载连接已中断，请切换网络或检查代理设置后重新下载。';
    } else {
      failure = checking ? '检查更新失败，请稍后重试。' : '更新未完成，请重试。';
    }
    debugPrint('Update ${failedPhase!.name} failed: ${error.runtimeType}');
    phase = UpdatePhase.failed;
    _emit();
  }

  Future<void> check() => _run((id) async {
        release = null;
        apk = null;
        receivedBytes = 0;
        failedPhase = null;
        _phase(UpdatePhase.checking, '正在检查更新…');
        await initialize();
        if (!_current(id)) return;
        final http = _createClient()
          ..connectionTimeout = const Duration(seconds: 8);
        _client = http;
        AppRelease next;
        try {
          final uri = Uri.parse(updateManifestUrl);
          final response = await _openDownload(
              http,
              uri.replace(queryParameters: {
                ...uri.queryParameters,
                't': DateTime.now().millisecondsSinceEpoch.toString()
              }));
          if (response.statusCode != 200)
            throw HttpException('更新服务器返回 HTTP ${response.statusCode}，请稍后重试。');
          final bytes = <int>[];
          await for (final chunk
              in response.timeout(const Duration(seconds: 10))) {
            if (!_current(id)) return;
            bytes.addAll(chunk);
            if (bytes.length > 65536) throw const FormatException('更新信息过大');
          }
          next = AppRelease.fromJson(
              jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
          if (next.packageName != _package)
            throw const FormatException('应用不匹配');
        } finally {
          http.close(force: true);
          if (identical(_client, http)) _client = null;
        }
        if (!_current(id)) return;
        if (next.versionCode <= _installedCode) {
          _phase(UpdatePhase.latest, '当前已是最新版本');
          return;
        }
        release = next;
        await _download(id);
      });

  Future<void> retryDownload() => _run((id) => _download(id));

  Future<void> _download(int id) async {
    final next = release;
    if (next == null) return;
    apk = null;
    receivedBytes = 0;
    failedPhase = null;
    _phase(UpdatePhase.connecting, '正在连接下载服务器…');
    final partial = File('$_cache/update-${next.versionCode}.part');
    final target = File('$_cache/update-${next.versionCode}.apk');
    final http = _createClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _client = http;
    IOSink? sink;
    Timer? refresh;
    try {
      if (await target.exists()) {
        _phase(UpdatePhase.verifying, '正在校验已下载的安装包…');
        final valid = await target.length() == next.size &&
            (await sha256.bind(target.openRead()).first).toString() ==
                next.hash;
        if (!_current(id)) return;
        if (valid) {
          apk = target;
          receivedBytes = next.size;
          _phase(UpdatePhase.ready, '下载完成，安装包已校验');
          return;
        }
        await target.delete();
        _phase(UpdatePhase.connecting, '正在连接下载服务器…');
      }
      final response = await _openDownload(http, next.apkUrl);
      if (!_current(id)) return;
      if (response.statusCode != 200)
        throw HttpException('下载服务器返回 HTTP ${response.statusCode}，请重新下载。');
      if (response.contentLength >= 0 && response.contentLength != next.size)
        throw const FormatException('安装包大小不匹配，请重新下载。');
      sink = partial.openWrite();
      _phase(UpdatePhase.downloading, '正在下载更新');
      var lastShown = receivedBytes;
      refresh = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (_current(id) &&
            phase == UpdatePhase.downloading &&
            lastShown != receivedBytes) {
          lastShown = receivedBytes;
          _emit();
        }
      });
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (!_current(id)) return;
        receivedBytes += chunk.length;
        if (receivedBytes > next.size)
          throw const FormatException('安装包大小不匹配，请重新下载。');
        sink.add(chunk);
        await sink.flush();
      }
      await sink.close();
      sink = null;
      if (!_current(id)) return;
      if (receivedBytes != next.size)
        throw const FormatException('下载未完成，请重新下载。');
      _phase(UpdatePhase.verifying, '正在校验安装包…');
      final digest = await sha256.bind(partial.openRead()).first;
      if (!_current(id)) return;
      if (digest.toString() != next.hash)
        throw const FormatException('安装包校验未通过，请重新下载。');
      if (await target.exists()) await target.delete();
      apk = await partial.rename(target.path);
      _phase(UpdatePhase.ready, '下载完成，安装包已校验');
    } finally {
      refresh?.cancel();
      try {
        await sink?.close();
      } on FileSystemException catch (_) {/* Preserve the original error. */}
      http.close(force: true);
      if (identical(_client, http)) _client = null;
      try {
        if (await partial.exists()) await partial.delete();
      } on FileSystemException catch (_) {/* Startup retries cleanup. */}
    }
  }

  Future<void> cancel() async {
    if (!canCancel) return;
    ++_generation;
    _client?.close(force: true);
    final task = _task;
    if (task != null) await task;
    if (!_disposed) _phase(UpdatePhase.idle, '');
  }

  Future<void> install() => _run((id) async {
        if (apk == null || release == null) return;
        _phase(UpdatePhase.installing, '正在准备系统安装…');
        final result = await channel.invokeMethod<String>('install',
            {'path': apk!.path, 'versionCode': release!.versionCode});
        if (!_current(id) || phase == UpdatePhase.failed) return;
        _phase(
            result == 'permissionRequired'
                ? UpdatePhase.permission
                : UpdatePhase.ready,
            result == 'permissionRequired'
                ? '请允许本应用安装更新'
                : '请在系统窗口确认安装，取消后可重试');
      });

  Future<void> openInstallSettings() => _run((id) async {
        _phase(UpdatePhase.permission, '正在打开安装权限设置…');
        await channel.invokeMethod('openInstallSettings');
        if (_current(id)) _phase(UpdatePhase.permission, '请在系统设置中允许安装，返回应用后继续');
      });

  void installationFailed() {
    if (_disposed || apk == null) return;
    failedPhase = UpdatePhase.installing;
    phase = UpdatePhase.failed;
    failure = '系统安装未完成，可重试安装或稍后安装。';
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _client?.close(force: true);
    super.dispose();
  }
}
