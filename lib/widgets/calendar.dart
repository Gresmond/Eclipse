part of 'todo_panel.dart';

/// What's on a day in the calendar: a to-do, or a time of a repeating task
/// that's not been made yet ([repeat]), made only once it's changed.
class _CalendarEntry {
  const _CalendarEntry(this.scope, this.item, this.date, {this.repeat});

  final TodoScope scope;
  final TodoItem item;
  final DateTime date;
  final Repeat? repeat;
}

/// The tasks on every day from [first] to [last], by day's key. A past day
/// has its lists as they stood; a coming one every time of every repeat.
Map<String, List<_CalendarEntry>> _calendarDays(AppState state, DateTime first, DateTime last) {
  final today = state.today;
  final days = <String, List<_CalendarEntry>>{};
  void add(_CalendarEntry entry) {
    if (entry.date.isBefore(first) || entry.date.isAfter(last)) return;
    (days[dateKey(entry.date)] ??= []).add(entry);
  }

  for (var day = first; day.isBefore(today) && !day.isAfter(last); day = DateTime(day.year, day.month, day.day + 1)) {
    for (final (scope, item) in _Planned(state, day, past: true).days[0]) {
      add(_CalendarEntry(scope, item, day));
    }
  }
  if (last.isBefore(today)) return days;
  final tomorrow = DateTime(today.year, today.month, today.day + 1);
  for (final scope in [TodoScope.today, TodoScope.tomorrow, TodoScope.week, TodoScope.month]) {
    for (final item in state.orderedTodos(scope)) {
      final date = switch (scope) {
        TodoScope.today => today,
        TodoScope.tomorrow => tomorrow,
        _ => item.dueDate,
      };
      if (date != null) add(_CalendarEntry(scope, item, date.isBefore(today) ? today : date));
    }
  }
  final from = first.isBefore(today) ? today : first;
  for (final repeat in state.repeats) {
    for (final day in state.unmadeOccurrences(repeat, from, last)) {
      add(_CalendarEntry(TodoScope.month, repeat.unmade(day), day, repeat: repeat));
    }
  }
  return {
    for (final MapEntry(:key, :value) in days.entries) key: _Planned._byTime(value, (e) => e.item, state.dayStartHour),
  };
}

/// The first and last days the month of [month] is drawn with: whole weeks,
/// Monday to Sunday.
(DateTime, DateTime) _calendarRange(DateTime month) {
  final first = DateTime(month.year, month.month);
  final last = DateTime(month.year, month.month + 1, 0);
  return (
    DateTime(first.year, first.month, first.day - (first.weekday - 1)),
    DateTime(last.year, last.month, last.day + 7 - last.weekday),
  );
}

/// [month]'s days' tasks, kept until the lists change.
Map<String, List<_CalendarEntry>> _calendarMonth(AppState state, DateTime month) =>
    state.fromTodos((_CalendarEntry, month, state.today), () {
      final (first, last) = _calendarRange(month);
      return _calendarDays(state, first, last);
    });

