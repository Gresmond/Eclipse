import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A [CircularProgressIndicator] that keeps a smooth edge under Impeller on
/// Linux, which leaves a stroked arc jagged: the same motion, drawn as short
/// lines, which it smooths. Sized by its parent.
class SmoothSpinner extends StatefulWidget {
  const SmoothSpinner({super.key, required this.color, this.strokeWidth = 2});

  final Color color;
  final double strokeWidth;

  @override
  State<SmoothSpinner> createState() => _SmoothSpinnerState();
}

class _SmoothSpinnerState extends State<SmoothSpinner> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: CircularProgressIndicator.defaultAnimationDuration,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _SpinnerPainter(_controller, widget.color, widget.strokeWidth));
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter(this.turn, this.color, this.strokeWidth) : super(repaint: turn);

  final Animation<double> turn;
  final Color color;
  final double strokeWidth;

  // Flutter's own timing, from CircularProgressIndicator.
  static const _paths = 2222, _rotations = 1333;
  static final _head = CurveTween(curve: const Interval(0, 0.5, curve: Curves.fastOutSlowIn))
      .chain(CurveTween(curve: const SawTooth(_paths)));
  static final _tail = CurveTween(curve: const Interval(0.5, 1, curve: Curves.fastOutSlowIn))
      .chain(CurveTween(curve: const SawTooth(_paths)));
  static final _offset = CurveTween(curve: const SawTooth(_paths));
  static final _rotation = CurveTween(curve: const SawTooth(_rotations));

  /// Short enough on these small rings that the lines read as a curve.
  static const _step = math.pi / 12;

  /// The arc at its shortest. Any shorter and it can land on the pixel grid as
  /// a hard-edged dot, with no soft edge at all.
  static const _shortest = 0.2;

  @override
  void paint(Canvas canvas, Size size) {
    final tail = _tail.evaluate(turn), head = _head.evaluate(turn);
    final start =
        -math.pi / 2 +
        tail * 3 / 2 * math.pi +
        _rotation.evaluate(turn) * math.pi * 2 +
        _offset.evaluate(turn) * 0.5 * math.pi;
    final sweep = math.max((head - tail) * 3 / 2 * math.pi, _shortest);
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    Offset at(double angle) => centre + Offset(math.cos(angle), math.sin(angle)) * radius;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final lines = (sweep / _step).ceil();
    for (var i = 0; i < lines; i++) {
      canvas.drawLine(at(start + sweep * i / lines), at(start + sweep * (i + 1) / lines), paint);
    }
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.turn != turn || old.color != color || old.strokeWidth != strokeWidth;
}
