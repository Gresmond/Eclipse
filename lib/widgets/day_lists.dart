part of 'todo_panel.dart';

/// Calendar days from [from] to [to], unaffected by clock changes.
int _daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// A task in one of a day's lists.
typedef _Task = (TodoScope, TodoItem);

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

  final days = List.generate(WeekCard.span + 1, (_) => <_Task>[]);
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

/// A task as a day's list draws it: [arriving] from another day, or
/// [leaving] once removed.
typedef _Shown = ({_Task task, bool arriving, bool leaving});

/// The comings and goings of one day's lists, for a list state made per
/// day: a task come from another day (ticked from Tomorrow, or moved
/// here) shows unticked at the bottom of its day before it settles into
/// place, and a removed one closes up where it was.
mixin _DayMotion<T extends StatefulWidget> on State<T> {
  /// Each day's tasks as last drawn, by its group.
  final _drawn = <String, List<int>>{};
  bool _started = false;
  final _arriving = <int>{};
  final _timers = <Timer>{};
  final _departing = <int, ({String group, int index, _Task task})>{};

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

  void _after(VoidCallback done) {
    late final Timer timer;
    timer = Timer(Motion.morph, () {
      _timers.remove(timer);
      if (mounted) setState(done);
    });
    _timers.add(timer);
  }

  /// [tasks], [group]'s list in order, as it's drawn now. Call once per
  /// group per build, after [_settle] for the build before.
  List<_Shown> _shown(String group, List<_Task> tasks) {
    final ids = [for (final (_, item) in tasks) item.id];
    // Everything there when the list first shows is simply there.
    final before = _drawn[group] ?? (_started ? const <int>[] : ids);
    final added = ids.toSet().difference(before.toSet());
    if (added.isNotEmpty) {
      _arriving.addAll(added);
      _after(() => _arriving.removeAll(added));
    }
    final shown = <_Shown>[
      for (final task in tasks)
        if (!_arriving.contains(task.$2.id)) (task: task, arriving: false, leaving: false),
      for (final task in tasks)
        if (_arriving.contains(task.$2.id)) (task: task, arriving: true, leaving: false),
    ];
    for (final departure in _departing.values.where((d) => d.group == group)) {
      if (ids.contains(departure.task.$2.id)) continue;
      shown.insert(departure.index.clamp(0, shown.length), (task: departure.task, arriving: false, leaving: true));
    }
    _drawn[group] = [for (final s in shown) s.task.$2.id];
    return shown;
  }

  /// After a build: every group is now drawn, so later ones are new.
  void _settle() => _started = true;

  /// Removes [task] from [group], closing it up.
  void _remove(String group, _Task task, VoidCallback remove) {
    final id = task.$2.id;
    if (_departing.containsKey(id)) return;
    _departing[id] = (group: group, index: (_drawn[group] ?? const []).indexOf(id), task: task);
    remove();
    _after(() => _departing.remove(id));
    setState(() {});
  }

  bool _hasDeparting(String group) => _departing.values.any((d) => d.group == group);
}

/// 'Oct 28', with the year when it isn't [today]'s.
String _shortDate(DateTime day, DateTime today) =>
    '${monthNames[day.month - 1].substring(0, 3)} ${day.day}${day.year != today.year ? ' ${day.year}' : ''}';

/// Adds [text] as a task due on [day], in the list it belongs to now.
void _addDue(AppState state, String text, DateTime day) {
  final today = state.today;
  final days = _daysBetween(today, day);
  if (days <= 0) {
    state.addTodo(TodoScope.today, text);
  } else if (days == 1) {
    state.addTodo(TodoScope.tomorrow, text);
  } else {
    // Due later this week files under This week, anything after under
    // This month; both move into Tomorrow and Today as the day nears.
    final sunday = DateTime(today.year, today.month, today.day + 7 - today.weekday);
    state.addTodo(day.isAfter(sunday) ? TodoScope.month : TodoScope.week, text, dueDate: day);
  }
}

/// Today and the six days after it, one day under another: today always,
/// the others only when something's due. The strip of days at the top
/// jumps to one, follows the scroll, and takes a task dropped on it.
class WeekCard extends StatefulWidget {
  const WeekCard({super.key});

  /// The days after today it reaches; anything later is further ahead.
  static const span = 6;

