import 'dart:math' as math;

import 'package:flutter/material.dart';

const _green = Color(0xff64765a);
const _softGreen = Color(0xffe9eee4);
const _muted = Color(0xff70756b);

class TravelPlanningLoading extends StatefulWidget {
  const TravelPlanningLoading({super.key, this.complete = false});

  final bool complete;

  @override
  State<TravelPlanningLoading> createState() => _TravelPlanningLoadingState();
}

class _TravelPlanningLoadingState extends State<TravelPlanningLoading>
    with TickerProviderStateMixin {
  late final AnimationController _runner;
  late final AnimationController _progress;

  @override
  void initState() {
    super.initState();
    _runner = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    _progress = AnimationController(
      vsync: this,
      animationBehavior: AnimationBehavior.preserve,
      value: widget.complete ? 1 : 0,
    );
    if (!widget.complete) {
      // 接口没有实时进度，预估值逐渐放缓，只有收到结果后才补满。
      _progress.animateTo(.94,
          duration: const Duration(minutes: 8), curve: Curves.easeOutCubic);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || widget.complete) {
      _runner.stop();
    } else if (!_runner.isAnimating) {
      _runner.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant TravelPlanningLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.complete && !oldWidget.complete) {
      _runner.stop();
      _progress.animateTo(1,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOutCubic);
    }
  }

  @override
  void dispose() {
    _runner.dispose();
    _progress.dispose();
    super.dispose();
  }

  String _message(double progress) {
    if (widget.complete) return '行程已生成，即将展示…';
    if (progress < .15) return '正在搜索目的地信息…';
    if (progress < .4) return '正在整理天气、景点和住宿…';
    if (progress < .75) return '正在生成每日行程与预算…';
    return '仍在生成行程，请耐心等待…';
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final runner = Semantics(
      label: reduceMotion || widget.complete ? '自行车上的鹈鹕' : '鹈鹕踩动踏板、车轮转动，正在规划行程',
      image: true,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _runner,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth.isFinite
                  ? math.min(240.0, constraints.maxWidth)
                  : 240.0;
              return CustomPaint(
                key: const ValueKey('travel-running-person'),
                size: Size(width, width * 158 / 240),
                painter: _PelicanBicyclePainter(
                  reduceMotion ? 0 : _runner.value,
                ),
              );
            },
          ),
        ),
      ),
    );
    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Card(
          color: const Color(0xfffffefa),
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AnimatedBuilder(
              animation: _progress,
              child: runner,
              builder: (context, runner) {
                final progress = _progress.value;
                final percentage = (progress * 100).floor();
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  runner!,
                  const SizedBox(height: 12),
                  AnimatedSwitcher(
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 250),
                    child: Text(
                      _message(progress),
                      key: ValueKey(_message(progress)),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xff292c25),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(children: [
                    Expanded(
                      child: Text(widget.complete ? '即将完成' : '预估进度',
                          style: const TextStyle(color: _muted, fontSize: 12)),
                    ),
                    Text('$percentage%',
                        style: const TextStyle(
                            color: _green, fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(8),
                    color: _green,
                    backgroundColor: _softGreen,
                    semanticsLabel: widget.complete ? '行程生成进度' : '行程生成预估进度',
                  ),
                  const SizedBox(height: 14),
                  const Text('规划可能需要几分钟，请保持页面打开。',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: _muted, fontSize: 12, height: 1.6)),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _PelicanBicyclePainter extends CustomPainter {
  const _PelicanBicyclePainter(this.phase);

  final double phase;

  static const _ink = Color(0xff46513f);
  static const _rim = Color(0xffdedfd6);
  static const _cream = Color(0xfff1ead8);
  static const _skin = Color(0xffd58a43);
  static const _pouch = Color(0xffbb6248);
  static const _hair = Color(0xff343a34);

  void _stroke(
    Canvas canvas,
    Path path,
    Color color,
    double width, {
    StrokeCap cap = StrokeCap.round,
    StrokeJoin join = StrokeJoin.round,
  }) {
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = cap
        ..strokeJoin = join,
    );
  }

  void _line(Canvas canvas, Offset from, Offset to, Color color, double width) {
    _stroke(
      canvas,
      Path()
        ..moveTo(from.dx, from.dy)
        ..lineTo(to.dx, to.dy),
      color,
      width,
    );
  }

  void _wheel(Canvas canvas, Offset center, double angle) {
    canvas.drawCircle(
      center,
      26,
      Paint()
        ..color = _ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      center,
      22,
      Paint()
        ..color = _rim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.35,
    );
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    final spokes = Paint()
      ..color = _rim
      ..strokeWidth = 1.1;
    for (var i = 0; i < 4; i++) {
      final spokeAngle = i * math.pi / 4;
      canvas.drawLine(
        Offset(
          math.cos(spokeAngle) * 22,
          math.sin(spokeAngle) * 22,
        ),
        Offset(
          -math.cos(spokeAngle) * 22,
          -math.sin(spokeAngle) * 22,
        ),
        spokes,
      );
    }
    canvas.restore();
    canvas.drawCircle(center, 3.2, Paint()..color = _green);
  }

  List<Offset> _legPoints({
    required Offset hip,
    required Offset foot,
    required double bend,
  }) {
    const upperLength = 28.0;
    const lowerLength = 29.0;
    final delta = foot - hip;
    final length = math.min(delta.distance, upperLength + lowerLength - .2);
    final safeLength = math.max(length, .1);
    final direction = delta / safeLength;
    final along = (upperLength * upperLength -
            lowerLength * lowerLength +
            safeLength * safeLength) /
        (2 * safeLength);
    final across = math.sqrt(
      math.max(0, upperLength * upperLength - along * along),
    );
    final knee = hip +
        direction * along +
        Offset(direction.dy, -direction.dx) * across * bend;
    final ankle = hip + direction * length;
    return [hip, knee, ankle];
  }

  void _drawLeg(
    Canvas canvas, {
    required Offset hip,
    required Offset foot,
    required double bend,
    required Color color,
    required double width,
  }) {
    final points = _legPoints(hip: hip, foot: foot, bend: bend);
    final path = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy);
    _stroke(canvas, path, color, width);
    for (final point in [points[1], points[2]]) {
      canvas.drawCircle(point, width / 2, Paint()..color = color);
    }
    _line(
      canvas,
      points[2],
      points[2] + const Offset(6, 0),
      color,
      width * .72,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 240, size.height / 158);

    canvas.drawCircle(
      const Offset(116, 67),
      46,
      Paint()..color = _softGreen,
    );

    // 两只车轮在后，车架与踏板在中间，小鸟骑在上面。
    _wheel(canvas, const Offset(67, 108), phase * math.pi * 2);
    _wheel(canvas, const Offset(166, 108), phase * math.pi * 2);

    final frame = Path()
      ..moveTo(67, 108)
      ..lineTo(111, 108)
      ..lineTo(96, 77)
      ..lineTo(67, 108)
      ..moveTo(96, 77)
      ..lineTo(141, 77)
      ..lineTo(111, 108)
      ..moveTo(141, 77)
      ..lineTo(166, 108)
      ..moveTo(141, 77)
      ..lineTo(144, 70);
    _stroke(canvas, frame, _green, 3.2);

    final bicycleDetail = Path()
      ..moveTo(86, 68)
      ..lineTo(105, 68)
      ..moveTo(143, 70)
      ..lineTo(156, 71)
      ..moveTo(144, 70)
      ..lineTo(148, 63)
      ..moveTo(96, 77)
      ..lineTo(94, 69);
    _stroke(canvas, bicycleDetail, _ink, 3);

    canvas.drawCircle(
      const Offset(111, 108),
      8,
      Paint()
        ..color = const Color(0xfffffefa)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      const Offset(111, 108),
      8,
      Paint()
        ..color = _green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final bob = math.sin(phase * math.pi * 2 * (3200 / 1100)) * .65;
    final pedalAngle = phase * math.pi * 2 * (3200 / 930);
    final pedalOffset = Offset(
      math.cos(pedalAngle) * 9,
      math.sin(pedalAngle) * 9,
    );
    canvas.save();
    canvas.translate(111, 108);
    canvas.rotate(pedalAngle);
    _line(
      canvas,
      Offset.zero,
      const Offset(9, 0),
      _green,
      2.4,
    );
    _line(
      canvas,
      Offset.zero,
      const Offset(-9, 0),
      _green,
      2.4,
    );
    _line(canvas, const Offset(9, 0), const Offset(14, 0), _ink, 3);
    _line(canvas, const Offset(-9, 0), const Offset(-14, 0), _ink, 3);
    canvas.restore();

    final nearFoot = const Offset(111, 108) - pedalOffset;
    final farFoot = const Offset(111, 108) + pedalOffset;
    _drawLeg(
      canvas,
      hip: Offset(105, 58 + bob),
      foot: farFoot + Offset(0, bob),
      bend: -1,
      color: const Color(0xffbb8150),
      width: 3.4,
    );
    _drawLeg(
      canvas,
      hip: Offset(103, 58 + bob),
      foot: nearFoot + Offset(0, bob),
      bend: 1,
      color: _skin,
      width: 3.7,
    );

    canvas.save();
    canvas.translate(0, bob);

    // 尾羽、圆润的身体与翅膀，让鹈鹕一眼可认。
    final tail = Path()
      ..moveTo(95, 42)
      ..quadraticBezierTo(86, 47, 80, 54)
      ..lineTo(75, 56)
      ..quadraticBezierTo(73, 55, 75, 51)
      ..lineTo(87, 37)
      ..quadraticBezierTo(93, 32, 100, 33)
      ..close();
    canvas.drawPath(tail, Paint()..color = _green);

    final body = Path()
      ..moveTo(88, 47)
      ..cubicTo(97, 32, 111, 29, 124, 36)
      ..cubicTo(137, 43, 132, 57, 126, 61)
      ..cubicTo(116, 69, 101, 64, 93, 57)
      ..close();
    canvas.drawPath(body, Paint()..color = _cream);

    final wing = Path()
      ..moveTo(94, 45)
      ..cubicTo(104, 34, 116, 40, 123, 49)
      ..cubicTo(112, 46, 105, 53, 105, 60)
      ..cubicTo(98, 58, 94, 53, 94, 45)
      ..close();
    canvas.drawPath(wing, Paint()..color = _green);

    final feathers = Path()
      ..moveTo(97, 48)
      ..lineTo(105, 50)
      ..moveTo(100, 43)
      ..lineTo(108, 46)
      ..moveTo(104, 56)
      ..lineTo(112, 51);
    _stroke(canvas, feathers, const Color(0xff78896b), 2);

    final neck = Path()
      ..moveTo(112, 49)
      ..quadraticBezierTo(116, 42, 120, 38);
    _stroke(canvas, neck, _cream, 7);

    final head = Path()
      ..moveTo(119, 36)
      ..cubicTo(118, 25, 121, 18, 129, 17)
      ..cubicTo(137, 15, 142, 21, 142, 27)
      ..cubicTo(143, 34, 139, 40, 132, 41)
      ..cubicTo(125, 42, 121, 39, 119, 36)
      ..close();
    canvas.drawPath(head, Paint()..color = _cream);

    canvas.save();
    canvas.translate(125, 34);
    canvas.rotate(math.sin(phase * math.pi * 2 * (3200 / 1100)) * .0105);
    canvas.translate(-125, -34);
    final bill = Path()
      ..moveTo(135, 30)
      ..quadraticBezierTo(150, 25, 169, 30)
      ..quadraticBezierTo(157, 37, 136, 36)
      ..close();
    canvas.drawPath(bill, Paint()..color = const Color(0xffd99043));
    final pouch = Path()
      ..moveTo(135, 35)
      ..quadraticBezierTo(145, 36, 152, 46)
      ..quadraticBezierTo(141, 45, 132, 39)
      ..close();
    canvas.drawPath(pouch, Paint()..color = _pouch);
    canvas.restore();

    canvas.drawCircle(const Offset(135, 27), 1.5, Paint()..color = _hair);
    final crest = Path()
      ..moveTo(121, 22)
      ..quadraticBezierTo(126, 16, 133, 20);
    _stroke(canvas, crest, _green, 3.5);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PelicanBicyclePainter oldDelegate) =>
      phase != oldDelegate.phase;
}
