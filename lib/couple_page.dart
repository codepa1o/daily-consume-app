import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'couple_effects.dart';
import 'data/api_client.dart';
import 'data/app_database.dart' show dateKey;
import 'data/couple.dart';
import 'data/journal.dart' show journalToday;

List<XFile>? recoveredCouplePhotos;

Future<void> recoverCouplePhoto() async {
  if (kIsWeb) return;
  try {
    final lost = await ImagePicker().retrieveLostData();
    recoveredCouplePhotos = lost.files?.take(9).toList();
  } on PlatformException {
    // A cancelled/failed picker never blocks account restoration.
  }
}

class CouplePage extends StatefulWidget {
  const CouplePage({super.key, this.api});
  final CoupleApi? api;
  @override
  State<CouplePage> createState() => _CouplePageState();
}

class _CouplePageState extends State<CouplePage> with WidgetsBindingObserver {
  late final api = widget.api ?? CoupleApi.instance;
  final owner = ApiClient.instance.account?.id;
  CoupleSpace? space;
  List<CoupleMemory> memories = [];
  bool loading = true,
      busy = false,
      hasMore = false,
      loadingMore = false,
      sky = false;
  String? error;
  int loadVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ModalRoute.of(context)?.isCurrent == true &&
        !busy) reload();
  }

  Future<void> reload() async {
    final version = ++loadVersion;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await api.space();
      final rows = value == null ? null : await api.memories();
      if (!mounted ||
          version != loadVersion ||
          ApiClient.instance.account?.id != owner) return;
      setState(() {
        space = value;
        memories = rows == null ? [] : _rows(rows);
        hasMore = rows?['has_more'] as bool? ?? false;
        loading = false;
      });
    } catch (failure) {
      if (mounted && version == loadVersion)
        setState(() {
          loading = false;
          error = coupleError(failure);
        });
    }
  }

  List<CoupleMemory> _rows(Map<String, dynamic> data) => (data['items'] as List)
      .map((e) => CoupleMemory.fromJson(Map<String, dynamic>.from(e as Map)))
      .toList();
  Future<void> more() async {
    if (loadingMore || !hasMore) return;
    final version = loadVersion;
    setState(() => loadingMore = true);
    try {
      final rows = await api.memories(offset: memories.length);
      if (!mounted || version != loadVersion) return;
      setState(() {
        final known = memories.map((m) => m.id).toSet();
        memories.addAll(_rows(rows).where((m) => known.add(m.id)));
        hasMore = rows['has_more'] as bool;
      });
    } catch (failure) {
      if (mounted) _message(coupleError(failure));
    } finally {
      if (mounted) setState(() => loadingMore = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> invite() async {
    setState(() => busy = true);
    try {
      final value = await api.invite();
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('邀请另一半'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('让对方在“我的 → 情侣空间”输入邀请码，确认加入。'),
                    const SizedBox(height: 20),
                    SelectableText(value['code'] as String,
                        style: const TextStyle(
                            fontSize: 25,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 12),
                    const Text('7 天有效；生成新邀请码会使旧码失效。',
                        style: TextStyle(fontSize: 12)),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭')),
                    FilledButton(
                        onPressed: () async {
                          await Clipboard.setData(
                              ClipboardData(text: value['code'] as String));
                          if (context.mounted)
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('邀请码已复制')));
                        },
                        child: const Text('复制邀请码'))
                  ]));
    } catch (failure) {
      if (mounted) _message(coupleError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> add() async {
    final saved = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => CoupleEditor(api: api)));
    if (saved == true && mounted) await reload();
  }

  Future<void> continuePhoto() async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) =>
            CoupleEditor(recoveredPhotos: recoveredCouplePhotos, api: api)));
    if (saved == true && mounted) {
      recoveredCouplePhotos = null;
      await reload();
    }
  }

  Future<void> changeAnniversary() async {
    final current = space!;
    final value = await showDatePicker(
      context: context,
      initialDate: current.since,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      helpText: '选择恋爱纪念日',
      cancelText: '取消',
      confirmText: '保存日期',
    );
    if (value == null || !mounted) return;
    setState(() => busy = true);
    try {
      await api.updateAnniversary(value);
      final updated = await api.space();
      if (!mounted) return;
      setState(() => space = updated);
      _message('恋爱纪念日已更新');
    } catch (failure) {
      if (mounted) _message(coupleError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> open(CoupleMemory memory) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) =>
            CoupleDetail(memory: memory, memories: memories, api: api)));
    if (mounted) await reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: const Color(0xfff6f0e6),
      appBar: AppBar(
          title: const Text('情侣空间'),
          backgroundColor: couplePaper,
          actions: [
            IconButton(
                onPressed: loading ? null : reload,
                icon: const Icon(Icons.refresh),
                tooltip: '刷新回忆')
          ]),
      floatingActionButton: space == null || loading || error != null
          ? null
          : FloatingActionButton.extended(
              onPressed: add,
              backgroundColor: coupleRose,
              foregroundColor: couplePaper,
              icon: const Icon(Icons.add),
              label: const Text('留下一刻')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? _CoupleFailure(message: error!, retry: reload)
              : space == null
                  ? _CoupleSetup(onJoined: reload, api: api)
                  : RefreshIndicator(
                      onRefresh: reload,
                      child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
                          children: [
                            const Text('OUR LITTLE MOMENTS',
                                style: TextStyle(
                                    color: coupleRose,
                                    fontSize: 11,
                                    letterSpacing: 2)),
                            const SizedBox(height: 8),
                            Text(space!.title,
                                style: const TextStyle(
                                    color: coupleInk,
                                    fontSize: 29,
                                    fontFamily: 'serif')),
                            const SizedBox(height: 14),
                            Material(
                                color: const Color(0xfffff3e9),
                                borderRadius: BorderRadius.circular(18),
                                child: InkWell(
                                    borderRadius: BorderRadius.circular(18),
                                    onTap: busy ? null : changeAnniversary,
                                    child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 18, vertical: 16),
                                        child: Row(children: [
                                          const Icon(Icons.favorite,
                                              color: coupleRose, size: 22),
                                          const SizedBox(width: 14),
                                          Expanded(
                                              child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                Text(
                                                    space!.timeTogether ==
                                                            '今天开始'
                                                        ? '从今天开始'
                                                        : '相恋 ${space!.timeTogether}',
                                                    style: const TextStyle(
                                                        color: coupleInk,
                                                        fontFamily: 'serif',
                                                        fontSize: 24)),
                                                const SizedBox(height: 4),
                                                Text(
                                                    '在一起的第 ${space!.daysTogether} 天 · ${dateKey(space!.since)}',
                                                    style: const TextStyle(
                                                        color: coupleRose,
                                                        fontSize: 13)),
                                              ])),
                                          const Icon(Icons.calendar_month,
                                              color: coupleRose, size: 20),
                                        ])))),
                            const SizedBox(height: 12),
                            Text(
                                space!.members.map((m) => m.name).join('  &  '),
                                style: const TextStyle(color: coupleInk)),
                            if (space!.members.length == 1)
                              Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: Card(
                                      color: couplePaper,
                                      child: ListTile(
                                          leading: const Icon(
                                              Icons.favorite_border,
                                              color: coupleRose),
                                          title: const Text('小窝准备好了，等另一半到来'),
                                          subtitle:
                                              const Text('加入后可以看到这里的全部照片与记录'),
                                          trailing:
                                              const Icon(Icons.chevron_right),
                                          onTap: busy ? null : invite))),
                            if (recoveredCouplePhotos?.isNotEmpty == true)
                              Card(
                                  color: couplePaper,
                                  child: Padding(
                                      padding: const EdgeInsets.all(14),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                                '发现上次选择的 ${recoveredCouplePhotos!.length} 张未发布照片'),
                                            const Text('确认后可以继续编辑，不会自动上传。',
                                                style: TextStyle(fontSize: 12)),
                                            Wrap(spacing: 8, children: [
                                              TextButton(
                                                  onPressed: continuePhoto,
                                                  child: const Text('继续使用')),
                                              TextButton(
                                                  onPressed: () => setState(() =>
                                                      recoveredCouplePhotos =
                                                          null),
                                                  child: const Text('忽略'))
                                            ]),
                                          ]))),
                            const SizedBox(height: 22),
                            Row(children: [
                              Expanded(
                                  child: Text(sky ? '我们的回忆星空' : '一起攒下的日常',
                                      style: const TextStyle(
                                          color: coupleInk, fontSize: 18))),
                              TextButton.icon(
                                  onPressed: () => setState(() => sky = !sky),
                                  icon: Icon(sky
                                      ? Icons.photo_album_outlined
                                      : Icons.auto_awesome),
                                  label: Text(sky ? '回忆册' : '星空')),
                            ]),
                            if (sky) ...[
                              for (var i = 0;
                                  i < memories.length ||
                                      (i == 0 && memories.isEmpty);
                                  i += 12)
                                Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: CoupleSky(
                                        memories:
                                            memories.skip(i).take(12).toList(),
                                        onSelected: open)),
                            ] else if (memories.isEmpty)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 40),
                                  child: Column(children: [
                                    const Icon(Icons.photo_camera_outlined,
                                        color: coupleRose, size: 42),
                                    const SizedBox(height: 18),
                                    const Text('这里还没有回忆',
                                        style: TextStyle(
                                            fontSize: 20, color: coupleInk)),
                                    const SizedBox(height: 8),
                                    const Text('一张照片、一句留言，或者今天的心情。',
                                        textAlign: TextAlign.center),
                                    const SizedBox(height: 20),
                                    FilledButton(
                                        onPressed: add,
                                        child: const Text('留下第一段回忆')),
                                  ]))
                            else ...[
                              LayoutBuilder(builder: (context, constraints) {
                                final columns =
                                    constraints.maxWidth >= 980 ? 2 : 1;
                                const gap = 16.0;
                                final width = columns == 1
                                    ? constraints.maxWidth
                                    : (constraints.maxWidth - gap) / 2;
                                return Wrap(
                                  spacing: gap,
                                  runSpacing: gap,
                                  children: [
                                    for (final day
                                        in coupleTimelineDays(memories))
                                      SizedBox(
                                          width: width,
                                          child: _timelineDay(day)),
                                  ],
                                );
                              }),
                            ],
                            if (hasMore)
                              TextButton(
                                  onPressed: loadingMore ? null : more,
                                  child:
                                      Text(loadingMore ? '正在加载…' : '查看更多回忆')),
                          ])));

  Widget _timelineDay(CoupleTimelineDay day) => Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: 8,
            top: 16,
            bottom: -22,
            child: Container(width: 2, color: const Color(0xffe2c8bd)),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: coupleRose,
                  shape: BoxShape.circle,
                  border: Border.all(color: couplePaper, width: 3),
                ),
              ),
              const SizedBox(width: 13),
              Text(dateKey(day.date).replaceAll('-', '.'),
                  style: const TextStyle(
                      color: coupleInk, fontSize: 18, fontFamily: 'serif')),
              const SizedBox(width: 10),
              Text('${day.memories.length} 段回忆',
                  style: const TextStyle(color: coupleRose, fontSize: 12)),
            ]),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Column(children: [
                for (var i = 0; i < day.memories.length; i++) ...[
                  if (i > 0) const SizedBox(height: 14),
                  Semantics(
                    button: true,
                    label: '打开回忆：${day.memories[i].title}',
                    child: InkWell(
                      onTap: () => open(day.memories[i]),
                      child: CouplePolaroid(memory: day.memories[i], api: api),
                    ),
                  ),
                ],
              ]),
            ),
          ]),
        ]),
      );
}

