import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// Eases discrete wheel ticks while leaving touchpad input native. Shows no
/// scrollbar.
class SmoothTaskScroll extends StatefulWidget {
  const SmoothTaskScroll({super.key, required this.builder});
  final Widget Function(BuildContext, ScrollController) builder;
  static final dragPosition = ValueNotifier<Offset?>(null);

  @override
  State<SmoothTaskScroll> createState() => _SmoothTaskScrollState();
}

class _SmoothTaskScrollState extends State<SmoothTaskScroll> {
  final _controller = _WheelController();

  /// Every task list on screen. While a task is dragged, one timer and one
  /// pointer route serve them all, rather than one per list.
  static final _lists = <_SmoothTaskScrollState>{};
  static Timer? _edgeTimer;

  static void _dragChanged() {
    if (SmoothTaskScroll.dragPosition.value == null) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
    } else {
      _edgeTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
        for (final list in _lists.toList()) {
          list._edgeScroll();
        }
      });
    }
  }

  static void _pointer(PointerEvent event) {
    if (event is! PointerScrollEvent || SmoothTaskScroll.dragPosition.value == null) return;
    for (final list in _lists.toList()) {
      if (list._controller.hasClients && list._inside(event.position)) {
        // The drag gesture holds the scroll position. Jump directly while held.
        list._jumpBy(event.scrollDelta.dy);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    if (_lists.isEmpty) {
      SmoothTaskScroll.dragPosition.addListener(_dragChanged);
      GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    }
    _lists.add(this);
  }

  @override
  void dispose() {
    _lists.remove(this);
    if (_lists.isEmpty) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
      SmoothTaskScroll.dragPosition.removeListener(_dragChanged);
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    }
    _controller.dispose();
    super.dispose();
  }

  bool _inside(Offset point) {
    final box = context.findRenderObject() as RenderBox?;
    return box != null && box.hasSize && (Offset.zero & box.size).contains(box.globalToLocal(point));
  }

  void _jumpBy(double delta) {
    final position = _controller.position;
    _controller.jumpTo((position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent));
  }

  void _edgeScroll() {
    final point = SmoothTaskScroll.dragPosition.value;
    if (point == null || !_controller.hasClients || !_inside(point)) return;
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(point);
    const edge = 48.0;
    final delta = local.dy < edge
        ? -8 * (1 - local.dy / edge)
        : local.dy > box.size.height - edge
        ? 8 * (1 - (box.size.height - local.dy) / edge)
        : 0.0;
    if (delta != 0) _jumpBy(delta);
  }

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    // Task lists scroll without a bar beside them.
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: widget.builder(context, _controller),
  );
}

class _WheelController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _WheelPosition(physics: physics, context: context, oldPosition: oldPosition);
}

class _WheelPosition extends ScrollPositionWithSingleContext {
  _WheelPosition({required super.physics, required super.context, super.oldPosition});
  double? _wheelTarget;
  int _generation = 0;

  @override
  void pointerScroll(double delta) {
    // The global route handles held drags; avoid applying the wheel twice.
    if (SmoothTaskScroll.dragPosition.value != null) return;
    if (delta == 0) return;
    final target = ((_wheelTarget ?? pixels) + delta).clamp(minScrollExtent, maxScrollExtent).toDouble();
    if (target == pixels) return;
    _wheelTarget = target;
    final generation = ++_generation;
    animateTo(target, duration: Motion.scroll, curve: Motion.clickCurve).whenComplete(() {
      if (generation == _generation) _wheelTarget = null;
    });
  }

  @override
  void beginActivity(ScrollActivity? newActivity) {
    // A direct drag or touchpad gesture takes over from wheel easing.
    if (newActivity is DragScrollActivity) {
      _generation++;
      _wheelTarget = null;
    }
    super.beginActivity(newActivity);
  }
}
