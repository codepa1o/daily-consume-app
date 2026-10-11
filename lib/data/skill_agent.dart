import 'dart:convert';

import 'api_client.dart';
import 'skill_agent_file.dart';

const defaultSkillAgentSkillUrl =
    'https://github.com/alchaincyf/zhangxuefeng-skill/blob/main/SKILL.md';

Map<String, dynamic> _object(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> _objects(Object? value) => value is List
    ? value.whereType<Map>().map((row) => Map<String, dynamic>.from(row)).toList()
    : <Map<String, dynamic>>[];

String _string(Map<String, dynamic> row, String key) => row[key] as String? ?? '';
int _int(Map<String, dynamic> row, String key) => (row[key] as num?)?.toInt() ?? 0;
DateTime _date(Map<String, dynamic> row, String key) =>
    DateTime.tryParse(_string(row, key))?.toLocal() ?? DateTime.now();

class SkillAgentConversation {
  const SkillAgentConversation({
    required this.id,
    required this.title,
    required this.skillUrl,
    required this.model,
    required this.messageCount,
    required this.lastQuestion,
    required this.updatedAt,
  });

  final int id, messageCount;
  final String title, skillUrl, model, lastQuestion;
  final DateTime updatedAt;

  factory SkillAgentConversation.fromJson(Map<String, dynamic> row) =>
      SkillAgentConversation(
        id: _int(row, 'id'),
        title: _string(row, 'title'),
        skillUrl: _string(row, 'skill_url'),
        model: _string(row, 'model'),
        messageCount: _int(row, 'message_count'),
        lastQuestion: _string(row, 'last_question'),
        updatedAt: _date(row, 'updated_at'),
      );
}

class SkillAgentMessage {
  const SkillAgentMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.status,
    required this.latencyMs,
    required this.error,
  });

  final int id, latencyMs;
  final String role, content, status, error;

  factory SkillAgentMessage.fromJson(Map<String, dynamic> row) =>
      SkillAgentMessage(
        id: _int(row, 'id'),
        role: _string(row, 'role'),
        content: _string(row, 'content'),
        status: _string(row, 'status'),
        latencyMs: _int(row, 'latency_ms'),
        error: _string(row, 'error_message'),
      );
}

class SkillAgentConversationDetail {
  const SkillAgentConversationDetail({
    required this.conversation,
    required this.messages,
  });
  final Map<String, dynamic> conversation;
  final List<SkillAgentMessage> messages;

  factory SkillAgentConversationDetail.fromJson(Map<String, dynamic> row) =>
      SkillAgentConversationDetail(
        conversation: _object(row['conversation']),
        messages: _objects(row['messages'])
            .map(SkillAgentMessage.fromJson)
            .toList(),
      );
}

class SkillAgentDocument {
  const SkillAgentDocument({
    required this.id,
    required this.filename,
    required this.fileType,
    required this.status,
    required this.error,
    required this.chunkCount,
    required this.updatedAt,
  });
  final int id, chunkCount;
  final String filename, fileType, status, error;
  final DateTime updatedAt;

  factory SkillAgentDocument.fromJson(Map<String, dynamic> row) =>
      SkillAgentDocument(
        id: _int(row, 'id'),
        filename: _string(row, 'filename'),
        fileType: _string(row, 'file_type'),
        status: _string(row, 'status'),
        error: _string(row, 'error_message'),
        chunkCount: _int(row, 'chunk_count'),
        updatedAt: _date(row, 'updated_at'),
      );
}

class SkillAgentSuite {
  const SkillAgentSuite({
    required this.id,
    required this.name,
    required this.skillUrl,
    required this.description,
    required this.caseCount,
    required this.isTemplate,
    required this.recentRuns,
  });
  final int id, caseCount;
  final String name, skillUrl, description;
  final bool isTemplate;
  final List<Map<String, dynamic>> recentRuns;

  factory SkillAgentSuite.fromJson(Map<String, dynamic> row) =>
      SkillAgentSuite(
        id: _int(row, 'id'),
        name: _string(row, 'name'),
        skillUrl: _string(row, 'skill_url'),
        description: _string(row, 'description'),
        caseCount: _int(row, 'case_count'),
        isTemplate: row['is_template'] as bool? ?? false,
        recentRuns: _objects(row['recent_runs']),
      );
}

class SkillAgentRun {
  const SkillAgentRun({
    required this.id,
    required this.question,
    required this.answer,
    required this.skillUrl,
    required this.status,
    required this.error,
    required this.model,
    required this.latencyMs,
    required this.searchUsed,
    required this.ragUsed,
    required this.createdAt,
  });
  final int id, latencyMs;
  final String question, answer, skillUrl, status, error, model;
  final bool searchUsed, ragUsed;
  final DateTime createdAt;

