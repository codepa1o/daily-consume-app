import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const updateManifestUrl = String.fromEnvironment(
  'UPDATE_MANIFEST_URL',
  defaultValue:
      'https://github.com/codepa1o/daily-consume-app/releases/latest/download/latest.json',
);
const _channel = MethodChannel('daily_consume/updates');

bool _trustedDownloadUri(Uri uri) {
  final origin = Uri.parse(updateManifestUrl);
  const githubAssetHosts = {
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
    'github-releases.githubusercontent.com',
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

Future<void> _showNotes(
        BuildContext context, String version, List<String> notes,
        {bool updated = false}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(updated ? '已更新至 $version' : '版本 $version'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: notes
                .map((note) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text('• $note'),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('知道了'))
        ],
      ),
    );

Future<void> showInstalledUpdateLog(BuildContext context) async {
  final notes =
      jsonDecode(await rootBundle.loadString('assets/release_notes.json'))
          as Map<String, dynamic>;
  if (!context.mounted) return;
  final host = context.findAncestorStateOfType<_UpdateHostState>();
  final version = notes['versionName'] as String;
  final items = List<String>.from(notes['releaseNotes'] as List);
  if (host != null) {
    await host._viewNotes(version, items);
  } else {
    await _showNotes(context, version, items);
  }
}

/// Lives above the tabs, so navigating or resuming never starts a second check.
class UpdateHost extends StatefulWidget {
  const UpdateHost({super.key, required this.child});
  final Widget child;

  @override
  State<UpdateHost> createState() => _UpdateHostState();
}

class _UpdateHostState extends State<UpdateHost> with WidgetsBindingObserver {
  AppRelease? release;
  Map<String, dynamic>? installedNotes;
  HttpClient? client;
  File? apk;
  String cacheDirectory = '';
  String status = '';
  String failure = '';
  double? progress;
  bool busy = false;
  bool needsPermission = false;
  bool hidden = false;
  bool disposed = false;
  bool notesOpen = false;
  bool waitingToInstall = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'installFailure' && mounted) {
          setState(() {
            failure = '安装未完成，请重试。';
            busy = false;
            hidden = false;
          });
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  Future<void> _start() async {
    try {
      final state = Map<String, dynamic>.from(
          await _channel.invokeMethod('state') as Map);
      cacheDirectory = state['cacheDirectory'] as String;
      final version = state['versionCode'] as int;
      final localNotes =
          jsonDecode(await rootBundle.loadString('assets/release_notes.json'))
              as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => installedNotes = localNotes);
      await _cleanOldDownloads(version);
      if (!mounted) return;
      final checking = _check(version, state['packageName'] as String)
          .catchError((Object error) {
        debugPrint('Update check unavailable: ${error.runtimeType}');
      });
      final lastSeen = state['seenVersion'] as int;
      // Older app versions did not save seenVersion. The first update still shows its log.
      if (lastSeen < version &&
          installedNotes!['versionCode'] == version &&
          mounted) {
        await _viewNotes(installedNotes!['versionName'] as String,
            List<String>.from(installedNotes!['releaseNotes'] as List),
            updated: version > 1);
        await _channel.invokeMethod('markSeen', version);
      }
      if (state['installError'] == true && mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('上次更新未完成，已保留原有数据。')));
      }
      await checking;
    } catch (error) {
      // No network / missing manifest never blocks the local diary.
      debugPrint('Update check unavailable: ${error.runtimeType}');
    }
  }

  Future<void> _viewNotes(String version, List<String> notes,
      {bool updated = false}) async {
    notesOpen = true;
    try {
      await _showNotes(context, version, notes, updated: updated);
    } finally {
      notesOpen = false;
      if (mounted && waitingToInstall) await _install();
    }
  }

  Future<void> _cleanOldDownloads(int currentVersion) async {
    try {
      await for (final file in Directory(cacheDirectory).list()) {
        final match = RegExp(r'^update-(\d+)\.(apk|part)$')
            .firstMatch(file.uri.pathSegments.last);
        if (file is File &&
            match != null &&
            (match[2] == 'part' || int.parse(match[1]!) <= currentVersion)) {
          await file.delete();
        }
      }
    } on FileSystemException catch (_) {
      /* Cache cleanup can wait until next launch. */
    }
  }

  Future<void> _check(int currentVersion, String package) async {
    final uri = Uri.parse(updateManifestUrl);
    if (uri.scheme != 'https') throw const FormatException('更新地址必须为 HTTPS');
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    client = http;
    try {
      final response = await _openDownload(
          http,
          uri.replace(queryParameters: {
            ...uri.queryParameters,
            't': DateTime.now().millisecondsSinceEpoch.toString(),
          }));
      if (response.statusCode == 404) return;
      if (response.statusCode != 200) throw HttpException('更新信息不可用');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) throw const FormatException('更新信息过大');
      }
      final next = AppRelease.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
      if (next.packageName != package) throw const FormatException('应用不匹配');
      if (next.versionCode <= currentVersion || !mounted) return;
      setState(() {
        release = next;
        hidden = false;
      });
    } finally {
      http.close(force: true);
      if (identical(client, http)) client = null;
    }
    if (release != null && mounted) await _download();
  }

  Future<void> _download() async {
    final next = release;
    if (next == null || busy) return;
    setState(() {
      busy = true;
      failure = '';
      status = '正在下载 ${next.versionName}';
      progress = 0;
    });
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    client = http;
    final partial = File('$cacheDirectory/update-${next.versionCode}.part');
    final target = File('$cacheDirectory/update-${next.versionCode}.apk');
    IOSink? sink;
    try {
      if (await target.exists()) {
        if (await target.length() == next.size &&
            (await sha256.bind(target.openRead()).first).toString() ==
                next.hash) {
          apk = target;
          if (mounted) setState(() => busy = false);
          if (mounted) await _install();
          return;
        }
        await target.delete();
      }
      final response = await _openDownload(http, next.apkUrl);
      if (response.statusCode != 200 ||
          (response.contentLength >= 0 &&
              response.contentLength != next.size)) {
        throw const FormatException('下载地址或文件大小不正确');
      }
      sink = partial.openWrite();
      var received = 0;
      var lastPercentage = -1;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (disposed) throw const HttpException('下载已取消');
        received += chunk.length;
        if (received > next.size) throw const FormatException('下载文件过大');
        sink.add(chunk);
        // Apply backpressure; the APK must not accumulate in memory.
        await sink.flush();
        final percentage = received * 100 ~/ next.size;
        if (percentage != lastPercentage && mounted) {
          lastPercentage = percentage;
          setState(() => progress = received / next.size);
        }
      }
      await sink.close();
      sink = null;
      if (received != next.size) throw const FormatException('下载未完成');
      if (mounted)
        setState(() {
          status = '正在校验安装包';
          progress = null;
        });
      final digest = await sha256.bind(partial.openRead()).first;
      if (digest.toString() != next.hash)
        throw const FormatException('安装包校验失败');
      if (await target.exists()) await target.delete();
      apk = await partial.rename(target.path);
      if (mounted) setState(() => busy = false);
      if (mounted) await _install();
    } catch (error) {
      if (mounted)
        setState(() {
          busy = false;
          progress = null;
          failure = '更新下载失败，请检查网络或稍后重试。';
        });
    } finally {
      try {
        await sink?.close();
      } on FileSystemException catch (_) {
        /* Preserve the download failure message. */
      }
      http.close(force: true);
      if (identical(client, http)) client = null;
      try {
        if (await partial.exists()) await partial.delete();
      } on FileSystemException catch (_) {
        /* Startup cleanup retries this temporary file. */
      }
    }
  }

  Future<void> _install() async {
    if (apk == null || busy || !mounted) return;
    if (notesOpen ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      setState(() {
        waitingToInstall = true;
        status = '下载完成，回到应用并关闭日志后继续安装';
      });
      return;
    }
    waitingToInstall = false;
    setState(() {
      busy = true;
      failure = '';
      status = '正在准备安装';
      progress = null;
    });
    try {
      final result = await _channel.invokeMethod<String>('install', {
        'path': apk!.path,
        'versionCode': release!.versionCode,
      });
      if (!mounted) return;
      setState(() {
        needsPermission = result == 'permissionRequired';
        busy = false;
        status = needsPermission ? '下载完成，请允许安装更新' : '请完成系统安装，取消后可重试';
      });
    } on PlatformException catch (error) {
      if (mounted)
        setState(() {
          busy = false;
          failure = error.message ?? '安装失败，请重试';
        });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (needsPermission)
        _resumeInstallation();
      else if (waitingToInstall) _install();
    }
  }

  Future<void> _resumeInstallation() async {
    if (busy) return;
    try {
      if (await _channel.invokeMethod<bool>('canInstall') == true && mounted) {
        setState(() => needsPermission = false);
        await _install();
      }
    } on PlatformException catch (_) {
      /* The install button remains available. */
    }
  }

  @override
  void dispose() {
    disposed = true;
    client?.close(force: true);
    _channel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Expanded(child: widget.child),
        if (release != null && !hidden)
          Material(
              color: const Color(0xffe9eee4),
              child: SafeArea(
                  top: false,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (release != null && !hidden) ...[
                        Row(children: [
                          Expanded(
                              child:
                                  Text(failure.isNotEmpty ? failure : status)),
                          TextButton(
                              onPressed: () => _viewNotes(
                                  release!.versionName, release!.notes),
                              child: const Text('更新内容')),
                          if (!busy)
                            IconButton(
                                tooltip: '稍后更新',
                                onPressed: () => setState(() => hidden = true),
                                icon: const Icon(Icons.close, size: 18)),
                        ]),
                        if (busy) LinearProgressIndicator(value: progress),
                        if (!busy)
                          Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton(
                                onPressed: () async {
                                  if (needsPermission) {
                                    try {
                                      await _channel
                                          .invokeMethod('openInstallSettings');
                                    } on PlatformException catch (_) {
                                      if (mounted)
                                        setState(
                                            () => failure = '请在系统设置中允许本应用安装更新');
                                    }
                                  } else if (apk != null) {
                                    await _install();
                                  } else {
                                    await _download();
                                  }
                                },
                                child: Text(needsPermission
                                    ? '允许安装更新'
                                    : apk != null
                                        ? '安装更新'
                                        : '重新下载'),
                              )),
                      ],
                    ]),
                  ))),
      ]);
}
