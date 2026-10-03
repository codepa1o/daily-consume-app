import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'update_controller.dart';
export 'update_controller.dart'
    show AppRelease, UpdateController, UpdatePhase, updateManifestUrl;

Future<void> _showNotes(
    BuildContext context, String version, List<String> notes,
    {bool updated = false}) async {
  final route = DialogRoute<void>(
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
  await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
}

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

Future<void> checkForAppUpdates(BuildContext context) async {
  final host = context.findAncestorStateOfType<_UpdateHostState>();
  if (host == null) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('当前环境不支持检查更新')));
    return;
  }
  await host._manualCheck();
}

class UpdateScope extends InheritedNotifier<UpdateController> {
  const UpdateScope(
      {super.key, required UpdateController controller, required super.child})
      : super(notifier: controller);
  static UpdateController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.notifier;
}

class UpdateHost extends StatefulWidget {
  const UpdateHost(
      {super.key, required this.child, this.controller, this.autoCheck = true});
  final Widget child;
  final UpdateController? controller;
  final bool autoCheck;
  @override
  State<UpdateHost> createState() => _UpdateHostState();
}

class _UpdateHostState extends State<UpdateHost> with WidgetsBindingObserver {
  late final UpdateController _controller =
      widget.controller ?? UpdateController();
  DialogRoute<void>? _dialog;
  Future<void>? _notes;
  bool _automatic = false;
  bool _pendingDialog = false;
  bool _resumingInstall = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_changed);
    _controller.channel.setMethodCallHandler((call) async {
      if (call.method == 'installFailure' && mounted) {
        _controller.installationFailed();
        unawaited(_showUpdates());
      }
    });
    if (Platform.isAndroid || widget.controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (widget.autoCheck) {
          unawaited(_start());
        } else {
          unawaited(_controller.initialize().catchError((Object error) {
            debugPrint(
                'Update initialization unavailable: ${error.runtimeType}');
          }));
        }
      });
    }
  }

  void _changed() {
    if (mounted &&
        _automatic &&
        _controller.release != null &&
        _controller.phase != UpdatePhase.checking) {
      unawaited(_showUpdates());
    }
  }

  Future<void> _start() async {
    try {
      await _controller.initialize();
      if (!mounted) return;
      final notes = _controller.installedNotes!;
      final code = _controller.currentVersionCode;
      if (_controller.seenVersion < code &&
          notes['versionCode'] == code &&
          notes['versionName'] == _controller.currentVersion) {
        await _viewNotes(notes['versionName'] as String,
            List<String>.from(notes['releaseNotes'] as List),
            updated: code > 1);
        if (!mounted) return;
        await _controller.channel.invokeMethod('markSeen', code);
      }
      if (!mounted) return;
      if (_controller.previousInstallError) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('上次更新未完成，可以在“我的”中检查更新并重试。')));
      }
      _automatic = true;
      try {
        await _controller.check();
      } finally {
        _automatic = false;
      }
    } catch (error) {
      debugPrint('Update initialization unavailable: ${error.runtimeType}');
    }
  }

  Future<void> _viewNotes(String version, List<String> notes,
      {bool updated = false}) async {
    if (_dialog != null || _notes != null) return;
    _notes = _showNotes(context, version, notes, updated: updated);
    try {
      await _notes;
    } finally {
      _notes = null;
    }
  }

  Future<void> _manualCheck() async {
    if (_notes != null) await _notes;
    if (!mounted) return;
    final task = _controller.check();
    unawaited(_showUpdates());
    await task;
  }

  Future<void> _showUpdates() async {
    if (_notes != null) await _notes;
    if (!mounted || _dialog != null) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      _pendingDialog = true;
      return;
    }
    _pendingDialog = false;
    final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => UpdateDialog(
            controller: _controller,
            onClose: () => Navigator.of(context).pop()));
    _dialog = route;
    await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    if (identical(_dialog, route)) _dialog = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    if (_pendingDialog) unawaited(_showUpdates());
    if (_dialog != null && _controller.phase == UpdatePhase.permission)
      unawaited(_resumeInstallation());
  }

  Future<void> _resumeInstallation() async {
    if (_resumingInstall || _controller.busy) return;
    _resumingInstall = true;
    try {
      final allowed =
          await _controller.channel.invokeMethod<bool>('canInstall');
      if (allowed == true &&
          mounted &&
          _dialog != null &&
          !_controller.busy &&
          _controller.phase == UpdatePhase.permission)
        await _controller.install();
    } on PlatformException catch (_) {
      /* Keep the permission action available. */
    } finally {
      _resumingInstall = false;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.channel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      UpdateScope(controller: _controller, child: widget.child);
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog(
      {super.key, required this.controller, required this.onClose});
  final UpdateController controller;
  final VoidCallback onClose;
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _confirmCancel = false;
  bool _cancelling = false;
  Future<void> _cancel() async {
    setState(() => _cancelling = true);
    await widget.controller.cancel();
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final downloading =
            [UpdatePhase.connecting, UpdatePhase.downloading].contains(c.phase);
        final protected = downloading ||
            c.phase == UpdatePhase.verifying ||
            c.phase == UpdatePhase.installing ||
            c.busy;
        final title = switch (c.phase) {
          UpdatePhase.checking || UpdatePhase.idle => '检查更新',
          UpdatePhase.connecting || UpdatePhase.downloading => '正在下载更新',
          UpdatePhase.verifying => '正在校验安装包',
          UpdatePhase.latest => '已是最新版本',
          UpdatePhase.failed => c.failedPhase == UpdatePhase.checking
              ? '检查更新失败'
              : c.apk != null
                  ? '安装未完成'
                  : '下载失败',
          UpdatePhase.permission => '允许安装更新',
          UpdatePhase.installing => '正在准备安装',
          UpdatePhase.ready => '下载完成',
        };
        return PopScope(
            canPop: !protected && c.phase != UpdatePhase.checking,
            child: AlertDialog(
              title: Text(title, style: const TextStyle(fontSize: 23)),
              content: SizedBox(
                  width: 360,
                  child: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(
                            '当前版本：${c.currentVersion.isEmpty ? '读取中…' : c.currentVersion}',
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xff72756c))),
                        if (c.release != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text('目标版本：${c.release!.versionName}',
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600))),
                        const SizedBox(height: 18),
                        Text(c.failure.isNotEmpty ? c.failure : c.message,
                            style: TextStyle(
                                height: 1.5,
                                color: c.failure.isNotEmpty
                                    ? Theme.of(context).colorScheme.error
                                    : null)),
                        if (c.release != null) ...[
                          const SizedBox(height: 16),
                          Text(
                              '已下载 ${updateSizeLabel(c.receivedBytes)} / 共 ${updateSizeLabel(c.release!.size)}',
                              key: const ValueKey('update-byte-count'),
                              style: const TextStyle(fontSize: 14)),
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                              key: const ValueKey('update-progress'),
                              value: c.progress,
                              minHeight: 6,
                              borderRadius: BorderRadius.circular(8)),
                          const SizedBox(height: 8),
                          Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                  '${(c.receivedBytes / c.release!.size * 100).clamp(0, 100).floor()}%',
                                  key: const ValueKey('update-percentage'),
                                  style: const TextStyle(fontSize: 12))),
                          ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              childrenPadding: const EdgeInsets.only(bottom: 8),
                              title: const Text('更新内容',
                                  style: TextStyle(fontSize: 14)),
                              children: [
                                for (final note in c.release!.notes)
                                  Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text('• $note',
                                              style: const TextStyle(
                                                  fontSize: 13, height: 1.5)))),
                              ]),
                        ] else if (c.phase == UpdatePhase.checking) ...[
                          const SizedBox(height: 16),
                          const LinearProgressIndicator(),
                        ],
                        if (_confirmCancel && downloading)
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                  _cancelling ? '正在取消下载…' : '确认取消下载？下次重试将从头下载。',
                                  style: const TextStyle(fontSize: 13))),
                      ]))),
              actions: [
                if (downloading) ...[
                  if (_confirmCancel)
                    TextButton(
                        onPressed: _cancelling
                            ? null
                            : () => setState(() => _confirmCancel = false),
                        child: const Text('继续下载')),
                  TextButton(
                      onPressed: _cancelling
                          ? null
                          : () {
                              if (_confirmCancel) {
                                unawaited(_cancel());
                              } else {
                                setState(() => _confirmCancel = true);
                              }
                            },
                      child: Text(_confirmCancel ? '确认取消' : '取消下载')),
                ] else if (c.phase == UpdatePhase.checking)
                  TextButton(
                      onPressed: _cancelling ? null : _cancel,
                      child: const Text('关闭')),
                if (!protected) ...[
                  TextButton(
                      onPressed: widget.onClose,
                      child: Text(c.apk != null
                          ? '稍后安装'
                          : c.phase == UpdatePhase.latest
                              ? '确定'
                              : '关闭')),
                  if (c.phase == UpdatePhase.failed ||
                      c.phase == UpdatePhase.ready ||
                      c.phase == UpdatePhase.permission)
                    FilledButton(
                        onPressed: c.phase == UpdatePhase.permission
                            ? c.openInstallSettings
                            : c.apk != null
                                ? c.install
                                : c.failedPhase == UpdatePhase.checking
                                    ? c.check
                                    : c.retryDownload,
                        child: Text(c.phase == UpdatePhase.permission
                            ? '允许安装更新'
                            : c.apk != null
                                ? '安装更新'
                                : c.failedPhase == UpdatePhase.checking
                                    ? '重试检查'
                                    : '重新下载')),
                ],
              ],
            ));
      });
}
