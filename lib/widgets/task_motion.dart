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
  Widget build(BuildContext context) =>
      _SlidingColumn(progress: _motion.progress, generation: _motion.generation, children: widget.children);
}

/// Stacks its children like a Column, but when they're reordered each one
/// glides from where it was drawn to its new place. Paint-only: children
/// are laid out once at their new places and only drawn somewhere else.
class _SlidingColumn extends MultiChildRenderObjectWidget {
  const _SlidingColumn({required this.progress, required this.generation, required super.children});

  /// Runs 0 to 1 for each reorder.
  final Animation<double> progress;

  /// Goes up by one with each reorder, so every row restarts from where it
  /// is on screen, even one still moving from the last change.
  final int generation;

  @override
  _RenderSlidingColumn createRenderObject(BuildContext context) => _RenderSlidingColumn(progress, generation);

  @override
  void updateRenderObject(BuildContext context, _RenderSlidingColumn renderObject) => renderObject
    ..progress = progress
    ..generation = generation;
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
  _RenderSlidingColumn(this._progress, this._generation);

  final _clip = LayerHandle<ClipPathLayer>();

  /// The row crossing the others as last painted, on top to the eye and so
  /// to the pointer.
  RenderBox? _lifted;

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
  void dispose() {
    _clip.layer = null;
    super.dispose();
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
    // The row going furthest (the one just ticked) crosses the others. They
    // are cut away where it passes, so no two rows ever show through each
    // other, and nothing is painted behind it: the card shows through as it
    // does everywhere else. Rows closing up after a removal just slide.
    var furthest = 0.0;
    var up = false, down = false;
    for (var child = firstChild; child != null; child = (child.parentData! as _SlideParentData).nextSibling) {
      final data = child.parentData! as _SlideParentData;
      final move = data.target! - data.from!;
      furthest = math.max(furthest, move.abs());
      up |= move < -0.5;
      down |= move > 0.5;
    }
    RenderBox? lifted;
    for (var child = firstChild; child != null; child = (child.parentData! as _SlideParentData).nextSibling) {
      final data = child.parentData! as _SlideParentData;
      final y = t >= 1 ? data.target! : data.from! + (data.target! - data.from!) * t;
      final distance = (data.target! - data.from!).abs();
      if (t >= 1) data.from = data.target;
      data.painted = y;
      // Hit testing and tooltips follow the row to where it's drawn.
      data.offset = Offset(0, y);
      if (t < 1 && up && down && lifted == null && distance > 0.5 && distance == furthest) lifted = child;
    }
    _lifted = lifted;
    void paintOthers(PaintingContext context, Offset offset) {
      for (var child = firstChild; child != null; child = (child.parentData! as _SlideParentData).nextSibling) {
        if (child != lifted) context.paintChild(child, offset + (child.parentData! as _SlideParentData).offset);
      }
    }

    if (lifted == null) {
      _clip.layer = null;
      paintOthers(context, offset);
      return;
    }
    final over = (lifted.parentData! as _SlideParentData).offset & lifted.size;
    _clip.layer = context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & size,
      _without(Offset.zero & size, over),
      paintOthers,
      oldLayer: _clip.layer,
    );
    context.paintChild(lifted, offset + (lifted.parentData! as _SlideParentData).offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final lifted = _lifted;
    final onLifted =
        lifted != null &&
        result.addWithPaintOffset(
          offset: (lifted.parentData! as _SlideParentData).offset,
          position: position,
          hitTest: (result, transformed) => lifted.hitTest(result, position: transformed),
        );
    return onLifted || defaultHitTestChildren(result, position: position);
  }
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
  final _group = _GlideGroup();

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
        group: _group,
        child: RepaintBoundary(child: widget.itemBuilder(context, i)),
      ),
    );
  }
}

/// The rows of one list as they glide: how far each built one moves this
/// reorder, so the one crossing the others is known to them all.
class _GlideGroup {
  int? _generation;
  final _moves = <_RenderGlideRow, double>{};

