import 'dart:convert';

import 'api_client.dart';
import 'skill_agent_file.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList()
    : <Map<String, dynamic>>[];

String _string(Map<String, dynamic> row, String key) =>
    row[key] as String? ?? '';

int _int(Map<String, dynamic> row, String key) =>
    (row[key] as num?)?.toInt() ?? 0;

DateTime _date(Map<String, dynamic> row, String key) =>
    DateTime.tryParse(_string(row, key))?.toLocal() ?? DateTime.now();

class ChatbotConversation {
  const ChatbotConversation({
    required this.id,
    required this.title,
    required this.messageCount,
    required this.lastQuestion,
    required this.updatedAt,
  });

  final int id;
  final String title, lastQuestion;
  final int messageCount;
  final DateTime updatedAt;

  factory ChatbotConversation.fromJson(Map<String, dynamic> row) =>
      ChatbotConversation(
        id: _int(row, 'id'),
        title: _string(row, 'title'),
        messageCount: _int(row, 'message_count'),
        lastQuestion: _string(row, 'last_question'),
        updatedAt: _date(row, 'updated_at'),
      );
}

class ChatbotMessage {
  const ChatbotMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.status,
    required this.error,
    required this.metadata,
  });

  final int id;
  final String role, content, status, error;
  final Map<String, dynamic> metadata;

  ChatbotMessage copyWith({
    int? id,
    String? content,
    String? status,
    String? error,
    Map<String, dynamic>? metadata,
  }) =>
      ChatbotMessage(
        id: id ?? this.id,
        role: role,
        content: content ?? this.content,
        status: status ?? this.status,
        error: error ?? this.error,
        metadata: metadata ?? this.metadata,
      );

  factory ChatbotMessage.fromJson(Map<String, dynamic> row) => ChatbotMessage(
        id: _int(row, 'id'),
        role: _string(row, 'role'),
        content: _string(row, 'content'),
        status: _string(row, 'status'),
        error: _string(row, 'error_message'),
        metadata: _map(row['metadata']),
      );
}

class ChatbotConversationDetail {
  const ChatbotConversationDetail({
    required this.conversation,
    required this.messages,
  });

  final Map<String, dynamic> conversation;
  final List<ChatbotMessage> messages;

  factory ChatbotConversationDetail.fromJson(Map<String, dynamic> row) =>
      ChatbotConversationDetail(
        conversation: _map(row['conversation']),
        messages:
            _maps(row['messages']).map(ChatbotMessage.fromJson).toList(),
      );
}

class ChatbotApi {
  ChatbotApi._();
  static final instance = ChatbotApi._();
  final _api = ApiClient.instance;

  Future<List<ChatbotConversation>> conversations() async =>
      _maps(await _api.request('GET', 'chatbot/conversations'))
          .map(ChatbotConversation.fromJson)
          .toList();

  Future<ChatbotConversation> createConversation() async =>
      ChatbotConversation.fromJson(_map(await _api.request(
        'POST',
        'chatbot/conversations',
        body: const {'title': '新对话'},
      )));

  Future<ChatbotConversationDetail> conversation(int id) async =>
      ChatbotConversationDetail.fromJson(
          _map(await _api.request('GET', 'chatbot/conversations/$id')));

  Future<void> renameConversation(int id, String title) async {
    await _api.request(
      'PATCH',
      'chatbot/conversations/$id',
      body: {'title': title},
    );
  }

  Future<void> deleteConversation(int id) async {
    await _api.request('DELETE', 'chatbot/conversations/$id');
  }

  Stream<Map<String, dynamic>> sendMessage(
    int conversationId,
    String question, {
    required bool useKnowledge,
    SkillAgentFile? attachment,
  }) =>
      _api.streamJsonEvents(
        'chatbot/conversations/$conversationId/messages/stream',
        {
          'question': question,
          'use_knowledge': useKnowledge,
          'attachments': [
            if (attachment != null)
              {
                'name': attachment.name,
                'content_base64': base64Encode(attachment.bytes),
              },
          ],
        },
      );
}
