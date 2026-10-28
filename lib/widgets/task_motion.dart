import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';

import '../theme/app_theme.dart';

/// Gives nested lists the same glide as the main task list.
class GlidingColumn extends StatefulWidget {
  const GlidingColumn({super.key, required this.children});

  final List<Widget> children;

  @override
  State<GlidingColumn> createState() => GlidingColumnState();
}

class GlidingColumnState extends State<GlidingColumn> with SingleTickerProviderStateMixin {
  late final _motion = ReorderMotion(this);

  @override
  void didUpdateWidget(GlidingColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    _motion.update(oldWidget.children.map((child) => child.key), widget.children.map((child) => child.key));
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SlidingColumn(
    progress: _motion.progress,
    generation: _motion.generation,
    lift: context.palette.tile,
    children: widget.children,
  );
}

/// Stacks its children like a Column, but when they're reordered each one
/// glides from where it was drawn to its new place. Paint-only: children
/// are laid out once at their new places and only drawn somewhere else.
class _SlidingColumn extends MultiChildRenderObjectWidget {
  const _SlidingColumn({required this.progress, required this.generation, required this.lift, required super.children});

  /// Runs 0 to 1 for each reorder.
  final Animation<double> progress;

  /// Goes up by one with each reorder, so every row restarts from where it
  /// is on screen, even one still moving from the last change.
  final int generation;

  /// The card colour under a row that's lifted while it glides, beneath it.
  final Color lift;

  @override
  _RenderSlidingColumn createRenderObject(BuildContext context) => _RenderSlidingColumn(progress, generation, lift);

  @override
  void updateRenderObject(BuildContext context, _RenderSlidingColumn renderObject) => renderObject
    ..progress = progress
    ..generation = generation
    ..lift = lift;
}

class _SlideParentData extends ContainerBoxParentData<RenderBox> {
  double? target;
  double? from;
  double? painted;
}

class _RenderSlidingColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SlideParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SlideParentData> {
  _RenderSlidingColumn(this._progress, this._generation, this._lift);

  Color _lift;
  set lift(Color value) {
    if (value == _lift) return;
    _lift = value;
    markNeedsPaint();
  }

  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (value == _progress) return;
    if (attached) {
      _progress.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _progress = value;
    markNeedsPaint();
  }

  int _generation;
  int? _laidOutFor;
  set generation(int value) {
    if (value == _generation) return;
    _generation = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _progress.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SlideParentData) child.parentData = _SlideParentData();
  }

