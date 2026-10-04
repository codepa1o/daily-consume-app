import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'data/couple.dart';
import 'data/app_database.dart' show dateKey;

const couplePaper = Color(0xfffffaf2);
const coupleInk = Color(0xff58453d);
const coupleRose = Color(0xffa45c50);

class CouplePhoto extends StatefulWidget {
  const CouplePhoto(
      {super.key,
      required this.memory,
      this.api,
      this.thumbnail = true,
      this.height = 220});
  final CoupleMemory memory;
  final CoupleApi? api;
  final bool thumbnail;
  final double height;
  @override
  State<CouplePhoto> createState() => _CouplePhotoState();
}

class _CouplePhotoState extends State<CouplePhoto> {
  late Future<Uint8List> photo;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    photo = widget.memory.hasPhoto
        ? (widget.api ?? CoupleApi.instance)
            .photo(widget.memory.id, thumbnail: widget.thumbnail)
        : Future.value(Uint8List(0));
  }

  @override
  void didUpdateWidget(CouplePhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.memory.id != widget.memory.id ||
        oldWidget.thumbnail != widget.thumbnail ||
        oldWidget.api != widget.api ||
        oldWidget.memory.hasPhoto != widget.memory.hasPhoto) _load();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
      height: widget.height,
      width: double.infinity,
      child: widget.memory.hasPhoto
          ? FutureBuilder<Uint8List>(
              future: photo,
              builder: (context, snapshot) {
                if (snapshot.hasData)
                  return Image.memory(snapshot.data!,
                      fit: BoxFit.cover,
                      gaplessPlayback: false,
                      semanticLabel: widget.memory.title,
                      errorBuilder: (_, __, ___) =>
                          const Center(child: Text('照片无法显示')));
                if (snapshot.hasError)
                  return ColoredBox(
                      color: const Color(0xffeee4d8),
                      child: Center(
                          child: TextButton.icon(
                              onPressed: () => setState(_load),
                              icon: const Icon(Icons.refresh),
                              label: const Text('重试照片'))));
                return const ColoredBox(
                    color: Color(0xffeee4d8),
                    child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2)));
              })
          : ColoredBox(
              color: const Color(0xffeee4d8),
              child: Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                          widget.memory.content.isEmpty
                              ? widget.memory.title
                              : widget.memory.content,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: coupleInk, fontSize: 18, height: 1.7))))));
}

class CouplePolaroid extends StatelessWidget {
  const CouplePolaroid(
      {super.key, required this.memory, this.full = false, this.api});
  final CoupleMemory memory;
  final CoupleApi? api;
  final bool full;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      decoration: BoxDecoration(
          color: couplePaper,
          border: Border.all(color: const Color(0xffeadfd0)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x18473522), blurRadius: 18, offset: Offset(0, 7))
          ]),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        CouplePhoto(memory: memory, thumbnail: !full, api: api),
        const SizedBox(height: 14),
        Text(memory.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: coupleInk, fontSize: 18, fontFamily: 'serif')),
        const SizedBox(height: 6),
        Text(
            '${memory.author}${dateKey(memory.date) == dateKey(memory.publishedDate) ? '' : ' · 回忆于 ${dateKey(memory.date)}'}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xff877267), fontSize: 12)),
      ]));
}

class CoupleDevelop extends StatefulWidget {
  const CoupleDevelop({super.key, required this.child});
  final Widget child;
  @override
  State<CoupleDevelop> createState() => _CoupleDevelopState();
}

class _CoupleDevelopState extends State<CoupleDevelop>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2300), value: 1);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedBuilder(
            animation: controller,
            builder: (_, child) => Transform.translate(
                offset: Offset(0, (1 - controller.value) * -16),
                child: Stack(children: [
                  child!,
                  Positioned.fill(
                      child: IgnorePointer(
                          child: ColoredBox(
                              color: couplePaper.withValues(
                                  alpha: 1 - controller.value)))),
                ])),
            child: widget.child),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
            onPressed: () {
              if (MediaQuery.disableAnimationsOf(context)) {
                controller.value = 1;
                return;
              }
              controller.forward(from: 0);
            },
            icon: const Icon(Icons.auto_awesome),
            label: const Text('再显影一次')),
      ]);
}

