import 'package:flutter/material.dart';

import 'data/api_client.dart';
import 'data/app_database.dart' show dateKey;
import 'data/couple.dart';
import 'data/journal.dart' show journalToday;
import 'couple_effects.dart' show coupleInk, couplePaper, coupleRose;

const _conflictGreen = Color(0xff64765a);
const _conflictSoft = Color(0xffe9eee4);
const _conflictMuted = Color(0xff7b746d);

String _conflictStatus(String status) => switch (status) {
      'agreed' => '双方确认共识',
      'talking' => '沟通中',
      _ => '等待双方反思',
    };

class CoupleConflictCalendarPage extends StatefulWidget {
  const CoupleConflictCalendarPage({super.key, required this.api});
  final CoupleApi api;

  @override
  State<CoupleConflictCalendarPage> createState() =>
      _CoupleConflictCalendarPageState();
}

class _CoupleConflictCalendarPageState
    extends State<CoupleConflictCalendarPage> {
  DateTime _month = _monthOf(journalToday());
  DateTime _selectedDate = journalToday();
  CoupleSpace? _space;
  List<CoupleConflict> _conflicts = [];
  String? _error;
  bool _loading = true;
  int _loadVersion = 0;

  List<CoupleConflict> get _selectedConflicts => _conflicts
      .where((item) => dateKey(item.conflictDate) == dateKey(_selectedDate))
      .toList();

  Map<int, String> get _memberNames => {
        for (final member in _space?.members ?? const <CoupleMember>[])
          member.id: member.name,
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final start = _month;
      final end = DateTime(_month.year, _month.month + 1, 0);
      final values = await Future.wait<Object?>([
        widget.api.conflicts(start, end),
        widget.api.space(),
      ]);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _conflicts = values[0] as List<CoupleConflict>;
        _space = values[1] as CoupleSpace?;
        _loading = false;
      });
    } catch (failure) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loading = false;
        _error = coupleError(failure);
      });
    }
  }

  void _changeMonth(int delta) {
    final next = DateTime(_month.year, _month.month + delta);
    if (next.isBefore(DateTime(2000)) ||
        next.isAfter(_monthOf(journalToday()))) {
      return;
    }
    setState(() {
      _month = next;
      _selectedDate = next;
    });
    _load();
  }

  Future<void> _addConflict() async {
    final id = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _ConflictCreateDialog(api: widget.api, date: _selectedDate),
    );
    if (id == null || !mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => CoupleConflictDetailPage(
        id: id,
        api: widget.api,
        memberNames: _memberNames,
      ),
    ));
    if (mounted) await _load();
  }

  Future<void> _open(CoupleConflict conflict) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => CoupleConflictDetailPage(
        id: conflict.id,
        api: widget.api,
        memberNames: _memberNames,
      ),
    ));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xfff6f0e6),
        appBar: AppBar(
          title: const Text('吵架反思'),
          backgroundColor: couplePaper,
          actions: [
            IconButton(
              tooltip: '刷新日历',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        floatingActionButton: _space?.members.length == 2
            ? FloatingActionButton.extended(
                onPressed: _loading ? null : _addConflict,
                backgroundColor: coupleRose,
                foregroundColor: couplePaper,
                icon: const Icon(Icons.add_rounded),
                label: const Text('记录这一天'),
              )
            : null,
        body: _error != null
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ]),
              )
            : _loading
                ? const Center(child: CircularProgressIndicator())
                : _space?.members.length != 2
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Text('邀请另一半加入后，就可以一起记录和回顾。',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: _conflictMuted)),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 104),
                        children: [
                          _calendar(),
                          const SizedBox(height: 18),
                          Row(children: [
                            Expanded(
                              child: Text(
                                  '${dateKey(_selectedDate)} · ${_selectedConflicts.length} 条记录',
                                  style: const TextStyle(
                                      color: coupleInk,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600)),
                            ),
                            TextButton.icon(
                              onPressed: _addConflict,
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: const Text('记录'),
                            ),
                          ]),
                          if (_selectedConflicts.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 32),
                              child: Text('这一天还没有记录，想整理时可以从这里开始。',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: _conflictMuted)),
                            ),
                          for (final conflict in _selectedConflicts)
                            _conflictTile(conflict),
                        ],
                      ),
      );

  Widget _calendar() {
    final first = DateTime(_month.year, _month.month, 1);
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = first.weekday - 1;
    final count = ((leading + days + 6) ~/ 7) * 7;
    final conflictsByDay = <int, int>{};
    for (final conflict in _conflicts) {
      conflictsByDay.update(conflict.conflictDate.day, (value) => value + 1,
          ifAbsent: () => 1);
    }
    return Column(children: [
      Row(children: [
        IconButton(
          onPressed: _month.year == 2000 && _month.month == 1
              ? null
              : () => _changeMonth(-1),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: Text('${_month.year}年${_month.month}月',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: coupleInk, fontSize: 18, fontFamily: 'serif')),
        ),
        IconButton(
          onPressed: _monthOf(journalToday()).isAfter(_month)
              ? () => _changeMonth(1)
              : null,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ]),
      const SizedBox(height: 4),
      Row(children: [
        for (final day in ['一', '二', '三', '四', '五', '六', '日'])
          Expanded(
              child: Center(
                  child: Text(day,
                      style: TextStyle(color: _conflictMuted, fontSize: 12)))),
      ]),
      const SizedBox(height: 5),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          mainAxisExtent: 48,
        ),
        itemBuilder: (context, index) {
          final dayNumber = index - leading + 1;
          if (dayNumber < 1 || dayNumber > days) return const SizedBox.shrink();
          final date = DateTime(_month.year, _month.month, dayNumber);
          final selected = dateKey(date) == dateKey(_selectedDate);
          final future = dateKey(date).compareTo(dateKey(journalToday())) > 0;
          final markers = conflictsByDay[dayNumber] ?? 0;
          return Semantics(
            button: !future,
            selected: selected,
            label:
                '${dateKey(date)}${markers > 0 ? '，$markers 条吵架记录' : ''}${future ? '，尚未到来' : ''}',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: future ? null : () => setState(() => _selectedDate = date),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 34,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected ? _conflictGreen : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$dayNumber',
                          style: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : future
                                      ? _conflictMuted
                                      : coupleInk,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.normal)),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      height: 6,
                      child: markers == 0
                          ? null
                          : Text('$markers',
                              style: const TextStyle(
                                  color: coupleRose, fontSize: 9, height: .7)),
                    ),
                  ]),
            ),
          );
        },
      ),
    ]);
  }

  Widget _conflictTile(CoupleConflict conflict) => Card(
        color: couplePaper,
        margin: const EdgeInsets.only(bottom: 9),
        child: ListTile(
          leading: const CircleAvatar(
            backgroundColor: _conflictSoft,
            child: Icon(Icons.forum_outlined, color: _conflictGreen),
          ),
          title: Text(conflict.title, style: const TextStyle(color: coupleInk)),
          subtitle: Text(
              '${_conflictStatus(conflict.status)} · ${conflict.reflectionCount}/2 份反思'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _open(conflict),
        ),
      );
}

