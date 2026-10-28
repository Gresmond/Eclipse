import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../widgets/hover_fill.dart';
import '../widgets/progress_ring.dart';
import '../widgets/status_cell.dart';
import '../widgets/todo_panel.dart';

/// Calendar days from [from] to [to], unaffected by clock changes.
int _daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// Display mode: everything as to-dos, one day after another from today
/// on. Today also lists its rituals and sleep schedule; later days show the
/// tasks due then. Days load as you scroll, and the week strip follows the
/// day at the top.
class DisplayView extends StatefulWidget {
  const DisplayView({super.key});

  /// The list's width, centred on the page.
  static const width = 820.0;

  @override
  State<DisplayView> createState() => _DisplayViewState();
}

class _DisplayViewState extends State<DisplayView> {
  final _scroll = ScrollController();
  final _listKey = GlobalKey();

  /// Days shown, from today; more are added near the bottom.
  int _days = 35;

  /// The day at the top of the list, which the week strip shows.
  int _top = 0;

  final _keys = <GlobalKey>[];
  GlobalKey _key(int i) {
    while (_keys.length <= i) {
      _keys.add(GlobalKey());
    }
    return _keys[i];
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scrolled);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrolled() {
    if (_scroll.position.extentAfter < 900) setState(() => _days += 28);
    final list = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (list == null) return;
    // The last day whose heading has reached the top.
    var top = 0;
    for (var i = 0; i < _days && i < _keys.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) break;
      if (box.localToGlobal(Offset.zero, ancestor: list).dy > 24) break;
      top = i;
    }
    if (top != _top) setState(() => _top = top);
  }

  /// Scrolls so day [index] (from today) sits at the top.
  void _goTo(int index) {
    index = max(0, index);
    if (index >= _days) setState(() => _days = index + 28);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (index == 0) {
        _scroll.animateTo(0, duration: Motion.page, curve: Motion.morphCurve);
        return;
      }
      final context = _keys[index].currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(context, duration: Motion.page, curve: Motion.morphCurve);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(
      context,
      (s) => (s.today, s.todosRevision, s.habitsRevision, s.entriesRevision, s.restWeekends),
    );
    final today = state.today;
    final focus = DateTime(today.year, today.month, today.day + _top);
    final monday = DateTime(focus.year, focus.month, focus.day - (focus.weekday - 1));
    int indexOf(DateTime day) => _daysBetween(today, day);

    // Week and month tasks are filed by their due date; undated ones sit
    // above today.
    final byDay = <String, List<(TodoScope, TodoItem)>>{};
    final undated = <(TodoScope, TodoItem)>[];
    for (final scope in [TodoScope.week, TodoScope.month]) {
      for (final item in state.orderedTodos(scope)) {
        final due = item.dueDate;
        if (due == null) {
          if (!item.done) undated.add((scope, item));
        } else {
          (byDay[dateKey(due)] ??= []).add((scope, item));
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 6, 32, 0),
      child: Center(
        child: SizedBox(
          width: DisplayView.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Title(today: today),
              const SizedBox(height: 18),
              _WeekBar(
                monday: monday,
                today: today,
                focus: focus,
                onDay: (day) => _goTo(indexOf(day)),
                onWeek: (delta) => _goTo(indexOf(DateTime(monday.year, monday.month, monday.day + 7 * delta))),
                onToday: () => _goTo(0),
              ),
              Expanded(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 120),
                    child: Column(
                      key: _listKey,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (undated.isNotEmpty)
                          _DaySection(heading: const [('No date', true)], tasks: undated, day: null),
                        for (var i = 0; i < _days; i++)
                          KeyedSubtree(
                            key: _key(i),
                            child: _section(state, DateTime(today.year, today.month, today.day + i), i, byDay),
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
    );
  }

  Widget _section(AppState state, DateTime day, int i, Map<String, List<(TodoScope, TodoItem)>> byDay) {
    final due = byDay[dateKey(day)] ?? const [];
    final tasks = switch (i) {
      0 => [for (final t in state.orderedTodos(TodoScope.today)) (TodoScope.today, t), ...due],
      1 => [for (final t in state.orderedTodos(TodoScope.tomorrow)) (TodoScope.tomorrow, t), ...due],
      _ => due,
    };
    final date = '${monthNames[day.month - 1].substring(0, 3)} ${day.day}';
    final weekday = weekdayNames[day.weekday - 1];
    return _DaySection(
      heading: [(date, true), if (i == 0) ('Today', true), if (i == 1) ('Tomorrow', false), (weekday, false)],
      today: i == 0,
      tasks: tasks,
      day: day,
      rituals: i == 0,
    );
  }
}

/// "Upcoming", with today's rituals as a ring beside it.
class _Title extends StatelessWidget {
  const _Title({required this.today});

  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final rituals = [
      for (final h in state.habitsFor(today.year, today.month))
        if (h.onDay(today)) h,
    ];
    final done = state.doneOn(today, rituals);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Upcoming',
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: 34,
            fontWeight: FontWeight.w600,
            letterSpacing: -1.1,
            height: 1.1,
            color: p.ink,
          ),
        ),
        const Spacer(),
        if (rituals.isNotEmpty) ...[
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$done of ${rituals.length}',
                style: TextStyle(
                  fontFamily: Fonts.display,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: p.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                'RITUALS TODAY',
                style: TextStyle(
                  fontFamily: Fonts.ui,
                  fontSize: 10,
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.w700,
                  color: p.inkMuted.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          ProgressRing(done: done, total: rituals.length, size: 48),
        ],
      ],
    );
  }
}

/// The month, a week of days to jump to, and buttons to move by a week.
class _WeekBar extends StatelessWidget {
  const _WeekBar({
    required this.monday,
    required this.today,
    required this.focus,
    required this.onDay,
    required this.onWeek,
    required this.onToday,
  });

  final DateTime monday, today, focus;
  final ValueChanged<DateTime> onDay;
  final ValueChanged<int> onWeek;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final thisWeek = !monday.isAfter(today);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '${monthNames[focus.month - 1]} ${focus.year}',
              style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w700, color: p.ink),
            ),
            const Spacer(),
            Container(
              height: 34,
              decoration: BoxDecoration(
                color: p.tile.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: p.tileBorder.withValues(alpha: 0.85)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _BarButton(
                    tooltip: 'Previous week',
                    onTap: thisWeek ? null : () => onWeek(-1),
                    child: const Icon(Icons.chevron_left_rounded, size: 18),
                  ),
                  _BarButton(
                    onTap: onToday,
                    child: Text(
                      'Today',
                      style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, fontWeight: FontWeight.w600, color: p.ink),
                    ),
                  ),
                  _BarButton(
                    tooltip: 'Next week',
                    onTap: () => onWeek(1),
                    child: const Icon(Icons.chevron_right_rounded, size: 18),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (var d = 0; d < 7; d++)
              Expanded(
                child: _WeekDay(
                  day: DateTime(monday.year, monday.month, monday.day + d),
                  today: today,
                  focused: DateTime(monday.year, monday.month, monday.day + d) == focus,
                  onTap: onDay,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Container(height: 1, color: p.tileBorder.withValues(alpha: 0.8)),
      ],
    );
  }
}

