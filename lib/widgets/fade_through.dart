import 'package:flutter/material.dart';

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

  static double _visibility(Widget widget) {
    if (widget is KeyedSubtree) return _visibility(widget.child);
    if (widget is ScaleTransition) return _visibility(widget.child!);
    return widget is FadeTransition ? widget.opacity.value : 0;
  }

  // The outgoing child runs the same animation in reverse, so the two
  // halves follow [Motion.incoming] and [Motion.outgoing].
  static final _curve = CurveTween(curve: Motion.incoming);

  /// Lays the outgoing child over the incoming one without letting it change
  /// the height, clipped to the incoming child's box. Takes the full width.
  static Widget sizeToCurrent(Widget? current, List<Widget> previous) => SizedBox(
    width: double.infinity,
    child: Stack(
      children: [
        for (final p in previous)
          Positioned.fill(
            child: ClipRect(
              child: OverflowBox(alignment: Alignment.topLeft, minHeight: 0, maxHeight: double.infinity, child: p),
            ),
          ),
        ?current,
      ],
    ),
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
