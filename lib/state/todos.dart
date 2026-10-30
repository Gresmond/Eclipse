part of '../app_state.dart';

/// To-dos in the Today, Tomorrow, week and month lists, past days' lists,
/// and repeating tasks.
mixin _Todos on ChangeNotifier {
  Store get store;
  DateTime get today;
  void _startDay();
  void _removed(String label, List<RowsBefore> before);

  int todosRevision = 0;
  final _todoDays = LruCache<String, Map<TodoScope, List<TodoItem>>>(3);
  final _orderedTodos = LruCache<(TodoScope, String?), List<TodoItem>>(16);

  void _todosChanged() {
    _repeats = null;
    _todoDays.clear();
    _orderedTodos.clear();
    todosRevision++;
    notifyListeners();
  }

  final Map<TodoScope, List<TodoItem>> todos = {};

  /// Today and the preceding calendar day remain editable.
  bool canEditDay(DateTime day) =>
      !dateOnly(day).isAfter(today) && !dateOnly(day).isBefore(DateTime(today.year, today.month, today.day - 1));

  void _reloadTodos() {
    for (final scope in TodoScope.values) {
      final next = store.todos(scope, scope.period(today));
      final previous = todos[scope]!;
      if (previous.length != next.length ||
          !Iterable.generate(next.length, (i) => previous[i].sameContent(next[i])).every((same) => same)) {
        todos[scope] = next;
      }
    }
  }

  void addTodo(TodoScope scope, String text, {DateTime? day, DateTime? dueDate, int? time, bool birthday = false}) {
    final target = day ?? today;
    if (text.trim().isEmpty || !canEditDay(target)) return;
    final value = normaliseNote(text.trim());
    if (target == today) {
      final item = store.addTodo(scope, today, value);
      todos[scope] = [...todos[scope]!, item];
      if (dueDate != null || time != null || birthday) {
        store.editTodo(item.id, value, dueDate, today, time: time, birthday: birthday);
        store.promoteDueTodos(today, earliest: today);
        store.rollTomorrowToToday(dateKey(today));
        _reloadTodos();
      }
    } else {
      store.editPastTodo(scope, target, text: value, dueDate: dueDate, time: time, birthday: birthday);
    }
    _todosChanged();
  }

  List<TodoItem> todosOn(TodoScope scope, DateTime day) =>
      _todoDays.putIfAbsent(dateKey(day), () => store.todoListsOn(day))[scope]!;

  List<TodoItem> orderedTodos(TodoScope scope, {DateTime? day}) => _orderedTodos.putIfAbsent((
    scope,
    day == null ? null : dateKey(day),
  ), () => sortTodos(day == null ? todos[scope]! : todosOn(scope, day)));

  void toggleTodo(TodoItem item, {DateTime? day, TodoScope scope = TodoScope.today}) {
    final target = day ?? today;
    if (!canEditDay(target)) return;
    if (target == today) {
      store.setTodoDone(item.id, !item.done, day: today);
    } else {
      store.setPastTodoDone(scope, target, item, !item.done, today);
    }
    _reloadTodos();
    _todosChanged();
  }

  void setTodoSubtasks(TodoScope scope, TodoItem item, List<TodoSubtask> children, {DateTime? day}) {
    final target = day ?? today;
    if (!canEditDay(target)) return;
    store.setTodoSubtasks(scope, item, children, target, live: target == today);
    _reloadTodos();
    _todosChanged();
  }

  /// Without a [time], it has none; not a [birthday] unless set.
  void editTodo(
    TodoScope scope,
    TodoItem item,
    String text,
    DateTime? dueDate, {
    DateTime? day,
    int? time,
    bool birthday = false,
  }) {
    final target = day ?? today;
    if (!canEditDay(target) || text.trim().isEmpty) return;
    final value = normaliseNote(text.trim());
    if (target == today) {
      store.editTodo(item.id, value, dueDate, today, time: time, birthday: birthday);
      store.promoteDueTodos(today, earliest: today);
      store.rollTomorrowToToday(dateKey(today));
      _reloadTodos();
    } else {
      store.editPastTodo(scope, target, item: item, text: value, dueDate: dueDate, time: time, birthday: birthday);
    }
    _todosChanged();
  }

  bool nestTodo(TodoScope sourceScope, TodoItem source, TodoScope targetScope, TodoItem target) {
    final from = todos[sourceScope]!.where((item) => item.id == source.id).firstOrNull;
    final into = todos[targetScope]!.where((item) => item.id == target.id).firstOrNull;
    if (from == null || into == null || from.id == into.id || from.done || from.subtasks.isNotEmpty) return false;
    store.nestTodo(targetScope, from, into, today);
    _reloadTodos();
    _todosChanged();
    return true;
  }

  void moveTodo(TodoScope source, TodoItem item, TodoScope destination) {
    if (source == destination) return;
    final current = todos[source]!.where((t) => t.id == item.id).firstOrNull;
    if (current == null || current.done) return;
    store.moveTodo(current.id, destination, today);
    _reloadTodos();
    _todosChanged();
  }

  /// Moves an open task to [day]: Today, Tomorrow, or due that day.
  void moveTodoTo(TodoScope source, TodoItem item, DateTime day) {
    final current = todos[source]!.where((t) => t.id == item.id).firstOrNull;
    if (current == null || current.done || day.isBefore(today)) return;
    final days = daysBetween(today, day);
    if (days <= 1) {
      moveTodo(source, current, days == 0 ? TodoScope.today : TodoScope.tomorrow);
      return;
    }
    // Due this week files under This week, anything after under This month.
    final sunday = DateTime(today.year, today.month, today.day + 7 - today.weekday);
    store.moveTodo(current.id, day.isAfter(sunday) ? TodoScope.month : TodoScope.week, today, due: day);
    _reloadTodos();
    _todosChanged();
  }

  void removeTodo(TodoScope scope, TodoItem item, {DateTime? day}) {
    final target = day ?? today;
    if (!canEditDay(target)) return;
    if (item.uid case final uid?) {
      _removed('Removed “${item.text}”', [
        store.rowsBefore('todos', ['uid'], 'uid = ?', [uid]),
        store.rowsBefore('todo_history', ['uid', 'day'], 'uid = ?', [uid]),
      ]);
    }
    if (target == today) {
      store.deleteTodo(item.id, day: today);
      todos[scope] = [
        for (final task in todos[scope]!)
          if (task.id != item.id) task,
      ];
    } else {
      store.editPastTodo(scope, target, item: item, deleted: true);
    }
    _todosChanged();
  }

  // Repeating tasks

  List<Repeat>? _repeats;
  List<Repeat> get repeats => _repeats ??= store.repeats();

  /// The repeat [item] is a time of, while it still repeats.
  Repeat? repeatOf(TodoItem item) {
    final uid = item.repeatUid;
    return uid == null ? null : repeats.where((r) => r.uid == uid).firstOrNull;
  }

  /// The first time [repeat] comes round on or after [from] that wasn't
  /// taken away, made or not and done or not: the one time of it shown.
  /// [kept] has the uids of the to-dos still in a list.
  DateTime? comingOccurrence(Repeat repeat, DateTime from, {Set<String> kept = const {}}) {
    final made = store.madeOccurrences(repeat.uid);
    for (var day = repeat.next(from); day != null; day = repeat.next(DateTime(day.year, day.month, day.day + 1))) {
      final uid = '${repeat.uid}@${dateKey(day)}';
      if (kept.contains(uid) || !made.contains(uid)) return day;
    }
    return null;
  }

  /// [repeat]'s to-do for [day], made now so it can be changed on its own.
  TodoItem occurrence(Repeat repeat, DateTime day) {
    final item = store.makeOccurrence(repeat, day);
    _startDay();
    _todosChanged();
    return item;
  }

  void addRepeat(String text, RepeatRule rule, DateTime start, {DateTime? until, int? time, bool birthday = false}) {
    if (text.trim().isEmpty) return;
    store.addRepeat(normaliseNote(text.trim()), rule, start, until: until, time: time, birthday: birthday);
    _startDay();
    _todosChanged();
  }

  /// Makes [item] repeat from [start], or its day (or today), on, in place
  /// of it.
  void makeRepeating(
    TodoScope scope,
    TodoItem item,
    String text,
    RepeatRule rule, {
    DateTime? start,
    DateTime? until,
    int? time,
    bool birthday = false,
  }) {
    final day = start ?? item.dueDate;
    final first = day == null || day.isBefore(today) ? today : dateOnly(day);
    store.transaction(() {
      store.addRepeat(normaliseNote(text.trim()), rule, first, until: until, time: time, birthday: birthday);
      store.deleteTodo(item.id, day: today);
    });
    _reloadTodos();
    _startDay();
    _todosChanged();
  }

  /// Renames [repeat] from [from] on, and sets its time and whether it's a birthday.
  void renameRepeat(Repeat repeat, String text, DateTime from, {int? time, bool birthday = false}) {
    if (text.trim().isEmpty) return;
    store.renameRepeat(repeat.uid, normaliseNote(text.trim()), from, today, time: time, birthday: birthday);
    _repeats = null;
    _reloadTodos();
    _todosChanged();
  }

  /// Stops [repeat] coming round from [from] on.
  void endRepeat(Repeat repeat, DateTime from) {
    const times = 'substr(uid, 1, length(?1)) = ?1';
    _removed('Removed “${repeat.text}” and later ones', [
      store.rowsBefore('todo_repeats', ['uid'], 'uid = ?', [repeat.uid]),
      store.rowsBefore('todos', ['uid'], times, ['${repeat.uid}@']),
      store.rowsBefore('todo_history', ['uid', 'day'], times, ['${repeat.uid}@']),
    ]);
    store.endRepeat(repeat.uid, from, today);
    _reloadTodos();
    _startDay();
    _todosChanged();
  }

  /// [repeat] from [from] on, as a new repeat by [rule] (from [start], when
  /// given); or, without one,
  /// no more after [from], whose to-do stays.
  void changeRepeat(
    Repeat repeat,
    DateTime from,
    String text,
    RepeatRule? rule, {
    DateTime? start,
    DateTime? until,
    int? time,
    bool birthday = false,
  }) {
    if (text.trim().isEmpty) return;
    final value = normaliseNote(text.trim());
    // A new start ends the old rule there, if it's sooner.
    final first = start ?? from;
    final end = first.isBefore(from) ? first : from;
    store.transaction(() {
      if (rule == null) {
        store.endRepeat(repeat.uid, DateTime(from.year, from.month, from.day + 1), today);
        if ((value, time, birthday) != (repeat.text, repeat.time, repeat.birthday)) {
          store.renameRepeat(repeat.uid, value, from, today, time: time, birthday: birthday);
        }
      } else {
        store.endRepeat(repeat.uid, end, today);
        store.addRepeat(
          value,
          rule,
          first.isBefore(today) ? today : first,
          until: until,
          time: time,
          birthday: birthday,
        );
      }
    });
    _reloadTodos();
    _startDay();
    _todosChanged();
  }
}
