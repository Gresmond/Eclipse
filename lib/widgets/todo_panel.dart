import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../smart_add.dart';
import '../theme/pixels.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_dialog.dart';
import 'appear.dart';
import 'confirm_on_enter.dart';
import 'day_picker.dart';
import 'day_toggles.dart';
import 'fade_through.dart';
import 'fold.dart';
import 'glide_pill.dart';
import 'hover_fill.dart';
import 'mark.dart';
import 'note_input.dart';
import 'paged_dialog.dart';
import 'search_glow.dart';
import 'setting_rows.dart';
import 'sleep_time.dart';
import 'smooth_task_scroll.dart';
import 'task_motion.dart';
import 'tile.dart';
import 'time_wheel.dart';

part 'day_lists.dart';
part 'task_row.dart';
part 'task_subtasks.dart';
part 'task_editor.dart';
part 'further_ahead.dart';
part 'task_add.dart';
part 'week_card.dart';
part 'repeat_panel.dart';
part 'due_date_dialog.dart';

class _TaskDrag {
  _TaskDrag(this.scope, this.item, this.day);
  VoidCallback? onFinished;
  VoidCallback? onAccepted;
  Future<void> Function()? fadeForNesting;
  VoidCallback? restoreAfterNesting;
  bool nesting = false;

  /// Where the pointer took hold of the row, from its top left.
  Offset grab = Offset.zero;

  /// The day's list it was picked up from ([TaskOrder._list]), if it can be
  /// put in order there.
  Object? list;
  final TodoScope scope;
  final TodoItem item;
  final DateTime day;
}

/// A day's list, for dragging its open tasks into order among the others
/// of their group: each of its rows has one.
class TaskOrder {
  const TaskOrder._({
    required this._list,
    required this._canPlace,
    required this._place,
    required this._keep,
    required this._discard,
  });

  final Object _list;

  /// Whether a drag can go next to a task.
  final bool Function(_TaskDrag drag, _Task next) _canPlace;

  /// Shows a drag just before a task, or after it.
  final void Function(_TaskDrag drag, _Task next, {required bool after}) _place;

  /// Keeps the order shown, or puts it back as it was.
  final VoidCallback _keep, _discard;
}

/// Identical circular pills, visible only while the individual icon is hovered.
class _TaskAction extends StatelessWidget {
  const _TaskAction({this.tooltip, required this.icon, required this.onPressed});

  static const size = 24.0;

  final String? tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return PixelTooltip(
      message: tooltip ?? '',
      child: IconButton(
        icon: Icon(icon, size: 14),
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: size, height: size),
        padding: EdgeInsets.zero,
        style: ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const WidgetStatePropertyAll(Size(size, size)),
          shape: const WidgetStatePropertyAll(CircleBorder()),
          foregroundColor: WidgetStatePropertyAll(p.inkMuted),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered) ? p.empty.withValues(alpha: 0.8) : Colors.transparent,
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
    );
  }
}

/// One task in a day's list: it ticks, edits and nests the same way
/// wherever it's shown.
class TaskRow extends StatelessWidget {
  const TaskRow({
    super.key,
    required this.scope,
    required this.item,
    required this.day,
    this.readOnly = false,
    this.upcomingDate,
    this.fadeIn = false,
    this.arriving = false,
    this.leaving = false,
    this.onRemove,
    this.make,
    this.order,
  });

  final DateTime? upcomingDate;

  final TodoScope scope;
  final TodoItem item;

  /// Makes [item], a time of a repeat not made yet, the first time it's
  /// ticked or changed.
  final TodoItem Function()? make;

  /// Its day's list, when its tasks can be dragged into order.
  final TaskOrder? order;

  /// The day whose lists it's from: today, or a past day looked back on.
  final DateTime day;
  final bool readOnly;

  /// Fades in: just added.
  final bool fadeIn;

  /// Just come from another day, shown unticked at the bottom until it
  /// settles into place.
  final bool arriving;

  /// Removed, closing up.
  final bool leaving;

  /// Removes it; by default straight from its list.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    // Today's lists stay today's if the day changes before it's removed.
    final todays = day == state.today;
    return SearchGlow(
      target: item.uid,
      child: _TodoRow(
        scope: scope,
        upcomingDate: upcomingDate,
        item: item,
        day: day,
        readOnly: readOnly,
        fadeIn: fadeIn,
        arriving: arriving,
        leaving: leaving,
        onRemove: onRemove ?? () => state.removeTodo(scope, item, day: todays ? null : day),
        make: make,
        order: order,
      ),
    );
  }
}

