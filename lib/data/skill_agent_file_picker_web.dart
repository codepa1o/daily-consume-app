import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'skill_agent_file.dart';

Future<SkillAgentFile?> pickSkillAgentFile() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.md,.markdown,.txt,.pdf';
  final selected = Completer<web.File?>();
  input.addEventListener('change', ((web.Event _) {
    final files = input.files;
    if (!selected.isCompleted) {
      selected.complete(files == null ? null : files.item(0));
    }
  }).toJS);
  input.addEventListener('cancel', ((web.Event _) {
    if (!selected.isCompleted) selected.complete(null);
  }).toJS);
  web.document.body?.append(input);
  input.click();
  final file = await selected.future.timeout(const Duration(minutes: 2), onTimeout: () => null);
  input.remove();
  if (file == null) return null;
  if (file.size > 10 * 1024 * 1024) {
    throw StateError('文件不能超过 10 MB。');
  }
  final buffer = await file.arrayBuffer().toDart;
  return SkillAgentFile(name: file.name, bytes: Uint8List.view(buffer.toDart));
}

Future<void> openSkillAgentUrl(String url) async {
  try {
    web.window.open(url, '_blank', 'noopener,noreferrer');
  } catch (_) {}
}
