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
    final lists = {
      for (final scope in [TodoScope.today, TodoScope.tomorrow, TodoScope.week, TodoScope.month])
        scope: state.orderedTodos(scope, day: past ? day : null),
    };
    for (final item in lists[TodoScope.today]!) {
      days[0].add((TodoScope.today, item));
    }
    for (final item in lists[TodoScope.tomorrow]!) {
      days[1].add((TodoScope.tomorrow, item));
    }
    // Further ahead has a repeat only at its next time not yet passed, and
    // not at all while that's in the week; a later time made already waits.
    final kept = {
      for (final items in lists.values)
        for (final item in items) ?item.uid,
    };
    final coming = {
      if (!past)
        for (final repeat in state.repeats) repeat.uid: ?state.comingOccurrence(repeat, day, kept: kept),
    };
    bool waits(TodoItem item) => switch (state.repeatOf(item)) {
      final repeat? when !past => coming[repeat.uid] != item.repeatDay,
      _ => false,
    };
    final byDay = <String, List<_Later>>{};
    for (final scope in [TodoScope.week, TodoScope.month]) {
      for (final item in lists[scope]!) {
        final due = item.dueDate;
        if (due == null) {
          // Only a past day's lists still have tasks without a day.
          if (!item.done) undated.add((scope: scope, item: item, repeat: null));
          continue;
        }
        final i = _daysBetween(day, due);
        if (i <= WeekCard.span) {
          days[i < 0 ? 0 : i].add((scope, item));
        } else if (!waits(item)) {
          (byDay[dateKey(due)] ??= []).add((scope: scope, item: item, repeat: null));
        }
      }
    }
    for (final repeat in state.repeats) {
      final next = coming[repeat.uid];
      if (next == null || _daysBetween(day, next) <= WeekCard.span) continue;
      if (kept.contains('${repeat.uid}@${dateKey(next)}')) continue;
      (byDay[dateKey(next)] ??= []).add((scope: null, item: null, repeat: repeat));
    }
    later = [for (final key in byDay.keys.toList()..sort()) (DateTime.parse(key), _byTime(byDay[key]!, (l) => l.item))];
    for (var i = 0; i < days.length; i++) {
      days[i] = _byTime(days[i], (t) => t.$2);
    }
  }

  /// [tasks] with the open ones at a time first, earliest first; the rest
  /// keep their order.
  static List<T> _byTime<T>(List<T> tasks, TodoItem? Function(T) item) {
    int? time(T t) => switch (item(t)) {
      final i? when !i.done => i.dueTime,
      _ => null,
    };
    if (!tasks.any((t) => time(t) != null)) return tasks;
    final indexed = tasks.indexed.toList()
      ..sort((a, b) {
        final (x, y) = (time(a.$2), time(b.$2));
        if (x != null && y != null && x != y) return x.compareTo(y);
        if ((x == null) != (y == null)) return x == null ? 1 : -1;
        return a.$1.compareTo(b.$1);
      });
    return [for (final (_, t) in indexed) t];
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
void _addDue(AppState state, String text, DateTime day, {int? time, bool birthday = false}) {
  final today = state.today;
  final days = _daysBetween(today, day);
  if (days <= 0) {
    state.addTodo(TodoScope.today, text, time: time, birthday: birthday);
  } else if (days == 1) {
    state.addTodo(TodoScope.tomorrow, text, time: time, birthday: birthday);
  } else {
    // Due later this week files under This week, anything after under
    // This month; both move into Tomorrow and Today as the day nears.
    final sunday = DateTime(today.year, today.month, today.day + 7 - today.weekday);
    state.addTodo(
      day.isAfter(sunday) ? TodoScope.month : TodoScope.week,
      text,
      dueDate: day,
      time: time,
      birthday: birthday,
    );
  }
}

/// Adds [text] on [day] as [choice] says: a task, or a repeating one.
void _addChosen(AppState state, String text, DateTime day, _DayChoice choice) {
  final (time, birthday) = (choice.time, choice.birthday);
  if (choice.repeat case final repeat?) {
    state.addRepeat(text, repeat.rule, day, until: repeat.until, time: time, birthday: birthday);
  } else {
    _addDue(state, text, day, time: time, birthday: birthday);
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
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.shownDay, s.viewDay, s.weekEmptyDays));
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
            padding: const EdgeInsets.only(right: 4),
            child: TileHeader(
              title: 'Week ahead',
              caption: open == 0 && tasks.isNotEmpty ? 'All clear' : '$open open',
              trailingAtEnd: true,
              trailing: _ShowToggle(
                icon: Icons.date_range_rounded,
                what: 'days with no tasks',
                shown: state.weekEmptyDays,
                onPressed: state.toggleWeekEmptyDays,
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Another day's week fades through as a whole.
          Expanded(
            child: FadeThrough(
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: _WeekList(
                key: ValueKey(dateKey(day)),
                planned: planned,
                emptyDays: state.weekEmptyDays,
                added: added,
              ),
            ),
          ),
          _FoldAway(
            folded: past,
            child: _DatedAdd(
              first: today,
              last: DateTime(today.year, today.month, today.day + WeekCard.span),
              onAdd: (text, choice) => _addChosen(state, text, choice.day, choice),
            ),
          ),
        ],
      ),
    );
  }
}

