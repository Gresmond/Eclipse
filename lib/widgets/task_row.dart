part of 'todo_panel.dart';

class _TodoRow extends StatefulWidget {
  const _TodoRow({
    required this.scope,
    required this.item,
    required this.day,
    this.readOnly = false,
    this.upcomingDate,
    this.showUpcomingWeekday = true,
    this.fadeIn = false,
    this.arriving = false,
    this.leaving = false,
    required this.onRemove,
    this.make,
    this.order,
  });

  final DateTime? upcomingDate;
  final bool showUpcomingWeekday;

  final TodoScope scope;
  final TodoItem item;
  final TaskOrder? order;

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

/// Hides a row's hover look while a task or subtask is being dragged, bringing
/// it back after if the pointer is still over the row.
mixin _HoverUnlessDragging<T extends StatefulWidget> on State<T> {
  bool _pointer = false;
  bool _focused = false;
  ValueNotifier<bool>? _dragging;
  bool get _hover => (_pointer || _focused) && !(_dragging?.value ?? false);

  void _dragChanged() => setState(() {});

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = AppScope.read(context).draggingTask;
    if (notifier != _dragging) {
      _dragging?.removeListener(_dragChanged);
      _dragging = notifier;
      _dragging?.addListener(_dragChanged);
    }
  }

  @override
  void dispose() {
    _dragging?.removeListener(_dragChanged);
    super.dispose();
  }
}

class _TodoRowState extends State<_TodoRow> with _HoverUnlessDragging {
  bool _pressed = false;

  /// The hover buttons exist only while shown or fading out: a long list
  /// would otherwise hold three hidden buttons per row.
  bool _actions = false;
  bool _touchActions = false;

  @override
  bool get _hover => (_pointer || _focused || _touchActions) && !(_dragging?.value ?? false);

  Set<(TodoScope, int)> get _opened => AppScope.read(context).openedTasks;
  bool get _expanded => _opened.contains((widget.scope, widget.item.id));
  set _expanded(bool open) =>
      open ? _opened.add((widget.scope, widget.item.id)) : _opened.remove((widget.scope, widget.item.id));

  /// The repeat last shown, kept while the row closes up.
  Repeat? _repeat;
  bool _nestingOut = false;

  /// The row, or which of its subtasks, is being dragged: it dims in place
  /// rather than being swapped for a dimmed copy, which rebuilt its whole
  /// subtree as the drag began and again as it ended.
  bool _draggingRow = false;
  int? _draggingSubtask;
  void _dragDim({bool? row, int? subtask, bool clear = false}) {
    if (!mounted) return;
    setState(() {
      if (row != null) _draggingRow = row;
      if (subtask != null || clear) _draggingSubtask = subtask;
    });
  }

  Widget _dimmed(bool dim, Widget child) =>
      AnimatedOpacity(opacity: dim ? 0.3 : 1, duration: Motion.hover, curve: Motion.hoverCurve, child: child);
  bool _acceptingNest = false;

  /// A dragged task is over the middle of the row, to nest in it.
  bool _nestOver = false;

  /// The row a dragged task is over, without its subtasks.
  BuildContext? _zones;
  int? _incomingSubtask;
  Timer? _incomingTimer;
  Timer? _collapseTimer;
  _TaskDrag? _activeDrag;

  Future<void> _fadeForNesting() async {
    if (!mounted) {
      return; // A source hidden by a week/month preview has already left.
    }
    setState(() => _nestingOut = true);
    await Future<void>.delayed(Motion.morph);
  }

  void _restoreAfterNesting() {
    if (mounted) setState(() => _nestingOut = false);
  }

  bool _nests(AppState state, _TaskDrag drag) =>
      !widget.readOnly &&
      widget.make == null &&
      !widget.item.done &&
      !_acceptingNest &&
      !drag.nesting &&
      widget.day == state.today &&
      drag.day == state.today &&
      drag.item.id != widget.item.id &&
      !drag.item.done &&
      drag.item.subtasks.isEmpty &&
      // From the other card, it moves there rather than nesting.
      _inWeekAhead(state, drag.item) == (widget.upcomingDate == null);

  void _setNestOver(bool over) {
    if (over != _nestOver) setState(() => _nestOver = over);
  }

