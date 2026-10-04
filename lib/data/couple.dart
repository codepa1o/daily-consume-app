import 'dart:convert';
import 'dart:typed_data';

import 'api_client.dart';
import 'app_database.dart' show dateKey;
import 'journal.dart' show journalDate, journalRequestId, journalToday;

const coupleEffects = ['拍立得显影', '翻面留言', '双人拼贴', '惊喜刮刮卡', '回忆星空', '立体照片'];

String coupleError(Object error) => error is ApiException
    ? error.statusCode == 404 && error.message == 'Not Found'
        ? '情侣空间服务暂不可用，请更新服务器后重试'
        : error.message
    : '操作失败，请重试';

class CoupleMember {
  const CoupleMember(this.id, this.name);
  final int id;
  final String name;
  factory CoupleMember.fromJson(Map<String, dynamic> value) =>
      CoupleMember(value['id'] as int, value['nickname'] as String);
}

class CoupleSpace {
  const CoupleSpace(
      {required this.id,
      required this.title,
      required this.since,
      required this.members});
  final int id;
  final String title;
  final DateTime since;
  final List<CoupleMember> members;
  int get daysTogether => journalToday().difference(since).inDays + 1;
  factory CoupleSpace.fromJson(Map<String, dynamic> value) => CoupleSpace(
      id: value['id'] as int,
      title: value['title'] as String,
      since: journalDate(DateTime.parse(value['since_date'] as String)),
      members: (value['members'] as List)
          .map(
              (e) => CoupleMember.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList());
}

class CoupleMemory {
  const CoupleMemory(
      {required this.id,
      required this.authorId,
      required this.author,
      required this.date,
      required this.publishedDate,
      required this.title,
      required this.content,
      required this.mood,
      required this.hasPhoto});
  final int id, authorId;
  final String author, title, content, mood;
  final DateTime date, publishedDate;
  final bool hasPhoto;
  factory CoupleMemory.fromJson(Map<String, dynamic> value) => CoupleMemory(
      id: value['id'] as int,
      authorId: value['author_id'] as int,
      author: value['author_name'] as String,
      date: DateTime.parse(value['memory_date'] as String),
      publishedDate:
          journalDate(DateTime.parse(value['published_date'] as String)),
      title: value['title'] as String,
      content: value['content'] as String,
      mood: value['mood'] as String,
      hasPhoto: value['has_photo'] as bool);
}

class CoupleTimelineDay {
  const CoupleTimelineDay(this.date, this.memories);
  final DateTime date;
  final List<CoupleMemory> memories;
}

/// Group publish-time-ordered rows. A date split across API pages keeps one marker.
List<CoupleTimelineDay> coupleTimelineDays(List<CoupleMemory> memories) {
  final days = <DateTime, List<CoupleMemory>>{};
  for (final memory in memories) {
    days.putIfAbsent(memory.publishedDate, () => []).add(memory);
  }
  return [
    for (final day in days.entries)
      CoupleTimelineDay(day.key, List.unmodifiable(day.value)),
  ];
}

/// The latest photo from each publication day, never two copies of one photo.
List<CoupleMemory> couplePair(List<CoupleMemory> memories, DateTime date) {
  final authors = <int>{};
  final sorted = memories
      .where((m) => m.hasPhoto && dateKey(m.publishedDate) == dateKey(date))
      .toList()
    ..sort((a, b) => b.id.compareTo(a.id));
  return sorted.where((m) => authors.add(m.authorId)).take(2).toList();
}

typedef CoupleRequest = Future<dynamic> Function(String method, String path,
    {Object? body, Map<String, String>? query, bool binary});

class CoupleApi {
  CoupleApi({CoupleRequest? request})
      : _request = request ?? ApiClient.instance.request;
  static final instance = CoupleApi();
  final CoupleRequest _request;

  Future<CoupleSpace?> space() async {
    final result = await _request('GET', 'couple/space', binary: false);
    return result == null
        ? null
        : CoupleSpace.fromJson(Map<String, dynamic>.from(result as Map));
  }

  Future<void> create(String title, DateTime since) async {
    await _request('POST', 'couple/space',
        binary: false,
        body: {'title': title.trim(), 'since_date': dateKey(since)});
  }

  Future<Map<String, dynamic>> invite() async => Map<String, dynamic>.from(
      await _request('POST', 'couple/invite', binary: false) as Map);
  Future<Map<String, dynamic>> preview(String code) async =>
      Map<String, dynamic>.from(await _request('POST', 'couple/invite/preview',
          binary: false, body: {'code': code.trim().toUpperCase()}) as Map);
  Future<void> join(String code) async {
    await _request('POST', 'couple/join',
        binary: false, body: {'code': code.trim().toUpperCase()});
  }

  Future<Map<String, dynamic>> memories({int offset = 0}) async =>
      Map<String, dynamic>.from(await _request('GET', 'couple/memories',
          binary: false, query: {'offset': '$offset', 'limit': '30'}) as Map);
  Future<List<CoupleMemory>> pair(DateTime date) async {
    final result = await _request('GET', 'couple/pair',
        binary: false, query: {'date': dateKey(date)});
    return (result['items'] as List)
        .map((e) => CoupleMemory.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> detail(int id) async =>
      Map<String, dynamic>.from(
          await _request('GET', 'couple/memories/$id', binary: false) as Map);
  Future<Uint8List> photo(int id, {bool thumbnail = true}) async =>
      await _request('GET', 'couple/memories/$id/photo',
          binary: true, query: {'thumbnail': '$thumbnail'}) as Uint8List;
  Future<void> save(
      {required String requestId,
      required DateTime date,
      required String title,
      required String content,
      required String mood,
      Uint8List? photo}) async {
    await _request('POST', 'couple/memories', binary: false, body: {
      'client_request_id': requestId,
      'memory_date': dateKey(date),
      'title': title.trim(),
      'content': content.trim(),
      'mood': mood,
      if (photo != null) 'photo_base64': base64Encode(photo),
    });
  }

  Future<void> comment(int id, String content, String requestId) async {
    await _request('POST', 'couple/memories/$id/comments',
        binary: false,
        body: {'content': content.trim(), 'client_request_id': requestId});
  }

  Future<void> react(int id, String? emoji) async {
    await _request('PUT', 'couple/memories/$id/reaction',
        binary: false, body: {'emoji': emoji});
  }

  Future<void> delete(int id) async {
    await _request('DELETE', 'couple/memories/$id', binary: false);
  }

  static String requestId() => journalRequestId();
}
