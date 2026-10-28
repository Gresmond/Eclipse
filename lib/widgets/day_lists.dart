part of 'todo_panel.dart';

/// Calendar days from [from] to [to], unaffected by clock changes.
int _daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// One thing further ahead than the week: a task, or the next time a
/// repeating task comes round, not made yet.
typedef _Later = ({TodoScope? scope, TodoItem? item, Repeat? repeat});

/// A day's lists sorted by day: the week card's [days] (that day and the
/// [WeekCard.span] after it), and [later] by date, only days with tasks.
class _Planned {
  _Planned(AppState state, DateTime day, {required bool past}) {
    List<TodoItem> list(TodoScope scope) => state.orderedTodos(scope, day: past ? day : null);
    for (final item in list(TodoScope.today)) {
      days[0].add((TodoScope.today, item));
    }
    for (final item in list(TodoScope.tomorrow)) {
      days[1].add((TodoScope.tomorrow, item));
    }
    final byDay = <String, List<_Later>>{};
    for (final scope in [TodoScope.week, TodoScope.month]) {
      for (final item in list(scope)) {
        final due = item.dueDate;
        if (due == null) {
          // Only a past day's lists still have tasks without a day.
          if (!item.done) undated.add((scope: scope, item: item, repeat: null));
          continue;
        }
        final i = _daysBetween(day, due);
        if (i <= WeekCard.span) {
          days[i < 0 ? 0 : i].add((scope, item));
        } else {
          (byDay[dateKey(due)] ??= []).add((scope: scope, item: item, repeat: null));
        }
      }
    }
    if (!past) {
      final beyond = DateTime(day.year, day.month, day.day + WeekCard.span + 1);
      for (final repeat in state.repeats) {
        if (state.nextOccurrence(repeat, beyond) case final next?) {
          (byDay[dateKey(next)] ??= []).add((scope: null, item: null, repeat: repeat));
        }
      }
    }
    later = [for (final key in byDay.keys.toList()..sort()) (DateTime.parse(key), byDay[key]!)];
  }

  final days = List.generate(WeekCard.span + 1, (_) => <(TodoScope, TodoItem)>[]);
  late final List<(DateTime, List<_Later>)> later;
  final undated = <_Later>[];
}

/// Remembers the tasks a list has shown, so one added since fades in.
mixin _NewTasks<T extends StatefulWidget> on State<T> {
  Set<int>? _seen;
  String? _seenDay;

  /// Those of [ids] not shown before for [day].
  Set<int> _added(DateTime day, Iterable<int> ids) {
    final now = ids.toSet(), key = dateKey(day);
    final added = _seenDay == key ? now.difference(_seen ?? now) : const <int>{};
    _seen = now;
    _seenDay = key;
    return added;
  }
}

/// 'Oct 28', with the year when it isn't [today]'s.
String _shortDate(DateTime day, DateTime today) =>
    '${monthNames[day.month - 1].substring(0, 3)} ${day.day}${day.year != today.year ? ' ${day.year}' : ''}';

/// Today and the week after it, one day under another, every task in its
/// day. The strip of days at the top jumps to one and follows the scroll.
class WeekCard extends StatefulWidget {
  const WeekCard({super.key});

  /// The days after today it reaches; anything later is further ahead.
  static const span = 7;

  @override
  State<WeekCard> createState() => _WeekCardState();
}

class _WeekCardState extends State<WeekCard> with _NewTasks {
  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.shownDay, s.viewDay));
    final day = state.shownDay;
    final planned = _Planned(state, day, past: state.viewDay != null);
    final tasks = planned.days.expand((d) => d);
    final open = tasks.where((t) => !t.$2.done).length;
    final added = _added(day, [for (final (_, item) in tasks) item.id]);

    return Tile(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TileHeader(title: 'Week ahead', caption: open == 0 && tasks.isNotEmpty ? 'All clear' : '$open open'),
          ),
          const SizedBox(height: 12),
          // Another day's week fades through as a whole.
          Expanded(
            child: FadeThrough(
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: _WeekList(key: ValueKey(dateKey(day)), planned: planned, added: added),
            ),
          ),
        ],
      ),
    );
  }
}

