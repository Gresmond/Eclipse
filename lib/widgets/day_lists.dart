part of 'todo_panel.dart';

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
        final i = daysBetween(day, due);
        if (i <= WeekCard.span) {
          days[i < 0 ? 0 : i].add((scope, item));
        } else if (!waits(item)) {
          (byDay[dateKey(due)] ??= []).add((scope: scope, item: item, repeat: null));
        }
      }
    }
    for (final repeat in state.repeats) {
      final next = coming[repeat.uid];
      if (next == null || daysBetween(day, next) <= WeekCard.span) continue;
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
  final days = daysBetween(today, day);
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