  @override
  State<WeekCard> createState() => _WeekCardState();
}

class _WeekCardState extends State<WeekCard> with _NewTasks {
  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.shownDay, s.viewDay));
    final day = state.shownDay;
    final past = state.viewDay != null;
    final planned = _Planned(state, day, past: past);
    final tasks = planned.days.expand((d) => d);
    final open = tasks.where((t) => !t.$2.done).length;
    final added = _added(day, [for (final (_, item) in tasks) item.id]);
    final today = state.today;

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
          _FoldAway(
            folded: past,
            child: _DatedAdd(
              first: today,
              last: DateTime(today.year, today.month, today.day + WeekCard.span),
              onAdd: (text, due, repeat) => repeat == null
                  ? _addDue(state, text, due)
                  : state.addRepeat(text, repeat.rule, due, until: repeat.until),
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

class _WeekListState extends State<_WeekList> with _DayMotion {
  final _keys = List.generate(WeekCard.span + 1, (_) => GlobalKey());

  /// Whether a task is being dragged over each day, to light it.
  final _over = List.generate(WeekCard.span + 1, (_) => ValueNotifier(false));
  final _overBy = List.generate(WeekCard.span + 1, (_) => <Object>{});

  /// The days showing, by index from the first: those with tasks.
  List<int> _visible = const [0];

  /// The day at the top of the list, which the strip marks.
  int _top = 0;

  @override
  void dispose() {
    for (final over in _over) {
      over.dispose();
    }
    super.dispose();
  }

  bool _scrolled(ScrollNotification notification) {
    final viewport = notification.context?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached) return false;
    final edge = viewport.localToGlobal(Offset.zero).dy;
    // The last day whose heading has reached the top.
    var top = _visible.first;
    for (final i in _visible) {
      final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) break;
      if (box.localToGlobal(Offset.zero).dy - edge > 24) break;
      top = i;
    }
    // At the very bottom, the last day is the one being looked at.
    final metrics = notification.metrics;
    if (metrics.extentAfter < 1 && metrics.extentBefore > 0) top = _visible.last;
    if (top != _top) setState(() => _top = top);
    return false;
  }

  void _goTo(int index) {
    final context = _keys[index].currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(context, duration: Motion.page, curve: Motion.morphCurve);
  }

  DateTime _date(int i) {
    final day = AppScope.read(context).shownDay;
    return DateTime(day.year, day.month, day.day + i);
  }

  /// An open task of today's lists, not already on day [i], moves there.
  bool _accepts(_TaskDrag drag, int i) {
    final state = AppScope.read(context);
    return state.viewDay == null &&
        drag.day == state.today &&
        !drag.item.done &&
        !widget.planned.days[i].any((t) => t.$2.id == drag.item.id);
  }

  void _drop(_TaskDrag drag, int i) => AppScope.read(context).moveTodoTo(drag.scope, drag.item, _date(i));

  void _hover(int i, Object by, bool over) {
    over ? _overBy[i].add(by) : _overBy[i].remove(by);
    _over[i].value = _overBy[i].isNotEmpty;
  }

  /// [child], part of day [i], taking a task dropped on it for that day.
  Widget _dropTarget(int i, Widget child) {
    final by = Object();
    return DragTarget<_TaskDrag>(
      onWillAcceptWithDetails: (details) {
        final ok = _accepts(details.data, i);
        if (ok) _hover(i, by, true);
        return ok;
      },
      onLeave: (_) => _hover(i, by, false),
      onAcceptWithDetails: (details) {
        _hover(i, by, false);
        _drop(details.data, i);
      },
      builder: (context, candidates, rejected) => child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final day = state.shownDay;
    final readOnly = !state.canEditDay(day);
    final planned = widget.planned;
    final shown = [for (var i = 0; i <= WeekCard.span; i++) _shown('$i', planned.days[i])];
    _settle();
    // Today always; another day while it has tasks, or one closing up.
    _visible = [
      for (var i = 0; i <= WeekCard.span; i++)
        if (i == 0 || planned.days[i].isNotEmpty || _hasDeparting('$i')) i,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: _WeekStrip(
            first: day,
            today: state.today,
            focus: _top,
            shown: {..._visible},
            onDay: _goTo,
            accepts: _accepts,
            onDrop: _drop,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _scrolled,
            child: SmoothTaskScroll(
              builder: (context, controller) => CustomScrollView(
                controller: controller,
                scrollCacheExtent: const ScrollCacheExtent.pixels(80),
                slivers: [
                  for (final i in _visible) _section(state, i, shown[i], readOnly),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(AppState state, int i, List<_Shown> shown, bool readOnly) {
    final p = context.palette;
    final date = _date(i);
    final added = widget.added;
    final weekday = weekdayNames[date.weekday - 1];
    final name = switch (_daysBetween(state.today, date)) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => null,
    };
    final Widget? foot;
    if (state.viewDay == null) {
      foot = _AddTask(day: date, today: state.today);
    } else if (!readOnly && i <= 1) {
      // Yesterday, while it can still be edited, takes tasks into its own
      // Today and Tomorrow.
      foot = _AddTask(day: date, today: state.today, past: state.viewDay);
    } else if (shown.isEmpty) {
      foot = Padding(
        padding: const EdgeInsets.fromLTRB(26, 6, 0, 4),
        child: Text(
          'Nothing planned',
          style: TextStyle(fontFamily: Fonts.body, fontSize: 13, color: p.inkMuted.withValues(alpha: 0.7)),
        ),
      );
    } else {
      foot = null;
    }
    final group = SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: _dropTarget(
            i,
            KeyedSubtree(
              key: _keys[i],
              child: _DayHeading(
                parts: [(_shortDate(date, state.today), true), if (name != null) (name, i == 0), (weekday, false)],
                strong: i == 0,
                first: i == _visible.first,
              ),
            ),
          ),
        ),
        if (i == 0 && shown.isEmpty && state.viewDay == null)
          SliverToBoxAdapter(
            child: _dropTarget(
              i,
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 6, 0, 2),
                child: Text(
                  'Nothing due',
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 13, color: p.inkMuted.withValues(alpha: 0.7)),
                ),
              ),
            ),
          ),
        LazyTaskSliver(
          ids: [for (final s in shown) (s.task.$1, s.task.$2.id)],
          itemBuilder: (context, index) {
            final (:task, :arriving, :leaving) = shown[index];
            final (scope, item) = task;
            return _dropTarget(
              i,
              TaskRow(
                key: ValueKey((scope, item.id)),
                scope: scope,
                item: item,
                day: state.shownDay,
                readOnly: readOnly,
                fadeIn: added.contains(item.id) || arriving,
                arriving: arriving,
                leaving: leaving,
                onRemove: () => _remove('$i', task, () => state.removeTodo(scope, item, day: state.shownDay)),
              ),
            );
          },
        ),
        if (foot != null) SliverToBoxAdapter(child: _dropTarget(i, foot)),
      ],
    );
    // A day a task is dragged over lights up.
    return ValueListenableBuilder(
      valueListenable: _over[i],
      builder: (context, over, sliver) => TweenAnimationBuilder<double>(
        tween: Tween(end: over ? 0.08 : 0),
        duration: Motion.hover,
        curve: Motion.hoverCurve,
        builder: (context, alpha, sliver) => DecoratedSliver(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: p.accent.withValues(alpha: alpha),
          ),
          sliver: sliver!,
        ),
        child: sliver,
      ),
      child: SliverPadding(padding: const EdgeInsets.only(right: 8), sliver: group),
    );
  }
}