/// One day's week: the strip of days, and the days' lists under it.
class _WeekList extends StatefulWidget {
  const _WeekList({super.key, required this.planned, required this.added});

  final _Planned planned;

  /// Tasks just added, which fade in.
  final Set<int> added;

  @override
  State<_WeekList> createState() => _WeekListState();
}

class _WeekListState extends State<_WeekList> {
  final _keys = List.generate(WeekCard.span + 1, (_) => GlobalKey());

  /// The day at the top of the list, which the strip marks.
  int _top = 0;

  bool _scrolled(ScrollNotification notification) {
    final viewport = notification.context?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached) return false;
    final edge = viewport.localToGlobal(Offset.zero).dy;
    // The last day whose heading has reached the top.
    var top = 0;
    for (var i = 0; i < _keys.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) break;
      if (box.localToGlobal(Offset.zero).dy - edge > 24) break;
      top = i;
    }
    // At the very bottom, the last day is the one being looked at.
    final metrics = notification.metrics;
    if (metrics.extentAfter < 1 && metrics.extentBefore > 0) top = _keys.length - 1;
    if (top != _top) setState(() => _top = top);
    return false;
  }

  void _goTo(int index) {
    final context = _keys[index].currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(context, duration: Motion.page, curve: Motion.morphCurve);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final day = state.shownDay;
    final readOnly = !state.canEditDay(day);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: _WeekStrip(first: day, today: state.today, focus: _top, onDay: _goTo),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _scrolled,
            child: SmoothTaskScroll(
              builder: (context, controller) => SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i <= WeekCard.span; i++)
                      KeyedSubtree(
                        key: _keys[i],
                        child: _section(state, DateTime(day.year, day.month, day.day + i), i, readOnly),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(AppState state, DateTime date, int i, bool readOnly) {
    final planned = widget.planned, added = widget.added;
    final p = context.palette;
    final weekday = weekdayNames[date.weekday - 1];
    final name = switch (_daysBetween(state.today, date)) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => null,
    };
    final section = _DaySection(
      heading: [(_shortDate(date, state.today), true), if (name != null) (name, i == 0), (weekday, false)],
      strong: i == 0,
      first: i == 0,
      children: [
        GlidingColumn(
          children: [
            for (final (scope, item) in planned.days[i])
              TaskRow(
                key: ValueKey((scope, item.id)),
                scope: scope,
                item: item,
                day: state.shownDay,
                readOnly: readOnly,
                fadeIn: added.contains(item.id),
              ),
          ],
        ),
        if (state.viewDay == null)
          _AddTask(day: date, today: state.today)
        // Yesterday, while it can still be edited, takes tasks into its own
        // Today and Tomorrow.
        else if (!readOnly && i <= 1)
          _AddTask(day: date, today: state.today, past: state.viewDay)
        else if (planned.days[i].isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 6, 0, 4),
            child: Text(
              'Nothing planned',
              style: TextStyle(fontFamily: Fonts.body, fontSize: 13, color: p.inkMuted.withValues(alpha: 0.7)),
            ),
          ),
      ],
    );
    final here = {for (final (_, item) in planned.days[i]) item.id};
    // An open task dragged here moves to this day.
    return DragTarget<_TaskDrag>(
      onWillAcceptWithDetails: (details) =>
          state.viewDay == null &&
          details.data.day == state.today &&
          !details.data.item.done &&
          !here.contains(details.data.item.id),
      onAcceptWithDetails: (details) => state.moveTodoTo(details.data.scope, details.data.item, date),
      builder: (context, candidates, rejected) => AnimatedContainer(
        duration: Motion.hover,
        curve: Motion.hoverCurve,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: candidates.isEmpty ? Colors.transparent : p.accent.withValues(alpha: 0.08),
        ),
        child: section,
      ),
    );
  }
}

