import 'package:flutter/material.dart';

/// Static values need no ticker. Allocate an animation only while it changes,
/// then release it after its render object has adopted the settled value.
class LazyMotion extends StatefulWidget {
  const LazyMotion({
    super.key,
    required this.value,
    required this.duration,
    required this.curve,
    required this.transition,
    required this.child,
  });
  final double value;
  final Duration duration;
  final Curve curve;
  final Widget Function(Animation<double>, Widget) transition;
  final Widget child;
  @override
  State<LazyMotion> createState() => _LazyMotionState();
}

class _LazyMotionState extends State<LazyMotion> with TickerProviderStateMixin {
  AnimationController? _controller;
  CurvedAnimation? _curve;
  late Animation<double> _value = AlwaysStoppedAnimation(widget.value);
  int _generation = 0;

  @override
  void didUpdateWidget(LazyMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value == widget.value) return;
    final from = _value.value;
    final controller = _controller ??= AnimationController(vsync: this);
    _curve?.dispose();
    _curve = CurvedAnimation(parent: controller, curve: widget.curve);
    _value = Tween(begin: from, end: widget.value).animate(_curve!);
    final generation = ++_generation;
    controller.duration = widget.duration;
    controller.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted || generation != _generation || !controller.isCompleted) return;
      final curve = _curve!;
      setState(() {
        _value = AlwaysStoppedAnimation(widget.value);
        _controller = null;
        _curve = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        curve.dispose();
        controller.dispose();
      });
    });
  }

  @override
  void dispose() {
    _curve?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.transition(_value, widget.child);
}