class CoupleConflictDetailPage extends StatefulWidget {
  const CoupleConflictDetailPage({
    super.key,
    required this.id,
    required this.api,
    required this.memberNames,
  });

  final int id;
  final CoupleApi api;
  final Map<int, String> memberNames;

  @override
  State<CoupleConflictDetailPage> createState() =>
      _CoupleConflictDetailPageState();
}

class _CoupleConflictDetailPageState extends State<CoupleConflictDetailPage> {
  final _observations = TextEditingController();
  final _feelings = TextEditingController();
  final _needs = TextEditingController();
  final _myPart = TextEditingController();
  final _request = TextEditingController();
  final _agreement = TextEditingController();
  final _comment = TextEditingController();
  String _commentRequestId = CoupleApi.requestId();
  Map<String, dynamic>? _data;
  DateTime? _followUpDate;
  int _agreementVersion = 0;
  bool _agreementDirty = false;
  String? _error;
  bool _loading = true, _busy = false, _editorInitialized = false;

  CoupleConflict get _conflict =>
      CoupleConflict.fromJson(Map<String, dynamic>.from(_data!));
  List<CoupleConflictReflection> get _reflections => (_data!['reflections']
          as List)
      .map((row) => CoupleConflictReflection.fromJson(
          Map<String, dynamic>.from(row as Map)))
      .toList();
  List<CoupleConflictComment> get _comments => (_data!['comments'] as List)
      .map((row) =>
          CoupleConflictComment.fromJson(Map<String, dynamic>.from(row as Map)))
      .toList();
  int get _myId => ApiClient.instance.account?.id ?? -1;
  CoupleConflictReflection? get _myReflection {
    for (final reflection in _reflections) {
      if (reflection.authorId == _myId) return reflection;
    }
    return null;
  }

