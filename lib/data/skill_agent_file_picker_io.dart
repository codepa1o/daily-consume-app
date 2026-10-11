import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'skill_agent_file.dart';

const _channel = MethodChannel('daily_consume/skill_agent_files');

Future<SkillAgentFile?> pickSkillAgentFile() async {
  final result = await _channel.invokeMapMethod<String, dynamic>('pickDocument');
  if (result == null) return null;
  final name = result['name'];
  final bytes = result['bytes'];
  if (name is! String || bytes is! List<int>) return null;
  return SkillAgentFile(name: name, bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
}

Future<void> openSkillAgentUrl(String url) async {
  try {
    await _channel.invokeMethod<void>('openUrl', url);
  } catch (_) {}
}
