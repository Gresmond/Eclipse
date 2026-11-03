import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// A rounded highlight drawn under [child], behind whichever of its
/// descendants [target] is on: the tab bar's and Settings' ribbons' pill.
///
/// The pill is placed as it paints, once everything is laid out, so it
/// starts to glide on the very frame the selection changes and always sits
/// exactly on its tab, however that tab moves or resizes (a window resize,
/// a label easing to a new width, a tab unfolding). Only a change of
/// [target] glides, over [Motion.morph]; a switch mid-glide sets off from
/// wherever the pill had got to.
class GlidePill extends StatefulWidget {
  const GlidePill({super.key, required this.target, required this.color, required this.child});

  /// The selected tab's key; null shows no pill.
  final GlobalKey? target;
  final Color color;
  final Widget child;

  @override
  State<GlidePill> createState() => _GlidePillState();
}

class _GlidePillState extends State<GlidePill> with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) =>
      _GlidePillBox(target: widget.target, color: widget.color, vsync: this, child: widget.child);
}

class _GlidePillBox extends SingleChildRenderObjectWidget {
  const _GlidePillBox({required this.target, required this.color, required this.vsync, super.child});

  final GlobalKey? target;
  final Color color;
  final TickerProvider vsync;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderGlidePill(target, color, vsync);

  @override
  void updateRenderObject(BuildContext context, RenderGlidePill renderObject) => renderObject
    ..target = target
    ..color = color;
}

class RenderGlidePill extends RenderProxyBox {
  RenderGlidePill(this._target, this._color, TickerProvider vsync)
    : _glide = AnimationController(vsync: vsync, duration: Motion.morph, value: 1) {
    _glide.addListener(markNeedsPaint);
  }

  final AnimationController _glide;

  /// Where the pill was last painted, and where a glide set off from.
  Rect? _shown, _from;

  GlobalKey? _target;
  set target(GlobalKey? value) {
    if (value == _target) return;
    _target = value;
    _from = _shown;
    if (_from != null) _glide.forward(from: 0);
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  /// The pill's rect now, in this box's coordinates; for tests.
  @visibleForTesting
  Rect? get pill => _shown;

  Rect? _targetRect() {
    final box = _target?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return MatrixUtils.transformRect(box.getTransformTo(this), Offset.zero & box.size);
  }

  @override
  void dispose() {
    _glide.dispose();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final to = _targetRect();
    final from = _from;
    final rect = to == null
        ? null
        : from == null || _glide.isCompleted
        ? to
        : Rect.lerp(from, to, Motion.morphCurve.transform(_glide.value))!;
    _shown = rect;
    if (_glide.isCompleted) _from = null;
    if (rect != null) {
      // A rounded rect, not a StadiumBorder: Impeller on Linux draws shape
      // paths without anti-aliasing, but rounded rects smoothly.
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(rect.shift(offset), Radius.circular(rect.shortestSide / 2)),
        Paint()..color = _color,
      );
    }
    super.paint(context, offset);
  }
}