class _CoupleSetup extends StatefulWidget {
  const _CoupleSetup({required this.onJoined, required this.api});
  final Future<void> Function() onJoined;
  final CoupleApi api;
  @override
  State<_CoupleSetup> createState() => _CoupleSetupState();
}

class _CoupleSetupState extends State<_CoupleSetup> {
  final title = TextEditingController(text: '两个人的小窝');
  final code = TextEditingController();
  DateTime since = journalToday();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() task) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await task();
    } catch (failure) {
      if (mounted) setState(() => error = coupleError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(24), children: [
        const Icon(Icons.favorite_border, size: 48, color: coupleRose),
        const SizedBox(height: 16),
        const Text('留一个地方，给我们',
            textAlign: TextAlign.center,
            style:
                TextStyle(fontFamily: 'serif', fontSize: 28, color: coupleInk)),
        const SizedBox(height: 10),
        const Text('一起保存照片、记录生活，发现对方留下的小惊喜。', textAlign: TextAlign.center),
        const SizedBox(height: 28),
        TextField(
            controller: title,
            enabled: !busy,
            maxLength: 60,
            decoration: const InputDecoration(
                labelText: '空间名称', border: OutlineInputBorder())),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_month),
            title: const Text('在一起的日期'),
            subtitle: Text(dateKey(since)),
            onTap: busy
                ? null
                : () async {
                    final value = await showDatePicker(
                        context: context,
                        initialDate:
                            DateTime(since.year, since.month, since.day),
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now());
                    if (value != null && mounted) setState(() => since = value);
                  }),
        FilledButton(
            onPressed: busy
                ? null
                : () => run(() async {
                      if (title.text.trim().isEmpty)
                        throw const ApiException('请填写空间名称');
                      await widget.api.create(title.text, since);
                      await widget.onJoined();
                    }),
            child: const Text('创建我们的小窝')),
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 24), child: Divider()),
        TextField(
            controller: code,
            enabled: !busy,
            maxLength: 12,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
                labelText: '另一半给你的邀请码', border: OutlineInputBorder())),
        OutlinedButton(
            onPressed: busy
                ? null
                : () => run(() async {
                      final inviteCode = code.text.trim().toUpperCase();
                      if (!RegExp(r'^[A-Z0-9]{12}$').hasMatch(inviteCode))
                        throw const ApiException('请输入 12 位邀请码');
                      final preview = await widget.api.preview(inviteCode);
                      if (!context.mounted) return;
                      final agreed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                                  title: Text('加入“${preview['title']}”？'),
                                  content: Text(
                                      '${preview['inviter']} 邀请你加入。\n在一起的日期：${preview['since_date']}\n\n加入后，双方可以查看这个空间已有及新发布的照片、记录和留言。'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: const Text('取消')),
                                    FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: const Text('确认加入'))
                                  ]));
                      if (agreed != true) return;
                      await widget.api.join(inviteCode);
                      await widget.onJoined();
                    }),
            child: const Text('查看邀请并加入')),
        if (busy)
          const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator())),
        if (error != null)
          Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
      ]);
}