class _BarButton extends StatefulWidget {
  const _BarButton({required this.child, required this.onTap, this.tooltip});

  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = widget.onTap != null;
    Widget button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: HoverFill(
          hover: _hover && enabled,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: IconTheme(
                data: IconThemeData(color: enabled ? p.ink : p.inkMuted.withValues(alpha: 0.35)),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) button = Tooltip(message: widget.tooltip!, child: button);
    return button;
  }
}

class _WeekDay extends StatefulWidget {
  const _WeekDay({required this.day, required this.today, required this.focused, required this.onTap});

  final DateTime day, today;
  final bool focused;
  final ValueChanged<DateTime> onTap;

  @override
  State<_WeekDay> createState() => _WeekDayState();
}

class _WeekDayState extends State<_WeekDay> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final past = widget.day.isBefore(widget.today);
    final isToday = widget.day == widget.today;
    final label = weekdayNames[widget.day.weekday - 1].substring(0, 3);
    final style = TextStyle(
      fontFamily: Fonts.ui,
      fontSize: 13,
      fontWeight: widget.focused ? FontWeight.w700 : FontWeight.w500,
      color: past ? p.inkMuted.withValues(alpha: 0.45) : (widget.focused ? p.ink : p.inkMuted),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return MouseRegion(
      cursor: past ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: past ? null : () => widget.onTap(widget.day),
        child: HoverFill(
          hover: _hover && !past,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label, style: style),
                const SizedBox(width: 6),
                AnimatedContainer(
                  duration: Motion.click,
                  curve: Motion.clickCurve,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isToday ? p.today : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${widget.day.day}',
                    style: style.copyWith(
                      color: isToday ? p.onToday : null,
                      fontWeight: isToday ? FontWeight.w700 : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One day: its heading, its tasks, today's rituals and sleep schedule, and
/// a line to add a task due that day.
class _DaySection extends StatelessWidget {
  const _DaySection({
    required this.heading,
    required this.tasks,
    required this.day,
    this.today = false,
    this.rituals = false,
  });

  /// The heading's parts, joined with dots; strong ones are full ink.
  final List<(String, bool)> heading;
  final List<(TodoScope, TodoItem)> tasks;

  /// Null for undated tasks, which can't be added to here.
  final DateTime? day;
  final bool today;
  final bool rituals;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final day = this.day;
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                for (final (i, (part, strong)) in heading.indexed) ...[
                  if (i > 0)
                    TextSpan(
                      text: '  ·  ',
                      style: TextStyle(color: p.inkMuted.withValues(alpha: 0.5)),
                    ),
                  TextSpan(
                    text: part,
                    style: TextStyle(color: today || strong ? p.ink : p.inkMuted),
                  ),
                ],
              ],
            ),
            style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w700, color: p.ink),
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: p.tileBorder.withValues(alpha: 0.8)),
          const SizedBox(height: 4),
          for (final (scope, item) in tasks) TaskRow(key: ValueKey((scope, item.id)), scope: scope, item: item),
          if (day != null) _AddTask(day: day, today: state.today),
          if (rituals && day != null) ...[
            _RitualGroup(
              title: 'Rituals',
              habits: [
                for (final h in state.habitsFor(day.year, day.month))
                  if (h.onDay(day)) h,
              ],
              day: day,
            ),
            _RitualGroup(
              title: 'Sleep schedule',
              habits: state.sleepHabitsFor(day.year, day.month),
              day: day,
              times: true,
            ),
          ],
        ],
      ),
    );
  }
}

