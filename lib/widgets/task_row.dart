part of 'todo_panel.dart';

/// Collapses every task again, as when the app opens.
@visibleForTesting
void collapseAllTasks() => _TodoRowState._opened.clear();

class _TodoRow extends StatefulWidget {
  const _TodoRow({
    required this.scope,
    required this.item,
    required this.day,
    this.readOnly = false,
    this.fadeIn = false,
    this.arriving = false,
    this.leaving = false,
    required this.onRemove,
    this.make,
  });

  final TodoScope scope;
  final TodoItem item;

  /// Makes [item], a time of a repeat not made yet, the first time it's
  /// ticked or changed.
  final TodoItem Function()? make;

  /// The day the list is for; an item from before its day, week or month
  /// says when it's from.
  final DateTime day;

  /// A past day's row: no ticking or removing.
  final bool readOnly;

  /// Fades in when first shown: a newly added item.
  final bool fadeIn;

  /// Show the incoming task before its completion tick lands.
  final bool arriving;

  /// Removed: closes up.
  final bool leaving;
  final VoidCallback onRemove;

  @override
  State<_TodoRow> createState() => _TodoRowState();
}

class _TodoRowState extends State<_TodoRow> {
  /// Tasks opened since the app started. Every task starts collapsed when the
  /// app opens, and one opened stays open while the app runs, across views.
  static final _opened = <(TodoScope, int)>{};

  bool _hover = false;
  bool _pressed = false;

  /// The hover buttons exist only while shown or fading out: a long list
  /// would otherwise hold three hidden buttons per row.
  bool _actions = false;

  bool get _expanded => _opened.contains((widget.scope, widget.item.id));
  set _expanded(bool open) =>
      open ? _opened.add((widget.scope, widget.item.id)) : _opened.remove((widget.scope, widget.item.id));

  /// The repeat last shown, kept while the row closes up.
  Repeat? _repeat;
  bool _nestingOut = false;
  bool _acceptingNest = false;
  int? _incomingSubtask;
  Timer? _incomingTimer;
  Timer? _collapseTimer;
  _TaskDrag? _activeDrag;

  Future<void> _fadeForNesting() async {
    if (!mounted) return; // A source hidden by a week/month preview has already left.
    setState(() => _nestingOut = true);
    await Future<void>.delayed(Motion.morph);
  }

  void _restoreAfterNesting() {
    if (mounted) setState(() => _nestingOut = false);
  }

  Future<void> _nest(AppState state, _TaskDrag drag) async {
    if (_acceptingNest || drag.nesting) return;
    drag.nesting = true;
    drag.onAccepted?.call(); // Keep a hovered week/month destination selected.
    setState(() => _acceptingNest = true);
    var nested = false;
    try {
      await drag.fadeForNesting?.call();
      final target = state.todos[widget.scope]!.where((task) => task.id == widget.item.id).firstOrNull;
      final index = target?.subtasks.length;
      nested = state.nestTodo(drag.scope, drag.item, widget.scope, widget.item);
      if (nested && mounted) {
        _incomingTimer?.cancel();
        _arrive(index);
      }
    } finally {
      if (!nested) drag.restoreAfterNesting?.call();
      if (mounted) setState(() => _acceptingNest = false);
    }
  }

  /// Opens space for the subtask at [index] and fades it in, like a new task.
  /// A collapsed task stays collapsed, its count showing the new subtask; a
  /// task with none yet has nothing to collapse, so it opens.
  void _arrive(int? index) {
    if (widget.item.subtasks.isEmpty) _expanded = true;
    if (!_expanded) return;
    _incomingTimer?.cancel();
    setState(() => _incomingSubtask = index);
    _incomingTimer = Timer(Motion.morph, () {
      if (mounted) setState(() => _incomingSubtask = null);
    });
  }

  /// A finished task folds its subtasks away once it has glided to its
  /// place among the ticked ones. Unticking leaves it as it is.
  @override
  void didUpdateWidget(_TodoRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final item = widget.item;
    if (item.id != oldWidget.item.id || !item.done) {
      _collapseTimer?.cancel();
    } else if (!oldWidget.item.done && item.subtasks.isNotEmpty && _expanded) {
      _collapseTimer?.cancel();
      _collapseTimer = Timer(Motion.reorder, () {
        if (mounted) setState(() => _expanded = false);
      });
    }
  }

