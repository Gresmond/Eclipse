import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Gradient arc showing how many of today's habits are done. When the last
/// one is ticked, the arc's tip runs on through the top without stopping and
/// carries the done colour round a second lap, the ring bouncing as it lands,
/// and stays that colour until one is unticked.
class ProgressRing extends StatefulWidget {
  const ProgressRing({super.key, required this.done, required this.total, this.size = 92});

  final int done;
  final int total;
  final double size;

  bool get complete => total > 0 && done == total;

  @override
  State<ProgressRing> createState() => _ProgressRingState();
}

class _ProgressRingState extends State<ProgressRing> with TickerProviderStateMixin {
  /// The celebration: one crest that closes the arc and then, without
  /// pausing at the top, sweeps the done colour round.
  late final _celebrate = AnimationController(vsync: this, duration: Motion.morph * 2);

  /// The arc as last painted, and where it was when the celebration began.
  double _shown = 0;
  double _from = 1;

  /// How strongly the done colour shows; eases out when one is unticked.
  late final _solid = AnimationController(vsync: this, duration: Motion.click);

  static const _bounce = Interval(0.55, 1.0, curve: Curves.easeInOutSine);

  @override
  void initState() {
    super.initState();
    // Already complete when it first appears: just show it, no celebration.
    if (widget.complete) {
      _celebrate.value = 1;
      _solid.value = 1;
    }
  }

  @override
  void didUpdateWidget(ProgressRing old) {
    super.didUpdateWidget(old);
    if (widget.complete == old.complete) return;
    if (widget.complete) {
      _from = _shown;
      _solid.value = 1;
      _celebrate.forward(from: 0);
    } else {
      _solid.animateBack(0, curve: Motion.clickCurve);
    }
  }

  @override
  void dispose() {
    _celebrate.dispose();
    _solid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final size = widget.size;
    final target = widget.total == 0 ? 0.0 : widget.done / widget.total;
    final label = Center(
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${widget.done}',
              style: TextStyle(fontFamily: Fonts.display, fontSize: size * 0.32, color: p.ink),
            ),
            TextSpan(
              text: '/${widget.total}',
              style: TextStyle(fontSize: size * 0.14, color: p.inkMuted),
            ),
          ],
        ),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target),
      duration: Motion.morph,
      curve: Motion.morphCurve,
      child: label,
      builder: (context, value, label) => AnimatedBuilder(
        animation: Listenable.merge([_celebrate, _solid]),
        child: label,
        builder: (context, label) {
          final t = _celebrate.value;
          // The crest's distance travelled: the rest of the arc, then a full
          // lap of wash, eased as a single journey.
          final rest = 1 - _from;
          final crest = (rest + 1) * Motion.morphCurve.transform(t);
          final arc = widget.complete ? math.min(_from + crest, 1.0) : value;
          final wash = (crest - rest).clamp(0.0, 1.0);
          _shown = arc;
          final bump = math.sin(math.pi * _bounce.transform(t));
          return Transform.scale(
            scale: 1 + 0.07 * bump,
            child: SizedBox.square(
              dimension: size,
              child: CustomPaint(
                painter: _RingPainter(arc, p, wash: wash, solid: _solid.value),
                child: label,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.progress, this.p, {required this.wash, required this.solid});

  final double progress;
  final Palette p;

  /// How far round from the top the done colour has swept, 0 to 1.
  final double wash;

  /// Opacity of that done colour.
  final double solid;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 7.0;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2 + 2);

    canvas.drawArc(
      arcRect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = p.empty,
    );

    if (progress <= 0) return;
    final sweep = math.pi * 2 * progress;
    final closed = progress >= 1;
    final g = p.gradient;
    final end = g.last;

    // The whole arc is one stroke with one shader, its round ends drawn as
    // discs in the shader's own colours. The wash is part of that shader
    // rather than a second stroke on top, so there's never anything
    // underneath to show through at its edges or where the ends meet.
    //
    // u runs from 0 at the top to 1 after a full circle. Progress reveals
    // this fixed gradient, so short arcs only show its first colours and
    // existing colours stay put as more tasks are completed. The washed part,
    // from the top to [wash], is pulled to that end colour by [solid].
    Color base(double u) {
      final x = u.clamp(0.0, 1.0) * (g.length - 1);
      final i = math.min(x.floor(), g.length - 2);
      return Color.lerp(g[i], g[i + 1], x - i)!;
    }

    Color washed(double u) => Color.lerp(base(u), end, solid)!;
    final w = solid > 0 ? wash : 0.0;
    Color colourAt(double u) => u < w ? washed(u) : base(u);

    final stops = <double>[];
    final colors = <Color>[];
    for (var i = 0; i < g.length; i++) {
      final u = i / (g.length - 1);
      if (w > 0 && w < 1 && u > w && (stops.isEmpty || stops.last < w)) {
        stops.addAll([w, w]);
        colors.addAll([washed(w), base(w)]);
      }
      stops.add(u);
      colors.add(w > 0 && u <= w ? washed(u) : base(u));
    }
    final shader = SweepGradient(
      endAngle: math.pi * 2,
      colors: colors,
      stops: stops,
      transform: const GradientRotation(-math.pi / 2),
    ).createShader(rect);

    canvas.drawArc(
      arcRect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..shader = shader,
    );

    final r = arcRect.width / 2;
    void disc(double u, Color color) {
      final a = -math.pi / 2 + sweep * u;
      canvas.drawCircle(arcRect.center + Offset(math.cos(a), math.sin(a)) * r, stroke / 2, Paint()..color = color);
    }

    if (!closed) {
      // Round ends; as the arc closes the tip's disc slides over the start's.
      disc(0, colourAt(0));
      disc(1, colourAt(progress));
    } else if (w < 1) {
      // Closed and washing: the tip has run on through the top and is now
      // the crest, still round, with the done colour behind it.
      disc(w, washed(w));
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.p != p || old.wash != wash || old.solid != solid;
}
