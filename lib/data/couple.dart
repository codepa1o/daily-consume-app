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
  String get timeTogether {
    final today = journalToday();
    var years = today.year - since.year;
    DateTime yearDate(int value) {
      final lastDay = DateTime(value, since.month + 1, 0).day;
      final day = since.day > lastDay ? lastDay : since.day;
      return DateTime(value, since.month, day);
    }

    var cursor = yearDate(since.year + years);
    if (cursor.isAfter(today)) {
      years--;
      cursor = yearDate(since.year + years);
    }

    var months = (today.year - cursor.year) * 12 + today.month - cursor.month;
    DateTime monthDate(int offset) {
      final first = DateTime(cursor.year, cursor.month + offset, 1);
      final lastDay = DateTime(first.year, first.month + 1, 0).day;
      final day = cursor.day > lastDay ? lastDay : cursor.day;
      return DateTime(first.year, first.month, day);
    }

    var monthCursor = monthDate(months);
    if (monthCursor.isAfter(today)) {
      months--;
      monthCursor = monthDate(months);
    }
    final days = today.difference(monthCursor).inDays;
    final duration = [
      if (years > 0) '$years 年',
      if (months > 0) '$months 个月',
      if (days > 0) '$days 天',
    ].join();
    return duration.isEmpty ? '今天开始' : duration;
  }

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
      required this.photoCount,
      required this.displayMode});
  final int id, authorId;
  final String author, title, content, mood;
  final DateTime date, publishedDate;
  final int photoCount;
  final String displayMode;
  bool get hasPhoto => photoCount > 0;
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
      photoCount: value['photo_count'] as int,
      displayMode: value['display_mode'] as String);
}

class CoupleTimelineDay {
  const CoupleTimelineDay(this.date, this.memories);
  final DateTime date;
  final List<CoupleMemory> memories;
}

class CoupleConflict {
  const CoupleConflict({
    required this.id,
    required this.conflictDate,
    required this.title,
    required this.summary,
    required this.createdBy,
    required this.status,
    required this.agreement,
    required this.followUpDate,
    required this.agreementVersion,
    required this.agreementConfirmedBy,
    required this.reflectionCount,
  });

  final int id;
  final DateTime conflictDate;
  final String title;
  final String summary;
  final int createdBy;
  final String status;
  final String agreement;
  final DateTime? followUpDate;
  final int agreementVersion;
  final List<int> agreementConfirmedBy;
  final int reflectionCount;

  factory CoupleConflict.fromJson(Map<String, dynamic> row) => CoupleConflict(
        id: row['id'] as int,
        conflictDate:
            journalDate(DateTime.parse(row['conflict_date'] as String)),
        title: row['title'] as String,
        summary: row['summary'] as String? ?? '',
        createdBy: row['created_by'] as int,
        status: row['status'] as String,
        agreement: row['agreement'] as String? ?? '',
        followUpDate: row['follow_up_date'] == null
            ? null
            : journalDate(DateTime.parse(row['follow_up_date'] as String)),
        agreementVersion: row['agreement_version'] as int? ?? 0,
        agreementConfirmedBy:
            (row['agreement_confirmed_by'] as List? ?? const [])
                .whereType<num>()
                .map((id) => id.toInt())
                .toList(),
        reflectionCount: row['reflection_count'] as int? ?? 0,
      );
}

class CoupleConflictReflection {
  const CoupleConflictReflection({
    required this.authorId,
    required this.author,
    required this.observations,
    required this.feelings,
    required this.needs,
    required this.myPart,
    required this.request,
    required this.published,
  });

  final int authorId;
  final String author;
  final String observations;
  final String feelings;
  final String needs;
  final String myPart;
  final String request;
  final bool published;

  factory CoupleConflictReflection.fromJson(Map<String, dynamic> row) =>
      CoupleConflictReflection(
        authorId: row['author_id'] as int,
        author: row['author_name'] as String,
        observations: row['observations'] as String,
        feelings: row['feelings'] as String,
        needs: row['needs'] as String,
        myPart: row['my_part'] as String,
        request: row['request'] as String,
        published: row['published'] as bool,
      );
}

class CoupleComment {
  const CoupleComment({
    required this.id,
    required this.authorId,
    required this.author,
    required this.content,
    required this.createdAt,
    this.parentId,
    this.replyToId,
    this.replyToAuthor,
    this.avatarBytes,
    this.likeCount = 0,
    this.likedByMe = false,
  });

  final int id, authorId, likeCount;
  final int? parentId, replyToId;
  final String author, content;
  final String? replyToAuthor;
  final Uint8List? avatarBytes;
  final DateTime createdAt;
  final bool likedByMe;

  factory CoupleComment.fromJson(Map<String, dynamic> row) => CoupleComment(
        id: row['id'] as int,
        authorId: row['author_id'] as int,
        author: row['author_name'] as String,
        content: row['content'] as String,
        // 新旧评论均使用服务端保存的原始发布时间，不能以客户端加载时间代替。
        createdAt: DateTime.parse(row['created_at'] as String),
        parentId: row['parent_id'] as int?,
        replyToId: row['reply_to_id'] as int?,
        replyToAuthor: row['reply_to_author'] as String?,
        avatarBytes: row['avatar_base64'] == null
            ? null
            : base64Decode(row['avatar_base64'] as String),
        likeCount: row['like_count'] as int? ?? 0,
        likedByMe: row['liked_by_me'] as bool? ?? false,
      );

