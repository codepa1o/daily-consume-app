import 'package:flutter/material.dart';

// 入口预览中的 Lucide 1.17.0 plane-takeoff 图标，使用原生绘制保持线条一致。
// 来源：https://github.com/lucide-icons/lucide/blob/1.17.0/icons/plane-takeoff.svg
class TravelPlanningIcon extends StatelessWidget {
  const TravelPlanningIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    return SizedBox.square(
      dimension: theme.size ?? 24,
      child: CustomPaint(
        painter: _TravelPlanningIconPainter(
            theme.color ?? Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}

class _TravelPlanningIconPainter extends CustomPainter {
  const _TravelPlanningIconPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawLine(const Offset(2, 22), const Offset(22, 22), paint);
    canvas.drawPath(
      Path()
        ..moveTo(6.36, 17.4)
        ..lineTo(4, 17)
        ..relativeLineTo(-2, -4)
        ..relativeLineTo(1.1, -.55)
        ..relativeArcToPoint(const Offset(1.8, 0),
            radius: const Radius.circular(2))
        ..relativeLineTo(.17, .1)
        ..relativeArcToPoint(const Offset(1.8, 0),
            radius: const Radius.circular(2), clockwise: false)
        ..lineTo(8, 12)
        ..lineTo(5, 6)
        ..relativeLineTo(.9, -.45)
        ..relativeArcToPoint(const Offset(2.09, .2),
            radius: const Radius.circular(2))
        ..relativeLineTo(4.02, 3)
        ..relativeArcToPoint(const Offset(2.1, .2),
            radius: const Radius.circular(2), clockwise: false)
        ..relativeLineTo(4.19, -2.06)
        ..relativeArcToPoint(const Offset(1.73, -.17),
            radius: const Radius.circular(2.41))
        ..lineTo(21, 7)
        ..relativeArcToPoint(const Offset(.87, 1.99),
            radius: const Radius.circular(1.4))
        ..relativeLineTo(-.38, .76)
        ..relativeCubicTo(-.23, .46, -.6, .84, -1.07, 1.08)
        ..lineTo(7.58, 17.2)
        ..relativeArcToPoint(const Offset(-1.22, .18),
            radius: const Radius.circular(2))
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TravelPlanningIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

const lucideIconLicense = '''
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.
THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
''';
