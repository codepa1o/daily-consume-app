import 'package:flutter/material.dart';

/// 与入口预览一致的线条人体图标。
class BodyDataIcon extends StatelessWidget {
  const BodyDataIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    return SizedBox.square(
      dimension: theme.size ?? 24,
      child: CustomPaint(
        painter: _BodyDataIconPainter(
            theme.color ?? Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}

class _BodyDataIconPainter extends CustomPainter {
  const _BodyDataIconPainter(this.color);
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
    canvas.drawCircle(const Offset(12, 5), 1, paint);
    canvas.drawPath(
      Path()
        ..moveTo(6, 8)
        ..lineTo(12, 10)
        ..lineTo(18, 8)
        ..moveTo(12, 10)
        ..lineTo(12, 14)
        ..moveTo(9, 20)
        ..lineTo(12, 14)
        ..lineTo(15, 20),
      paint,
    );
  }

  @override
  bool shouldRepaint(_BodyDataIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