/// One day's week: the days' lists, with [emptyDays] those with none.
class _WeekList extends StatefulWidget {
  const _WeekList({super.key, required this.planned, required this.emptyDays, required this.added});

  final _Planned planned;
  final bool emptyDays;

  /// Tasks just added, which fade in.
  final Set<int> added;

  @override
  State<_WeekList> createState() => _WeekListState();
}

class _WeekListState extends State<_WeekList> with _DayMotion {
  /// Whether a task is being dragged over each day, to light it.
  final _over = List.generate(WeekCard.span + 1, (_) => ValueNotifier(false));
  final _overBy = List.generate(WeekCard.span + 1, (_) => <Object>{});

  @override
  void dispose() {
    for (final over in _over) {
      over.dispose();
    }
    super.dispose();
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
    // Today always; another day while it has tasks, or one closing up,
    // unless empty days show too.
    final visible = [
      for (var i = 0; i <= WeekCard.span; i++)
        if (i == 0 || widget.emptyDays || planned.days[i].isNotEmpty || _hasDeparting('$i')) i,
    ];
    return SmoothTaskScroll(
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        scrollCacheExtent: const ScrollCacheExtent.pixels(80),
        slivers: [
          for (final i in visible) _section(state, i, shown[i], readOnly, first: i == visible.first),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }

  Widget _section(AppState state, int i, List<_Shown> shown, bool readOnly, {required bool first}) {
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
            _DayHeading(
              parts: [(_shortDate(date, state.today), true), if (name != null) (name, i == 0), (weekday, false)],
              strong: i == 0,
              first: first,
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

/// A day's heading, its parts joined with dots, over a rule.
class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.parts, this.strong = false, this.first = false, this.instant = false});

  /// The heading's parts; strong ones are full ink.
  final List<(String, bool)> parts;

  /// All in full ink: today's.
  final bool strong;

  /// The first in its list, with less room above.
  final bool first;

  /// Takes its room at once instead of easing to it.
  final bool instant;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Easing when a day comes in above it, or the one above goes.
    return AnimatedPadding(
      duration: instant ? Duration.zero : Motion.morph,
      curve: Motion.morphCurve,
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

/// Puts the cursor back in [focus]'s field with [selection] as it was.
/// Refocused from code, a desktop field would select all its text.
void _refocus(FocusNode focus, TextEditingController controller, TextSelection selection) {
  focus.requestFocus();
  // After the focus change, which is applied as a microtask.
  scheduleMicrotask(() {
    if (selection.isValid && selection.end <= controller.text.length) controller.selection = selection;
  });
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
/// [last]. The calendar button picks the day, its time, how it repeats and,
/// with [birthdays], whether it's a birthday; Enter without a day asks for
/// one.
class _DatedAdd extends StatefulWidget {
  const _DatedAdd({required this.first, this.last, this.birthdays = false, required this.onAdd});

  final DateTime first;
  final DateTime? last;
  final bool birthdays;
  final void Function(String text, _DayChoice choice) onAdd;

  @override
  State<_DatedAdd> createState() => _DatedAddState();
}

class _DatedAddState extends State<_DatedAdd> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  _DayChoice? _choice;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<_DayChoice?> _pick() async {
    final (choice, typing, selection) = (_choice, _focus.hasFocus, _controller.selection);
    final picked = await _pickDayAndRepeat(
      context,
      first: widget.first,
      last: widget.last,
      selected: choice?.day,
      repeat: choice?.repeat,
      time: choice?.time,
      birthday: choice?.birthday ?? false,
      birthdays: widget.birthdays,
    );
    if (!mounted) return null;
    if (picked != null) setState(() => _choice = picked);
    if (picked != null || typing) _refocus(_focus, _controller, selection);
    return picked;
  }

  Future<void> _submit() async {
    if (_controller.text.trim().isEmpty) return;
    // Every task has a day: without one yet, it's asked for.
    final choice = _choice ?? await _pick();
    if (choice == null || !mounted) return;
    widget.onAdd(_controller.text, choice);
    setState(() => _choice = null);
    _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final today = AppScope.read(context).today;
    final due = _choice?.day, repeat = _choice?.repeat, time = _choice?.time, birthday = _choice?.birthday == true;
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
              if (due != null)
                Flexible(
                  child: Text(_shortDate(due, today), maxLines: 1, overflow: TextOverflow.ellipsis, style: note),
                ),
              if (time != null) ...[
                const SizedBox(width: 6),
                Text(clockLabel(time), style: _timeStyle(p).copyWith(fontSize: 11)),
              ],
              if (repeat != null) ...[
                const SizedBox(width: 8),
                Icon(birthday ? _birthdayIcon : Icons.repeat_rounded, size: 12, color: p.accent),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    birthday ? 'Birthday' : repeat.rule.label,
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
  int? _time;

  /// While the wheel is open, the time stays though the field is empty.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && !_picking && _controller.text.trim().isEmpty && _time != null) {
        setState(() => _time = null);
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
    if (text.trim().isEmpty) return _focus.requestFocus();
    if (widget.past case final past?) {
      state.addTodo(widget.day == past ? TodoScope.today : TodoScope.tomorrow, text, day: past);
    } else {
      _addDue(state, text, widget.day, time: _time);
      setState(() => _time = null);
    }
    _controller.clear();
    _focus.requestFocus();
  }

  Future<void> _pick(BuildContext anchor) async {
    _picking = true;
    final selection = _controller.selection;
    final picked = await pickTime(anchor, minutes: _time, start: _time ?? 9 * 60);
    _picking = false;
    if (!mounted) return;
    if (picked != null) setState(() => _time = picked);
    _refocus(_focus, _controller, selection);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final time = _time;
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
          leading: _TaskAction(icon: Icons.add_rounded, onPressed: () => _submit(state)),
          // Only a time: a day's tasks don't repeat from here.
          trailing: widget.past != null
              ? const SizedBox.shrink()
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (time != null) Text(clockLabel(time), style: _timeStyle(p).copyWith(fontSize: 11)),
                    Builder(
                      builder: (anchor) => _TaskAction(
                        tooltip: time == null ? 'Add a time' : 'Change time',
                        icon: Icons.more_time_rounded,
                        onPressed: () => _pick(anchor),
                      ),
                    ),
                  ],
                ),
          onSubmitted: () => _submit(state),
        ),
      ),
    );
  }
}