  bool get _canSaveReflection => [
        _observations.text,
        _feelings.text,
        _needs.text,
        _myPart.text,
        _request.text,
      ].any((value) => value.trim().isNotEmpty);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _observations.dispose();
    _feelings.dispose();
    _needs.dispose();
    _myPart.dispose();
    _request.dispose();
    _agreement.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final value = await widget.api.conflict(widget.id);
      if (!mounted) return;
      if (!_editorInitialized) {
        for (final reflection in (value['reflections'] as List).map((row) =>
            CoupleConflictReflection.fromJson(
                Map<String, dynamic>.from(row as Map)))) {
          if (reflection.authorId == _myId) {
            _observations.text = reflection.observations;
            _feelings.text = reflection.feelings;
            _needs.text = reflection.needs;
            _myPart.text = reflection.myPart;
            _request.text = reflection.request;
          }
        }
        _editorInitialized = true;
      }
      if (!_agreementDirty) {
        final latest = CoupleConflict.fromJson(value);
        _agreement.text = latest.agreement;
        _followUpDate = latest.followUpDate;
        _agreementVersion = latest.agreementVersion;
      }
      setState(() {
        _data = value;
        _loading = false;
        _error = null;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = coupleError(failure);
      });
    }
  }

  Future<void> _saveReflection({required bool publish}) async {
    if (!_canSaveReflection || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.saveConflictReflection(
        widget.id,
        observations: _observations.text,
        feelings: _feelings.text,
        needs: _needs.text,
        myPart: _myPart.text,
        request: _request.text,
        published: publish || (_myReflection?.published ?? false),
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(publish ? '反思已发布给另一半' : '草稿已保存，仅自己可见')));
      }
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(coupleError(failure))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAgreement() async {
    if (_agreement.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.saveConflictAgreement(widget.id, _agreement.text,
          expectedVersion: _agreementVersion, followUpDate: _followUpDate);
      _agreementDirty = false;
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('约定已保存，并记录了你的确认')));
      }
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(coupleError(failure))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendComment() async {
    if (_comment.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.api
          .commentConflict(widget.id, _comment.text, _commentRequestId);
      _comment.clear();
      _commentRequestId = CoupleApi.requestId();
      await _load();
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(coupleError(failure))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseFollowUpDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _followUpDate ?? journalToday(),
      firstDate: _conflict.conflictDate,
      lastDate: journalToday().add(const Duration(days: 3650)),
      helpText: '选择一起回顾约定的日期',
    );
    if (date != null && mounted) {
      setState(() {
        _followUpDate = date;
        _agreementDirty = true;
      });
    }
  }

  Future<void> _delete() async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条记录？'),
        content: const Text('双方的反思和评论也会一起删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    try {
      await widget.api.deleteConflict(widget.id);
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(coupleError(failure))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xfff6f0e6),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xfff6f0e6),
        appBar: AppBar(title: const Text('吵架反思')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!),
            TextButton(onPressed: _load, child: const Text('重试')),
          ]),
        ),
      );
    }
    final conflict = _conflict;
    final reflections = _reflections;
    final myReflection = _myReflection;
    final publishedCount = reflections.where((item) => item.published).length;
    final confirmed = conflict.agreementConfirmedBy.toSet();
    final allConfirmed = widget.memberNames.keys.every(confirmed.contains);
    final confirmedNames = widget.memberNames.entries
        .where((entry) => confirmed.contains(entry.key))
        .map((entry) => entry.value)
        .toList();
    return Scaffold(
      backgroundColor: const Color(0xfff6f0e6),
      appBar: AppBar(
        title: const Text('一起回顾'),
        backgroundColor: couplePaper,
        actions: [
          IconButton(
            tooltip: '刷新反思与评论',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (conflict.createdBy == _myId)
            IconButton(
                tooltip: '删除记录',
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline_rounded)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
        children: [
          _section(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(dateKey(conflict.conflictDate),
                  style: const TextStyle(color: coupleRose, fontSize: 12)),
              const SizedBox(height: 6),
              Text(conflict.title,
                  style: const TextStyle(
                      color: coupleInk, fontSize: 22, fontFamily: 'serif')),
              if (conflict.summary.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(conflict.summary,
                    style: const TextStyle(color: coupleInk, height: 1.6)),
              ],
              const SizedBox(height: 10),
              Text(_conflictStatus(conflict.status),
                  style: const TextStyle(color: _conflictGreen, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 12),
          _section(
            title: '各自写下自己的反思',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('先记下自己的体验；草稿只有自己可见，发布后双方都能查看。',
                  style: TextStyle(color: _conflictMuted, fontSize: 12)),
              const SizedBox(height: 12),
              if (myReflection != null) _reflectionCard(myReflection, '我的反思'),
              _promptField('当时发生了什么', '尽量描述具体事情，不急着判断对错。', _observations,
                  maxLines: 3),
              _promptField('当时的感受', '例如：委屈、生气、失望或担心。', _feelings,
                  maxLength: 1000),
              _promptField('我在意或需要的是', '想想这件事背后对你重要的是什么。', _needs,
                  maxLength: 2000),
              _promptField('我愿意承担或改进的部分', '只写自己愿意尝试的部分。', _myPart,
                  maxLength: 2000),
              _promptField('我想提出的具体请求', '写一个双方可以讨论、做到的下一步。', _request,
                  maxLines: 3, maxLength: 2000),
              if (myReflection?.published == true)
                FilledButton.tonal(
                  onPressed: _busy || !_canSaveReflection
                      ? null
                      : () => _saveReflection(publish: true),
                  child: Text(_busy ? '保存中…' : '保存更新'),
                )
              else
                Row(children: [
                  TextButton(
                    onPressed: _busy || !_canSaveReflection
                        ? null
                        : () => _saveReflection(publish: false),
                    child: Text(_busy ? '保存中…' : '保存草稿'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _busy || !_canSaveReflection
                        ? null
                        : () => _saveReflection(publish: true),
                    child: const Text('发布给另一半'),
                  ),
                ]),
            ]),
          ),
          for (final reflection in reflections)
            if (reflection.authorId != _myId && reflection.published) ...[
              const SizedBox(height: 12),
              _reflectionCard(reflection, '${reflection.author}的反思'),
            ],
          const SizedBox(height: 12),
          _section(
            title: '共同约定',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (publishedCount < 2)
                const Text('双方都发布反思后，可以一起写下约定。',
                    style: TextStyle(color: _conflictMuted, fontSize: 12))
              else ...[
                TextField(
                  controller: _agreement,
                  enabled: !_busy,
                  onChanged: (_) => setState(() => _agreementDirty = true),
                  maxLength: 2000,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '下次我们可以怎么做',
                    hintText: '写下双方都愿意尝试的一件事',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                Wrap(spacing: 8, children: [
                  TextButton.icon(
                    onPressed: _busy ? null : _chooseFollowUpDate,
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(_followUpDate == null
                        ? '设置回访日期（选填）'
                        : '回访日期：${dateKey(_followUpDate!)}'),
                  ),
                  if (_followUpDate != null)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _followUpDate = null;
                                _agreementDirty = true;
                              }),
                      child: const Text('清除日期'),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            _agreementDirty = false;
                            _load();
                          },
                    child: const Text('载入最新约定'),
                  ),
                ]),
                if (conflict.agreement.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                        '已确认：${confirmedNames.isEmpty ? '还没有' : confirmedNames.join('、')}'),
                  ),
                FilledButton.tonal(
                  onPressed: _busy || _agreement.text.trim().isEmpty
                      ? null
                      : _saveAgreement,
                  child: const Text('保存约定并确认'),
                ),
                if (allConfirmed && conflict.agreement.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('你们都确认了这条约定。',
                        style: TextStyle(color: _conflictGreen)),
                  ),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          _section(
            title: '评论',
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_comments.isEmpty)
                    const Text('还没有评论，可以在这里继续交流。',
                        style: TextStyle(color: _conflictMuted, fontSize: 12)),
                  for (final comment in _comments)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.chat_bubble_outline_rounded,
                                size: 17, color: _conflictGreen),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '${comment.author} · ${comment.createdAt.toLocal().month}月${comment.createdAt.toLocal().day}日 ${comment.createdAt.toLocal().hour.toString().padLeft(2, '0')}:${comment.createdAt.toLocal().minute.toString().padLeft(2, '0')}',
                                        style: const TextStyle(
                                            color: coupleRose, fontSize: 12)),
                                    const SizedBox(height: 3),
                                    Text(comment.content,
                                        style: const TextStyle(height: 1.5)),
                                  ]),
                            ),
                          ]),
                    ),
                  TextField(
                    controller: _comment,
                    enabled: !_busy,
                    onChanged: (_) => setState(() {}),
                    maxLength: 1000,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: '写一句评论…',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      onPressed: _busy || _comment.text.trim().isEmpty
                          ? null
                          : _sendComment,
                      icon: const Icon(Icons.send_rounded, size: 17),
                      label: Text(_busy ? '发送中…' : '发送'),
                    ),
                  ),
                ]),
          ),
        ],
      ),
    );
  }

  Widget _section({String? title, required Widget child}) => Card(
        color: couplePaper,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (title != null) ...[
              Text(title,
                  style: const TextStyle(
                      color: coupleInk,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
            ],
            child,
          ]),
        ),
      );

  Widget _reflectionCard(CoupleConflictReflection reflection, String title) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: _conflictSoft, borderRadius: BorderRadius.circular(12)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    color: _conflictGreen, fontWeight: FontWeight.w600)),
            _reflectionLine('发生了什么', reflection.observations),
            _reflectionLine('当时的感受', reflection.feelings),
            _reflectionLine('在意或需要', reflection.needs),
            _reflectionLine('自己的部分', reflection.myPart),
            _reflectionLine('下次的请求', reflection.request),
          ]),
        ),
      );

  Widget _reflectionLine(String label, String value) => value.trim().isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 7),
          child: Text('$label：$value', style: const TextStyle(height: 1.5)),
        );

  Widget _promptField(
          String label, String hint, TextEditingController controller,
          {int maxLines = 2, int maxLength = 3000}) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: TextField(
          controller: controller,
          enabled: !_busy,
          onChanged: (_) => setState(() {}),
          maxLength: maxLength,
          minLines: maxLines,
          maxLines: maxLines + 1,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}

