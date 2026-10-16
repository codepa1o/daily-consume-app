import 'dart:async';

import 'package:flutter/material.dart';

import '../account_pages.dart' show AccountAvatar;
import '../couple_effects.dart' show coupleInk, couplePaper, coupleRose;
import '../data/api_client.dart';
import '../data/couple.dart';

/// 回忆与反思共用评论区，回复只缩进一层，草稿不随后台刷新清空。
class CoupleComments extends StatefulWidget {
  const CoupleComments(
      {super.key,
      required this.api,
      required this.resourceId,
      required this.initialComments,
      this.conflict = false,
      this.onChanged});

  final CoupleApi api;
  final int resourceId;
  final List<dynamic> initialComments;
  final bool conflict;
  final Future<void> Function()? onChanged;

  @override
  State<CoupleComments> createState() => _CoupleCommentsState();
}

class _CoupleCommentsState extends State<CoupleComments>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _editorKey = GlobalKey();
  final _expanded = <int>{};
  final _pendingLikes = <int>{};
  late List<CoupleComment> _items;
  late final int? _owner;
  Timer? _poll;
  CoupleComment? _replyTo;
  String _requestId = CoupleApi.requestId();
  String? _error;
  bool _sending = false,
      _refreshing = false,
      _uncertain = false,
      _sessionChanged = false;
  int _fetchVersion = 0;

  List<CoupleComment> _parse(List<dynamic> rows) => rows
      .map((row) =>
          CoupleComment.fromJson(Map<String, dynamic>.from(row as Map)))
      .toList();

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    _items = _parse(widget.initialComments);
    ApiClient.instance.addListener(_accountChanged);
    WidgetsBinding.instance.addObserver(this);
    // 仅在当前页面可见、应用位于前台时轻量刷新，双方互动可自动同步。
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (ModalRoute.of(context)?.isCurrent == true &&
          (state == null || state == AppLifecycleState.resumed)) {
        unawaited(_refresh(background: true));
      }
    });
  }

  @override
  void didUpdateWidget(covariant CoupleComments oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.initialComments, widget.initialComments)) {
      _fetchVersion++;
      final current = {for (final item in _items) item.id: item};
      _items = _parse(widget.initialComments)
          .map((item) =>
              _pendingLikes.contains(item.id) ? current[item.id] ?? item : item)
          .toList();
    }
  }

  void _accountChanged() {
    if (!mounted || ApiClient.instance.account?.id == _owner) return;
    _text.clear();
    setState(() {
      _sessionChanged = true;
      _items.clear();
      _replyTo = null;
      _fetchVersion++;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ModalRoute.of(context)?.isCurrent == true) {
      unawaited(_refresh(background: true));
    }
  }

  Future<void> _refresh({bool background = false}) async {
    if (_sessionChanged ||
        _refreshing ||
        _pendingLikes.isNotEmpty ||
        (background && _sending)) return;
    final version = ++_fetchVersion;
    setState(() => _refreshing = true);
    try {
      final items = await widget.api
          .comments(widget.resourceId, conflict: widget.conflict);
      if (mounted && !_sessionChanged && version == _fetchVersion)
        setState(() {
          _items = items;
          if (!_uncertain && !_sending) _error = null;
        });
    } catch (error) {
      if (mounted && !_sessionChanged && !background)
        setState(() => _error = coupleError(error));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _replace(CoupleComment value) {
    _items = [
      for (final item in _items)
        if (item.id == value.id) value else item
    ];
  }

  Future<void> _like(CoupleComment item) async {
    if (_sessionChanged || _pendingLikes.contains(item.id)) return;
    final liked = !item.likedByMe;
    setState(() {
      _pendingLikes.add(item.id);
      _fetchVersion++; // 丢弃点赞前发出的旧刷新结果，避免覆盖乐观显示。
      _error = null;
      _replace(item.withLike(liked, item.likeCount + (liked ? 1 : -1)));
    });
    try {
      final result = await widget.api.likeComment(
          widget.resourceId, item.id, liked,
          conflict: widget.conflict);
      if (mounted && !_sessionChanged)
        setState(() => _replace(item.withLike(result.liked, result.count)));
    } catch (error) {
      // 请求失败先恢复原显示；再次点赞仍发送同一目标状态，不会重复计数。
      if (mounted && !_sessionChanged)
        setState(() {
          _replace(item);
          _error = coupleError(error);
        });
    } finally {
      if (mounted) setState(() => _pendingLikes.remove(item.id));
    }
  }

  void _reply(CoupleComment? item) {
    if (_sending || _uncertain || _sessionChanged) return;
    setState(() {
      _replyTo = item;
      _requestId = CoupleApi.requestId();
      _error = null;
    });
    if (item != null) {
      _focus.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _editorKey.currentContext != null) {
          Scrollable.ensureVisible(_editorKey.currentContext!,
              duration: const Duration(milliseconds: 180), alignment: .3);
        }
      });
    }
  }

  Future<void> _send() async {
    if (_sending || _sessionChanged || _text.text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    var confirmed = false;
    try {
      if (widget.conflict) {
        await widget.api.commentConflict(
            widget.resourceId, _text.text, _requestId,
            replyToId: _replyTo?.id);
      } else {
        await widget.api.comment(widget.resourceId, _text.text, _requestId,
            replyToId: _replyTo?.id);
      }
      confirmed = true;
      if (!mounted || _sessionChanged) return;
      if (_replyTo != null) _expanded.add(_replyTo!.parentId ?? _replyTo!.id);
      _text.clear();
      setState(() {
        _replyTo = null;
        _uncertain = false;
        _requestId = CoupleApi.requestId();
      });
      await _refresh();
      if (mounted && !_sessionChanged) await widget.onChanged?.call();
    } catch (error) {
      if (!mounted || _sessionChanged) return;
      // 超时或服务端异常可能已写入：保留内容和回复对象，重试复用请求编号。
      setState(() {
        // 写入已确认后，刷新失败只提示刷新，不能再把发送当作待重试请求。
        _uncertain = !confirmed &&
            (error is! ApiException ||
                error.statusCode == 0 ||
                error.statusCode >= 500);
        _error = confirmed
            ? '留言已发送，刷新失败，请点击刷新评论。'
            : _uncertain
                ? '发送结果尚未确认，内容已保留。请重试同一次发送。'
                : coupleError(error);
        if (!_uncertain) _requestId = CoupleApi.requestId();
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ApiClient.instance.removeListener(_accountChanged);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Widget _tile(CoupleComment item, {int replyCount = 0}) => Row(
        key: ValueKey('comment-${item.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AccountAvatar(bytes: item.avatarBytes, radius: 16),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(item.author,
                    style: const TextStyle(
                        color: coupleRose, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(coupleCommentTime(item.createdAt),
                    style: const TextStyle(
                        color: Color(0xff877267), fontSize: 11)),
                const SizedBox(height: 8),
                Text.rich(
                    TextSpan(children: [
                      if (item.replyToAuthor != null)
                        TextSpan(
                            text: '回复 ${item.replyToAuthor}：',
                            style: const TextStyle(color: coupleRose)),
                      TextSpan(text: item.content),
                    ]),
                    style: const TextStyle(color: coupleInk, height: 1.5)),
                Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Tooltip(
                          message: item.likedByMe ? '取消点赞' : '点赞',
                          child: TextButton.icon(
                            key: ValueKey('like-comment-${item.id}'),
                            onPressed: _pendingLikes.contains(item.id)
                                ? null
                                : () => _like(item),
                            style: TextButton.styleFrom(
                                foregroundColor: item.likedByMe
                                    ? coupleRose
                                    : const Color(0xff877267)),
                            icon: Icon(
                                item.likedByMe
                                    ? Icons.thumb_up_rounded
                                    : Icons.thumb_up_outlined,
                                size: 17),
                            label: Text(item.likeCount == 0
                                ? '点赞'
                                : '${item.likeCount}'),
                          )),
                      TextButton(
                          key: ValueKey('reply-comment-${item.id}'),
                          style:
                              TextButton.styleFrom(foregroundColor: coupleRose),
                          onPressed: _sending || _uncertain
                              ? null
                              : () => _reply(item),
                          child:
                              Text(replyCount == 0 ? '回复' : '回复（$replyCount）')),
                    ]),
              ])),
        ],
      );

  @override
  Widget build(BuildContext context) {
    if (_sessionChanged) return const Text('账号已切换，请返回后重新打开');
    final roots = _items.where((item) => item.parentId == null);
    final replies = <int, List<CoupleComment>>{};
    for (final item in _items) {
      if (item.parentId != null)
        replies.putIfAbsent(item.parentId!, () => []).add(item);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
            child: Text('共 ${_items.length} 条留言',
                style:
                    const TextStyle(color: Color(0xff877267), fontSize: 12))),
        IconButton(
            tooltip: '刷新评论',
            onPressed: _refreshing || _sending ? null : () => _refresh(),
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      if (_items.isEmpty)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
                widget.conflict ? '还没有评论，可以在这里继续交流。' : '还没有留言，给另一半留一句话吧。',
                style: const TextStyle(color: Color(0xff877267)))),
      for (final item in roots) ...[
        Card(
            color: couplePaper,
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _tile(item, replyCount: replies[item.id]?.length ?? 0),
                      if (replies[item.id]?.isNotEmpty == true)
                        Padding(
                            padding: const EdgeInsets.only(left: 24),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: const Color(0xfff6f0e6),
                                  borderRadius: BorderRadius.circular(12)),
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (final reply
                                        in _expanded.contains(item.id)
                                            ? replies[item.id]!
                                            : replies[item.id]!.take(2)) ...[
                                      _tile(reply),
                                      const SizedBox(height: 8),
                                    ],
                                    if (replies[item.id]!.length > 2)
                                      Align(
                                          alignment: Alignment.centerLeft,
                                          child: TextButton(
                                            key: ValueKey(
                                                'expand-comment-${item.id}'),
                                            style: TextButton.styleFrom(
                                                foregroundColor: coupleRose),
                                            onPressed: () => setState(() {
                                              if (!_expanded.remove(item.id))
                                                _expanded.add(item.id);
                                            }),
                                            child: Text(_expanded
                                                    .contains(item.id)
                                                ? '收起回复'
                                                : '展开全部 ${replies[item.id]!.length} 条回复'),
                                          )),
                                  ]),
                            )),
                    ]))),
        const SizedBox(height: 12),
      ],
      if (_replyTo != null)
        Row(children: [
          Expanded(
              child: Text('回复 ${_replyTo!.author}',
                  style: const TextStyle(color: coupleRose))),
          IconButton(
              tooltip: '取消回复',
              onPressed: _sending || _uncertain ? null : () => _reply(null),
              icon: const Icon(Icons.close_rounded)),
        ]),
      TextField(
          key: _editorKey,
          controller: _text,
          focusNode: _focus,
          enabled: !_sending && !_uncertain,
          onChanged: (_) => setState(() {}),
          minLines: 2,
          maxLines: 5,
          maxLength: 1000,
          decoration: InputDecoration(
              hintText: _replyTo == null
                  ? widget.conflict
                      ? '写一句评论…'
                      : '想对你说…'
                  : '回复 ${_replyTo!.author}…',
              border: const OutlineInputBorder())),
      if (_error != null)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))),
      const SizedBox(height: 8),
      Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: coupleRose, foregroundColor: couplePaper),
            onPressed: _sending || _text.text.trim().isEmpty ? null : _send,
            icon: const Icon(Icons.send_rounded, size: 17),
            label: Text(_sending
                ? '发送中…'
                : _uncertain
                    ? '重试发送'
                    : widget.conflict
                        ? '发送'
                        : '留下这句话'),
          )),
    ]);
  }
}
