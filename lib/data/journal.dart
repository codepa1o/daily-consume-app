import 'dart:math';

import 'api_client.dart';
import 'app_database.dart' show dateKey;

DateTime journalDate(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);
DateTime journalToday() =>
    journalDate(DateTime.now().toUtc().add(const Duration(hours: 8)));
DateTime journalLastDate() => DateTime.utc(journalToday().year + 10, 12, 31);
String journalMonthKey(DateTime value) => dateKey(value).substring(0, 7);

List<DateTime?> journalMonthCells(DateTime month) {
  final first = DateTime.utc(month.year, month.month, 1);
  final count = DateTime.utc(month.year, month.month + 1, 0).day;
  final cells = <DateTime?>[
    ...List<DateTime?>.filled(first.weekday - 1, null),
    for (var day = 1; day <= count; day++)
      DateTime.utc(month.year, month.month, day),
  ];
  while (cells.length % 7 != 0) {
    cells.add(null);
  }
  return cells;
}

String journalRequestId() {
  final random = Random.secure();
  return List.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String journalError(Object error) => error is ApiException
    ? error.statusCode == 404 && error.message == 'Not Found'
        ? '生活日历服务暂不可用，请更新服务器后重试'
        : error.message
    : '加载失败，请重试';

class JournalEntry {
  const JournalEntry(
      {required this.id,
      required this.date,
      required this.kind,
      required this.title,
      required this.content,
      required this.isTodo,
      required this.completed,
      required this.version});
  final int id;
  final DateTime date;
  final String kind, title, content;
  final bool isTodo, completed;
  final int version;

  factory JournalEntry.fromJson(Map<String, dynamic> json) => JournalEntry(
      id: json['id'] as int,
      date: journalDate(DateTime.parse(json['entry_date'] as String)),
      kind: json['kind'] as String,
      title: json['title'] as String,
      content: json['content'] as String,
      isTodo: json['is_todo'] as bool,
      completed: json['completed'] as bool,
      version: json['version'] as int);

  String get label => isTodo
      ? (completed ? '已完成' : '待办')
      : kind == 'diary'
          ? '日记'
          : '备忘';
  String get heading => title.isNotEmpty ? title : content.split('\n').first;
  bool get overdue => isTodo && !completed && date.isBefore(journalToday());
  Map<String, dynamic> toInput() => {
        'entry_date': dateKey(date),
        'kind': kind,
        'title': title,
        'content': content,
        'is_todo': isTodo,
        'completed': completed,
      };
  bool matches(Map<String, dynamic> input) =>
      toInput().entries.every((item) => input[item.key] == item.value);
}

class JournalDaySummary {
  const JournalDaySummary(
      {required this.diaries,
      required this.memos,
      required this.pending,
      required this.completed});
  final int diaries, memos, pending, completed;
  factory JournalDaySummary.fromJson(Map<String, dynamic> json) =>
      JournalDaySummary(
          diaries: json['diaries'] as int,
          memos: json['memos'] as int,
          pending: json['pending'] as int,
          completed: json['completed'] as int);
}

class JournalPage {
  const JournalPage(
      {required this.items, required this.total, required this.hasMore});
  final List<JournalEntry> items;
  final int total;
  final bool hasMore;
  factory JournalPage.fromJson(Map<String, dynamic> json) => JournalPage(
      items: (json['items'] as List)
          .map((row) =>
              JournalEntry.fromJson(Map<String, dynamic>.from(row as Map)))
          .toList(),
      total: json['total'] as int,
      hasMore: json['has_more'] as bool);
}

typedef JournalRequest = Future<dynamic> Function(String method, String path,
    {Object? body, Map<String, String>? query});

class JournalApi {
  JournalApi({JournalRequest? request})
      : _request = request ?? ApiClient.instance.request;
  final JournalRequest _request;
  static final instance = JournalApi();

  Future<Map<DateTime, JournalDaySummary>> calendar(DateTime month) async {
    final result = await _request('GET', 'journal/calendar',
        query: {'month': journalMonthKey(month)});
    return {
      for (final row in result['days'] as List)
        journalDate(DateTime.parse(row['entry_date'] as String)):
            JournalDaySummary.fromJson(Map<String, dynamic>.from(row as Map))
    };
  }

  Future<JournalPage> entries(
          {DateTime? date,
          String? kind,
          String q = '',
          int offset = 0}) async =>
      JournalPage.fromJson(Map<String, dynamic>.from(
          await _request('GET', 'journal/entries', query: {
        if (date != null) 'date': dateKey(date),
        if (kind != null) 'kind': kind,
        'q': q,
        'offset': '$offset',
        'limit': '50',
      }) as Map));

  Future<JournalEntry> detail(int id) async =>
      JournalEntry.fromJson(Map<String, dynamic>.from(
          await _request('GET', 'journal/entries/$id') as Map));

  Future<JournalEntry> save(Map<String, dynamic> input,
      {JournalEntry? original, required String requestId}) async {
    final result = await _request(original == null ? 'POST' : 'PUT',
        original == null ? 'journal/entries' : 'journal/entries/${original.id}',
        body: {
          ...input,
          if (original == null)
            'client_request_id': requestId
          else
            'expected_version': original.version
        });
    return JournalEntry.fromJson(Map<String, dynamic>.from(result as Map));
  }

  Future<void> delete(JournalEntry entry) async {
    await _request('DELETE', 'journal/entries/${entry.id}',
        query: {'expected_version': '${entry.version}'});
  }

  Future<void> setCompleted(JournalEntry entry, bool value) async {
    final latest = await detail(entry.id);
    if (latest.version != entry.version) {
      throw const ApiException('记录已修改，请刷新后重试', statusCode: 409);
    }
    await save({...latest.toInput(), 'completed': value},
        original: latest, requestId: '');
  }
}