/// The week card's days in a row, the one at the top of the list marked.
/// Days with nothing due are dimmed, but still take a dropped task.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.first,
    required this.today,
    required this.focus,
    required this.shown,
    required this.onDay,
    required this.accepts,
    required this.onDrop,
  });

  final DateTime first, today;
  final int focus;

  /// The days with a section in the list.
  final Set<int> shown;
  final ValueChanged<int> onDay;
  final bool Function(_TaskDrag drag, int day) accepts;
  final void Function(_TaskDrag drag, int day) onDrop;

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
                child: DragTarget<_TaskDrag>(
                  onWillAcceptWithDetails: (details) => accepts(details.data, i),
                  onAcceptWithDetails: (details) => onDrop(details.data, i),
                  builder: (context, candidates, rejected) => _StripDay(
                    day: DateTime(first.year, first.month, first.day + i),
                    today: today,
                    focused: i == focus,
                    empty: !shown.contains(i),
                    dropping: candidates.isNotEmpty,
                    onTap: () => onDay(i),
                  ),
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
  const _StripDay({
    required this.day,
    required this.today,
    required this.focused,
    required this.empty,
    required this.dropping,
    required this.onTap,
  });

  final DateTime day, today;
  final bool focused;

  /// Nothing due: dimmed, and nothing to jump to.
  final bool empty;

  /// A task is dragged over it.
  final bool dropping;
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
    final empty = widget.empty;
    final dropping = widget.dropping;
    final ink = empty && !dropping ? p.inkMuted.withValues(alpha: 0.4) : (focused ? p.ink : p.inkMuted);
    return Tooltip(
      message:
          '${weekdayNames[widget.day.weekday - 1]} ${_shortDate(widget.day, widget.today)}'
          '${empty ? ', nothing due' : ''}',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: empty ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: empty ? null : widget.onTap,
          child: HoverFill(
            hover: (_hover && !empty) || dropping,
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
                      color: empty && !dropping ? ink : (focused ? p.ink : p.inkMuted.withValues(alpha: 0.8)),
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
                      color: isToday ? p.today : (dropping ? p.accent.withValues(alpha: 0.18) : Colors.transparent),
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
                        color: isToday ? p.onToday : ink,
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

/// A day's heading, its parts joined with dots, over a rule.
class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.parts, this.strong = false, this.first = false});

  /// The heading's parts; strong ones are full ink.
  final List<(String, bool)> parts;

  /// All in full ink: today's.
  final bool strong;

  /// The first in its list, with less room above.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: EdgeInsets.only(top: first ? 12 : 22, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                for (final (i, (part, full)) in parts.indexed) ...[
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
        ],
      ),
    );
  }
}

