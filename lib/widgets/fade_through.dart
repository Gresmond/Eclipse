import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import '../theme/app_theme.dart';

/// An [AnimatedSwitcher] that fades the old child out before the new one
/// fades in, so the two never show together at any real strength.
class FadeThrough extends StatelessWidget {
  const FadeThrough({
    super.key,
    required this.child,
    this.duration = Motion.page,
    this.scaleFrom = 1.0,
    this.layoutBuilder = AnimatedSwitcher.defaultLayoutBuilder,
    this.deferBuild = false,
  });

  final Widget child;

  /// Covers both halves: fading out, then fading in.
  final Duration duration;

  /// The incoming child grows from this scale as it fades in.
  final double scaleFrom;

  final AnimatedSwitcherLayoutBuilder layoutBuilder;
  final bool deferBuild;

  static Animation<double>? _opacity(Widget widget) {
    if (widget is KeyedSubtree) return _opacity(widget.child);
    if (widget is ScaleTransition) return _opacity(widget.child!);
    return widget is FadeTransition ? widget.opacity : null;
  }

  static double _visibility(Widget widget) => _opacity(widget)?.value ?? 0;

  // The outgoing child runs the same animation in reverse, so the two
  // halves follow [Motion.incoming] and [Motion.outgoing].
  static final _curve = CurveTween(curve: Motion.incoming);

  /// Lays the outgoing child over the incoming one. The box is as tall as
  /// either while the outgoing one still shows, so it's never cut off as it
  /// fades; once it's gone, the box takes the incoming child's height (an
  /// [AnimatedSize] above eases the change). Takes the full width.
  ///
  /// Every child sits in the same widgets, keyed by its own key, whether
  /// incoming or outgoing, so a child that starts fading out keeps its state
  /// rather than being built afresh for its last frames.
  static Widget sizeToCurrent(Widget? current, List<Widget> previous) =>
      SizedBox(width: double.infinity, child: _sizeTo(current, previous, ownWidth: false));

  /// As [sizeToCurrent], but as wide as the children, not the full width:
  /// each child has a width of its own, and keeps it after fading out.
  static Widget sizeToEither(Widget? current, List<Widget> previous) => _sizeTo(current, previous, ownWidth: true);

  static Widget _sizeTo(Widget? current, List<Widget> previous, {required bool ownWidth}) => Stack(
    children: [
      for (final p in previous) _SizeSlot(key: p.key, fade: _opacity(p), ownWidth: ownWidth, child: p),
      if (current != null) _SizeSlot(key: current.key, ownWidth: ownWidth, child: current),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      layoutBuilder: (current, previous) => layoutBuilder(
        current,
        previous.isEmpty ? const [] : [previous.reduce((a, b) => _visibility(a) > _visibility(b) ? a : b)],
      ),
      transitionBuilder: (child, anim) {
        final t = anim.drive(_curve);
        Widget faded = FadeTransition(
          opacity: t,
          child: deferBuild ? _DeferredPage(animation: anim, child: child) : child,
        );
        if (scaleFrom != 1.0) {
          faded = ScaleTransition(
            scale: t.drive(Tween(begin: scaleFrom, end: 1.0)),
            child: faded,
          );
        }
        return faded;
      },
      child: child,
    );
  }
}

/// Full-page destinations have tight bounds, so they can wait until visible.
/// Rapid navigation then avoids constructing pages the user never sees.
class _DeferredPage extends StatefulWidget {
  const _DeferredPage({required this.animation, required this.child});
  final Animation<double> animation;
  final Widget child;
  @override
  State<_DeferredPage> createState() => _DeferredPageState();
}

class _DeferredPageState extends State<_DeferredPage> {
  late bool _ready = widget.animation.value >= Motion.incoming.begin;
  @override
  void initState() {
    super.initState();
    widget.animation.addListener(_check);
  }

  void _check() {
    if (!_ready && widget.animation.value >= Motion.incoming.begin) setState(() => _ready = true);
  }

  @override
  void didUpdateWidget(_DeferredPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeListener(_check);
      widget.animation.addListener(_check);
    }
  }

  @override
  void dispose() {
    widget.animation.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ready ? widget.child : const SizedBox.expand();
}

/// One child of [FadeThrough.sizeToCurrent]. The incoming child, and an
/// outgoing one while it still shows, set the box's size; an outgoing one
/// that has faded out fills the box without sizing it. Only the placement
/// changes, never the widgets, so the child keeps its state throughout.
class _SizeSlot extends StatefulWidget {
  const _SizeSlot({super.key, this.fade, this.ownWidth = false, required this.child});

  /// The outgoing child's opacity; null for the incoming child.
  final Animation<double>? fade;

  /// Whether one that has faded out keeps its own width rather than the
  /// box's, which may be too narrow for it.
  final bool ownWidth;
  final Widget child;

  @override
  State<_SizeSlot> createState() => _SizeSlotState();
}

class _SizeSlotState extends State<_SizeSlot> {
  bool get _gone => (widget.fade?.value ?? 1) <= 0;
  late bool _wasGone = _gone;

  void _check() {
    if (_gone != _wasGone) setState(() => _wasGone = _gone);
  }

  @override
  void initState() {
    super.initState();
    widget.fade?.addListener(_check);
  }

  @override
  void didUpdateWidget(_SizeSlot old) {
    super.didUpdateWidget(old);
    if (old.fade != widget.fade) {
      old.fade?.removeListener(_check);
      widget.fade?.addListener(_check);
    }
    _wasGone = _gone;
  }

  @override
  void dispose() {
    widget.fade?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fill = _wasGone ? 0.0 : null;
    return Positioned(
      left: fill,
      top: fill,
      right: fill,
      bottom: fill,
      child: ClipRect(
        clipBehavior: _wasGone ? Clip.hardEdge : Clip.none,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          // Loose, so a narrower outgoing child keeps its width rather than
          // being stretched across the card as it fades out.
          minWidth: widget.fade == null ? null : 0,
          minHeight: _wasGone ? 0 : null,
          maxWidth: _wasGone && widget.ownWidth ? double.infinity : null,
          maxHeight: _wasGone ? double.infinity : null,
          fit: OverflowBoxFit.deferToChild,
          child: widget.child,
        ),
      ),
    );
  }
}
