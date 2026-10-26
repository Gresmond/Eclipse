import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'appear.dart';
import 'confirm_on_enter.dart';
import 'fade_through.dart';
import 'hover_fill.dart';
import 'mark.dart';
import 'note_input.dart';
import 'smooth_task_scroll.dart';
import 'task_motion.dart';
import 'tile.dart';

part 'task_row.dart';
part 'task_editor.dart';

class _TaskDrag {
  _TaskDrag(this.scope, this.item, this.day);
  VoidCallback? onFinished;
  VoidCallback? onAccepted;
  Future<void> Function()? fadeForNesting;
  VoidCallback? restoreAfterNesting;
  bool nesting = false;
  final TodoScope scope;
  final TodoItem item;
  final DateTime day;
}

class TodoPanel extends StatefulWidget {
  const TodoPanel({super.key, required this.scope, this.day, this.tabbed = false});

  final TodoScope scope;
  final bool tabbed;

  /// A past day to show its recorded list; only yesterday is editable. Null
  /// for today's list.
  final DateTime? day;

  @override
  State<TodoPanel> createState() => _TodoPanelState();
}

class _TodoPanelState extends State<TodoPanel> {
  Timer? _switchTimer;
  TodoScope? _previewFrom;

  void _finishPreview() {
    _switchTimer?.cancel();
    if (!mounted || _previewFrom == null) return;
    setState(() {
      _selectedScope = _previewFrom;
      _previewFrom = null;
      _seen = null;
      _order = [];
      _clearArrivals();
      _clearDepartures();
    });
  }

  void _acceptDrag(AppState state, _TaskDrag drag) {
    _switchTimer?.cancel();
    _previewFrom = null;
    state.moveTodo(drag.scope, drag.item, _scope);
  }

  void _switchScope() {
    _switchTimer?.cancel();
    setState(() {
      _selectedScope = _scope == TodoScope.week ? TodoScope.month : TodoScope.week;
      _controller.clear();
      _due = null;
      _clearArrivals();
      _clearDepartures();
      _seen = null;
      _order = [];
    });
  }

  TodoScope? _selectedScope;
  TodoScope get _scope => _selectedScope ?? widget.scope;

  final _controller = TextEditingController();
  final _focus = FocusNode();
  DateTime? _due;

  List<int> _order = const [];

  /// Items already shown; any others fade in. Null until the first build,
  /// so a list that's just opened appears at once.
  Set<int>? _seen;

  // New arrivals open their space at the bottom before joining the sorted
  // list. A completed transfer then uses the same tick-and-glide as a tap.
  final _arriving = <int>{};
  final _arrivalTimers = <Timer>{};

  void _clearArrivals() {
    for (final timer in _arrivalTimers) {
      timer.cancel();
    }
    _arrivalTimers.clear();
    _arriving.clear();
  }

  final _departing = <int, ({TodoItem item, int index, Timer timer})>{};

  void _clearDepartures() {
    for (final departure in _departing.values) {
      departure.timer.cancel();
    }
    _departing.clear();
  }

  void _remove(AppState state, TodoItem item) {
    if (_departing.containsKey(item.id)) return;
    final timer = Timer(Motion.morph, () {
      if (mounted) setState(() => _departing.remove(item.id));
    });
    _departing[item.id] = (item: item, index: _order.indexOf(item.id), timer: timer);
    state.removeTodo(_scope, item, day: widget.day);
    setState(() {});
  }

  /// The day whose list is showing. Another day's list fades through as a
  /// whole, rather than its rows gliding or fading in one by one.
  DateTime? _shownDay;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _switchTimer?.cancel();
    _clearArrivals();
    _clearDepartures();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(AppState state) {
    if (_controller.text.trim().isEmpty) return;
    state.addTodo(_scope, _controller.text, day: widget.day, dueDate: _due);
    setState(() => _due = null);
    _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (widget.day == null ? s.todos[_scope] : s.todosRevision, s.today));
    final day = widget.day;
    final readOnly = !state.canEditDay(day ?? state.today);
    final all = day == null ? state.todos[_scope]! : state.todosOn(_scope, day);
    final listDay = day ?? state.today;
    final ids = {for (final item in all) item.id};
    if (listDay != _shownDay) {
      _shownDay = listDay;
      _clearArrivals();
      _clearDepartures();
      _seen = ids;
      _order = [];
    }
    final seen = _seen ?? ids;
    final added = ids.difference(seen);
    _arriving.removeWhere((id) => !ids.contains(id));
    if (added.isNotEmpty) {
      _arriving.addAll(added);
      late final Timer timer;
      timer = Timer(Motion.morph, () {
        _arrivalTimers.remove(timer);
        if (mounted) setState(() => _arriving.removeAll(added));
      });
      _arrivalTimers.add(timer);
    }
    _seen = ids;

    final settled = state.orderedTodos(_scope, day: day).where((item) => !_arriving.contains(item.id));
    // Arrivals first appear unchecked at the bottom, exactly like a new task.
    final items = [...settled, ...all.where((item) => _arriving.contains(item.id))];
    for (final departure in _departing.values) {
      items.insert(departure.index.clamp(0, items.length), departure.item);
    }
    final open = all.length - all.where((t) => t.done).length;
    final order = [for (final t in items) t.id];
    _order = order;

