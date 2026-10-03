import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A two-second hold with visible progress; releasing or dragging cancels it.
class WorkoutCheckInButton extends StatefulWidget {
  const WorkoutCheckInButton(
      {super.key, required this.enabled, required this.onCheckIn});

  final bool enabled;
  final Future<void> Function() onCheckIn;

  @override
  State<WorkoutCheckInButton> createState() => _WorkoutCheckInButtonState();
}

class _WorkoutCheckInButtonState extends State<WorkoutCheckInButton>
    with SingleTickerProviderStateMixin {
  static const _sage = Color(0xff64765a);
  late final _progress =
      AnimationController(vsync: this, duration: const Duration(seconds: 2));
  bool _saving = false;

  @override
  void didUpdateWidget(covariant WorkoutCheckInButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _progress.reset();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _cancel() {
    if (!_saving) _progress.reset();
  }

  Future<void> _finish() async {
    if (!widget.enabled || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.onCheckIn();
    } finally {
      if (mounted) {
        _progress.reset();
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: widget.enabled,
        label: '长按两秒完成健身打卡',
        onLongPress: widget.enabled ? _finish : null,
        child: RawGestureDetector(
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          gestures: widget.enabled
              ? {
                  LongPressGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                          LongPressGestureRecognizer>(
                    () => LongPressGestureRecognizer(
                        duration: const Duration(seconds: 2)),
                    (recognizer) {
                      recognizer.onLongPressDown = (_) {
                        if (!_saving) _progress.forward(from: 0);
                      };
                      recognizer.onLongPressCancel = _cancel;
                      recognizer.onLongPressUp = _cancel;
                      recognizer.onLongPress = _finish;
                    },
                  ),
                }
              : {},
          child: AnimatedBuilder(
            animation: _progress,
            builder: (context, _) => SizedBox(
              width: 172,
              height: 172,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 172,
                    height: 172,
                    child: CircularProgressIndicator(
                        value: _progress.value,
                        strokeWidth: 5,
                        backgroundColor: const Color(0xffe8e7df),
                        color: _sage,
                        strokeCap: StrokeCap.round),
                  ),
                  Container(
                    width: 150,
                    height: 150,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: widget.enabled
                              ? const [Color(0xff78896e), _sage]
                              : const [Color(0xffc9ccc2), Color(0xffa8ada1)]),
                      boxShadow: [
                        BoxShadow(
                            color: _sage.withValues(alpha: .18),
                            blurRadius: 22,
                            offset: const Offset(0, 9))
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_saving)
                          const SizedBox(
                              width: 23,
                              height: 23,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                        else
                          const Icon(Icons.fitness_center_rounded,
                              color: Colors.white, size: 25),
                        const SizedBox(height: 7),
                        Text(
                            _progress.value > 0
                                ? '${(_progress.value * 100).round()}%'
                                : '打卡',
                            style: const TextStyle(
                                color: Colors.white,
                                fontFamily: 'serif',
                                fontSize: 27,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(_progress.value > 0 ? '继续按住' : '长按 2 秒',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 10)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