/// The week card's days in a row, the one at the top of the list marked.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.first, required this.today, required this.focus, required this.onDay});

  final DateTime first, today;
  final int focus;
  final ValueChanged<int> onDay;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var i = 0; i <= WeekCard.span; i++)
              Expanded(
                child: _StripDay(
                  day: DateTime(first.year, first.month, first.day + i),
                  today: today,
                  focused: i == focus,
                  onTap: () => onDay(i),
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

class _StripDay extends StatefulWidget {
  const _StripDay({required this.day, required this.today, required this.focused, required this.onTap});

  final DateTime day, today;
  final bool focused;
  final VoidCallback onTap;

  @override
  State<_StripDay> createState() => _StripDayState();
}

class _StripDayState extends State<_StripDay> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isToday = widget.day == widget.today;
    final focused = widget.focused;
    return Tooltip(
      message: '${weekdayNames[widget.day.weekday - 1]} ${_shortDate(widget.day, widget.today)}',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: HoverFill(
            hover: _hover,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                children: [
                  Text(
                    weekdayNames[widget.day.weekday - 1].substring(0, 3).toUpperCase(),
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                      color: focused ? p.ink : p.inkMuted.withValues(alpha: 0.8),
                    ),
                  ),
                  const SizedBox(height: 4),
                  AnimatedContainer(
                    duration: Motion.click,
                    curve: Motion.clickCurve,
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isToday ? p.today : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: focused && !isToday ? p.inkMuted.withValues(alpha: 0.6) : Colors.transparent,
                      ),
                    ),
                    child: Text(
                      '${widget.day.day}',
                      style: TextStyle(
                        fontFamily: Fonts.ui,
                        fontSize: 13,
                        fontWeight: isToday || focused ? FontWeight.w700 : FontWeight.w500,
                        color: isToday ? p.onToday : (focused ? p.ink : p.inkMuted),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
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

/// A day's heading, its parts joined with dots, over a rule and its rows.
class _DaySection extends StatelessWidget {
  const _DaySection({required this.heading, required this.children, this.strong = false, this.first = false});

  /// The heading's parts; strong ones are full ink.
  final List<(String, bool)> heading;
  final List<Widget> children;

  /// All in full ink: today's.
  final bool strong;

  /// The first in its list, with less room above.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: EdgeInsets.only(top: first ? 12 : 22, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                for (final (i, (part, full)) in heading.indexed) ...[
                  if (i > 0)
                    TextSpan(
                      text: '  ·  ',
                      style: TextStyle(color: p.inkMuted.withValues(alpha: 0.5)),
                    ),
                  TextSpan(
                    text: part,
                    style: TextStyle(color: strong || full ? p.ink : p.inkMuted),
                  ),
                ],
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, fontWeight: FontWeight.w700, color: p.ink),
          ),
          const SizedBox(height: 6),
          Container(height: 1, color: p.tileBorder.withValues(alpha: 0.6)),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

/// "+ Add task" under a day, which opens into a field: Enter adds and keeps
/// it open for the next, Escape or clicking away closes it. The repeat
/// button makes the next one repeat from that day.
class _AddTask extends StatefulWidget {
  const _AddTask({required this.day, required this.today, this.past});

  final DateTime day, today;

  /// The past day whose lists it adds to; [day] is that day or the next.
  final DateTime? past;

  @override
  State<_AddTask> createState() => _AddTaskState();
}

class _AddTaskState extends State<_AddTask> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _open = false;
  bool _hover = false;
  _RepeatChoice? _repeat;

  /// While the repeat dialog is open, the field stays open behind it.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && !_picking && _controller.text.trim().isEmpty) {
        setState(() {
          _open = false;
          _repeat = null;
        });
      }
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
    if (widget.past case final past?) {
      state.addTodo(widget.day == past ? TodoScope.today : TodoScope.tomorrow, text, day: past);
    } else if (_repeat case final repeat?) {
      state.addRepeat(text, repeat.rule, widget.day, until: repeat.until);
      setState(() => _repeat = null);
    } else {
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
    }
    _controller.clear();
    _focus.requestFocus();
  }

  Future<void> _pick() async {
    _picking = true;
    final picked = await _pickRepeat(context, widget.day, _repeat);
    _picking = false;
    if (!mounted) return;
    if (picked != null) setState(() => _repeat = picked.choice);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    if (_open) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 0, 4),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              _controller.clear();
              _focus.unfocus();
            },
          },
          child: _Field(
            controller: _controller,
            focus: _focus,
            autofocus: true,
            leading: Icon(Icons.add_rounded, size: 18, color: p.accent),
            trailing: widget.past == null ? _RepeatButton(repeat: _repeat, onPressed: _pick) : const SizedBox.shrink(),
            onSubmitted: () => _submit(state),
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                    style: TextStyle(fontFamily: Fonts.body, fontSize: 13.5, color: _hover ? p.accent : p.inkMuted),
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

/// The repeat button of a field for a new task: lit with its rule once set.
class _RepeatButton extends StatelessWidget {
  const _RepeatButton({required this.repeat, required this.onPressed});

  final _RepeatChoice? repeat;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final repeat = this.repeat;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (repeat != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                repeat.rule.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: Fonts.body, fontSize: 11, color: p.accent),
              ),
            ),
          ),
        _TaskAction(
          tooltip: repeat == null ? 'Repeat' : 'Change repeat',
          icon: repeat == null ? Icons.repeat_rounded : Icons.repeat_on_rounded,
          onPressed: onPressed,
        ),
      ],
    );
  }
}