/// [child] at a card's foot, folded away (while looking back) so it eases
/// out and back rather than snapping.
class _FoldAway extends StatelessWidget {
  const _FoldAway({required this.folded, required this.child});

  final bool folded;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedAlign(
      duration: Motion.morph,
      curve: Motion.morphCurve,
      alignment: Alignment.topCenter,
      heightFactor: folded ? 0 : 1,
      child: AnimatedOpacity(
        duration: Motion.morph,
        curve: Motion.morphCurve,
        opacity: folded ? 0 : 1,
        child: IgnorePointer(
          ignoring: folded,
          child: ExcludeFocus(excluding: folded, child: child),
        ),
      ),
    ),
  );
}

/// The field at a card's foot for a new task on a day between [first] and
/// [last]. The calendar button picks the day and how it repeats; Enter
/// without a day asks for one.
class _DatedAdd extends StatefulWidget {
  const _DatedAdd({required this.first, this.last, required this.onAdd});

  final DateTime first;
  final DateTime? last;
  final void Function(String text, DateTime due, _RepeatChoice? repeat) onAdd;

  @override
  State<_DatedAdd> createState() => _DatedAddState();
}

class _DatedAddState extends State<_DatedAdd> {
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

  Future<DateTime?> _pick() async {
    final picked = await _pickDayAndRepeat(
      context,
      first: widget.first,
      last: widget.last,
      selected: _due,
      repeat: _repeat,
    );
    if (picked == null || !mounted) return null;
    setState(() {
      _due = picked.day;
      _repeat = picked.repeat;
    });
    _focus.requestFocus();
    return picked.day;
  }

  Future<void> _submit() async {
    if (_controller.text.trim().isEmpty) return;
    // Every task has a day: without one yet, it's asked for.
    final due = _due ?? await _pick();
    if (due == null || !mounted) return;
    widget.onAdd(_controller.text, due, _repeat);
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
    final today = AppScope.read(context).today;
    final due = _due, repeat = _repeat;
    final note = TextStyle(fontFamily: Fonts.body, fontSize: 11, color: p.inkMuted);
    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 6),
      child: _Field(
        controller: _controller,
        focus: _focus,
        leading: _TaskAction(
          tooltip: due == null ? 'Pick a day' : 'Due ${dayMonth(due)}/${due.year}, click to change',
          icon: due == null ? Icons.calendar_today_outlined : Icons.event_available_outlined,
          onPressed: _pick,
        ),
        trailing: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (due != null) Text(_shortDate(due, today), style: note),
              if (repeat != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.repeat_rounded, size: 12, color: p.accent),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    repeat.rule.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: note.copyWith(color: p.accent),
                  ),
                ),
              ],
            ],
          ),
        ),
        onSubmitted: _submit,
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
      _addDue(state, text, widget.day);
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
  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.shownDay, s.viewDay));
    final day = state.shownDay;
    final past = state.viewDay != null;
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
    final today = state.today;

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
              child: _LaterList(key: ValueKey(dateKey(day)), groups: groups, added: added),
            ),
          ),
          _FoldAway(
            folded: past,
            child: _DatedAdd(
              first: DateTime(today.year, today.month, today.day + WeekCard.span + 1),
              onAdd: (text, due, repeat) => repeat == null
                  ? state.addTodo(TodoScope.month, text, dueDate: due)
                  : state.addRepeat(text, repeat.rule, due, until: repeat.until),
            ),
          ),
        ],
      ),
    );
  }
}

