import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/app_theme.dart';

/// Like an [AnimatedSwitcher], fades the old child out before the new one
/// fades in, so the two never show together at any real strength. A child
/// whose key matches one still fading out (a quick switch back) turns that
/// one round, rather than starting a new one from nothing, so it keeps its
/// state and comes straight back from where it had got to.
class FadeThrough extends StatefulWidget {
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

  /// Whether [context] is in a page a [FadeThrough] with deferBuild is
  /// bringing in, built as it starts to show rather than there from the
  /// start: such a page can spread its first build over a few frames.
  static bool arriving(BuildContext context) => context.getInheritedWidgetOfExactType<_Arriving>() != null;

  // The outgoing child runs the same animation in reverse, so the two
  // halves follow [Motion.incoming] and [Motion.outgoing].
  static final _curve = CurveTween(curve: Motion.incoming);

  // The layouts in use. The default ([AnimatedSwitcher.defaultLayoutBuilder])
  // centres the two.

  /// Both fill the space given: whole pages and cards.
  static Widget fill(Widget? current, List<Widget> previous) =>
      Stack(fit: StackFit.expand, children: [...previous, ?current]);

  /// Both sit at [alignment], the box sized by the larger.
  static AnimatedSwitcherLayoutBuilder aligned(Alignment alignment) =>
      (current, previous) => Stack(alignment: alignment, children: [...previous, ?current]);

  /// Only the incoming child sizes the box; the outgoing one is pinned over
  /// its top, as wide as the box, and may hang below it as it fades.
  static Widget pinTop(Widget? current, List<Widget> previous) => Stack(
    clipBehavior: Clip.none,
    alignment: Alignment.topLeft,
    children: [
      for (final w in previous) Positioned(key: w.key, left: 0, right: 0, top: 0, child: w),
      ?current,
    ],
  );

  /// As [pinTop], but the outgoing child keeps its own width rather than
  /// holding the box to it.
  static Widget pinTopLeft(Widget? current, List<Widget> previous) => Stack(
    clipBehavior: Clip.none,
    alignment: Alignment.topLeft,
    children: [
      for (final w in previous) Positioned(key: w.key, left: 0, top: 0, child: w),
      ?current,
    ],
  );

  /// Lays the outgoing child over the incoming one. The box is as tall as
  /// either while the outgoing one still shows, so it's never cut off as it
  /// fades; once it's gone, the box takes the incoming child's height (an
  /// [AnimatedSize] above eases the change). Takes the full width.
  ///
  /// Every child sits in the same widgets, keyed by its own key, whether
  /// incoming or outgoing, so a child that starts fading out keeps its state
  /// rather than being built afresh for its last frames.
  static Widget sizeToCurrent(Widget? current, List<Widget> previous) => SizedBox(
    width: double.infinity,
    child: Stack(
      children: [
        for (final p in previous) _SizeSlot(key: p.key, fade: _opacity(p), child: p),
        if (current != null) _SizeSlot(key: current.key, child: current),
      ],
    ),
  );

  @override
  State<FadeThrough> createState() => _FadeThroughState();
}

/// A child of a [FadeThrough], fading in or out.
class _Entry {
  _Entry(this.child, this.controller, this.serial);

  Widget child;
  final AnimationController controller;
  final int serial;
  late Widget transition;
}

class _FadeThroughState extends State<FadeThrough> with TickerProviderStateMixin {
  late _Entry _current;
  final _outgoing = <_Entry>[];
  var _serial = 0;

  @override
  void initState() {
    super.initState();
    // The first child is simply there.
    _current = _entry(widget.child, value: 1);
  }