  factory SkillAgentRun.fromJson(Map<String, dynamic> row) => SkillAgentRun(
        id: _int(row, 'id'),
        question: _string(row, 'question'),
        answer: _string(row, 'answer'),
        skillUrl: _string(row, 'skill_url'),
        status: _string(row, 'status'),
        error: _string(row, 'error_message'),
        model: _string(row, 'model'),
        latencyMs: _int(row, 'latency_ms'),
        searchUsed: row['search_used'] as bool? ?? false,
        ragUsed: row['rag_used'] as bool? ?? false,
        createdAt: _date(row, 'created_at'),
      );
}

class SkillAgentApi {
  SkillAgentApi._();
  static final instance = SkillAgentApi._();
  final _api = ApiClient.instance;

  Future<List<SkillAgentConversation>> conversations() async =>
      _objects(await _api.request('GET', 'skill-agent/conversations'))
          .map(SkillAgentConversation.fromJson)
          .toList();

  Future<SkillAgentConversation> createConversation(
          String skillUrl, String title) async =>
      SkillAgentConversation.fromJson(_object(await _api.request(
          'POST', 'skill-agent/conversations',
          body: {'skill_url': skillUrl, 'title': title})));

  Future<SkillAgentConversationDetail> conversation(int id) async =>
      SkillAgentConversationDetail.fromJson(_object(
          await _api.request('GET', 'skill-agent/conversations/$id')));

  Future<void> renameConversation(int id, String title) async {
    await _api.request('PATCH', 'skill-agent/conversations/$id',
        body: {'title': title});
  }

  Future<void> deleteConversation(int id) async {
    await _api.request('DELETE', 'skill-agent/conversations/$id');
  }

  Stream<Map<String, dynamic>> sendMessage(int id, String question) =>
      _api.streamJsonEvents('skill-agent/conversations/$id/messages/stream',
          {'question': question});

  Future<List<SkillAgentRun>> runs() async =>
      _objects(await _api.request('GET', 'skill-agent/runs'))
          .map(SkillAgentRun.fromJson)
          .toList();

  Future<SkillAgentRun> run(int id) async => SkillAgentRun.fromJson(_object(
      await _api.request('GET', 'skill-agent/runs/$id')));

  Stream<Map<String, dynamic>> startRun(String skillUrl, String question) =>
      _api.streamJsonEvents('skill-agent/runs/stream',
          {'skill_url': skillUrl, 'question': question});

  Future<Map<String, dynamic>> rerun(int id) async =>
      _object(await _api.request('POST', 'skill-agent/runs/$id/rerun'));

  Future<List<SkillAgentDocument>> documents() async =>
      _objects(await _api.request('GET', 'skill-agent/knowledge'))
          .map(SkillAgentDocument.fromJson)
          .toList();

  Future<int> upload(SkillAgentFile file) async {
    final result = _object(await _api.request(
      'POST',
      'skill-agent/knowledge/upload',
      body: {
        'filename': file.name,
        'content_base64': base64Encode(file.bytes),
      },
      timeout: const Duration(seconds: 90),
    ));
    return _int(_object(result['document']), 'id');
  }

  Future<Map<String, dynamic>> document(int id) async =>
      _object(await _api.request('GET', 'skill-agent/knowledge/$id'));

  Future<void> reindexDocument(int id) async {
    await _api.request('POST', 'skill-agent/knowledge/$id/reindex');
  }

  Future<void> deleteDocument(int id) async {
    await _api.request('DELETE', 'skill-agent/knowledge/$id');
  }

  Future<List<SkillAgentSuite>> suites() async =>
      _objects(await _api.request('GET', 'skill-agent/evals/suites'))
          .map(SkillAgentSuite.fromJson)
          .toList();

  Future<Map<String, dynamic>> createSuite(
          String name, String skillUrl, String description) async =>
      _object(await _api.request('POST', 'skill-agent/evals/suites', body: {
        'name': name,
        'skill_url': skillUrl,
        'description': description,
      }));

  Future<Map<String, dynamic>> suite(int id) async =>
      _object(await _api.request('GET', 'skill-agent/evals/suites/$id'));

  Future<void> createCase(int suiteId, Map<String, String> data) async {
    await _api.request('POST', 'skill-agent/evals/suites/$suiteId/cases',
        body: data);
  }

  Future<Map<String, dynamic>> runSuite(int id) async =>
      _object(await _api.request('POST', 'skill-agent/evals/suites/$id/run'));

  Future<Map<String, dynamic>> evalRun(int id) async =>
      _object(await _api.request('GET', 'skill-agent/evals/runs/$id'));

  Future<Map<String, dynamic>> diagnostics() async =>
      _object(await _api.request('GET', 'skill-agent/diagnostics'));
}
