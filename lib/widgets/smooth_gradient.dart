import 'package:flutter/material.dart';

/// A [BoxDecoration] whose gradient keeps a smooth edge under Impeller on
/// Linux, which leaves gradient-filled shapes jagged. Draws the shape in a
/// solid colour, which it antialiases, then lays the gradient inside it. Box
/// shadows aren't supported.
class SmoothGradientDecoration extends BoxDecoration {
  const SmoothGradientDecoration({super.color, super.border, super.borderRadius, super.gradient, super.shape})
    : assert(gradient != null || color != null || border != null);

  factory SmoothGradientDecoration._from(BoxDecoration d) => SmoothGradientDecoration(
    color: d.color,
    border: d.border,
    borderRadius: d.borderRadius,
    gradient: d.gradient,
    shape: d.shape,
  );

  @override
  BoxDecoration? lerpFrom(Decoration? a, double t) {
    if (a is! BoxDecoration?) return null;
    final mixed = BoxDecoration.lerp(a, this, t);
    return mixed == null ? null : SmoothGradientDecoration._from(mixed);
  }

  @override
  BoxDecoration? lerpTo(Decoration? b, double t) {
    if (b is! BoxDecoration?) return null;
    final mixed = BoxDecoration.lerp(this, b, t);
    return mixed == null ? null : SmoothGradientDecoration._from(mixed);
  }

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _SmoothGradientPainter(this, onChanged);
}

class _SmoothGradientPainter extends BoxPainter {
  _SmoothGradientPainter(this.decoration, super.onChanged);

  final SmoothGradientDecoration decoration;

  /// Everything but the gradient. Paints the border over it.
  late final BoxPainter _rest = BoxDecoration(
    color: decoration.gradient == null ? decoration.color : null,
    border: decoration.border,
    borderRadius: decoration.borderRadius,
    shape: decoration.shape,
  ).createBoxPainter(onChanged);

  void _drawShape(Canvas canvas, Rect rect, TextDirection? direction, Paint paint) {
    if (decoration.shape == BoxShape.circle) {
      canvas.drawCircle(rect.center, rect.shortestSide / 2, paint);
    } else {
      canvas.drawRRect((decoration.borderRadius?.resolve(direction) ?? BorderRadius.zero).toRRect(rect), paint);
    }
  }

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final direction = configuration.textDirection;
    final gradient = decoration.gradient;
    if (gradient != null) {
      final first = gradient.colors.first;
      if (gradient.colors.every((c) => c == first)) {
        _drawShape(canvas, rect, direction, Paint()..color = first);
      } else {
        canvas.saveLayer(rect.inflate(1), Paint());
        _drawShape(canvas, rect, direction, Paint()..color = const Color(0xFFFFFFFF));
        canvas.drawRect(
          rect.inflate(1),
          Paint()
            ..blendMode = BlendMode.srcIn
            ..shader = gradient.createShader(rect, textDirection: direction),
        );
        canvas.restore();
      }
    }
    _rest.paint(canvas, offset, configuration);
  }

  @override
  void dispose() {
    _rest.dispose();
    super.dispose();
  }
}
