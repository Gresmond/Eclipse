import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import '../theme/pixels.dart';
import '../theme/tokens.dart';

/// Shared pill-style segmented control with an animated sliding highlight for
/// single selection or independent pill toggles when [chosen] is supplied.
class SegmentedPills extends StatefulWidget {
  const SegmentedPills({
    super.key,
    required this.labels,
    this.selected = -1,
    this.chosen,
    required this.onSelect,
    this.expand = false,
    this.compact = false,
  });

  final List<String> labels;
  final int selected;
  final Set<int>? chosen;
  final ValueChanged<int> onSelect;
  final bool expand;
  final bool compact;

  @override
  State<SegmentedPills> createState() => _SegmentedPillsState();
}

class _SegmentedPillsState extends State<SegmentedPills> {
  late List<GlobalKey> _keys = [for (final _ in widget.labels) GlobalKey()];

  @override
  void didUpdateWidget(SegmentedPills old) {
    super.didUpdateWidget(old);
    if (widget.labels.length != _keys.length) {
      _keys = [for (final _ in widget.labels) GlobalKey()];
    }
  }

  bool _on(int i) => widget.chosen?.contains(i) ?? i == widget.selected;

  Widget _labelWidget(Palette p, int i) {
    final on = _on(i);
    return Align(
      alignment: Alignment.center,
      widthFactor: widget.expand ? null : 1,
      heightFactor: 1,
      child: PixelFit(
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: on ? p.onDone : p.inkMuted),
          duration: context.themed(Motion.morph),
          curve: Motion.morphCurve,
          builder: (context, color, _) => Text(
            widget.labels[i],
            style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: color),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final padding = widget.compact
        ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 6);
    final Widget row;
    if (widget.chosen == null) {
      final target = widget.selected >= 0 && widget.selected < _keys.length ? _keys[widget.selected] : null;
      row = GlidePill(
        target: target,
        color: p.done,
        child: PixelRow(
          mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (final i in List.generate(widget.labels.length, (idx) => idx))
              (() {
                final segment = MouseRegion(
                  key: _keys[i],
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onSelect(i),
                    child: Padding(padding: padding, child: _labelWidget(p, i)),
                  ),
                );
                return widget.expand ? Expanded(child: segment) : segment;
              })(),
          ],
        ),
      );
    } else {
      row = PixelRow(
        mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (final (i, label) in widget.labels.indexed)
            (() {
              final segment = MouseRegion(
                // Keep per-pill state stable as choices are toggled on or off.
                key: ValueKey(label),
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onSelect(i),
                  child: AnimatedContainer(
                    duration: context.themed(Motion.click),
                    curve: Motion.clickCurve,
                    padding: padding,
                    decoration: BoxDecoration(
                      color: p.done.withValues(alpha: _on(i) ? 1 : 0),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _labelWidget(p, i),
                  ),
                ),
              );
              return widget.expand ? Expanded(child: segment) : segment;
            })(),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.borderSoft),
      ),
      child: row,
    );
  }
}

/// A rounded highlight drawn under [child], behind whichever of its
/// descendants [target] is on: the tab bar's and Settings' ribbons' pill.
///
/// The pill is placed as it paints, once everything is laid out, so it
/// starts to glide on the very frame the selection changes and always sits
/// exactly on its tab, however that tab moves or resizes (a window resize,
/// a label easing to a new width, a tab unfolding). Only a change of
/// [target] glides, over [Motion.morph]; a switch mid-glide sets off from
/// wherever the pill had got to. Going to or from no target, it fades where
/// it stands.
class GlidePill extends StatefulWidget {
  const GlidePill({super.key, required this.target, required this.color, required this.child});

  /// The selected tab's key; null shows no pill.
  final GlobalKey? target;
  final Color color;
  final Widget child;

  @override
  State<GlidePill> createState() => _GlidePillState();
}

class _GlidePillState extends State<GlidePill> with TickerProviderStateMixin {
  @override
  Widget build(BuildContext context) => _GlidePillBox(
    target: widget.target,
    color: widget.color,
    disableAnimations: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
    vsync: this,
    child: widget.child,
  );
}

class _GlidePillBox extends SingleChildRenderObjectWidget {
  const _GlidePillBox({
    required this.target,
    required this.color,
    required this.disableAnimations,
    required this.vsync,
    super.child,
  });

  final GlobalKey? target;
  final Color color;
  final bool disableAnimations;
  final TickerProvider vsync;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderGlidePill(target, color, vsync, disableAnimations);

  @override
  void updateRenderObject(BuildContext context, RenderGlidePill renderObject) => renderObject
    ..disableAnimations = disableAnimations
    ..target = target
    ..color = color;
}

class RenderGlidePill extends RenderProxyBox {
  RenderGlidePill(this._target, this._color, TickerProvider vsync, [this._disableAnimations = false])
    : _glide = AnimationController(vsync: vsync, duration: Motion.morph, value: 1),
      _presence = AnimationController(vsync: vsync, duration: Motion.morph, value: _target == null ? 0 : 1) {
    _glide.addListener(markNeedsPaint);
    _presence.addListener(markNeedsPaint);
  }

  final AnimationController _glide, _presence;

  bool _disableAnimations;
  set disableAnimations(bool value) {
    if (value == _disableAnimations) return;
    _disableAnimations = value;
    if (value) {
      _from = null;
      _glide.value = 1;
      _presence.value = _target == null ? 0 : 1;
      markNeedsPaint();
    }
  }

  /// Where the pill was last painted, and where a glide set off from.
  Rect? _shown, _from;

  GlobalKey? _target;
  set target(GlobalKey? value) {
    if (value == _target) return;
    final had = _target != null;
    _target = value;
    if (_disableAnimations) {
      _from = null;
      _glide.value = 1;
      _presence.value = value == null ? 0 : 1;
    } else if (value == null) {
      _presence.reverse();
    } else if (had) {
      _from = _shown;
      if (_from != null) _glide.forward(from: 0);
    } else {
      _from = null;
      _glide.value = 1;
      _presence.forward();
    }
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
    _presence.dispose();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final to = _targetRect();
    final from = _from;
    final rect = to == null
        ? (_target == null && _presence.value > 0 ? _shown : null)
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
        Paint()..color = _color.withValues(alpha: _color.a * _presence.value),
      );
    }
    super.paint(context, offset);
  }
}