/// Confirms removal of [item], asking once for repeating tasks; returns true
/// when removed.
Future<bool> confirmRemoveTask(
  BuildContext context,
  TodoScope scope,
  TodoItem item, {
  TodoItem Function()? make,
  DateTime? day,
}) async {
  final state = AppScope.read(context);
  final effectiveDay = day ?? state.today;
  final repeat = state.repeatOf(item);
  if (repeat == null) {
    final target = make?.call() ?? item;
    state.removeTodo(scope, target, day: day);
    return true;
  }
  final future = await _askWhich(context, removing: true);
  if (future == null || !context.mounted) return false;
  final target = make?.call() ?? item;
  state.removeTogether(() {
    state.removeTodo(scope, target, day: day);
    if (future) state.endRepeat(repeat, target.repeatDay ?? effectiveDay);
  });
  return true;
}

/// Touch actions for a task in the compact planner.
class TaskDetailsMenu extends StatelessWidget {
  const TaskDetailsMenu({super.key, required this.scope, required this.item, this.make});

  final TodoScope scope;
  final TodoItem item;
  final TodoItem Function()? make;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    return PopupMenuButton<int>(
      tooltip: 'Actions for ${item.text}',
      icon: const Icon(Icons.more_vert_rounded, size: 18),
      itemBuilder: (_) => [
        const PopupMenuItem(value: -2, child: Text('Edit task')),
        const PopupMenuItem(value: -1, child: Text('Add subtask')),
        for (final (i, sub) in item.subtasks.indexed) PopupMenuItem(value: i, child: Text('Edit ${sub.text}')),
        const PopupMenuItem(value: -3, child: Text('Delete task')),
      ],
      onSelected: (index) async {
        if (index == -3) {
          await confirmRemoveTask(context, scope, item, make: make);
          return;
        }
        if (index == -2) {
          await _editTask(context, scope, item, state.today, make: make);
          return;
        }
        final sub = index < 0 ? null : item.subtasks[index];
        final result = await showAppDialog<({String text, bool numbered, String? note})>(
          context: context,
          builder: (_) => _SubtaskDialog(text: sub?.text ?? '', numbered: item.numbered, note: sub?.note),
        );
        if (result == null || !context.mounted || result.text.trim().isEmpty) return;
        final current = make?.call() ?? item;
        final children = [for (final child in current.subtasks) child.copyWith(numbered: result.numbered)];
        final edited = TodoSubtask(
          result.text.trim(),
          done: sub?.done ?? false,
          numbered: result.numbered,
          note: result.note,
        );
        if (index < 0) {
          children.add(edited);
        } else if (index < children.length && current.subtasks[index].text == sub?.text) {
          children[index] = edited;
        } else {
          return;
        }
        final repeat = state.repeatOf(current);
        if (repeat != null) {
          final future = await _askWhich(context, removing: false);
          if (future == null || !context.mounted) return;
          if (future) {
            state.setRepeatSubtasks(scope, current, repeat, children, day: state.today);
            return;
          }
        }
        state.setTodoSubtasks(scope, current, children);
      },
    );
  }
}

class PhonePlan extends StatelessWidget {
  const PhonePlan({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.laterBirthdays));
    final plan = state.fromTodos((PhonePlan, state.today), () => _Planned(state, state.today, past: false));
    final bodyStyle = TextStyle(fontFamily: Fonts.body, fontSize: 15, height: 1.35, color: p.ink);
    final mutedStyle = TextStyle(fontFamily: Fonts.body, fontSize: 12, height: 1.35, color: p.inkMuted);

    Future<void> toggleSubtask(TodoScope scope, TodoItem item, int index, TodoItem Function()? make) async {
      final current = make?.call() ?? item;
      final children = [
        for (final (j, s) in current.subtasks.indexed)
          if (j == index) TodoSubtask(s.text, done: !s.done, note: s.note, numbered: s.numbered) else s,
      ];
      state.setTodoSubtasks(scope, current, children);
    }

