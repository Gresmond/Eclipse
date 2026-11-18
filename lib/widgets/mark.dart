import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/lru_cache.dart';
import 'lazy_motion.dart';

/// Pieces shared by the things you tick: ritual squares and to-do circles.

/// Draws [icon] centred on [centre], grown in by [amount] (0 to 1): it
/// fades in and scales up from 60%.
void paintMark(Canvas canvas, Offset centre, IconData icon, double size, Color color, double amount) {
  if (amount <= 0) return;
  if (icon == Icons.check_rounded || icon == Icons.close_rounded) {
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(0.6 + 0.4 * amount);
    // Impeller on Linux leaves stroked paths jagged, but smooths lines. They
    // overlap where they meet, so a fade draws them as one on a layer.
    final fading = color.a * amount < 1;
    if (fading) {
      final reach = size * 0.4;
      canvas.saveLayer(
        Rect.fromCircle(center: Offset.zero, radius: reach),
        Paint()..color = Color.fromRGBO(0, 0, 0, color.a * amount),
      );
    }
    final paint = Paint()
      ..color = color.withValues(alpha: 1)
      ..strokeWidth = size * 0.085
      ..strokeCap = StrokeCap.round;
    if (icon == Icons.close_rounded) {
      canvas.drawLine(Offset(-size * 0.23, -size * 0.23), Offset(size * 0.23, size * 0.23), paint);
      canvas.drawLine(Offset(size * 0.23, -size * 0.23), Offset(-size * 0.23, size * 0.23), paint);
    } else {
      canvas.drawLine(Offset(-size * 0.28, 0), Offset(-size * 0.08, size * 0.20), paint);
      canvas.drawLine(Offset(-size * 0.08, size * 0.20), Offset(size * 0.28, -size * 0.20), paint);
    }
    if (fading) canvas.restore();
    canvas.restore();
    return;
  }
  final g = _glyph(icon, size, color.withValues(alpha: color.a * amount));
  canvas.save();
  canvas.translate(centre.dx, centre.dy);
  canvas.scale(0.6 + 0.4 * amount);
  g.paint(canvas, Offset(-g.width / 2, -g.height / 2));
  canvas.restore();
}

/// Laid-out marks by glyph, size and colour (alpha in 32 steps), so a fade
/// reuses a handful of layouts instead of making one per frame.
final _glyphs = LruCache<(int, double, int), TextPainter>(256, onEvict: (painter) => painter.dispose());

TextPainter _glyph(IconData icon, double size, Color color) {
  final quantised = color.withValues(alpha: (color.a * 32).round() / 32);
  return _glyphs.putIfAbsent((icon.codePoint, size, quantised.toARGB32()), () {
    return TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          height: 1,
          color: quantised,
        ),
      ),
    )..layout();
  });
}

/// Lifts its child a little on [hover] and dips it while [pressed].
class PressScale extends StatelessWidget {
  const PressScale({
    super.key,
    required this.hover,
    required this.pressed,
    required this.lift,
    required this.dip,
    required this.child,
  });

  final bool hover;
  final bool pressed;
  final double lift;
  final double dip;
  final Widget child;

  @override
  Widget build(BuildContext context) => LazyMotion(
    value: pressed ? dip : (hover ? lift : 1.0),
    duration: Motion.hover,
    curve: Motion.hoverCurve,
    transition: (animation, child) => ScaleTransition(scale: animation, child: child),
    child: child,
  );
}