/// A task's time, in the sleep schedule's semi-mono.
TextStyle _timeStyle(Palette p) => SleepName.timeStyle(p);

/// A rounded field for a new task's name, as at the foot of a to-do card.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.focus,
    required this.leading,
    required this.trailing,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final Widget leading, trailing;
  final VoidCallback onSubmitted;

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
            // Its buttons leave the cursor in the field.
            TextFieldTapRegion(child: leading),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: const [NoteInputFormatter()],
                style: TextStyle(fontFamily: Fonts.body, fontSize: 13.5, color: p.ink),
                cursorColor: p.accent,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Add task',
                  hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted.withValues(alpha: 0.65)),
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                ),
                onSubmitted: (_) => onSubmitted(),
              ),
            ),
            // Its buttons and labels keep to the end, the name taking the rest.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: TextFieldTapRegion(child: trailing),
            ),
          ],
        ),
      ),
    );
  }
}

/// A birthday's mark, in place of the repeat arrows in Further ahead.
const _birthdayIcon = Icons.celebration_rounded;

/// A card's button that shows or hides something: lit while it shows.
class _ShowToggle extends StatelessWidget {
  const _ShowToggle({required this.icon, required this.what, required this.shown, required this.onPressed});

  static const size = 28.0;

  final IconData icon;