/// One day's further-ahead list: each date's tasks, then the repeats due
/// round on it; tasks without a day last.
class _LaterList extends StatefulWidget {
  const _LaterList({super.key, required this.groups, required this.added});

  final List<(DateTime?, List<_Later>)> groups;

  /// Tasks just added, which fade in.
  final Set<int> added;

  @override
  State<_LaterList> createState() => _LaterListState();
}

class _LaterListState extends State<_LaterList> with _DayMotion {
  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final day = state.shownDay;
    final readOnly = !state.canEditDay(day);
    final groups = [
      for (final (date, items) in widget.groups)
        (
          date: date,
          key: date == null ? 'none' : dateKey(date),
          tasks: [
            for (final later in items)
              if (later.item case final item?) (later.scope!, item),
          ],
          repeats: [for (final later in items) ?later.repeat],
        ),
    ];
    // A day whose last task was just removed stays while it closes up.
    for (final key in {for (final d in _departing.values) d.group}.difference({for (final g in groups) g.key})) {
      groups.add((date: key == 'none' ? null : DateTime.parse(key), key: key, tasks: const [], repeats: const []));
    }
    groups.sort((a, b) => a.date == null ? 1 : (b.date == null ? -1 : a.date!.compareTo(b.date!)));
    final shown = {for (final g in groups) g.key: _shown(g.key, g.tasks)};
    _settle();
    if (groups.isEmpty) {
      return Center(
        child: Text(
          'Nothing more than a week away',
          style: TextStyle(
            fontFamily: Fonts.body,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: p.inkMuted.withValues(alpha: 0.7),
          ),
        ),
      );
    }
    return SmoothTaskScroll(
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        scrollCacheExtent: const ScrollCacheExtent.pixels(80),
        slivers: [
          for (final (i, g) in groups.indexed)
            SliverPadding(
              padding: const EdgeInsets.only(right: 8),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: _DayHeading(
                      first: i == 0,
                      parts: switch (g.date) {
                        null => const [('No date', true)],
                        final date => [(_shortDate(date, state.today), true), (weekdayNames[date.weekday - 1], false)],
                      },
                    ),
                  ),
                  LazyTaskSliver(
                    ids: [
                      for (final s in shown[g.key]!) (s.task.$1, s.task.$2.id),
                      for (final repeat in g.repeats) repeat.uid,
                    ],
                    itemBuilder: (context, index) {
                      final tasks = shown[g.key]!;
                      if (index >= tasks.length) {
                        return _RepeatPreview(repeat: g.repeats[index - tasks.length], day: g.date!);
                      }
                      final (:task, :arriving, :leaving) = tasks[index];
                      final (scope, item) = task;
                      return TaskRow(
                        key: ValueKey((scope, item.id)),
                        scope: scope,
                        item: item,
                        day: day,
                        readOnly: readOnly,
                        fadeIn: widget.added.contains(item.id) || arriving,
                        arriving: arriving,
                        leaving: leaving,
                        onRemove: () => _remove(g.key, task, () => state.removeTodo(scope, item, day: day)),
                      );
                    },
                  ),
                ],
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 8)),
        ],
      ),
    );
  }
}

/// The next time a repeating task comes round, before it's made: its name
/// and rule, to change or take away like a task.
class _RepeatPreview extends StatefulWidget {
  const _RepeatPreview({required this.repeat, required this.day});

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