/// A rounded field for a new task's name, as at the foot of a to-do card.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.focus,
    required this.leading,
    required this.trailing,
    required this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final Widget leading, trailing;
  final VoidCallback onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: focus,
      builder: (context, _) => Container(
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: p.empty.withValues(alpha: focus.hasFocus ? 0.65 : 0.45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: focus.hasFocus ? p.accent.withValues(alpha: 0.45) : Colors.transparent),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                autofocus: autofocus,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: const [NoteInputFormatter()],
                style: TextStyle(fontFamily: Fonts.body, fontSize: 13.5, color: p.ink),
                cursorColor: p.accent,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Add a task',
                  hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted.withValues(alpha: 0.65)),
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                ),
                onSubmitted: (_) => onSubmitted(),
              ),
            ),
            // Its buttons and labels keep to the end, the name taking the rest.
            ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: trailing),
          ],
        ),
      ),
    );
  }
}

/// Tasks more than a week away, under their days (only days with any),
/// and the next time each repeating task comes round after the week.
class FurtherAheadCard extends StatefulWidget {
  const FurtherAheadCard({super.key});

  @override
  State<FurtherAheadCard> createState() => _FurtherAheadCardState();
}

class _FurtherAheadCardState extends State<FurtherAheadCard> with _NewTasks {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  DateTime? _due;
  _RepeatChoice? _repeat;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  DateTime get _first {
    final today = AppScope.read(context).today;
    return DateTime(today.year, today.month, today.day + WeekCard.span + 1);
  }

  Future<DateTime?> _pickDue() async {
    final picked = await _pickDate(context, first: _first, selected: _due);
    if (picked != null && mounted) setState(() => _due = picked);
    return picked;
  }