  _Entry _entry(Widget child, {required double value}) {
    final controller = AnimationController(vsync: this, duration: widget.duration, value: value);
    final entry = _Entry(child, controller, _serial++);
    controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && _outgoing.remove(entry)) {
        setState(() {});
        controller.dispose();
      }
    });
    entry.transition = _transition(entry);
    return entry;
  }

  Widget _transition(_Entry entry) {
    final anim = entry.controller.view;
    final t = anim.drive(FadeThrough._curve);
    Widget faded = FadeTransition(
      opacity: t,
      child: widget.deferBuild ? _DeferredPage(animation: anim, child: entry.child) : entry.child,
    );
    if (widget.scaleFrom != 1.0) {
      faded = ScaleTransition(
        scale: t.drive(Tween(begin: widget.scaleFrom, end: 1.0)),
        child: faded,
      );
    }
    return KeyedSubtree(key: ValueKey(entry.serial), child: faded);
  }

  @override
  void didUpdateWidget(FadeThrough old) {
    super.didUpdateWidget(old);
    final restyled = widget.deferBuild != old.deferBuild || widget.scaleFrom != old.scaleFrom;
    if (widget.duration != old.duration || restyled) {
      for (final entry in [_current, ..._outgoing]) {
        entry.controller.duration = widget.duration;
        if (restyled) entry.transition = _transition(entry);
      }
    }
    final child = widget.child;
    if (Widget.canUpdate(_current.child, child)) {
      _current
        ..child = child
        ..transition = _transition(_current);
      return;
    }
    _outgoing.add(_current..controller.reverse());
    // Switched back to one still fading out: it turns round.
    final back = _outgoing.where((e) => e != _current && Widget.canUpdate(e.child, child)).lastOrNull;
    if (back != null) {
      _outgoing.remove(back);
      _current = back
        ..child = child
        ..transition = _transition(back)
        ..controller.forward();
    } else {
      _current = _entry(child, value: 0)..controller.forward();
    }
  }

  @override
  void dispose() {
    for (final entry in [_current, ..._outgoing]) {
      entry.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.layoutBuilder(
    _current.transition,
    _outgoing.isEmpty
        ? const []
        : [
            _outgoing
                .map((e) => e.transition)
                .reduce((a, b) => FadeThrough._visibility(a) > FadeThrough._visibility(b) ? a : b),
          ],
  );
}

/// Marks a page that a deferred [FadeThrough] built as it began to show.
class _Arriving extends InheritedWidget {
  const _Arriving({required super.child});

  @override
  bool updateShouldNotify(_Arriving old) => false;
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

  /// Built because it began to show, not there from the start.
  late final _arrived = !_ready;
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
  Widget build(BuildContext context) => !_ready
      ? const SizedBox.expand()
      : _arrived
      ? _Arriving(child: widget.child)
      : widget.child;
}

/// One child of [FadeThrough.sizeToCurrent]. The incoming child, and an
/// outgoing one while it still shows, set the box's size; an outgoing one
/// that has faded out fills the box without sizing it. Only the placement
/// changes, never the widgets, so the child keeps its state throughout.
class _SizeSlot extends StatefulWidget {
  const _SizeSlot({super.key, this.fade, required this.child});

  /// The outgoing child's opacity; null for the incoming child.
  final Animation<double>? fade;
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
          maxHeight: _wasGone ? double.infinity : null,
          fit: OverflowBoxFit.deferToChild,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Its child's size, except that when [page] changes it eases between the
/// two pages' sizes so that neither shows outside it as a [FadeThrough]
/// over [duration] swaps them: a taller page's room opens while the old one
/// fades out, before the new one shows, and a shorter one's room closes
/// only once the old page has gone. Within a page it follows its child
/// exactly, or, with [easeWithin], eases to a new size over [Motion.morph]
/// as an [AnimatedSize] would.
class PageSize extends StatefulWidget {
  const PageSize({
    super.key,
    required this.page,
    this.duration = Motion.page,
    this.easeWithin = false,
    required this.child,
  });

  final Object page;

  /// The [FadeThrough]'s, inside it.
  final Duration duration;
  final bool easeWithin;
  final Widget child;

  @override
  State<PageSize> createState() => _PageSizeState();
}

class _PageSizeState extends State<PageSize> with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) => _PageSizeBox(
    page: widget.page,
    duration: widget.duration,
    easeWithin: widget.easeWithin,
    vsync: this,
    child: widget.child,
  );
}

class _PageSizeBox extends SingleChildRenderObjectWidget {
  const _PageSizeBox({
    required this.page,
    required this.duration,
    required this.easeWithin,
    required this.vsync,
    super.child,
  });

  final Object page;
  final Duration duration;
  final bool easeWithin;
  final TickerProvider vsync;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPageSize(page, duration, easeWithin, vsync);

  @override
  void updateRenderObject(BuildContext context, _RenderPageSize renderObject) => renderObject
    ..page = page
    ..duration = duration
    ..easeWithin = easeWithin;
}

class _RenderPageSize extends RenderProxyBox {
  _RenderPageSize(this._page, this.duration, this.easeWithin, TickerProvider vsync)
    : _controller = AnimationController(vsync: vsync, value: 1) {
    _controller.addListener(() {
      if (_controller.value != _last) markNeedsLayout();
    });
  }

  final AnimationController _controller;
  Duration duration;
  bool easeWithin;
  double _last = 1;

  /// The size it eases from, and the child's it eases to; [_phased] for a
  /// new page, whose growing comes first and shrinking last.
  Size? _from, _to;
  bool _phased = false;
  bool _newPage = false;

  Object _page;
  set page(Object value) {
    if (value == _page) return;
    _page = value;
    _newPage = true;
    markNeedsLayout();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static final _grow = Interval(0, Motion.incoming.begin, curve: Motion.morphCurve);
  static final _shrink = Interval(1 - Motion.incoming.begin, 1, curve: Motion.morphCurve);

  double _eased(double from, double to, double t) {
    final curve = !_phased ? Motion.morphCurve : (to >= from ? _grow : _shrink);
    return from + (to - from) * curve.transform(t);
  }

  void _start({required bool phased}) {
    _from = size;
    _phased = phased;
    _controller.duration = phased ? duration : Motion.morph;
    _last = 0;
    _controller.forward(from: 0);
  }

  @override
  void performLayout() {
    final child = this.child!..layout(constraints, parentUsesSize: true);
    final target = child.size;
    if (hasSize && _newPage) {
      _start(phased: true);
    } else if (hasSize && easeWithin && _to != null && target != _to && !_controller.isAnimating) {
      _start(phased: false);
    }
    _newPage = false;
    _to = target;
    _last = _controller.value;
    final from = _from;
    if (from == null || _controller.isCompleted) {
      _from = null;
      size = constraints.constrain(target);
      return;
    }
    final t = _controller.value;
    size = constraints.constrain(
      Size(_eased(from.width, target.width, t), _eased(from.height, target.height, t)),
    );
  }
}