  /// A row starting [generation]'s glide, going [move].
  void start(_RenderGlideRow row, int generation, double move) {
    if (_generation != generation) {
      _generation = generation;
      _moves.clear();
    }
    _moves[row] = move;
  }

  void remove(_RenderGlideRow row) => _moves.remove(row);

  /// The row going furthest when rows pass each other (some go up and some
  /// down, as when one is ticked to the foot), if any.
  _RenderGlideRow? get crossing {
    var up = false, down = false;
    _RenderGlideRow? furthest;
    for (final MapEntry(key: row, value: move) in _moves.entries) {
      up |= move < -0.5;
      down |= move > 0.5;
      if (furthest == null || move.abs() > _moves[furthest]!.abs()) furthest = row;
    }
    return up && down ? furthest : null;
  }
}

class _GlideRow extends SingleChildRenderObjectWidget {
  const _GlideRow({
    super.key,
    required this.progress,
    required this.generation,
    required this.position,
    required this.group,
    required super.child,
  });
  final Animation<double> progress;
  final int generation;
  final ScrollPosition position;
  final _GlideGroup group;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGlideRow(progress, generation, position, group);
  @override
  void updateRenderObject(BuildContext context, _RenderGlideRow renderObject) => renderObject.generation = generation;
}

/// Paint-only movement in scroll-content coordinates. Scrolling stays native.
/// A row that the one crossing the others passes over is cut away under it,
/// so the two never show through each other; nothing is painted behind
/// either.
class _RenderGlideRow extends RenderProxyBox {
  _RenderGlideRow(this.progress, this.generation, this.position, this.group);
  final Animation<double> progress;
  final ScrollPosition position;
  final _GlideGroup group;
  int generation;
  int? _paintedGeneration;
  double? _painted, _from;
  Offset _translation = Offset.zero;
  final _clip = LayerHandle<ClipPathLayer>();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    progress.removeListener(markNeedsPaint);
    group.remove(this);
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  /// Where it lies now in the scroll's content, top left.
  Offset get _target => localToGlobal(Offset.zero) + Offset(0, position.pixels);

  /// The row crossing this one, in this one's terms; null if there's none,
  /// or this is it.
  Rect? _crossingOver(Offset target) {
    final crossing = progress.value < 1 ? group.crossing : null;
    return crossing == null || crossing == this || !crossing.attached || !crossing.hasSize
        ? null
        : (crossing._at(crossing._target) - target) & crossing.size;
  }

  /// Where it's drawn this frame, in the scroll's content.
  Offset _at(Offset target) {
    final from = _paintedGeneration == generation ? _from! : (_painted ?? target.dy);
    return Offset(target.dx, progress.value >= 1 ? target.dy : from + (target.dy - from) * progress.value);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final target = _target;
    if (_paintedGeneration != generation) {
      _from = _painted ?? target.dy;
      _paintedGeneration = generation;
      group.start(this, generation, target.dy - _from!);
    }
    final y = _at(target).dy;
    _painted = y;
    _translation = Offset(0, y - target.dy);
    final child = this.child;
    if (child == null) return;
    final mine = _translation & size;
    final over = _crossingOver(target);
    if (over == null || !over.overlaps(mine)) {
      _clip.layer = null;
      context.paintChild(child, offset + _translation);
      return;
    }
    _clip.layer = context.pushClipPath(
      needsCompositing,
      offset,
      mine,
      _without(mine, over),
      (context, offset) => context.paintChild(child, offset + _translation),
      oldLayer: _clip.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(0, _translation.dy, 0, 1);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Cut away under the crossing row, so a click there goes on to it.
    if (_crossingOver(_target)?.contains(position) ?? false) return false;
    return result.addWithPaintOffset(
      offset: _translation,
      position: position,
      hitTest: (result, transformed) => super.hitTest(result, position: transformed),
    );
  }
}

/// [area] less the rounded row [cut], to clip the rows [cut] passes over.
Path _without(Rect area, Rect cut) => Path()
  ..fillType = PathFillType.evenOdd
  ..addRect(area.inflate(1))
  ..addRRect(RRect.fromRectAndRadius(cut, const Radius.circular(12)));