class CoupleEditor extends StatefulWidget {
  const CoupleEditor({super.key, this.recoveredPhotos, this.api});
  final List<XFile>? recoveredPhotos;
  final CoupleApi? api;
  @override
  State<CoupleEditor> createState() => _CoupleEditorState();
}

class _CoupleEditorState extends State<CoupleEditor> {
  final title = TextEditingController(), content = TextEditingController();
  final requestId = CoupleApi.requestId();
  final form = GlobalKey<FormState>();
  final photos = <Uint8List>[];
  final photoPageController = PageController();
  DateTime date = journalToday();
  String mood = '', displayMode = 'grid';
  int currentPhoto = 0;
  bool busy = false, saved = false, dirty = false;
  String? error;
  @override
  void initState() {
    super.initState();
    title.addListener(_changed);
    content.addListener(_changed);
    final recovered = widget.recoveredPhotos;
    if (recovered != null && recovered.isNotEmpty) {
      busy = true;
      _read(recovered.take(9).toList()).whenComplete(() {
        if (mounted) setState(() => busy = false);
      });
    }
  }

  void _changed() {
    if (!dirty && mounted) setState(() => dirty = true);
  }

  void showCurrentPhoto() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && photoPageController.hasClients && photos.isNotEmpty) {
        photoPageController.jumpToPage(currentPhoto);
      }
    });
  }

  @override
  void dispose() {
    title.dispose();
    content.dispose();
    photoPageController.dispose();
    super.dispose();
  }

  Future<void> _read(List<XFile> files) async {
    try {
      if (photos.length + files.length > 9)
        throw const ApiException('一段回忆最多添加 9 张照片');
      var totalBytes = photos.fold<int>(0, (sum, photo) => sum + photo.length);
      final selected = <Uint8List>[];
      for (final file in files) {
        final length = await file.length();
        if (length > 8 * 1024 * 1024) throw const ApiException('单张照片不能超过 8 MB');
        if (totalBytes + length > 12 * 1024 * 1024)
          throw const ApiException('一段回忆的照片总大小不能超过 12 MB');
        final bytes = await file.readAsBytes();
        totalBytes += bytes.length;
        selected.add(bytes);
      }
      if (selected.isEmpty) return;
      if (mounted)
        setState(() {
          photos.addAll(selected);
          currentPhoto = photos.length - 1;
          dirty = true;
          error = null;
        });
      showCurrentPhoto();
    } catch (failure) {
      if (mounted) setState(() => error = coupleError(failure));
    }
  }

  Future<void> pick() async {
    final remaining = 9 - photos.length;
    if (remaining <= 0) {
      setState(() => error = '一段回忆最多添加 9 张照片');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final files = await ImagePicker().pickMultiImage(
          limit: remaining,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 85,
          requestFullMetadata: false);
      if (files.isNotEmpty) await _read(files);
    } catch (failure) {
      if (mounted) setState(() => error = '照片选择失败，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await (widget.api ?? CoupleApi.instance).save(
          requestId: requestId,
          date: date,
          title: title.text,
          content: content.text,
          mood: mood,
          photos: photos,
          displayMode: displayMode);
      if (!mounted) return;
      setState(() {
        saved = true;
        busy = false;
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        final message = coupleError(failure);
        setState(() {
          busy = false;
          error = message;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  void removePhoto(int index) {
    setState(() {
      photos.removeAt(index);
      if (index < currentPhoto) currentPhoto--;
      if (currentPhoto >= photos.length) currentPhoto = photos.length - 1;
      if (currentPhoto < 0) currentPhoto = 0;
      dirty = true;
    });
    showCurrentPhoto();
  }

  Widget photoPreview() {
    if (photos.isEmpty) return const SizedBox.shrink();
    Widget image(int index) => Image.memory(photos[index],
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const ColoredBox(
            color: Color(0xffeee4d8), child: Center(child: Text('当前照片无法预览'))));
    if (displayMode == 'grid') {
      return GridView.builder(
        shrinkWrap: true,
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: photos.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
        itemBuilder: (context, index) => ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(fit: StackFit.expand, children: [
              image(index),
              Positioned(
                  top: 2,
                  right: 2,
                  child: IconButton.filledTonal(
                      tooltip: '移除第 ${index + 1} 张照片',
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                          backgroundColor: const Color(0xccfffaf2),
                          foregroundColor: coupleInk),
                      onPressed: busy ? null : () => removePhoto(index),
                      icon: const Icon(Icons.close, size: 18)))
            ])),
      );
    }
    return SizedBox(
        height: 226,
        child: Stack(alignment: Alignment.center, children: [
          for (var layer = 2; layer >= 1; layer--)
            if (photos.length > currentPhoto + layer)
              Positioned(
                  left: 8.0 * layer,
                  right: 8.0 * layer,
                  top: 5.0 * layer,
                  bottom: 5.0 * layer,
                  child: Transform.rotate(
                      angle: layer * .018,
                      child: Container(
                          decoration: BoxDecoration(
                              color: couplePaper,
                              border:
                                  Border.all(color: const Color(0xffeadfd0))),
                          padding: const EdgeInsets.all(5),
                          child: image(currentPhoto + layer)))),
          PageView.builder(
              controller: photoPageController,
              itemCount: photos.length,
              onPageChanged: (index) => setState(() => currentPhoto = index),
              itemBuilder: (_, index) => Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
                  child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: image(index)))),
          Positioned(
              top: 6,
              right: 16,
              child: IconButton.filledTonal(
                  tooltip: '移除当前照片',
                  onPressed: busy ? null : () => removePhoto(currentPhoto),
                  icon: const Icon(Icons.close))),
          Positioned(
              right: 22,
              bottom: 20,
              child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: const Color(0xcc292621),
                      borderRadius: BorderRadius.circular(20)),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      child: Text('${currentPhoto + 1} / ${photos.length}',
                          style: const TextStyle(
                              color: couplePaper, fontSize: 12)))))
        ]));
  }

  Future<void> discard() async {
    if (busy) return;
    final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('放弃这段未保存的回忆？'),
                content: const Text('照片和文字尚未保存到服务器。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('继续编辑')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('放弃'))
                ]));
    if (leave == true && mounted) {
      setState(() => dirty = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: saved || (!dirty && !busy),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !busy) discard();
      },
      child: Scaffold(
          backgroundColor: couplePaper,
          appBar: AppBar(title: const Text('留下一刻'), actions: [
            TextButton(
                onPressed: busy ? null : save,
                child: Text(busy ? '保存中…' : '保存'))
          ]),
          body: Form(
              key: form,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: ListView(padding: const EdgeInsets.all(20), children: [
                    Row(children: [
                      const Text('照片展示方式'),
                      const Spacer(),
                      Text('${photos.length} / 9 张',
                          style: const TextStyle(color: Color(0xff877267))),
                    ]),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, children: [
                      ChoiceChip(
                          label: const Text('九宫格'),
                          avatar: const Icon(Icons.grid_view, size: 18),
                          selected: displayMode == 'grid',
                          onSelected: busy
                              ? null
                              : (_) {
                                  setState(() {
                                    displayMode = 'grid';
                                    dirty = true;
                                  });
                                  showCurrentPhoto();
                                }),
                      ChoiceChip(
                          label: const Text('滑动相册'),
                          avatar: const Icon(Icons.view_carousel_outlined,
                              size: 18),
                          selected: displayMode == 'swipe',
                          onSelected: busy
                              ? null
                              : (_) {
                                  setState(() {
                                    displayMode = 'swipe';
                                    dirty = true;
                                  });
                                  showCurrentPhoto();
                                }),
                    ]),
                    const SizedBox(height: 10),
                    photoPreview(),
                    if (photos.isNotEmpty) const SizedBox(height: 10),
                    Wrap(spacing: 8, children: [
                      OutlinedButton.icon(
                          onPressed: busy || photos.length >= 9 ? null : pick,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: Text(photos.isEmpty ? '添加照片' : '继续添加')),
                    ]),
                    const SizedBox(height: 16),
                    TextFormField(
                        controller: title,
                        enabled: !busy,
                        maxLength: 100,
                        decoration: const InputDecoration(
                            labelText: '给这一刻起个名字',
                            border: OutlineInputBorder()),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? '请写一个标题' : null),
                    const SizedBox(height: 12),
                    TextFormField(
                        controller: content,
                        enabled: !busy,
                        minLines: 5,
                        maxLines: 12,
                        maxLength: 5000,
                        decoration: const InputDecoration(
                            labelText: '今天发生了什么，或想对另一半说什么？',
                            alignLabelWithHint: true,
                            border: OutlineInputBorder())),
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.calendar_month),
                        title: const Text('回忆日期'),
                        subtitle: Text(dateKey(date)),
                        onTap: busy
                            ? null
                            : () async {
                                final value = await showDatePicker(
                                    context: context,
                                    initialDate: DateTime(
                                        date.year, date.month, date.day),
                                    firstDate: DateTime(2000),
                                    lastDate: DateTime.now());
                                if (value != null && mounted)
                                  setState(() {
                                    date = value;
                                    dirty = true;
                                  });
                              }),
                    const Text('今天的心情'),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      for (final value in ['开心', '平静', '想你', '疲惫', '难过'])
                        ChoiceChip(
                            label: Text(value),
                            selected: mood == value,
                            onSelected: busy
                                ? null
                                : (selected) => setState(() {
                                      mood = selected ? value : '';
                                      dirty = true;
                                    })),
                    ]),
                    const SizedBox(height: 18),
                    const Text('保存后，你们都可以看到。照片会转换成浏览图，移除定位等附加信息。',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xff877267))),
                    if (error != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                    const SizedBox(height: 20),
                    FilledButton(
                        onPressed: busy ? null : save,
                        child: Text(busy ? '保存中…' : '保存到我们的小窝')),
                  ]),
                ),
              ))));
}