    return DragTarget<_TaskDrag>(
      onWillAcceptWithDetails: (details) =>
          !readOnly &&
          day == null &&
          details.data.day == state.today &&
          !details.data.item.done &&
          details.data.scope != _scope,
      onAcceptWithDetails: (details) => _acceptDrag(state, details.data),
      builder: (context, candidates, rejected) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: candidates.isEmpty ? null : Border.all(color: p.accent, width: 2),
        ),
        child: Tile(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TileHeader(
                  title: _scope.label,
                  caption: open == 0 && items.isNotEmpty ? 'All clear' : '$open open',
                  trailing: widget.tabbed
                      ? Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: DragTarget<_TaskDrag>(
                            onWillAcceptWithDetails: (details) {
                              if (readOnly ||
                                  day != null ||
                                  details.data.day != state.today ||
                                  details.data.item.done) {
                                return false;
                              }
                              _switchTimer?.cancel();
                              _switchTimer = Timer(const Duration(milliseconds: 500), () {
                                if (mounted && _previewFrom == null) {
                                  _previewFrom = _scope;
                                  details.data.onFinished = _finishPreview;
                                  details.data.onAccepted = () => _previewFrom = null;
                                  setState(() {
                                    _selectedScope = _scope == TodoScope.week ? TodoScope.month : TodoScope.week;
                                    _seen = null;
                                    _order = [];
                                    _clearArrivals();
                                    _clearDepartures();
                                  });
                                }
                              });
                              return true;
                            },
                            onLeave: (_) => _switchTimer?.cancel(),
                            onAcceptWithDetails: (details) {
                              _switchTimer?.cancel();
                              _acceptDrag(state, details.data);
                            },
                            builder: (context, candidates, rejected) => _TaskAction(
                              tooltip: _scope == TodoScope.week ? 'Switch to this month' : 'Switch to this week',
                              icon: Icons.swap_horiz_rounded,
                              onPressed: _switchScope,
                            ),
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 10),
              // Fills the card; scrolls only if the list outgrows it.
              Expanded(
                child: FadeThrough(
                  layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
                  child: KeyedSubtree(
                    key: ValueKey(dateKey(listDay)),
                    child: items.isEmpty
                        ? Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        color: p.empty.withValues(alpha: 0.6),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        Icons.wb_sunny_outlined,
                                        size: 16,
                                        color: p.inkMuted.withValues(alpha: 0.7),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'All clear',
                                      style: TextStyle(
                                        fontFamily: Fonts.body,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: p.inkMuted.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        : SmoothTaskScroll(
                            builder: (context, controller) => LazyTaskList(
                              controller: controller,
                              ids: [for (final item in items) item.id],
                              itemBuilder: (context, index) {
                                final item = items[index];
                                return RepaintBoundary(
                                  child: _TodoRow(
                                    scope: _scope,
                                    item: item,
                                    day: listDay,
                                    readOnly: readOnly,
                                    fadeIn: added.contains(item.id),
                                    arriving: _arriving.contains(item.id),
                                    leaving: _departing.containsKey(item.id),
                                    onRemove: () => _remove(state, item),
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ),
              ),
              // Kept while looking back, folded away, so it eases out and back
              // rather than snapping.
              ClipRect(
                child: AnimatedAlign(
                  duration: Motion.morph,
                  curve: Motion.morphCurve,
                  alignment: Alignment.topCenter,
                  heightFactor: readOnly ? 0 : 1,
                  child: AnimatedOpacity(
                    duration: Motion.morph,
                    curve: Motion.morphCurve,
                    opacity: readOnly ? 0 : 1,
                    child: IgnorePointer(
                      ignoring: readOnly,
                      child: ExcludeFocus(
                        excluding: readOnly,
                        child: Container(
                          margin: const EdgeInsets.only(top: 6, right: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
                          decoration: BoxDecoration(
                            color: p.empty.withValues(alpha: _focus.hasFocus ? 0.65 : 0.45),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: _focus.hasFocus ? p.accent.withValues(alpha: 0.45) : Colors.transparent,
                              width: 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              if (_scope == TodoScope.week || _scope == TodoScope.month)
                                _TaskAction(
                                  tooltip: _due == null
                                      ? 'Add a due date'
                                      : 'Due ${dayMonth(_due!)}/${_due!.year} — click to change',
                                  icon: _due == null ? Icons.calendar_today_outlined : Icons.event_available_outlined,
                                  onPressed: () async {
                                    final selected = await _pickDueDate(context, _due, _scope);
                                    if (selected != null && mounted) setState(() => _due = selected);
                                  },
                                )
                              else
                                Icon(Icons.add_rounded, size: 18, color: _focus.hasFocus ? p.accent : p.inkMuted),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _focus,
                                  textCapitalization: TextCapitalization.sentences,
                                  inputFormatters: const [NoteInputFormatter()],
                                  style: TextStyle(fontFamily: Fonts.body, fontSize: 13.5, color: p.ink),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    hintText: 'Add a task',
                                    hintStyle: TextStyle(
                                      fontFamily: Fonts.body,
                                      color: p.inkMuted.withValues(alpha: 0.65),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                                  ),
                                  onSubmitted: (_) => _submit(state),
                                ),
                              ),
                              if (_due != null) ...[
                                const SizedBox(width: 6),
                                Text(
                                  dayMonth(_due!),
                                  style: TextStyle(fontFamily: Fonts.body, fontSize: 11, color: p.inkMuted),
                                ),
                                _TaskAction(
                                  tooltip: 'Clear due date',
                                  icon: Icons.close_rounded,
                                  onPressed: () => setState(() => _due = null),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Identical circular pills, visible only while the individual icon is hovered.
class _TaskAction extends StatelessWidget {
  const _TaskAction({required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 14),
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      padding: EdgeInsets.zero,
      style: ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const WidgetStatePropertyAll(Size(24, 24)),
        shape: const WidgetStatePropertyAll(CircleBorder()),
        foregroundColor: WidgetStatePropertyAll(p.inkMuted),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? p.empty.withValues(alpha: 0.8) : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    );
  }
}