  CoupleComment withLike(bool liked, int count) => CoupleComment(
      id: id,
      authorId: authorId,
      author: author,
      content: content,
      createdAt: createdAt,
      parentId: parentId,
      replyToId: replyToId,
      replyToAuthor: replyToAuthor,
      avatarBytes: avatarBytes,
      likeCount: count,
      likedByMe: liked);
}

/// 固定显示北京时间，避免两人的设备时区不同导致同一条留言时间不一致。
String coupleCommentTime(DateTime value) {
  final time = value.toUtc().add(const Duration(hours: 8));
  String two(int number) => number.toString().padLeft(2, '0');
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
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

  Future<void> updateAnniversary(DateTime since) async {
    await _request('PUT', 'couple/space/anniversary',
        binary: false, body: {'since_date': dateKey(since)});
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
  Future<Uint8List> photo(int id,
          {int position = 0, bool thumbnail = true}) async =>
      await _request('GET', 'couple/memories/$id/photos/$position',
          binary: true, query: {'thumbnail': '$thumbnail'}) as Uint8List;
  Future<Uint8List> coverPhoto(int id) async =>
      await _request('GET', 'couple/memories/$id/photo',
          binary: true, query: {'thumbnail': 'true'}) as Uint8List;
  Future<List<Uint8List>> thumbnails(int id) async {
    final result =
        await _request('GET', 'couple/memories/$id/photos', binary: false);
    return (result['items'] as List)
        .map(
            (item) => base64Decode((item as Map)['thumbnail_base64'] as String))
        .toList();
  }

  Future<void> save(
      {required String requestId,
      required DateTime date,
      required String title,
      required String content,
      required String mood,
      required List<Uint8List> photos,
      required String displayMode}) async {
    await _request('POST', 'couple/memories', binary: false, body: {
      'client_request_id': requestId,
      'memory_date': dateKey(date),
      'title': title.trim(),
      'content': content.trim(),
      'mood': mood,
      'display_mode': displayMode,
      if (photos.isNotEmpty) 'photos_base64': photos.map(base64Encode).toList(),
    });
  }

  Future<void> comment(int id, String content, String requestId,
      {int? replyToId}) async {
    await _request('POST', 'couple/memories/$id/comments',
        binary: false,
        body: {
          'content': content.trim(),
          'client_request_id': requestId,
          if (replyToId != null) 'reply_to_id': replyToId
        });
  }

  Future<List<CoupleComment>> comments(int id, {bool conflict = false}) async =>
      (await _request('GET',
              'couple/${conflict ? 'conflicts' : 'memories'}/$id/comments',
              binary: false) as List)
          .map((row) =>
              CoupleComment.fromJson(Map<String, dynamic>.from(row as Map)))
          .toList();

  Future<({bool liked, int count})> likeComment(
      int id, int commentId, bool liked,
      {bool conflict = false}) async {
    final result = await _request('PUT',
        'couple/${conflict ? 'conflicts' : 'memories'}/$id/comments/$commentId/like',
        binary: false, body: {'liked': liked}) as Map;
    return (liked: result['liked'] as bool, count: result['like_count'] as int);
  }

  Future<void> react(int id, String? emoji) async {
    await _request('PUT', 'couple/memories/$id/reaction',
        binary: false, body: {'emoji': emoji});
  }

  Future<void> delete(int id) async {
    await _request('DELETE', 'couple/memories/$id', binary: false);
  }

  Future<List<CoupleConflict>> conflicts(DateTime start, DateTime end) async =>
      (await _request('GET', 'couple/conflicts', binary: false, query: {
        'start': dateKey(start),
        'end': dateKey(end),
      }) as List)
          .map((row) =>
              CoupleConflict.fromJson(Map<String, dynamic>.from(row as Map)))
          .toList();

  Future<int> createConflict({
    required DateTime date,
    required String title,
    required String summary,
    required String requestId,
  }) async =>
      (await _request('POST', 'couple/conflicts', binary: false, body: {
        'conflict_date': dateKey(date),
        'title': title.trim(),
        'summary': summary.trim(),
        'client_request_id': requestId,
      }) as Map)['id'] as int;

  Future<Map<String, dynamic>> conflict(int id) async =>
      Map<String, dynamic>.from(
          await _request('GET', 'couple/conflicts/$id', binary: false) as Map);

  Future<void> saveConflictReflection(
    int id, {
    required String observations,
    required String feelings,
    required String needs,
    required String myPart,
    required String request,
    required bool published,
  }) async {
    await _request('PUT', 'couple/conflicts/$id/reflection',
        binary: false,
        body: {
          'observations': observations.trim(),
          'feelings': feelings.trim(),
          'needs': needs.trim(),
          'my_part': myPart.trim(),
          'request': request.trim(),
          'published': published,
        });
  }

  Future<void> saveConflictAgreement(int id, String agreement,
      {required int expectedVersion, DateTime? followUpDate}) async {
    await _request('PUT', 'couple/conflicts/$id/agreement',
        binary: false,
        body: {
          'agreement': agreement.trim(),
          'expected_version': expectedVersion,
          'follow_up_date': followUpDate == null ? null : dateKey(followUpDate),
        });
  }

  Future<void> commentConflict(int id, String content, String requestId,
      {int? replyToId}) async {
    await _request('POST', 'couple/conflicts/$id/comments',
        binary: false,
        body: {
          'content': content.trim(),
          'client_request_id': requestId,
          if (replyToId != null) 'reply_to_id': replyToId
        });
  }

  Future<void> deleteConflict(int id) async {
    await _request('DELETE', 'couple/conflicts/$id', binary: false);
  }

  static String requestId() => journalRequestId();
}