  /// What it shows, as in "Show [what]".
  final String what;
  final bool shown;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      tooltip: shown ? 'Hide $what' : 'Show $what',
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      style: ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const WidgetStatePropertyAll(Size(size, size)),
        shape: const WidgetStatePropertyAll(CircleBorder()),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? p.empty.withValues(alpha: 0.8) : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      icon: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: shown ? p.accent : p.inkMuted.withValues(alpha: 0.45)),
        duration: Motion.click,
        curve: Motion.clickCurve,
        builder: (context, colour, _) => Icon(icon, size: 16, color: colour),
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
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.shownDay, s.viewDay, s.laterBirthdays));
    final day = state.shownDay;
    final past = state.viewDay != null;
    final planned = _Planned(state, day, past: past);
    // Birthdays are only known from today on, so a past day leaves them out.
    final birthdays = state.laterBirthdays && !past;
    bool shows(_Later later) => birthdays || !(later.item?.birthday ?? later.repeat!.birthday);
    final groups = [
      for (final (date, items) in [
        for (final (date, items) in planned.later) (date as DateTime?, items),
        if (planned.undated.isNotEmpty) (null, planned.undated),
      ])
        if (items.where(shows).toList() case final shown when shown.isNotEmpty) (date, shown),
    ];
    final count = groups.fold(0, (n, g) => n + g.$2.length);
    // Hidden birthdays count as seen, so showing them doesn't fade them in.
    final added = _added(day, [
      for (final (_, items) in [...planned.later, (null, planned.undated)])
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
            padding: const EdgeInsets.only(right: 4),
            child: TileHeader(
              title: 'Further ahead',
              caption: '$count planned',
              trailingAtEnd: true,
              trailing: AnimatedOpacity(
                opacity: past ? 0 : 1,
                duration: Motion.morph,
                curve: Motion.morphCurve,
                child: IgnorePointer(
                  ignoring: past,
                  child: _ShowToggle(
                    icon: _birthdayIcon,
                    what: 'birthdays',
                    shown: state.laterBirthdays,
                    onPressed: state.toggleLaterBirthdays,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: FadeThrough(
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: _LaterList(key: ValueKey(dateKey(day)), groups: groups, birthdays: birthdays, added: added),
            ),
          ),
          _FoldAway(
            folded: past,
            child: _DatedAdd(
              first: DateTime(today.year, today.month, today.day + WeekCard.span + 1),
              birthdays: true,
              onAdd: (text, choice) => _addChosen(state, text, choice.day, choice),
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
  const _LaterList({super.key, required this.groups, required this.birthdays, required this.added});

  final List<(DateTime?, List<_Later>)> groups;

  /// Whether birthdays show: shown or hidden, they pop in or out at once.
  final bool birthdays;

  /// Tasks just added, which fade in.
  final Set<int> added;

  @override
  State<_LaterList> createState() => _LaterListState();
}

class _LaterListState extends State<_LaterList> with _DayMotion {
  /// Birthdays were just shown or hidden: this build jumps to how it is.
  var _instant = false;

  /// Birthday repeats just hidden, closing up where they were.
  final _hiding = <String, ({String group, int index, Repeat repeat})>{};

  static String _key(DateTime? date) => date == null ? 'none' : dateKey(date);

  /// A row by its day and task or repeat, so one that moves day counts as
  /// gone from where it was.
  static String _place(String group, _Later later) => '$group/${later.item?.id ?? later.repeat!.uid}';

  @override
  void didUpdateWidget(_LaterList old) {
    super.didUpdateWidget(old);
    // Birthdays shown or hidden pop in or out at once, as empty days do in
    // the week: the list is simply drawn as it now is.
    if (widget.birthdays != old.birthdays) {
      _instant = true;
      _drawn
        ..clear()
        ..addAll({
          for (final (date, items) in widget.groups) _key(date): [for (final later in items) ?later.item?.id],
        });
      return;
    }
    // Whatever's gone (ticked into Today or moved) closes up where it was.
    final now = {
      for (final (date, items) in widget.groups)
        for (final later in items) _place(_key(date), later),
    };
    for (final (date, items) in old.groups) {
      final group = _key(date);
      var repeats = 0;
      for (final later in items) {
        if (later.repeat != null) repeats++;
        if (now.contains(_place(group, later))) continue;
        if (later.item case final item?) {
          if (_departing.containsKey(item.id)) continue;
          _departing[item.id] = (
            group: group,
            index: (_drawn[group] ?? const []).indexOf(item.id),
            task: (later.scope!, item),
          );
          _after(() => _departing.remove(item.id));
        } else {
          final uid = later.repeat!.uid;
          _hiding[uid] = (group: group, index: repeats - 1, repeat: later.repeat!);
          _after(() => _hiding.remove(uid));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final instant = _instant;
    _instant = false;
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
    final current = {for (final g in groups) g.key};
    // A day whose last task was just removed stays while it closes up.
    for (final key in {
      for (final d in _departing.values) d.group,
      for (final h in _hiding.values) h.group,
    }.difference(current)) {
      groups.add((date: key == 'none' ? null : DateTime.parse(key), key: key, tasks: const [], repeats: <Repeat>[]));
    }
    for (final h in _hiding.values) {
      final repeats = groups.firstWhere((g) => g.key == h.group).repeats;
      if (!repeats.any((r) => r.uid == h.repeat.uid)) repeats.insert(h.index.clamp(0, repeats.length), h.repeat);
    }
    final hidden = _hiding.keys.toSet();
    groups.sort((a, b) => a.date == null ? 1 : (b.date == null ? -1 : a.date!.compareTo(b.date!)));
    final shown = {for (final g in groups) g.key: _shown(g.key, g.tasks)};
    _settle();
    if (groups.isEmpty) {
      return Center(
        child: Text(
          widget.birthdays || AppScope.read(context).viewDay != null
              ? 'Nothing more than a week away'
              : 'Nothing but birthdays',
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
              key: ValueKey(g.key),
              padding: const EdgeInsets.only(right: 8),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    // A day comes and goes with its last tasks.
                    child: Appear(
                      animate: false,
                      shown: current.contains(g.key),
                      child: _DayHeading(
                        instant: instant,
                        first: i == 0,
                        parts: switch (g.date) {
                          null => const [('No date', true)],
                          final date => [
                            (_shortDate(date, state.today), true),
                            (weekdayNames[date.weekday - 1], false),
                          ],
                        },
                      ),
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
                        final repeat = g.repeats[index - tasks.length];
                        final (fadeIn, leaving) = (false, hidden.contains(repeat.uid));
                        if (repeat.birthday) {
                          return _LaterRow(day: day, repeat: repeat, date: g.date, fadeIn: fadeIn, leaving: leaving);
                        }
                        // Ticked like any other task, it's made first, then
                        // closes up here as it goes to Today: ticked.
                        final date = g.date!;
                        final made = leaving ? _made(state, '${repeat.uid}@${dateKey(date)}') : null;
                        TodoItem make() => state.occurrence(repeat, date);
                        return TaskRow(
                          key: ValueKey(repeat.uid),
                          scope: TodoScope.month,
                          item: made ?? _unmade(repeat, date),
                          day: day,
                          readOnly: readOnly,
                          fadeIn: fadeIn,
                          leaving: leaving,
                          make: made == null ? make : null,
                          onRemove: () => state.removeTodo(TodoScope.month, make()),
                        );
                      }
                      final (:task, :arriving, :leaving) = tasks[index];
                      final (scope, item) = task;
                      final fadeIn = widget.added.contains(item.id) || arriving;
                      void remove() => _remove(g.key, task, () => state.removeTodo(scope, item, day: day));
                      if (item.birthday) {
                        return _LaterRow(
                          key: ValueKey((scope, item.id)),
                          day: day,
                          task: task,
                          readOnly: readOnly,
                          fadeIn: fadeIn,
                          leaving: leaving,
                          onRemove: remove,
                        );
                      }
                      // Leaving because it was ticked, it closes up ticked.
                      final latest = leaving ? _latest(state, item) : null;
                      return TaskRow(
                        key: ValueKey((scope, item.id)),
                        scope: latest?.$1 ?? scope,
                        item: latest?.$2 ?? item,
                        day: day,
                        readOnly: readOnly,
                        fadeIn: fadeIn,
                        leaving: leaving,
                        onRemove: remove,
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

/// [repeat]'s to-do for [date], before it's made.
TodoItem _unmade(Repeat repeat, DateTime date) => TodoItem(
  -1,
  repeat.text,
  since: date,
  dueDate: date,
  dueTime: repeat.time,
  birthday: repeat.birthday,
  uid: '${repeat.uid}@${dateKey(date)}',
);

/// The to-do made with [uid], wherever it is now.
TodoItem? _made(AppState state, String uid) =>
    [for (final items in state.todos.values) ...items].where((item) => item.uid == uid).firstOrNull;

/// [item] as it is now, and the list it's in, if it's still in one.
_Task? _latest(AppState state, TodoItem item) => [
  for (final MapEntry(key: scope, value: items) in state.todos.entries)
    for (final task in items) (scope, task),
].where((t) => t.$2.id == item.id).firstOrNull;

/// A birthday further ahead: a [task], or the next time a [repeat] comes round
/// on [date] before it's made. Either is only looked at from here, to
/// change or take away; it's ticked once it's in the week.
class _LaterRow extends StatefulWidget {
  const _LaterRow({
    super.key,
    required this.day,
    this.task,
    this.repeat,
    this.date,
    this.readOnly = false,
    this.fadeIn = false,
    this.leaving = false,
    this.onRemove,
  }) : assert(task != null || (repeat != null && date != null));

  /// The day the list is for.
  final DateTime day;
  final _Task? task;
  final Repeat? repeat;
  final DateTime? date;
  final bool readOnly;

  /// Fades in: just added.
  final bool fadeIn;

  /// Removed, closing up.
  final bool leaving;
  final VoidCallback? onRemove;

  @override
  State<_LaterRow> createState() => _LaterRowState();
}

class _LaterRowState extends State<_LaterRow> {
  bool _hover = false;

  /// The to-do, or the one the repeat will make, not made until it's
  /// changed on its own.
  TodoItem get _item => widget.task?.$2 ?? _unmade(widget.repeat!, widget.date!);

  TodoItem _make() => AppScope.read(context).occurrence(widget.repeat!, widget.date!);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final item = _item;
    final repeat = widget.repeat ?? state.repeatOf(item);
    final scope = widget.task?.$1 ?? TodoScope.month;
    final made = widget.task != null;
    final caption = switch (repeat) {
      // A birthday's icon says it comes round every year.
      _? when item.birthday => null,
      final repeat? => repeat.rule.label,
      null when item.subtasks.isNotEmpty =>
        '${item.subtasks.where((child) => child.done).length}/${item.subtasks.length} complete',
      null => null,
    };
    return Appear(
      animate: widget.fadeIn,
      shown: !widget.leaving,
      child: IgnorePointer(
        ignoring: widget.readOnly || widget.leaving,
        child: Padding(
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
                      child: repeat == null
                          ? null
                          : Icon(
                              item.birthday ? _birthdayIcon : Icons.repeat_rounded,
                              size: 16,
                              color: p.inkMuted.withValues(alpha: 0.8),
                            ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: [
                                if (item.dueTime case final time?)
                                  TextSpan(text: '${clockLabel(time)}  ', style: _timeStyle(p).copyWith(height: 1.35)),
                                TextSpan(text: item.text),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: Fonts.body,
                              fontSize: 14,
                              height: 1.35,
                              color: item.done
                                  ? p.inkMuted.withValues(alpha: p.brightness == Brightness.dark ? 0.75 : 0.7)
                                  : p.ink,
                              decoration: item.done ? TextDecoration.lineThrough : null,
                            ),
                          ),
                          if (caption != null)
                            Text(
                              caption,
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
                              onPressed: () => _editTask(context, scope, item, widget.day, make: made ? null : _make),
                            ),
                            _TaskAction(
                              tooltip: 'Remove',
                              icon: Icons.close_rounded,
                              onPressed: () => _removeTask(
                                context,
                                item,
                                widget.day,
                                made ? widget.onRemove! : () => state.removeTodo(TodoScope.month, _make()),
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
        ),
      ),
    );
  }
}