/// A month of days filling the window, with every task on its day.
class CalendarView extends StatelessWidget {
  const CalendarView({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.calendarMonth, s.today, s.todosRevision, s.holidays));
    final month = state.calendarMonth;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
      child: Tile(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: PixelColumn(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PixelRow(
              children: [
                for (final name in weekdayNames)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(name.substring(0, 3).toUpperCase(), style: capsLabel(p.inkMuted)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: FadeThrough(
                layoutBuilder: FadeThrough.fill,
                child: _CalendarGrid(key: ValueKey(month), month: month),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarGrid extends StatelessWidget {
  const _CalendarGrid({super.key, required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final (first, last) = _calendarRange(month);
    final tasks = _calendarMonth(state, month);
    final weeks = (daysBetween(first, last) + 1) ~/ 7;
    const gap = 6.0;
    return PixelColumn(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var week = 0; week < weeks; week++) ...[
          if (week > 0) const SizedBox(height: gap),
          Expanded(
            child: PixelRow(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < 7; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final date = DateTime(first.year, first.month, first.day + week * 7 + i);
                        return _CalendarCell(
                          date: date,
                          month: month,
                          entries: tasks[dateKey(date)] ?? const [],
                          column: i,
                          lower: week >= weeks / 2,
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// A task being dragged to another day.
class _CalendarDrag {
  const _CalendarDrag(this.entry);
  final _CalendarEntry entry;
}

/// One day: its number, and as many of its tasks as fit.
class _CalendarCell extends StatelessWidget {
  const _CalendarCell({
    required this.date,
    required this.month,
    required this.entries,
    required this.column,
    required this.lower,
  });

  final DateTime date, month;
  final List<_CalendarEntry> entries;

  /// Where it is, to open its panel towards the middle of the window.
  final int column;
  final bool lower;

  static double _rowHeight(BuildContext context) {
    return (MediaQuery.textScalerOf(context).scale(20) + 6).ceilToDouble();
  }

  void _open(BuildContext context) => showFadeMenu(
    context,
    gap: 6,
    width: 360,
    alignLeft: column < 4,
    above: lower,
    builder: (_) => _CalendarDayPanel(date: date, month: month),
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final today = state.today;
    final past = date.isBefore(today);
    final isToday = date == today;
    final inMonth = date.month == month.month && date.year == month.year;
    final holiday = holidayOn(state.holidays, date) != null;

    return DragTarget<_CalendarDrag>(
      onWillAcceptWithDetails: (details) => !past && details.data.entry.date != date,
      onAcceptWithDetails: (details) {
        final entry = details.data.entry;
        final repeat = entry.repeat;
        repeat == null
            ? state.moveTodoTo(entry.scope, entry.item, date)
            : state.moveTodoTo(TodoScope.month, state.occurrence(repeat, entry.date), date);
      },
      builder: (context, candidates, _) => Hoverable(
        onTap: past ? null : () => _open(context),
        behavior: HitTestBehavior.opaque,
        builder: (hover) {
          final Color fill;
          if (candidates.isNotEmpty) {
            fill = p.accent.withValues(alpha: 0.16);
          } else if (isToday) {
            fill = p.todayPanel;
          } else if (holiday) {
            fill = p.accent.withValues(alpha: 0.08);
          } else {
            final strength = !inMonth || past ? 0.14 : (hover ? 0.55 : 0.32);
            fill = p.empty.withValues(alpha: strength);
          }
          return AnimatedContainer(
            duration: context.themed(Motion.hover),
            curve: Motion.hoverCurve,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isToday ? p.todayPanelBorder : p.borderSoft.withValues(alpha: 0)),
            ),
            child: PixelColumn(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 28,
                  child: PixelRow(
                    children: [
                      _CalendarNumber(date: date, isToday: isToday, muted: past || !inMonth),
                      const Spacer(),
                      if (hover && !past)
                        _TaskAction(tooltip: 'Add task', icon: Icons.add_rounded, onPressed: () => _open(context)),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final row = _rowHeight(context);
                      final fit = (constraints.maxHeight / row).floor();
                      final over = entries.length > fit;
                      final shown = over ? (fit - 1).clamp(0, entries.length) : entries.length;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in entries.take(shown))
                            SizedBox(
                              height: row,
                              child: _CalendarRow(
                                key: ValueKey(entry.item.uid ?? entry.item.id),
                                entry: entry,
                                muted: past || !inMonth,
                                readOnly: past,
                              ),
                            ),
                          if (over && fit > 0)
                            SizedBox(
                              height: row,
                              child: _CalendarMore(count: entries.length - shown, onTap: () => _open(context)),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CalendarNumber extends StatelessWidget {
  const _CalendarNumber({required this.date, required this.isToday, required this.muted});

  final DateTime date;
  final bool isToday, muted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    TextStyle style(Color colour) => TextStyle(
      fontFamily: Fonts.display,
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1,
      color: colour,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (isToday) {
      return Container(
        width: 28,
        height: 28,
        alignment: const PixelCentre(),
        decoration: BoxDecoration(color: p.done, borderRadius: BorderRadius.circular(30)),
        child: Text('${date.day}', style: style(p.onAccent)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        date.day == 1 ? '1 ${shortMonth(date.month)}' : '${date.day}',
        style: style(muted ? p.inkMuted : p.ink),
      ),
    );
  }
}

/// "+3 more": the rest of a day's tasks, in its panel.
class _CalendarMore extends StatelessWidget {
  const _CalendarMore({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      builder: (hover) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '+$count more',
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: hover ? p.ink : p.inkMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// A task on a day: its tick box ticks it, its name opens the editor, and it
/// can be dragged to another day.
class _CalendarRow extends StatefulWidget {
  const _CalendarRow({super.key, required this.entry, required this.muted, required this.readOnly});

  final _CalendarEntry entry;
  final bool muted, readOnly;

  @override
  State<_CalendarRow> createState() => _CalendarRowState();
}

class _CalendarRowState extends State<_CalendarRow> {
  bool _hover = false, _hoverTick = false, _pressed = false;

  TodoItem _make() => AppScope.read(context).occurrence(widget.entry.repeat!, widget.entry.date);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final entry = widget.entry;
    final item = entry.item;
    final made = entry.repeat == null;
    final faint = widget.muted || item.done;

    final row = PixelRow(
      children: [
        MouseRegion(
          cursor: widget.readOnly ? MouseCursor.defer : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hoverTick = true),
          onExit: (_) => setState(() {
            _hoverTick = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.readOnly
                ? null
                : () => state.toggleTodo(made ? item : _make(), day: state.today, scope: entry.scope),
            child: _Check(done: item.done, hover: _hoverTick && !widget.readOnly, pressed: _pressed),
          ),
        ),
        const SizedBox(width: 8),
        if (item.birthday) ...[Icon(Icons.celebration_rounded, size: 14, color: p.inkMuted), const SizedBox(width: 4)],
        if (item.dueTime case final time?) ...[
          Text(clockLabel(time), style: _taskTimeStyle(p)),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            item.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: Fonts.body,
              fontSize: 14,
              color: faint ? p.inkMuted : p.ink,
              decoration: item.done ? TextDecoration.lineThrough : null,
              decorationColor: p.inkMuted.withValues(alpha: 0.45),
            ),
          ),
        ),
        if (_hover && !widget.readOnly)
          _TaskAction(
            tooltip: 'Remove',
            icon: Icons.close_rounded,
            onPressed: () => _removeTask(
              context,
              item,
              state.today,
              made ? () => state.removeTodo(entry.scope, item) : () => state.removeTodo(TodoScope.month, _make()),
            ),
          ),
      ],
    );

    final body = MouseRegion(
      cursor: widget.readOnly ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.readOnly
            ? null
            : () => _editTask(context, entry.scope, item, state.today, make: made ? null : _make),
        child: AnimatedContainer(
          duration: context.themed(Motion.hover),
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: p.empty.withValues(alpha: _hover && !widget.readOnly ? 0.6 : 0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: row,
        ),
      ),
    );

    return Draggable<_CalendarDrag>(
      data: _CalendarDrag(entry),
      maxSimultaneousDrags: widget.readOnly || item.done || item.birthday ? 0 : 1,
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
      childWhenDragging: Opacity(opacity: 0.35, child: body),
      child: body,
    );
  }
}

/// A day's whole list, and its add field, over the calendar.
class _CalendarDayPanel extends StatelessWidget {
  const _CalendarDayPanel({required this.date, required this.month});

  final DateTime date, month;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision));
    final past = date.isBefore(state.today);
    final entries = _calendarMonth(state, month)[dateKey(date)] ?? const <_CalendarEntry>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(weekdayNames[date.weekday - 1].toUpperCase(), style: capsLabel(p.inkMuted)),
          const SizedBox(height: 4),
          Text(dayAndMonth(date), style: cornerCardTitle(p.ink)),
          const SizedBox(height: 10),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in entries)
                      SizedBox(
                        height: _CalendarCell._rowHeight(context) + 4,
                        child: _CalendarRow(
                          key: ValueKey(entry.item.uid ?? entry.item.id),
                          entry: entry,
                          muted: past,
                          readOnly: past,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (!past) _AddTask(day: date, today: state.today, anyDay: true, autofocus: true),
        ],
      ),
    );
  }
}