  @override
  void performLayout() {
    final restart = _laidOutFor != null && _laidOutFor != _generation;
    _laidOutFor = _generation;
    var y = 0.0;
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _SlideParentData;
      child.layout(BoxConstraints.tightFor(width: constraints.maxWidth), parentUsesSize: true);
      // A new row starts in place; a moved one from where it was last drawn.
      data.from = restart ? (data.painted ?? y) : (data.from ?? y);
      data.target = y;
      y += child.size.height;
      child = data.nextSibling;
    }
    size = constraints.constrain(Size(constraints.maxWidth, y));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final t = _progress.value;
    // The row going furthest (the one just ticked) rides above the rest on
    // the card's colour, so rows never show through each other as they pass.
    // Only when rows cross: rows closing up after a removal just slide.
    var furthest = 0.0;
    var up = false, down = false;
    for (var child = firstChild; child != null; child = (child.parentData! as _SlideParentData).nextSibling) {
      final data = child.parentData! as _SlideParentData;
      final move = data.target! - data.from!;
      furthest = math.max(furthest, move.abs());
      up |= move < -0.5;
      down |= move > 0.5;
    }
    if (!(up && down)) furthest = double.infinity;
    final lifted = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _SlideParentData;
      final distance = (data.target! - data.from!).abs();
      final y = t >= 1 ? data.target! : data.from! + (data.target! - data.from!) * t;
      if (t >= 1) data.from = data.target;
      data.painted = y;
      // Hit testing and tooltips follow the row to where it's drawn.
      data.offset = Offset(0, y);
      if (t < 1 && distance > 0.5 && distance == furthest) {
        lifted.add(child);
      } else {
        context.paintChild(child, offset + data.offset);
      }
      child = data.nextSibling;
    }
    for (final row in lifted) {
      final rect = (offset + (row.parentData! as _SlideParentData).offset) & row.size;
      final rrect = RRect.fromRectAndRadius(rect.deflate(1), const Radius.circular(10));
      context.canvas.drawRRect(rrect, Paint()..color = _lift);
      context.paintChild(row, rect.topLeft);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Shared timing and linear membership checks for task and subtask reorders.
class ReorderMotion {
  ReorderMotion(TickerProvider vsync)
    : controller = AnimationController(vsync: vsync, duration: Motion.reorder, value: 1) {
    progress = CurvedAnimation(parent: controller, curve: Motion.morphCurve);
  }
  final AnimationController controller;
  late final CurvedAnimation progress;
  int generation = 0;
  void update(Iterable<Object?> previous, Iterable<Object?> next) {
    final before = previous.toList(), after = next.toList();
    final oldKeys = before.toSet(), newKeys = after.toSet();
    if (!listEquals(before.where(newKeys.contains).toList(), after.where(oldKeys.contains).toList())) {
      generation++;
      controller.forward(from: 0);
    }
  }

  void dispose() {
    progress.dispose();
    controller.dispose();
  }
}

/// A list's rows as a sliver: only those in or near the viewport are
/// built, and each glides to a new place when they're reordered.
class LazyTaskSliver extends StatefulWidget {
  const LazyTaskSliver({super.key, required this.ids, required this.itemBuilder});

  /// Each row's key, in order.
  final List<Object> ids;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<LazyTaskSliver> createState() => _LazyTaskSliverState();
}

class _LazyTaskSliverState extends State<LazyTaskSliver> with SingleTickerProviderStateMixin {
  late final _motion = ReorderMotion(this);

  @override
  void didUpdateWidget(LazyTaskSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    _motion.update(oldWidget.ids, widget.ids);
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indices = {for (final (i, id) in widget.ids.indexed) id: i};
    return SliverList.builder(
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      addSemanticIndexes: false,
      itemCount: widget.ids.length,
      findChildIndexCallback: (key) => key is ValueKey ? indices[key.value] : null,
      itemBuilder: (context, i) => _GlideRow(
        key: ValueKey(widget.ids[i]),
        progress: _motion.progress,
        generation: _motion.generation,
        position: Scrollable.of(context).position,
        color: context.palette.tile,
        child: RepaintBoundary(child: widget.itemBuilder(context, i)),
      ),
    );
  }
}

class _GlideRow extends SingleChildRenderObjectWidget {
  const _GlideRow({
    super.key,
    required this.progress,
    required this.generation,
    required this.position,
    required this.color,
    required super.child,
  });
  final Animation<double> progress;
  final int generation;
  final ScrollPosition position;
  final Color color;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGlideRow(progress, generation, position, color);
  @override
  void updateRenderObject(BuildContext context, _RenderGlideRow renderObject) => renderObject
    ..generation = generation
    ..color = color;
}

/// Paint-only movement in scroll-content coordinates. Scrolling stays native.
class _RenderGlideRow extends RenderProxyBox {
  _RenderGlideRow(this.progress, this.generation, this.position, this.color);
  final Animation<double> progress;
  final ScrollPosition position;
  int generation;
  Color color;
  int? _paintedGeneration;
  double? _painted, _from;
  Offset _translation = Offset.zero;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    progress.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final target = localToGlobal(Offset.zero).dy + position.pixels;
    if (_paintedGeneration != generation) {
      _from = _painted ?? target;
      _paintedGeneration = generation;
    }
    final y = progress.value >= 1 ? target : _from! + (target - _from!) * progress.value;
    _painted = y;
    _translation = Offset(0, y - target);
    if (_translation.dy.abs() > 0.1) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius((offset + _translation) & size, const Radius.circular(10)),
        Paint()..color = color,
      );
    }
    if (child != null) context.paintChild(child!, offset + _translation);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(0, _translation.dy, 0, 1);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
    offset: _translation,
    position: position,
    hitTest: (result, transformed) => super.hitTest(result, position: transformed),
  );
}