  /// The subtasks' order while one is dragged, as indexes into the list.
  List<int>? _dragOrder;

  /// Numbered steps keep their places; others sink once ticked.
  List<int> get _subtaskOrder {
    final children = widget.item.subtasks;
    final order = _dragOrder;
    if (order != null && order.length == children.length) return order;
    final all = [for (var i = 0; i < children.length; i++) i];
    return widget.item.numbered ? all : [...all.where((i) => !children[i].done), ...all.where((i) => children[i].done)];
  }

  /// Keyed by text, so a subtask keeps its row, and glides, as the list is
  /// reordered.
  Key _subtaskKey(int index) {
    final children = widget.item.subtasks;
    final text = children[index].text;
    var repeat = 0;
    for (var i = 0; i < index; i++) {
      if (children[i].text == text) repeat++;
    }
    return ValueKey((text, repeat));
  }

  /// Picked up anywhere on the row; the others glide aside as it passes
  /// over them, and it stays where it was last shown when let go. Unless
  /// they're numbered, open and ticked subtasks each keep to their own
  /// group, as ticked ones sink below.
  Widget _draggableSubtask(AppState state, int index, Widget row) {
    final p = context.palette;
    final item = widget.item;
    final child = item.subtasks[index];
    final canDrag = !widget.readOnly && !widget.leaving && item.subtasks.length > 1 && (item.numbered || !child.done);
    return DragTarget<_SubtaskDrag>(
      key: _subtaskKey(index),
      onWillAcceptWithDetails: (details) {
        final from = details.data.index;
        if (details.data.itemId != item.id || from >= item.subtasks.length) return false;
        if (!item.numbered && item.subtasks[from].done != child.done) return false;
        if (from != index) {
          final order = [..._subtaskOrder];
          final to = order.indexOf(index);
          order
            ..remove(from)
            ..insert(to, from);
          setState(() => _dragOrder = order);
        }
        return true;
      },
      builder: (context, _, _) => Draggable<_SubtaskDrag>(
        data: _SubtaskDrag(item.id, index),
        maxSimultaneousDrags: canDrag ? 1 : 0,
        onDragEnd: (_) {
          final order = _dragOrder;
          if (order == null || !mounted) return;
          setState(() => _dragOrder = null);
          if (order.length != item.subtasks.length || listEquals(order, _subtaskOrder)) return;
          state.setTodoSubtasks(widget.scope, item, [for (final i in order) item.subtasks[i]], day: widget.day);
        },
        feedback: Material(
          color: p.tile.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 220,
            padding: const EdgeInsets.all(10),
            child: Text(
              child.text,
              style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: row),
        child: row,
      ),
    );
  }

  @override
  void dispose() {
    _incomingTimer?.cancel();
    _collapseTimer?.cancel();
    super.dispose();
  }

  /// The item to change: made first, if it's a repeat's time not yet made.
  TodoItem _real() => widget.make?.call() ?? widget.item;

  Future<void> _editSubtask(AppState state, {int? index}) async {
    final children = widget.item.subtasks;
    final result = await showAppDialog<({String text, bool numbered})>(
      context: context,
      builder: (_) => _SubtaskDialog(text: index == null ? '' : children[index].text, numbered: widget.item.numbered),
    );
    if (result == null || result.text.trim().isEmpty || !mounted) return;
    final text = normaliseNote(result.text.trim());
    // The switch applies to the whole task, so every subtask takes it.
    final next = [for (final child in widget.item.subtasks) child.copyWith(numbered: result.numbered)];
    if (index == null) {
      next.add(TodoSubtask(text, numbered: result.numbered));
      _arrive(next.length - 1);
    } else {
      next[index] = next[index].copyWith(text: text);
    }
    state.setTodoSubtasks(widget.scope, _real(), next, day: widget.day);
  }

  /// When search last opened one of its subtasks, opening it to show it.
  DateTime? _foundSubtask;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final item = widget.item;
    if (AppScope.watch(context, (s) => s.found).found case final found?
        when found.at != _foundSubtask && item.uid != null && found.target.startsWith('${item.uid}#')) {
      _foundSubtask = found.at;
      _expanded = true;
    }
    final done = item.done && !widget.arriving;
    // Planned tasks are on their own day; only Today and Tomorrow carry.
    final carried =
        (widget.scope == TodoScope.today || widget.scope == TodoScope.tomorrow) &&
        widget.scope.period(item.since) != widget.scope.period(widget.day);
    // Closing up after its repeat ended, it still shows the repeat.
    final repeat = widget.leaving ? _repeat : (_repeat = state.repeatOf(item));

    final parentRow = Appear(
      animate: widget.fadeIn,
      shown: !widget.leaving && !_nestingOut,
      fadeBeforeCollapse: _nestingOut,
      child: IgnorePointer(
        ignoring: widget.readOnly || widget.leaving || _nestingOut,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = _actions = true),
          onExit: (_) => setState(() {
            _hover = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: () => state.toggleTodo(_real(), day: widget.day, scope: widget.scope),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: HoverFill(
                hover: _hover,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      _Check(done: done, hover: _hover, pressed: _pressed),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AnimatedDefaultTextStyle(
                          duration: Motion.click,
                          curve: Motion.clickCurve,
                          style: TextStyle(
                            fontFamily: Fonts.body,
                            fontSize: 15,
                            height: 1.35,
                            color: done
                                ? p.inkMuted.withValues(alpha: p.brightness == Brightness.dark ? 0.75 : 0.7)
                                : p.ink,
                            decoration: done ? TextDecoration.lineThrough : null,
                            decorationColor: p.inkMuted.withValues(alpha: 0.45),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DragTarget<_TaskDrag>(
                                onWillAcceptWithDetails: (details) =>
                                    !widget.readOnly &&
                                    widget.make == null &&
                                    !_acceptingNest &&
                                    !details.data.nesting &&
                                    widget.day == state.today &&
                                    details.data.day == state.today &&
                                    details.data.item.id != item.id &&
                                    !details.data.item.done &&
                                    details.data.item.subtasks.isEmpty,
                                onAcceptWithDetails: (details) => _nest(state, details.data),
                                builder: (context, candidates, rejected) => AnimatedContainer(
                                  duration: Motion.hover,
                                  curve: Motion.hoverCurve,
                                  decoration: BoxDecoration(
                                    color: p.accent.withValues(alpha: candidates.isEmpty ? 0 : 0.18),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text.rich(
                                    TextSpan(
                                      children: [
                                        if (item.dueTime case final time?)
                                          TextSpan(
                                            text: '${clockLabel(time)}  ',
                                            style: _timeStyle(p).copyWith(height: 1.35),
                                          ),
                                        TextSpan(text: item.text),
                                      ],
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (item.subtasks.isNotEmpty)
                                Text(
                                  '${item.subtasks.where((child) => child.done).length}/${item.subtasks.length} complete',
                                  style: TextStyle(fontSize: 12, color: p.inkMuted, decoration: TextDecoration.none),
                                ),
                              // A birthday looks like any other task here.
                              if (repeat != null && !item.birthday)
                                Row(
                                  children: [
                                    Icon(Icons.repeat_rounded, size: 12, color: p.inkMuted),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        repeat.rule.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: p.inkMuted,
                                          decoration: TextDecoration.none,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (carried) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: p.missed.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.history_rounded, size: 12, color: p.missed),
                              const SizedBox(width: 4),
                              Text(
                                dayMonth(item.since),
                                style: TextStyle(
                                  fontFamily: Fonts.ui,
                                  fontSize: 12,
                                  color: p.missed,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // As far from the buttons as they are from the row's right edge.
                        if (!widget.readOnly) const SizedBox(width: 8),
                      ],
                      if (!widget.readOnly)
                        IgnorePointer(
                          ignoring: !_hover || widget.leaving,
                          child: ExcludeFocus(
                            excluding: !_hover || widget.leaving,
                            child: AnimatedOpacity(
                              opacity: _hover ? 1 : 0,
                              duration: Motion.hover,
                              curve: Motion.hoverCurve,
                              onEnd: () {
                                if (mounted && !_hover) setState(() => _actions = false);
                              },
                              child: !_actions
                                  // The three buttons' room, so the text never reflows.
                                  ? const SizedBox(width: 3 * _TaskAction.size, height: _TaskAction.size)
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _TaskAction(
                                          tooltip: 'Add subtask',
                                          icon: Icons.playlist_add_rounded,
                                          onPressed: () => _editSubtask(state),
                                        ),
                                        _TaskAction(
                                          tooltip: 'Edit task',
                                          icon: Icons.edit_rounded,
                                          onPressed: () =>
                                              _editTask(context, widget.scope, item, widget.day, make: widget.make),
                                        ),
                                        _TaskAction(
                                          tooltip: 'Remove',
                                          icon: Icons.close_rounded,
                                          onPressed: () => _removeTask(context, item, widget.day, widget.onRemove),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final row = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(padding: const EdgeInsets.only(left: 18), child: parentRow),
            if (item.subtasks.isNotEmpty)
              // Centred on the checkbox, which is centred in its row.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _TaskAction(
                    tooltip: _expanded ? 'Collapse subtasks' : 'Expand subtasks',
                    icon: _expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                ),
              ),
          ],
        ),
        ClipRect(
          child: AnimatedSize(
            // An arriving subtask opens its space at a new task's pace.
            duration: _incomingSubtask == null ? Motion.click : Motion.morph,
            curve: _incomingSubtask == null ? Motion.clickCurve : Motion.morphCurve,
            alignment: Alignment.topCenter,
            child: !_expanded || item.subtasks.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(left: 44, bottom: 4),
                    child: GlidingColumn(
                      children: [
                        for (final index in _subtaskOrder)
                          _draggableSubtask(
                            state,
                            index,
                            SearchGlow(
                              target: item.uid == null ? null : '${item.uid}#$index',
                              // After its task's brief light.
                              delay: const Duration(milliseconds: 700),
                              child: Appear(
                                animate: _incomingSubtask == index || widget.fadeIn,
                                animateSize: false,
                                child: _SubtaskRow(
                                  done: item.subtasks[index].done,
                                  text: item.subtasks[index].text,
                                  number: item.numbered ? index + 1 : null,
                                  readOnly: widget.readOnly,
                                  onToggle: () {
                                    final next = [...item.subtasks];
                                    next[index] = next[index].copyWith(done: !next[index].done);
                                    state.setTodoSubtasks(widget.scope, item, next, day: widget.day);
                                  },
                                  onEdit: () => _editSubtask(state, index: index),
                                  onRemove: () {
                                    final next = [...item.subtasks]..removeAt(index);
                                    state.setTodoSubtasks(widget.scope, item, next, day: widget.day);
                                  },
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
    // Keep the row's subtree mounted when completion changes. Swapping the
    // Draggable for the row resets its tick and nested glide animations.
    final canDrag =
        !item.done &&
        !widget.readOnly &&
        widget.make == null &&
        widget.day == state.today &&
        !widget.leaving &&
        !_nestingOut;
    final drag = _TaskDrag(widget.scope, item, widget.day)
      ..fadeForNesting = _fadeForNesting
      ..restoreAfterNesting = _restoreAfterNesting;
    return Draggable<_TaskDrag>(
      data: drag,
      onDragStarted: () {
        _activeDrag = drag;
        SmoothTaskScroll.dragPosition.value = Offset.zero;
      },
      onDragUpdate: (details) => SmoothTaskScroll.dragPosition.value = details.globalPosition,
      onDragEnd: (_) => SmoothTaskScroll.dragPosition.value = null,
      onDraggableCanceled: (_, _) {
        SmoothTaskScroll.dragPosition.value = null;
        _activeDrag?.onFinished?.call();
      },
      onDragCompleted: () {
        SmoothTaskScroll.dragPosition.value = null;
        _activeDrag?.onFinished?.call();
      },
      maxSimultaneousDrags: canDrag ? 1 : 0,
      feedback: Material(
        color: p.tile.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 240,
          padding: const EdgeInsets.all(12),
          child: Text(
            item.text,
            style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: row),
      child: row,
    );
  }
}

class _Check extends StatefulWidget {
  const _Check({required this.done, required this.hover, required this.pressed});

  final bool done;
  final bool hover;
  final bool pressed;

  @override
  State<_Check> createState() => _CheckState();
}

class _CheckState extends State<_Check> with TickerProviderStateMixin {
  late final _fill = AnimationController(vsync: this, duration: Motion.click, value: widget.done ? 1 : 0);
  late final _curved = CurvedAnimation(parent: _fill, curve: Motion.clickCurve);
  late final _hover = AnimationController(vsync: this, duration: Motion.hover);

  @override
  void didUpdateWidget(_Check old) {
    super.didUpdateWidget(old);
    if (widget.done != old.done) {
      widget.done ? _fill.forward() : _fill.reverse();
    }
    if (widget.hover != old.hover) {
      widget.hover ? _hover.animateTo(1, curve: Motion.hoverCurve) : _hover.animateBack(0, curve: Motion.hoverCurve);
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _fill.dispose();
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: PressScale(
        hover: widget.hover,
        pressed: widget.pressed,
        lift: 1.06,
        dip: 0.88,
        child: CustomPaint(
          size: const Size.square(20),
          painter: _CheckPainter(fill: _curved, hover: _hover, palette: context.palette),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.fill, required this.hover, required this.palette})
    : super(repaint: Listenable.merge([fill, hover]));

  final Animation<double> fill;
  final Animation<double> hover;
  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final t = fill.value;
    final h = hover.value;
    final centre = size.center(Offset.zero);
    final r = size.width / 2;

    // The ring fades as the fill arrives, so there's never a hard swap.
    final ring = Color.lerp(p.inkMuted.withValues(alpha: 0.38), p.accent.withValues(alpha: 0.6), h)!;
    canvas.drawCircle(
      centre,
      r - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = ring.withValues(alpha: ring.a * (1 - t)),
    );
    if (t > 0) {
      canvas.drawCircle(centre, r, Paint()..color = p.done.withValues(alpha: t));
    }

    // The tick grows in after the fill, as on a ritual square.
    paintMark(canvas, centre, Icons.check_rounded, 13, p.onAccent, Motion.incoming.transform(t));
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.palette != palette || old.fill != fill || old.hover != hover;
}

/// A subtask being dragged to a new place in its task.
class _SubtaskDrag {
  const _SubtaskDrag(this.itemId, this.index);
  final int itemId;
  final int index;
}

/// A subtask, laid out, tinted and ticked as a task row is.
class _SubtaskRow extends StatefulWidget {
  const _SubtaskRow({
    required this.done,
    required this.text,
    required this.number,
    required this.readOnly,
    required this.onToggle,
    required this.onEdit,
    required this.onRemove,
  });

  final bool done;
  final String text;

  /// Its place in a numbered list.
  final int? number;
  final bool readOnly;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  State<_SubtaskRow> createState() => _SubtaskRowState();
}

class _SubtaskRowState extends State<_SubtaskRow> {
  bool _hover = false;
  bool _pressed = false;
  bool _actions = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final done = widget.done;
    return IgnorePointer(
      ignoring: widget.readOnly,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = _actions = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: HoverFill(
              hover: _hover,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    _Check(done: done, hover: _hover, pressed: _pressed),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AnimatedDefaultTextStyle(
                        duration: Motion.click,
                        curve: Motion.clickCurve,
                        style: TextStyle(
                          fontFamily: Fonts.body,
                          fontSize: 15,
                          height: 1.35,
                          color: done
                              ? p.inkMuted.withValues(alpha: p.brightness == Brightness.dark ? 0.75 : 0.7)
                              : p.ink,
                          decoration: done ? TextDecoration.lineThrough : null,
                          decorationColor: p.inkMuted.withValues(alpha: 0.45),
                        ),
                        // One paragraph, as a task's time and name, so the
                        // number keeps the text's baseline at any scale; two
                        // round to the pixel apart.
                        child: Text.rich(
                          TextSpan(
                            children: [
                              if (widget.number case final number?)
                                TextSpan(text: '$number. ', style: _timeStyle(p).copyWith(height: 1.35)),
                              TextSpan(text: widget.text),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!widget.readOnly)
                      IgnorePointer(
                        ignoring: !_hover,
                        child: ExcludeFocus(
                          excluding: !_hover,
                          child: AnimatedOpacity(
                            opacity: _hover ? 1 : 0,
                            duration: Motion.hover,
                            curve: Motion.hoverCurve,
                            onEnd: () {
                              if (mounted && !_hover) setState(() => _actions = false);
                            },
                            child: !_actions
                                // The two buttons' room, so the text never reflows.
                                ? const SizedBox(width: 2 * _TaskAction.size, height: _TaskAction.size)
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _TaskAction(
                                        tooltip: 'Edit subtask',
                                        icon: Icons.edit_rounded,
                                        onPressed: widget.onEdit,
                                      ),
                                      _TaskAction(
                                        tooltip: 'Remove subtask',
                                        icon: Icons.close_rounded,
                                        onPressed: widget.onRemove,
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
