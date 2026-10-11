import 'skill_agent_file.dart';
import 'skill_agent_file_picker_stub.dart'
    if (dart.library.io) 'skill_agent_file_picker_io.dart'
    if (dart.library.js_interop) 'skill_agent_file_picker_web.dart' as platform;

export 'skill_agent_file.dart';

Future<SkillAgentFile?> pickSkillAgentFile() => platform.pickSkillAgentFile();
Future<void> openSkillAgentUrl(String url) => platform.openSkillAgentUrl(url);