class CoupleDetail extends StatefulWidget {
  const CoupleDetail(
      {super.key, required this.memory, required this.memories, this.api});
  final CoupleMemory memory;
  final List<CoupleMemory> memories;
  final CoupleApi? api;
  @override
  State<CoupleDetail> createState() => _CoupleDetailState();
}

class _CoupleDetailState extends State<CoupleDetail>
    with WidgetsBindingObserver {
  late final api = widget.api ?? CoupleApi.instance;
  final comment = TextEditingController();
  String commentRequestId = CoupleApi.requestId();
  Map<String, dynamic>? detail;
  String? error, actionError;
  int effect = 0, revision = 0;
  bool busy = false, scratchRevealed = false;
  late Future<List<CoupleMemory>> pair = api.pair(widget.memory.publishedDate);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    comment.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ModalRoute.of(context)?.isCurrent == true &&
        !busy) reload();
  }

  Future<void> reload() async {
    final version = ++revision;
    try {
      final value = await api.detail(widget.memory.id);
      if (mounted && version == revision)
        setState(() {
          detail = value;
          error = null;
        });
    } catch (failure) {
      if (mounted && version == revision)
        setState(() => error = coupleError(failure));
    }
  }

  Future<void> action(Future<void> Function() task) async {
    if (busy) return;
    setState(() {
      busy = true;
      actionError = null;
    });
    try {
      await task();
    } catch (failure) {
      if (mounted) setState(() => actionError = coupleError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> delete() async {
    final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('删除这段回忆？'),
                content: const Text('这张照片、记录、留言和互动会一起删除，双方都无法再查看。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (agreed != true || !mounted) return;
    await action(() async {
      await api.delete(widget.memory.id);
      if (mounted) Navigator.pop(context);
    });
  }

  Widget _effect(CoupleMemory memory, List<dynamic> comments) {
    final front = CouplePolaroid(memory: memory, full: true, api: api);
    switch (effect) {
      case 0:
        return CoupleDevelop(
            key: ValueKey('develop-${memory.id}'), child: front);
      case 1:
        return CoupleFlip(
            key: ValueKey('flip-${memory.id}'),
            front: front,
            back: Container(
                width: double.infinity,
                constraints: const BoxConstraints(minHeight: 300),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                    color: couplePaper,
                    border: Border.all(color: const Color(0xffeadfd0))),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('留给你的话',
                          style: TextStyle(fontSize: 13, color: coupleRose)),
                      const SizedBox(height: 18),
                      Text(
                          memory.content.isEmpty
                              ? '这张照片里，有我们一起度过的一刻。'
                              : memory.content,
                          style: const TextStyle(
                              fontFamily: 'serif',
                              fontSize: 18,
                              height: 1.8,
                              color: coupleInk)),
                      if (comments.isNotEmpty) ...[
                        const Divider(height: 32),
                        Text('${comments.last['author_name']} 留言：'),
                        const SizedBox(height: 8),
                        Text(comments.last['content'] as String,
                            style:
                                const TextStyle(color: coupleInk, height: 1.7))
                      ],
                    ])));
      case 2:
        return FutureBuilder<List<CoupleMemory>>(
            future: pair,
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return _CoupleFailure(
                    message: coupleError(snapshot.error!),
                    retry: () =>
                        setState(() => pair = api.pair(memory.publishedDate)));
              if (!snapshot.hasData)
                return const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()));
              final rows = couplePair(snapshot.data!, memory.publishedDate);
              if (rows.length < 2)
                return Column(children: [
                  front,
                  const SizedBox(height: 16),
                  const Text('等你们在同一天各发布一张照片，就能拼成“今天的我们”。',
                      textAlign: TextAlign.center)
                ]);
              return Column(children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (var i = 0; i < rows.length; i++)
                    Expanded(
                        child: Padding(
                            padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
                            child: Transform.rotate(
                                angle: i == 0 ? -.04 : .04,
                                child: Container(
                                    padding: const EdgeInsets.all(8),
                                    color: couplePaper,
                                    child: Column(children: [
                                      CouplePhoto(
                                          memory: rows[i],
                                          height: 160,
                                          api: api),
                                      const SizedBox(height: 10),
                                      Text(rows[i].author,
                                          textAlign: TextAlign.center),
                                      Text(rows[i].title,
                                          maxLines: 2,
                                          textAlign: TextAlign.center,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 12)),
                                    ])))))
                ]),
                const SizedBox(height: 16),
                Text('${dateKey(memory.date)} · 今天的我们'),
              ]);
            });
      case 3:
        return CoupleScratch(
            key: ValueKey('scratch-${memory.id}'),
            child: front,
            onRevealed: (value) => setState(() => scratchRevealed = value));
      case 4:
        return CoupleSky(
            memories: widget.memories,
            onSelected: (selected) {
              Navigator.of(context).push<void>(MaterialPageRoute(
                  builder: (_) => CoupleDetail(
                      memory: selected, memories: widget.memories, api: api)));
            });
      default:
        return CoupleDepth(key: ValueKey('depth-${memory.id}'), child: front);
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = detail;
    final memory = row == null ? widget.memory : CoupleMemory.fromJson(row);
    final comments = row?['comments'] as List? ?? [];
    final reactions = row?['reactions'] as List? ?? [];
    final mine = reactions
        .where((r) => r['user_id'] == ApiClient.instance.account?.id)
        .firstOrNull;
    return Scaffold(
        backgroundColor: const Color(0xfff6f0e6),
        appBar: AppBar(
            title: const Text('我们的回忆'),
            backgroundColor: couplePaper,
            actions: [
              IconButton(
                  onPressed: busy ? null : reload,
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新留言'),
              if (memory.authorId == ApiClient.instance.account?.id)
                IconButton(
                    onPressed: busy ? null : delete,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '删除自己的回忆'),
            ]),
        body: error != null
            ? _CoupleFailure(message: error!, retry: reload)
            : detail == null
                ? const Center(child: CircularProgressIndicator())
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            DropdownButtonFormField<int>(
                                initialValue: effect,
                                decoration: const InputDecoration(
                                    labelText: '照片玩法',
                                    border: OutlineInputBorder()),
                                items: [
                                  for (var i = 0; i < coupleEffects.length; i++)
                                    DropdownMenuItem(
                                        value: i, child: Text(coupleEffects[i]))
                                ],
                                onChanged: (value) {
                                  if (value != null)
                                    setState(() {
                                      effect = value;
                                      scratchRevealed = false;
                                    });
                                }),
                            const SizedBox(height: 28),
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                child: _effect(memory, comments)),
                            const SizedBox(height: 24),
                            if (memory.mood.isNotEmpty)
                              Text('${memory.author}的心情：${memory.mood}',
                                  style: const TextStyle(color: coupleRose)),
                            if (memory.content.isNotEmpty &&
                                effect != 1 &&
                                (effect != 3 || scratchRevealed))
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  child: Text(memory.content,
                                      style: const TextStyle(
                                          color: coupleInk, height: 1.8))),
                            const Divider(height: 32),
                            Wrap(spacing: 8, runSpacing: 6, children: [
                              for (final emoji in ['❤️', '抱抱', '想你', '开心'])
                                ChoiceChip(
                                    label: Text(emoji),
                                    selected: mine?['emoji'] == emoji,
                                    onSelected: busy
                                        ? null
                                        : (selected) => action(() async {
                                              await api.react(memory.id,
                                                  selected ? emoji : null);
                                              await reload();
                                            }))
                            ]),
                            if (reactions.isNotEmpty)
                              Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Text(
                                      reactions
                                          .map((r) =>
                                              '${r['author_name']}：${r['emoji']}')
                                          .join('  '),
                                      style: const TextStyle(
                                          color: coupleRose, fontSize: 12))),
                            const SizedBox(height: 24),
                            const Text('照片背后的留言',
                                style:
                                    TextStyle(fontSize: 18, color: coupleInk)),
                            const SizedBox(height: 12),
                            if (comments.isEmpty)
                              const Text('还没有留言，给另一半留一句话吧。',
                                  style: TextStyle(color: Color(0xff877267))),
                            for (final entry in comments)
                              Card(
                                  color: couplePaper,
                                  child: Padding(
                                      padding: const EdgeInsets.all(14),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(entry['author_name'] as String,
                                                style: const TextStyle(
                                                    color: coupleRose,
                                                    fontSize: 12)),
                                            const SizedBox(height: 6),
                                            Text(entry['content'] as String,
                                                style: const TextStyle(
                                                    height: 1.6)),
                                          ]))),
                            const SizedBox(height: 14),
                            TextField(
                                controller: comment,
                                enabled: !busy,
                                minLines: 2,
                                maxLines: 5,
                                maxLength: 1000,
                                decoration: const InputDecoration(
                                    hintText: '想对你说…',
                                    border: OutlineInputBorder())),
                            Align(
                                alignment: Alignment.centerRight,
                                child: FilledButton(
                                    onPressed: busy
                                        ? null
                                        : () => action(() async {
                                              if (comment.text.trim().isEmpty)
                                                throw const ApiException(
                                                    '请先写下留言');
                                              await api.comment(
                                                  memory.id,
                                                  comment.text,
                                                  commentRequestId);
                                              comment.clear();
                                              commentRequestId =
                                                  CoupleApi.requestId();
                                              await reload();
                                            }),
                                    child: Text(busy ? '保存中…' : '留下这句话'))),
                            if (actionError != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Text(actionError!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                          ]),
                    ),
                  ));
  }
}

class _CoupleFailure extends StatelessWidget {
  const _CoupleFailure({required this.message, required this.retry});
  final String message;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_outlined),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton(onPressed: retry, child: const Text('重试'))
          ])));
}