/// Today's rituals or sleep schedule as to-dos: the same square as on the
/// Ritual cards, cycling done, not done and other.
class _RitualGroup extends StatelessWidget {
  const _RitualGroup({required this.title, required this.habits, required this.day, this.times = false});

  final String title;
  final List<Habit> habits;
  final DateTime day;
  final bool times;

  @override
  Widget build(BuildContext context) {
    if (habits.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    final state = AppScope.read(context);
    final rest = state.isRestDay(day);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 4),
            child: Text(
              '${title.toUpperCase()}   ${state.doneOn(day, habits)}/${habits.length}',
              style: TextStyle(
                fontFamily: Fonts.ui,
                fontSize: 10.5,
                letterSpacing: 1.8,
                fontWeight: FontWeight.w700,
                color: p.inkMuted.withValues(alpha: 0.8),
              ),
            ),
          ),
          for (final h in habits)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 2, bottom: 2),
              child: Tooltip(
                message: times ? '' : (h.description ?? ''),
                waitDuration: const Duration(milliseconds: 600),
                child: Row(
                  children: [
                    StatusCell(day: day, habit: h, size: 30, rest: rest),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        h.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: Fonts.body,
                          fontSize: 14,
                          height: 1.35,
                          color: state.statusOf(day, h) == HabitStatus.none ? p.ink : p.inkMuted,
                        ),
                      ),
                    ),
                    if (times && h.minutes != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          clockLabel(h.minutes!),
                          style: TextStyle(fontFamily: Fonts.time, fontSize: 12, color: p.inkMuted),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "+ Add task", which opens into a field: Enter adds and keeps it open for
/// the next, Escape or clicking away closes it.
class _AddTask extends StatefulWidget {
  const _AddTask({required this.day, required this.today});

  final DateTime day, today;

  @override
  State<_AddTask> createState() => _AddTaskState();
}

class _AddTaskState extends State<_AddTask> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _open = false;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _controller.text.trim().isEmpty) setState(() => _open = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(AppState state) {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    final days = _daysBetween(widget.today, widget.day);
    if (days <= 0) {
      state.addTodo(TodoScope.today, text);
    } else if (days == 1) {
      state.addTodo(TodoScope.tomorrow, text);
    } else {
      // Due later this week files under This week, anything after under
      // This month; both move into Tomorrow and Today as the day nears.
      final sunday = DateTime(widget.today.year, widget.today.month, widget.today.day + 7 - widget.today.weekday);
      final scope = widget.day.isAfter(sunday) ? TodoScope.month : TodoScope.week;
      state.addTodo(scope, text, dueDate: widget.day);
    }
    _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    if (_open) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(26, 4, 8, 4),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              _controller.clear();
              _focus.unfocus();
            },
          },
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.ink),
            cursorColor: p.accent,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Task name',
              hintStyle: TextStyle(color: p.inkMuted.withValues(alpha: 0.6)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: p.tile,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: p.tileBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: p.tileBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: p.accent.withValues(alpha: 0.7)),
              ),
            ),
            onSubmitted: (_) => _submit(state),
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = true),
        child: Padding(
          padding: const EdgeInsets.only(left: 18, top: 2),
          child: HoverFill(
            hover: _hover,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: Icon(
                      Icons.add_rounded,
                      size: 18,
                      color: _hover ? p.accent : p.accent.withValues(alpha: 0.75),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Text(
                    'Add task',
                    style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: _hover ? p.accent : p.inkMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