class CoupleFlip extends StatefulWidget {
  const CoupleFlip({super.key, required this.front, required this.back});
  final Widget front, back;
  @override
  State<CoupleFlip> createState() => _CoupleFlipState();
}

class _CoupleFlipState extends State<CoupleFlip> {
  bool flipped = false;
  @override
  Widget build(BuildContext context) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        TweenAnimationBuilder<double>(
            tween: Tween(end: flipped ? math.pi : 0),
            duration: Duration(
                milliseconds:
                    MediaQuery.disableAnimationsOf(context) ? 0 : 650),
            builder: (_, angle, __) {
              final back = angle > math.pi / 2;
              return Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, .001)
                    ..rotateY(back ? angle - math.pi : angle),
                  child: back ? widget.back : widget.front);
            }),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
            onPressed: () => setState(() => flipped = !flipped),
            icon: const Icon(Icons.flip),
            label: Text(flipped ? '回到照片' : '翻到背面看留言')),
      ]);
}

class CoupleScratch extends StatefulWidget {
  const CoupleScratch({super.key, required this.child, this.onRevealed});
  final Widget child;
  final ValueChanged<bool>? onRevealed;
  @override
  State<CoupleScratch> createState() => _CoupleScratchState();
}

class _CoupleScratchState extends State<CoupleScratch> {
  final strokes = <List<Offset>>[];
  bool revealed = false;
  @override
  Widget build(BuildContext context) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                    onPanStart: revealed
                        ? null
                        : (d) => setState(() => strokes.add([d.localPosition])),
                    onPanUpdate: revealed
                        ? null
                        : (d) => setState(() {
                              if (strokes.isNotEmpty &&
                                  strokes.fold<int>(0, (n, p) => n + p.length) <
                                      2000) {
                                strokes.last.add(d.localPosition);
                              }
                            }),
                    child: Stack(children: [
                      ExcludeSemantics(
                          excluding: !revealed, child: widget.child),
                      if (!revealed)
                        Positioned.fill(
                            child: CustomPaint(
                                painter: _ScratchCover(strokes
                                    .map((s) => List<Offset>.of(s))
                                    .toList()),
                                child: const SizedBox.expand())),
                    ]))),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
                onPressed: () {
                  setState(() {
                    revealed = !revealed;
                    strokes.clear();
                  });
                  widget.onRevealed?.call(revealed);
                },
                icon: Icon(revealed ? Icons.refresh : Icons.card_giftcard),
                label: Text(revealed ? '重新盖上' : '直接打开惊喜')),
          ]);
}

class _ScratchCover extends CustomPainter {
  _ScratchCover(this.strokes);
  final List<List<Offset>> strokes;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 32 || size.height == 0) return;
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = const LinearGradient(
                  colors: [Color(0xffd2aea0), Color(0xffa77b70)])
              .createShader(Offset.zero & size));
    final text = TextPainter(
        text: const TextSpan(
            text: '有个小惊喜给你\n用手指轻轻擦开',
            style: TextStyle(color: couplePaper, fontSize: 20, height: 1.8)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center)
      ..layout(maxWidth: size.width - 32);
    text.paint(canvas,
        Offset((size.width - text.width) / 2, (size.height - text.height) / 2));
    final eraser = Paint()
      ..blendMode = BlendMode.clear
      ..strokeWidth = 42
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (final p in stroke.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      if (stroke.length == 1)
        canvas.drawCircle(
            stroke.first, 21, Paint()..blendMode = BlendMode.clear);
      else
        canvas.drawPath(path, eraser);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScratchCover oldDelegate) => true;
}

class CoupleDepth extends StatefulWidget {
  const CoupleDepth({super.key, required this.child});
  final Widget child;
  @override
  State<CoupleDepth> createState() => _CoupleDepthState();
}