  Future<void> _submit(AppState state) async {
    if (_controller.text.trim().isEmpty) return;
    // Every task has a day: without one yet, it's asked for.
    final due = _due ?? await _pickDue();
    if (due == null || !mounted) return;
    if (_repeat case final repeat?) {
      state.addRepeat(_controller.text, repeat.rule, due, until: repeat.until);
    } else {
      state.addTodo(TodoScope.month, _controller.text, dueDate: due);
    }
    setState(() {
      _due = null;
      _repeat = null;
    });
    _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.shownDay, s.viewDay));
    final day = state.shownDay;
    final past = state.viewDay != null;
    final readOnly = !state.canEditDay(day);
    final planned = _Planned(state, day, past: past);
    final groups = [
      for (final (date, items) in planned.later) (date as DateTime?, items),
      if (planned.undated.isNotEmpty) (null, planned.undated),
    ];
    final count = groups.fold(0, (n, g) => n + g.$2.length);
    final added = _added(day, [
      for (final (_, items) in groups)
        for (final later in items)
          if (later.item case final item?) item.id,
    ]);

    return Tile(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TileHeader(title: 'Further ahead', caption: '$count planned'),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: FadeThrough(
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: KeyedSubtree(
                key: ValueKey(dateKey(day)),
                child: groups.isEmpty
                    ? Center(
                        child: Text(
                          'Nothing more than a week away',
                          style: TextStyle(
                            fontFamily: Fonts.body,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: p.inkMuted.withValues(alpha: 0.7),
                          ),
                        ),
                      )
                    : SmoothTaskScroll(
                        builder: (context, controller) => SingleChildScrollView(
                          controller: controller,
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final (i, (date, items)) in groups.indexed)
                                _DaySection(
                                  first: i == 0,
                                  heading: date == null
                                      ? const [('No date', true)]
                                      : [
                                          (_shortDate(date, state.today), true),
                                          (weekdayNames[date.weekday - 1], false),
                                        ],
                                  children: [
                                    GlidingColumn(
                                      children: [
                                        for (final later in items)
                                          if (later.repeat case final repeat?)
                                            _RepeatPreview(key: ValueKey(repeat.uid), repeat: repeat, day: date!)
                                          else
                                            TaskRow(
                                              key: ValueKey((later.scope, later.item!.id)),
                                              scope: later.scope!,
                                              item: later.item!,
                                              day: day,
                                              readOnly: readOnly,
                                              fadeIn: added.contains(later.item!.id),
                                            ),
                                      ],
                                    ),
                                  ],
                                ),
                            ],
                          ),
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
              heightFactor: past ? 0 : 1,
              child: AnimatedOpacity(
                duration: Motion.morph,
                curve: Motion.morphCurve,
                opacity: past ? 0 : 1,
                child: IgnorePointer(
                  ignoring: past,
                  child: ExcludeFocus(
                    excluding: past,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6, right: 6),
                      child: _Field(
                        controller: _controller,
                        focus: _focus,
                        leading: _TaskAction(
                          tooltip: _due == null
                              ? 'Pick a day'
                              : 'Due ${dayMonth(_due!)}/${_due!.year}, click to change',
                          icon: _due == null ? Icons.calendar_today_outlined : Icons.event_available_outlined,
                          onPressed: _pickDue,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_due != null)
                              Text(
                                _shortDate(_due!, state.today),
                                style: TextStyle(fontFamily: Fonts.body, fontSize: 11, color: p.inkMuted),
                              ),
                            Flexible(
                              child: _RepeatButton(
                                repeat: _repeat,
                                onPressed: () async {
                                  final picked = await _pickRepeat(context, _due ?? _first, _repeat);
                                  if (picked != null && mounted) setState(() => _repeat = picked.choice);
                                },
                              ),
                            ),
                          ],
                        ),
                        onSubmitted: () => _submit(state),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The next time a repeating task comes round, before it's made: its name
/// and rule, to change or take away like a task.
class _RepeatPreview extends StatefulWidget {
  const _RepeatPreview({super.key, required this.repeat, required this.day});

  final Repeat repeat;
  final DateTime day;

  @override
  State<_RepeatPreview> createState() => _RepeatPreviewState();
}

class _RepeatPreviewState extends State<_RepeatPreview> {
  bool _hover = false;

  /// The to-do it will be, not made until it's changed on its own.
  TodoItem get _item => TodoItem(
    -1,
    widget.repeat.text,
    since: widget.day,
    dueDate: widget.day,
    uid: '${widget.repeat.uid}@${dateKey(widget.day)}',
  );

  TodoItem _make() => AppScope.read(context).occurrence(widget.repeat, widget.day);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    return Padding(
      padding: const EdgeInsets.only(left: 18, top: 2, bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: HoverFill(
          hover: _hover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: Icon(Icons.repeat_rounded, size: 16, color: p.inkMuted.withValues(alpha: 0.8)),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.repeat.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.35, color: p.ink),
                      ),
                      Text(
                        widget.repeat.rule.label,
                        style: TextStyle(fontFamily: Fonts.body, fontSize: 10.5, color: p.inkMuted),
                      ),
                    ],
                  ),
                ),
                AnimatedOpacity(
                  opacity: _hover ? 1 : 0,
                  duration: Motion.hover,
                  curve: Motion.hoverCurve,
                  child: IgnorePointer(
                    ignoring: !_hover,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TaskAction(
                          tooltip: 'Edit task',
                          icon: Icons.edit_outlined,
                          onPressed: () => _editTask(context, TodoScope.month, _item, state.today, make: _make),
                        ),
                        _TaskAction(
                          tooltip: 'Remove',
                          icon: Icons.close_rounded,
                          onPressed: () => _removeTask(
                            context,
                            _item,
                            state.today,
                            () => state.removeTodo(TodoScope.month, _make()),
                          ),
                        ),
                      ],
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