    Widget row(TodoScope scope, TodoItem item, [TodoItem Function()? make]) {
      final hasMeta = item.dueTime != null || item.location != null || item.repeatUid != null || item.birthday;
      return Dismissible(
        key: ValueKey('plan-${item.uid ?? item.id}-${item.repeatDay?.millisecondsSinceEpoch ?? 0}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (_) => confirmRemoveTask(context, scope, item, make: make),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(color: p.missed, borderRadius: BorderRadius.circular(12)),
          child: Icon(Icons.delete_rounded, size: 18, color: p.onAccent),
        ),
        child: SearchGlow(
          target: item.uid,
          radius: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _editTask(context, scope, item, state.today, make: make),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Row(
                    children: [
                      if (item.birthday)
                        SizedBox(
                          width: 26,
                          height: 26,
                          child: Icon(Icons.cake_rounded, size: 18, color: p.accent),
                        )
                      else
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            state.toggleTodo(make?.call() ?? item, scope: scope);
                          },
                          child: SizedBox(
                            width: 34,
                            height: 34,
                            child: Center(
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: item.done ? p.done : Colors.transparent,
                                  border: item.done ? null : Border.all(color: p.inkMuted, width: 1.5),
                                ),
                                child: item.done ? Icon(Icons.check_rounded, size: 16, color: p.onDone) : null,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (hasMeta)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Row(
                                    children: [
                                      if (item.dueTime case final time?)
                                        Text(
                                          clockLabel(time),
                                          style: TextStyle(fontFamily: Fonts.taskTime, fontSize: 12, color: p.inkMuted),
                                        ),
                                      if (item.location case final loc?) ...[
                                        if (item.dueTime != null) const SizedBox(width: 8),
                                        Icon(Icons.place_rounded, size: 12, color: p.inkMuted),
                                        const SizedBox(width: 2),
                                        Flexible(
                                          child: Text(loc, maxLines: 1, overflow: TextOverflow.ellipsis, style: mutedStyle),
                                        ),
                                      ],
                                      if (item.birthday || item.repeatUid != null) ...[
                                        if (item.dueTime != null || item.location != null) const SizedBox(width: 8),
                                        Icon(
                                          item.birthday ? Icons.cake_rounded : Icons.repeat_rounded,
                                          size: 12,
                                          color: p.inkMuted,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              Text(
                                item.text,
                                style: bodyStyle.copyWith(
                                  color: item.done ? p.inkMuted : p.ink,
                                  decoration: item.done ? TextDecoration.lineThrough : null,
                                  decorationColor: p.inkMuted.withValues(alpha: 0.45),
                                ),
                              ),
                              if (item.note case final note?)
                                Text(note, maxLines: 3, overflow: TextOverflow.ellipsis, style: mutedStyle),
                            ],
                          ),
                        ),
                      ),
                      TaskDetailsMenu(scope: scope, item: item, make: make),
                    ],
                  ),
                ),
              ),
              for (final (j, sub) in item.subtasks.indexed)
                Padding(
                  padding: const EdgeInsets.only(left: 38),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      HapticFeedback.selectionClick();
                      unawaited(toggleSubtask(scope, item, j, make));
                    },
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 40),
                      child: Row(
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: sub.done ? p.done : Colors.transparent,
                              border: sub.done ? null : Border.all(color: p.inkMuted, width: 1.5),
                            ),
                            child: sub.done ? Icon(Icons.check_rounded, size: 12, color: p.onDone) : null,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(
                                sub.text,
                                style: bodyStyle.copyWith(
                                  fontSize: 14,
                                  color: sub.done ? p.inkMuted : p.ink,
                                  decoration: sub.done ? TextDecoration.lineThrough : null,
                                  decorationColor: p.inkMuted.withValues(alpha: 0.45),
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
          ),
        ),
      );
    }

    final laterGroups = [
      for (final (day, entries) in plan.later)
        if (entries.where((e) => state.laterBirthdays || !((e.item?.birthday ?? e.repeat?.birthday) ?? false)).toList()
            case final visible when visible.isNotEmpty)
          (day, visible),
    ];

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Plan',
                  style: TextStyle(
                    fontFamily: Fonts.display,
                    fontSize: 38,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.6,
                    height: 1.05,
                    color: p.ink,
                  ),
                ),
              ),
              IconButton(
                tooltip: state.laterBirthdays ? 'Hide birthdays' : 'Show birthdays',
                icon: Icon(Icons.cake_rounded, size: 22, color: state.laterBirthdays ? p.accent : p.inkMuted),
                onPressed: state.toggleLaterBirthdays,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Tile(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TileHeader(title: 'TOMORROW', titleStyle: capsLabel(p.inkMuted)),
                const SizedBox(height: 8),
                if (plan.days[1].isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('Nothing planned', style: bodyStyle.copyWith(color: p.inkMuted)),
                  )
                else
                  for (final (scope, item) in plan.days[1]) row(scope, item),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Tile(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TileHeader(title: 'WEEK AHEAD', titleStyle: capsLabel(p.inkMuted)),
                const SizedBox(height: 8),
                if (plan.days.skip(2).every((day) => day.isEmpty))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('Nothing planned', style: bodyStyle.copyWith(color: p.inkMuted)),
                  )
                else
                  for (final (i, tasks) in plan.days.indexed.skip(2))
                    if (tasks.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 4),
                        child: Text(
                          shortDay(DateTime(state.today.year, state.today.month, state.today.day + i), today: state.today),
                          style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: p.inkMuted),
                        ),
                      ),
                      for (final (scope, item) in tasks) row(scope, item),
                    ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Tile(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TileHeader(title: 'FURTHER AHEAD', titleStyle: capsLabel(p.inkMuted)),
                const SizedBox(height: 8),
                if (laterGroups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('Nothing planned', style: bodyStyle.copyWith(color: p.inkMuted)),
                  )
                else
                  for (final (day, entries) in laterGroups) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        shortDay(day, today: state.today),
                        style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: p.inkMuted),
                      ),
                    ),
                    for (final entry in entries)
                      if (entry.item case final item?)
                        row(entry.scope!, item)
                      else
                        row(TodoScope.month, entry.repeat!.unmade(day), () => state.occurrence(entry.repeat!, day)),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