class _ConflictCreateDialog extends StatefulWidget {
  const _ConflictCreateDialog({required this.api, required this.date});
  final CoupleApi api;
  final DateTime date;

  @override
  State<_ConflictCreateDialog> createState() => _ConflictCreateDialogState();
}

class _ConflictCreateDialogState extends State<_ConflictCreateDialog> {
  final _title = TextEditingController();
  final _summary = TextEditingController();
  final _requestId = CoupleApi.requestId();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_title.text.trim().isEmpty) {
      setState(() => _error = '请先填写争执主题');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final id = await widget.api.createConflict(
          date: widget.date,
          title: _title.text,
          summary: _summary.text,
          requestId: _requestId);
      if (mounted) Navigator.pop(context, id);
    } catch (error) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = coupleError(error);
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_saving,
        child: AlertDialog(
          scrollable: true,
          title: const Text('记录一次争执'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('日期：${dateKey(widget.date)}'),
            const SizedBox(height: 10),
            TextField(
                controller: _title,
                enabled: !_saving,
                autofocus: true,
                maxLength: 120,
                decoration: const InputDecoration(
                    labelText: '争执主题', hintText: '例如：周末安排')),
            TextField(
                controller: _summary,
                enabled: !_saving,
                maxLength: 3000,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                    labelText: '起因或经过（选填）',
                    hintText: '先记下当时发生了什么',
                    alignLabelWithHint: true)),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
          actions: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '保存中…' : '创建记录')),
          ],
        ),
      );
}

DateTime _monthOf(DateTime date) => DateTime(date.year, date.month);
