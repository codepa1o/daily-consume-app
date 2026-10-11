import 'dart:typed_data';

class SkillAgentFile {
  const SkillAgentFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}