class _CoupleDepthState extends State<CoupleDepth> {
  Offset tilt = Offset.zero;
  @override
  Widget build(BuildContext context) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        Semantics(
            label: '可随手指倾斜的立体照片卡片',
            child: GestureDetector(
                onPanUpdate: MediaQuery.disableAnimationsOf(context)
                    ? null
                    : (d) => setState(() => tilt = Offset(
                        (tilt.dx + d.delta.dx / 100).clamp(-1, 1),
                        (tilt.dy + d.delta.dy / 100).clamp(-1, 1))),
                onPanEnd: (_) => setState(() => tilt = Offset.zero),
                onPanCancel: () => setState(() => tilt = Offset.zero),
                child: TweenAnimationBuilder<Offset>(
                    tween: Tween(end: tilt),
                    duration: Duration(
                        milliseconds:
                            MediaQuery.disableAnimationsOf(context) ? 0 : 120),
                    builder: (_, value, child) => Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, .0015)
                          ..rotateX(-value.dy * .14)
                          ..rotateY(value.dx * .2),
                        child: Stack(children: [
                          child!,
                          Positioned.fill(
                              child: IgnorePointer(
                                  child: DecoratedBox(
                                      decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                              begin: Alignment(
                                                  -value.dx, -value.dy),
                                              end:
                                                  Alignment(value.dx, value.dy),
                                              colors: [
                                Colors.white.withValues(
                                    alpha: .04 + value.distance * .05),
                                Colors.transparent
                              ])))))
                        ])),
                    child: widget.child))),
        const SizedBox(height: 16),
        TextButton.icon(
            onPressed: () => setState(() => tilt =
                tilt.dx > 0 ? const Offset(-.8, -.3) : const Offset(.8, .3)),
            icon: const Icon(Icons.threed_rotation),
            label: const Text('换个角度看')),
        const Text('手指移动体验卡片视差',
            style: TextStyle(color: Color(0xff877267), fontSize: 12)),
      ]);
}

class CoupleSky extends StatelessWidget {
  const CoupleSky(
      {super.key, required this.memories, required this.onSelected});
  final List<CoupleMemory> memories;
  final ValueChanged<CoupleMemory> onSelected;
  @override
  Widget build(BuildContext context) {
    final rows = memories.take(12).toList();
    return Container(
        height: 340,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const RadialGradient(
                center: Alignment(.6, -.7),
                radius: 1.4,
                colors: [Color(0xff394260), Color(0xff172131)])),
        child: LayoutBuilder(
            builder: (context, constraints) => Stack(children: [
                  const Positioned.fill(
                      child: CustomPaint(painter: _SkyBackground())),
                  if (rows.isEmpty)
                    const Center(
                        child: Text('留下第一段回忆，点亮我们的星空',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: couplePaper))),
                  for (var i = 0; i < rows.length; i++)
                    Positioned(
                      left: (i % 3) * constraints.maxWidth / 3,
                      top: (i ~/ 3) * 76.0 + [0.0, 15.0, 6.0][i % 3] + 12,
                      width: constraints.maxWidth / 3,
                      child: TextButton(
                          onPressed: () => onSelected(rows[i]),
                          style: TextButton.styleFrom(
                              foregroundColor: const Color(0xffffe3af),
                              minimumSize: const Size(44, 58)),
                          child: Column(children: [
                            const Icon(Icons.star_rounded, size: 24),
                            const SizedBox(height: 4),
                            Text(rows[i].title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12)),
                            Text(dateKey(rows[i].date).substring(5),
                                style: const TextStyle(fontSize: 11))
                          ])),
                    ),
                ])));
  }
}

class _SkyBackground extends CustomPainter {
  const _SkyBackground();
  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(42);
    for (var i = 0; i < 85; i++) {
      canvas.drawCircle(
          Offset(random.nextDouble() * size.width,
              random.nextDouble() * size.height),
          random.nextDouble() + .4,
          Paint()
            ..color =
                couplePaper.withValues(alpha: .3 + random.nextDouble() * .4));
    }
  }

  @override
  bool shouldRepaint(_SkyBackground oldDelegate) => false;
}