  /// A task dragged over the row nests in it from the middle, or goes
  /// before or after it from the top or bottom where it can be put in
  /// order; one that can't nests from all of it.
  Widget _dropZones(AppState state, Widget child) {
    final order = widget.order;
    final task = (widget.scope, widget.item);
    bool places(_TaskDrag drag) => order != null && order._canPlace(drag, task);
    return DragTarget<_TaskDrag>(
      onWillAcceptWithDetails: (details) => _nests(state, details.data) || places(details.data),
      onMove: (details) {
        final drag = details.data;
        final box = _zones?.findRenderObject();
        if (box is! RenderBox || !box.hasSize || box.size.height == 0) return;
        final y = box.globalToLocal(details.offset + drag.grab).dy / box.size.height;
        final nests = _nests(state, drag), placed = places(drag);
        final edge = !placed ? 0.0 : (nests ? 0.3 : 0.5);
        if (nests && y >= edge && y <= 1 - edge) return _setNestOver(true);
        _setNestOver(false);
        if (placed) order!._place(drag, task, after: y > 0.5);
      },
      onLeave: (_) => _setNestOver(false),
      onAcceptWithDetails: (details) {
        if (_nestOver) {
          _setNestOver(false);
          _nest(state, details.data);
        } else if (places(details.data)) {
          order!._keep();
        }
      },
      builder: (context, _, _) {
        _zones = context;
        return child;
      },
    );
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
      if (!mounted) return;
      final future = state.repeatOf(widget.item) == null ? false : await _askWhich(context, removing: false);
      if (future == null || !mounted) return;
      nested = state.nestTodo(drag.scope, drag.item, widget.scope, widget.item, future: future);
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
    final dragging = state.draggingTask;
    return DragTarget<_SubtaskDrag>(
      key: _subtaskKey(index),
      onWillAcceptWithDetails: (details) {
        final from = details.data.index;
        if (details.data.itemId != item.id || from >= item.subtasks.length) {
          return false;
        }
        if (!item.numbered && item.subtasks[from].done != child.done) {
          return false;
        }
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
        onDragStarted: () {
          dragging.value = true;
          _dragDim(subtask: index);
        },
        onDragCompleted: () => dragging.value = false,
        onDraggableCanceled: (_, _) => dragging.value = false,
        onDragEnd: (_) {
          _dragDim(clear: true);
          final order = _dragOrder;
          if (order == null || !mounted) return;
          final base = item.numbered
              ? [for (var i = 0; i < item.subtasks.length; i++) i]
              : [
                  for (var i = 0; i < item.subtasks.length; i++)
                    if (!item.subtasks[i].done) i,
                  for (var i = 0; i < item.subtasks.length; i++)
                    if (item.subtasks[i].done) i,
                ];
          if (order.length != item.subtasks.length || listEquals(order, base)) {
            setState(() => _dragOrder = null);
            return;
          }
          // The new order stays up while a repeat's asks which times take it.
          _setSubtasks(state, [for (final i in order) item.subtasks[i]]).whenComplete(() {
            if (mounted) setState(() => _dragOrder = null);
          });
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
        child: _dimmed(_draggingSubtask == index, row),
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

  /// Gives this task the checklist [next]. A change to a repeat's steps,
  /// not just their ticks, asks whether it's for this time or every one
  /// after it too.
  Future<void> _setSubtasks(AppState state, List<TodoSubtask> next) async {
    final before = widget.item.subtasks;
    final repeat = state.repeatOf(widget.item);
    var future = false;
    if (repeat != null && !_sameSteps(before, next)) {
      final answer = await _askWhich(context, removing: false);
      if (answer == null || !mounted) return;
      future = answer;
    }
    if (future) {
      state.setRepeatSubtasks(widget.scope, _real(), repeat!, next, day: widget.day);
    } else {
      state.setTodoSubtasks(widget.scope, _real(), next, day: widget.day);
    }
  }

  static bool _sameSteps(List<TodoSubtask> a, List<TodoSubtask> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].text != b[i].text || a[i].numbered != b[i].numbered) {
        return false;
      }
    }
    return true;
  }

  Future<void> _editSubtask(AppState state, {int? index}) async {
    final children = widget.item.subtasks;
    final result = await showAppDialog<({String text, bool numbered, String? note})>(
      context: context,
      builder: (_) => _SubtaskDialog(
        text: index == null ? '' : children[index].text,
        numbered: widget.item.numbered,
        note: index == null ? null : children[index].note,
      ),
    );
    if (result == null || result.text.trim().isEmpty || !mounted) return;
    final text = normaliseNote(result.text.trim());
    // The switch applies to the whole task, so every subtask takes it.
    final next = [for (final child in widget.item.subtasks) child.copyWith(numbered: result.numbered)];
    if (index == null) {
      next.add(TodoSubtask(text, numbered: result.numbered).withNote(result.note));
      _arrive(next.length - 1);
    } else {
      next[index] = next[index].copyWith(text: text).withNote(result.note);
    }
    await _setSubtasks(state, next);
  }

  /// Opens the task's note, or its subtask at [index]'s, and keeps what's
  /// saved. A repeat's time not made yet is made first, as when it's ticked;
  /// the note is that time's alone.
  Future<void> _editTaskNote(AppState state, {int? index}) async {
    final item = widget.item;
    final child = index == null ? null : item.subtasks[index];
    final result = await _editNote(context, child?.text ?? item.text, child?.note ?? item.note);
    if (result == null || !mounted) return;
    if (index == null) {
      state.setTodoNote(widget.scope, _real(), result, day: widget.day);
    } else if (cleanNote(result) != child!.note) {
      final next = [...item.subtasks];
      next[index] = next[index].withNote(result);
      state.setTodoSubtasks(widget.scope, _real(), next, day: widget.day);
    }
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
      child: Focus(
        canRequestFocus: !widget.readOnly,
        descendantsAreFocusable: !widget.readOnly,
        onFocusChange: (focused) {
          if (_focused != focused) {
            setState(() {
              _focused = focused;
              if (focused && !widget.readOnly) _actions = true;
            });
          }
        },
        onKeyEvent: widget.readOnly
            ? null
            : (node, event) {
                if (node.hasPrimaryFocus &&
                    event is KeyDownEvent &&
                    (event.logicalKey == LogicalKeyboardKey.enter ||
                        event.logicalKey == LogicalKeyboardKey.space)) {
                  state.toggleTodo(_real(), day: widget.day, scope: widget.scope);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
        child: IgnorePointer(
          ignoring: widget.leaving || _nestingOut,
          child: MouseRegion(
            cursor: widget.readOnly ? MouseCursor.defer : SystemMouseCursors.click,
            onEnter: widget.readOnly ? null : (_) => setState(() => _pointer = _actions = true),
            onExit: widget.readOnly
                ? null
                : (_) => setState(() {
                    _pointer = false;
                    _pressed = false;
                  }),
            child: TapRegion(
              onTapOutside: (_) {
                if (_touchActions && mounted) setState(() => _touchActions = false);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: widget.readOnly || item.birthday ? null : (_) => setState(() => _pressed = true),
                onTapUp: widget.readOnly || item.birthday ? null : (_) => setState(() => _pressed = false),
                onTapCancel: widget.readOnly || item.birthday ? null : () => setState(() => _pressed = false),
                onTap: widget.readOnly
                    ? null
                    : item.birthday
                    ? () => editTask(context, widget.scope, item, widget.day, make: widget.make)
                    : () => state.toggleTodo(_real(), day: widget.day, scope: widget.scope),
                onLongPress: widget.readOnly
                    ? null
                    : () => setState(() {
                        _touchActions = !_touchActions;
                        if (_touchActions) _actions = true;
                      }),
            child: Padding(
              padding: EdgeInsets.only(
                top: widget.upcomingDate != null && !widget.showUpcomingWeekday ? 6 : 2,
                bottom: 2,
              ),
              child: HoverFill(
                hover: _hover,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: widget.upcomingDate == null ? 8 : 0, vertical: 4),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: widget.upcomingDate == null ? 43 : 0),
                    child: Row(
                      children: [
                        if (widget.upcomingDate == null) ...[
                          if (item.birthday)
                            SizedBox.square(
                              dimension: MediaQuery.textScalerOf(context).scale(20),
                              child: Center(child: Icon(_birthdayIcon, size: 18, color: p.accent)),
                            )
                          else
                            _Check(done: done, hover: _hover, pressed: _pressed),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: AnimatedDefaultTextStyle(
                            duration: context.themed(Motion.click),
                            curve: Motion.clickCurve,
                            style: TextStyle(
                              fontFamily: Fonts.body,
                              fontSize: 15,
                              height: 1.35,
                              color: done ? p.inkMuted : p.ink,
                              decoration: done ? TextDecoration.lineThrough : null,
                              decorationColor: p.inkMuted.withValues(alpha: 0.45),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AnimatedContainer(
                                  duration: context.themed(Motion.hover),
                                  curve: Motion.hoverCurve,
                                  decoration: BoxDecoration(
                                    color: p.accent.withValues(alpha: _nestOver ? 0.18 : 0),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if ((widget.upcomingDate != null && widget.showUpcomingWeekday) ||
                                          item.dueTime != null ||
                                          item.location != null)
                                        _Caption(
                                          weekday: switch (widget.upcomingDate) {
                                            final date? when widget.showUpcomingWeekday => weekdayNames[date.weekday - 1],
                                            _ => null,
                                          },
                                          time: item.dueTime,
                                          location: item.location,
                                        ),
                                      Text(item.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                                    ],
                                  ),
                                ),
                                if (item.note case final note?)
                                  _NoteLine(note, onTap: widget.readOnly ? null : () => _editTaskNote(state)),
                                if (item.subtasks.isNotEmpty)
                                  Text(
                                    '${item.subtasks.where((child) => child.done).length} of ${item.subtasks.length} subtasks complete',
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
                            child: PixelTooltip(
                              message: 'Originally planned for ${shortDay(item.since, today: widget.day)}',
                              child: Icon(Icons.history_rounded, size: 12, color: p.missedInk),
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
                                duration: context.themed(Motion.hover),
                                curve: Motion.hoverCurve,
                                onEnd: () {
                                  if (mounted && !_hover) {
                                    setState(() => _actions = false);
                                  }
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
                                                editTask(context, widget.scope, item, widget.day, make: widget.make),
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
        ),
      ),
      ),
    );
    final row = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _dropZones(
          state,
          Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.only(left: widget.upcomingDate == null || item.subtasks.isNotEmpty ? 18 : 0),
                child: parentRow,
              ),
              if (item.subtasks.isNotEmpty)
                // Centred on the checkbox, which is centred in its row.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Align(
                    alignment: Alignment.center,
                    child: _TaskAction(
                      tooltip: _expanded ? 'Collapse subtasks' : 'Expand subtasks',
                      icon: _expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                      onPressed: () => setState(() => _expanded = !_expanded),
                    ),
                  ),
                ),
            ],
          ),
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
                              delay: Motion.glowDelay,
                              child: Appear(
                                animate: _incomingSubtask == index || widget.fadeIn,
                                animateSize: false,
                                child: _SubtaskRow(
                                  done: item.subtasks[index].done,
                                  text: item.subtasks[index].text,
                                  note: item.subtasks[index].note,
                                  onNote: () => _editTaskNote(state, index: index),
                                  number: item.numbered ? index + 1 : null,
                                  readOnly: widget.readOnly,
                                  onToggle: () {
                                    final next = [...item.subtasks];
                                    next[index] = next[index].copyWith(done: !next[index].done);
                                    // A repeat's time not made yet is made first, as when it's ticked.
                                    state.setTodoSubtasks(widget.scope, _real(), next, day: widget.day);
                                  },
                                  onEdit: () => _editSubtask(state, index: index),
                                  onRemove: () {
                                    final next = [...item.subtasks]..removeAt(index);
                                    _setSubtasks(state, next);
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
      ..restoreAfterNesting = _restoreAfterNesting
      ..list = widget.order?._list;
    final dragging = state.draggingTask;
    return Draggable<_TaskDrag>(
      data: drag,
      dragAnchorStrategy: (draggable, context, position) =>
          drag.grab = childDragAnchorStrategy(draggable, context, position),
      onDragStarted: () {
        _activeDrag = drag;
        dragging.value = true;
        _dragDim(row: true);
        SmoothTaskScroll.dragPosition.value = Offset.zero;
      },
      onDragUpdate: (details) => SmoothTaskScroll.dragPosition.value = details.globalPosition,
      onDragEnd: (_) {
        SmoothTaskScroll.dragPosition.value = null;
        _dragDim(row: false);
      },
      // Let go anywhere but on another task or day, it stays where it was
      // last shown among its day's tasks.
      onDraggableCanceled: (_, _) {
        dragging.value = false;
        SmoothTaskScroll.dragPosition.value = null;
        _activeDrag?.onFinished?.call();
        widget.order?._keep();
      },
      onDragCompleted: () {
        dragging.value = false;
        SmoothTaskScroll.dragPosition.value = null;
        _activeDrag?.onFinished?.call();
        widget.order?._discard();
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
      child: _dimmed(_draggingRow, row),
    );
  }
}

