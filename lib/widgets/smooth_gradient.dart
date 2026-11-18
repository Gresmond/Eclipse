import 'package:flutter/material.dart';

/// A [BoxDecoration] whose gradient keeps a smooth edge under Impeller on
/// Linux, which leaves gradient-filled shapes jagged. Draws the shape in a
/// solid colour, which it antialiases, then lays the gradient inside it. Keeps
/// a circle's border smooth too. Box shadows aren't supported.
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

  /// A border of one colour and width, drawn here as a filled ring: a stroked
  /// circle comes out jagged.
  late final BorderSide? _ring = switch (decoration.border) {
    final Border border when border.isUniform && border.top.style != BorderStyle.none => border.top,
    _ => null,
  };

  /// Everything else but the gradient. Paints a border over it.
  late final BoxPainter _rest = BoxDecoration(
    color: decoration.gradient == null ? decoration.color : null,
    border: _ring == null ? decoration.border : null,
    borderRadius: decoration.borderRadius,
    shape: decoration.shape,
  ).createBoxPainter(onChanged);

  RRect _shape(Rect rect, TextDirection? direction) => decoration.shape == BoxShape.circle
      ? RRect.fromRectAndRadius(
          Rect.fromCircle(center: rect.center, radius: rect.shortestSide / 2),
          Radius.circular(rect.shortestSide / 2),
        )
      : (decoration.borderRadius?.resolve(direction) ?? BorderRadius.zero).toRRect(rect);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final direction = configuration.textDirection;
    final shape = _shape(rect, direction);
    final gradient = decoration.gradient;
    final ring = _ring;
    if (gradient != null) {
      // Stops under the ring's middle, so none of it shows round the outside.
      // Grows out as the ring fades: with no ring left to hide it, a half pixel
      // inset blurs the straight edges and steps the corners.
      final fill = ring == null ? shape : shape.deflate(ring.width / 2 * ring.color.a);
      final first = gradient.colors.first;
      if (gradient.colors.every((c) => c == first)) {
        canvas.drawRRect(fill, Paint()..color = first);
      } else {
        canvas.saveLayer(rect.inflate(1), Paint());
        canvas.drawRRect(fill, Paint()..color = const Color(0xFFFFFFFF));
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
    if (ring != null) canvas.drawDRRect(shape, shape.deflate(ring.width), Paint()..color = ring.color);
  }

  @override
  void dispose() {
    _rest.dispose();
    super.dispose();
  }
}
