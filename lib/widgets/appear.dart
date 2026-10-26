import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// How a list item arrives and leaves: it opens up its space and fades in
/// when first built (if [animate]), and closes up and fades out once
/// [shown] turns false, then calls [onHidden].
class Appear extends StatefulWidget {
  const Appear({
    super.key,
    required this.animate,
    this.shown = true,
    this.onHidden,
    this.animateSize = true,
    this.fadeBeforeCollapse = false,
    required this.child,
  });

  final bool animate;
  final bool shown;
  final VoidCallback? onHidden;
  final Widget child;
  final bool animateSize, fadeBeforeCollapse;

  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Motion.morph, value: widget.animate ? 0 : 1)
    ..forward();
  late final _curved = CurvedAnimation(parent: _controller, curve: Motion.morphCurve);

  late final _sizeFirst = _controller.drive(CurveTween(curve: const Interval(0, 0.5, curve: Motion.morphCurve)));
  late final _fadeLast = _controller.drive(CurveTween(curve: const Interval(0.5, 1, curve: Motion.morphCurve)));

  @override
  void didUpdateWidget(Appear old) {
    super.didUpdateWidget(old);
    if (old.shown && !widget.shown) {
      _controller.reverse().whenCompleteOrCancel(() {
        if (mounted && !widget.shown) widget.onHidden?.call();
      });
    } else if (!old.shown && widget.shown) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final faded = FadeTransition(opacity: widget.fadeBeforeCollapse ? _fadeLast : _curved, child: widget.child);
    if (!widget.animateSize) return faded;
    return SizeTransition(
      sizeFactor: widget.fadeBeforeCollapse ? _sizeFirst : _curved,
      alignment: Alignment.topCenter,
      child: faded,
    );
  }
}
