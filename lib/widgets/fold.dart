import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Smoothly opens and closes [child] along [axis] while keeping its content
/// unclickable and out of keyboard focus when folded away.
class Fold extends StatefulWidget {
  const Fold({
    super.key,
    required this.open,
    required this.child,
    this.axis = Axis.vertical,
    this.duration = Motion.morph,
    this.sizeCurve = Motion.morphCurve,
    this.reverseSizeCurve,
    this.opacityCurve = Motion.morphCurve,
    this.reverseOpacityCurve,
    this.removeWhenClosed = false,
  });

  final bool open;
  final Widget child;
  final Axis axis;
  final Duration duration;
  final Curve sizeCurve;
  final Curve? reverseSizeCurve;
  final Curve opacityCurve;
  final Curve? reverseOpacityCurve;
  final bool removeWhenClosed;

  @override
  State<Fold> createState() => _FoldState();
}

class _FoldState extends State<Fold> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.open ? 1 : 0,
  )..addStatusListener(_statusChanged);

  late CurvedAnimation _size = _curvedSize();
  late CurvedAnimation _opacity = _curvedOpacity();

  CurvedAnimation _curvedSize() => CurvedAnimation(
    parent: _controller,
    curve: widget.sizeCurve,
    reverseCurve: widget.reverseSizeCurve,
  );

  CurvedAnimation _curvedOpacity() => CurvedAnimation(
    parent: _controller,
    curve: widget.opacityCurve,
    reverseCurve: widget.reverseOpacityCurve,
  );

  bool get _disabled => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void _statusChanged(AnimationStatus status) {
    if (widget.removeWhenClosed && status == AnimationStatus.dismissed && mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_disabled && _controller.isAnimating) {
      _controller.value = widget.open ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(Fold old) {
    super.didUpdateWidget(old);
    if (widget.duration != old.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.sizeCurve != old.sizeCurve || widget.reverseSizeCurve != old.reverseSizeCurve) {
      _size.dispose();
      _size = _curvedSize();
    }
    if (widget.opacityCurve != old.opacityCurve || widget.reverseOpacityCurve != old.reverseOpacityCurve) {
      _opacity.dispose();
      _opacity = _curvedOpacity();
    }
    if (widget.open != old.open) {
      if (_disabled) {
        _controller.value = widget.open ? 1 : 0;
        if (widget.removeWhenClosed) setState(() {});
      } else {
        widget.open ? _controller.forward() : _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_statusChanged);
    _size.dispose();
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.removeWhenClosed && _controller.isDismissed && !widget.open) {
      return const SizedBox.shrink();
    }
    return SizeTransition(
      sizeFactor: _size,
      axis: widget.axis,
      alignment: widget.axis == Axis.horizontal ? Alignment.centerLeft : Alignment.topCenter,
      child: FadeTransition(
        opacity: _opacity,
        child: IgnorePointer(
          ignoring: !widget.open,
          child: ExcludeFocus(excluding: !widget.open, child: widget.child),
        ),
      ),
    );
  }
}
