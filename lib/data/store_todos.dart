part of 'store.dart';

/// Task persistence and historical routing share atomic write operations.
extension StoreTodos on Store {
  /// Moves tasks on for [day]. These moves aren't synced: each computer
  /// makes them itself from the edits it has, so one that hasn't heard of
  /// a tick yet can't overwrite it by carrying the task forward.
  Map<TodoScope, List<TodoItem>> startDay(DateTime day) => local(day: dateKey(day), () {
    captureTodoBaseline(day);
    promoteDueTodos(day);
    rollTomorrowToToday(dateKey(day));
    final lists = <TodoScope, List<TodoItem>>{};
    for (final scope in TodoScope.values) {
      carryForward(scope, scope.period(day), day: day);
      lists[scope] = todos(scope, scope.period(day));
    }
    return lists;
  });

  // To-dos

  List<TodoItem> todos(TodoScope scope, String period) => [
    for (final r in _db.select('SELECT * FROM todos WHERE scope = ? AND period = ? ORDER BY id', [scope.name, period]))
      _todo(r),
  ];

  DateTime get _today => dayOf(DateTime.now(), parseDayStartHour(setting('dayStartHour')));

  /// Establish the first known daily state for tasks from older versions.
  /// Once a task has history, its last snapshot already covers unchanged days.
  void captureTodoBaseline(DateTime day) => _recordTodos(
    _db.select('SELECT * FROM todos t WHERE NOT EXISTS (SELECT 1 FROM todo_history h WHERE h.uid = t.uid)'),
    day,
  );

  /// The rows of [ids], by id, in one query.
  Map<Object?, Row> _byIds(List<int> ids) => ids.isEmpty
      ? const {}
      : {
          for (final r in _db.select(
            'SELECT * FROM todos WHERE id IN (${List.filled(ids.length, '?').join(',')})',
            ids,
          ))
            r['id']: r,
        };

  /// Open tasks that give reminders, each with the day it's on: its due
  /// day, or, in Tomorrow without one, tomorrow; in Today without one, the
  /// day it came into Today. A task carried on from an earlier day is still
  /// on that day, as one with a due date is, so its time doesn't remind again.
  List<(TodoItem, DateTime)> remindingTodos(DateTime today) => [
    for (final r in _db.select('SELECT * FROM todos WHERE done = 0 AND reminders > 0'))
      if (DateTime.tryParse(r['due_date'] as String? ?? '') ??
              switch (r['scope']) {
                'today' => _inTodaySince(r, today),
                'tomorrow' => DateTime(today.year, today.month, today.day + 1),
                _ => null,
              }
          case final day?)
        (_todo(r), day),
  ];

  /// Looks up a reminding open task by [uid] across all scopes/periods,
  /// including deferred future-month tasks not in `AppState.todos`.
  (TodoScope, TodoItem)? remindingTodoByUid(String uid) {
    final rows = _db.select('SELECT * FROM todos WHERE uid = ? AND done = 0', [uid]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final scope = TodoScope.values.byName(row['scope'] as String);
    return (scope, _todo(row));
  }

  /// The first day of the stay in Today that [r] is on now with its current
  /// time and reminders: the day after the last its record shows it in
  /// another list or before its time or reminders were changed.
  DateTime _inTodaySince(Row r, DateTime today) {
    final first = _db.select(
      "SELECT MIN(day) AS day FROM todo_history WHERE uid = ?1 AND json_extract(snapshot, '\$.scope') = 'today' "
      "AND day > COALESCE((SELECT MAX(day) FROM todo_history WHERE uid = ?1 AND ("
      "json_extract(snapshot, '\$.scope') != 'today' OR "
      "json_extract(snapshot, '\$.due_time') IS NOT ?2 OR "
      "json_extract(snapshot, '\$.reminders') IS NOT ?3)), '')",
      [r['uid'], r['due_time'], r['reminders']],
    ).first['day'];
    final day = DateTime.tryParse(first as String? ?? '');
    return day == null || day.isAfter(today) ? today : day;
  }

  /// Rolls unfinished to-dos from earlier days' 'tomorrow' list into today's
  /// 'today' list.
  int rollTomorrowToToday(String todayPeriod) {
    return transaction(() {
      final rows = _db.select('SELECT * FROM todos WHERE scope = ? AND done = 0 AND period < ?', [
        TodoScope.tomorrow.name,
        todayPeriod,
      ]);
      _db.execute(
        'UPDATE todos SET scope = ?, period = ? '
        'WHERE scope = ? AND done = 0 AND period < ?',
        [TodoScope.today.name, todayPeriod, TodoScope.tomorrow.name, todayPeriod],
      );
      final changed = _db.updatedRows;
      final now = _byIds([for (final r in rows) r['id'] as int]);
      for (final r in rows) {
        // The task belongs to Today from the next calendar day, even if the
        // application was closed for several days.
        final updated = [now[r['id']]!];
        if (DateTime.tryParse(r['period'] as String) case final previous?) {
          _recordTodos(updated, DateTime(previous.year, previous.month, previous.day + 1));
        }
        _recordTodos(updated, DateTime.parse(todayPeriod));
      }
      return changed;
    });
  }

  /// Moves unfinished to-dos from earlier periods into [period]. Returns how
  /// many moved.
  ///
  /// Also brings back any from later periods, uncounted: those were carried
  /// ahead before the clock went back (travelling west over midnight), and
  /// would otherwise vanish until the date caught up.
  int carryForward(TodoScope scope, String period, {DateTime? day}) {
    return transaction(() {
      final ids = _db.select('SELECT id FROM todos WHERE scope = ? AND done = 0 AND period != ?', [scope.name, period]);
      _db.execute(
        'UPDATE todos SET carried = carried + (period < ?), period = ? '
        'WHERE scope = ? AND done = 0 AND period != ?',
        [period, period, scope.name, period],
      );
      final changed = _db.updatedRows;
      _recordTodos(_byIds([for (final r in ids) r['id'] as int]).values.toList(), day ?? _today);
      return changed;
    });
  }

  TodoItem addTodo(TodoScope scope, DateTime day, String text, {bool done = false}) {
    return transaction(() {
      _db.execute(
        'INSERT INTO todos (uid, scope, period, text, done, since, done_at) VALUES (lower(hex(randomblob(8))), ?, ?, ?, ?, ?, ?)',
        [scope.name, scope.period(day), text, done ? 1 : 0, dateKey(day), done ? _tickTime() : null],
      );
      final id = _db.lastInsertRowId;
      _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [id]), day);
      return _todo(_db.select('SELECT * FROM todos WHERE id = ?', [id]).single);
    });
  }

  Set<TodoScope> setTodoDone(int id, bool done, {DateTime? day, bool cascade = true}) {
    final touched = <TodoScope>{};
    transaction(() {
      final rows = _db.select('SELECT * FROM todos WHERE id = ?', [id]);
      if (rows.isEmpty) return;
      final snapshot = Map<String, dynamic>.from(rows.single);
      touched.add(TodoScope.values.byName(snapshot['scope'] as String));
      _toggleTodoSnapshot(snapshot, done, day ?? _today);
      touched.add(TodoScope.values.byName(snapshot['scope'] as String));
      if (cascade) {
        snapshot['subtasks'] = TodoSubtask.encode([
          for (final child in TodoSubtask.decode(snapshot['subtasks'] as String?)) child.copyWith(done: done),
        ]);
      }
      _db.execute(
        'UPDATE todos SET done = ?, done_at = ?, scope = ?, period = ?, return_scope = ?, return_to_tomorrow = ?, defer_promotion_day = ?, subtasks = ? WHERE id = ?',
        [
          snapshot['done'],
          snapshot['done_at'],
          snapshot['scope'],
          snapshot['period'],
          snapshot['return_scope'],
          snapshot['return_to_tomorrow'],
          snapshot['defer_promotion_day'],
          snapshot['subtasks'],
          id,
        ],
      );
      _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [id]), day ?? _today);
    });
    return touched;
  }

  /// Gives [item] the checklist [children] on [day]. On a day before [today]
  /// it reaches the live task too, unless that was finished or reopened since
  /// and so keeps its own.
  void setTodoSubtasks(
    TodoScope scope,
    TodoItem item,
    List<TodoSubtask> children,
    DateTime day, {
    required DateTime today,
  }) {
    transaction(() => _setTodoSubtasks(scope, item, children, day, today: today));
  }

  void _setTodoSubtasks(
    TodoScope scope,
    TodoItem item,
    List<TodoSubtask> children,
    DateTime day, {
    required DateTime today,
  }) {
    final encoded = TodoSubtask.encode(children);
    final done = children.isEmpty ? item.done : children.every((child) => child.done);
    if (day == today) {
      _db.execute('UPDATE todos SET subtasks = ? WHERE id = ?', [encoded, item.id]);
      setTodoDone(item.id, done, day: day, cascade: false);
    } else if (done != item.done) {
      setPastTodoDone(scope, day, item, done, today, subtasks: encoded);
    } else {
      _editPastTodo(scope, day, item: item, subtasks: encoded, done: done);
      _db.execute('UPDATE todos SET subtasks = ? WHERE uid = ? AND done = ?', [encoded, item.uid, done ? 1 : 0]);
      if (_db.updatedRows > 0) _recordTodos(_db.select('SELECT * FROM todos WHERE uid = ?', [item.uid]), today);
    }
  }

  /// Convert a standalone task into a checklist entry in one transaction.
  void nestTodo(TodoScope scope, TodoItem source, TodoItem target, DateTime day) {
    transaction(() {
      _setTodoSubtasks(
        scope,
        target,
        [...target.subtasks, TodoSubtask(source.text, done: source.done, numbered: target.numbered, note: source.note)],
        day,
        today: day,
      );
      deleteTodo(source.id, day: day);
    });
  }

  /// Gives [item] the note [note], or none for a blank one. The note goes
  /// with the task wherever it's kept: on a day before [today] it's that
  /// day's record and the live task both.
  Set<TodoScope> setTodoNote(TodoScope scope, TodoItem item, String? note, DateTime day, {required DateTime today}) {
    final value = cleanNote(note);
    final touched = <TodoScope>{scope};
    transaction(() {
      if (day != today) _editPastTodo(scope, day, item: item, note: (value: value));
      final (column, key) = item.uid == null ? ('id', item.id as Object) : ('uid', item.uid as Object);
      _db.execute('UPDATE todos SET note = ? WHERE $column = ?', [value, key]);
      if (_db.updatedRows > 0) {
        final updated = _db.select('SELECT * FROM todos WHERE $column = ?', [key]);
        _recordTodos(updated, today);
        for (final r in updated) {
          touched.add(TodoScope.values.byName(r['scope'] as String));
        }
      }
    });
    return touched;
  }

  /// [ids], open tasks of one day's list, in the order they were dragged
  /// into. Only those whose place changed are written.
  void setTodoPositions(List<int> ids, DateTime day) {
    transaction(() {
      final moved = <int>[];
      for (final (i, id) in ids.indexed) {
        _db.execute('UPDATE todos SET position = ? WHERE id = ? AND done = 0 AND position IS NOT ?', [i, id, i]);
        if (_db.updatedRows > 0) moved.add(id);
      }
      _recordTodos(_byIds(moved).values.toList(), day);
    });
  }

  /// A manual move keeps identity/history and clears all automatic routing,
  /// and its place among its old day's tasks: it goes after those put in
  /// order on its new day.
  /// [due]: the day it's now due, for This week or This month.
  void moveTodo(int id, TodoScope destination, DateTime day, {DateTime? due}) {
    transaction(() {
      _db.execute(
        'UPDATE todos SET scope = ?, period = ?, due_date = ?, position = NULL, '
        'return_scope = NULL, return_to_tomorrow = 0, defer_promotion_day = NULL '
        'WHERE id = ? AND done = 0',
        [destination.name, destination.period(day), due == null ? null : dateKey(due), id],
      );
      if (_db.updatedRows > 0) {
        _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [id]), day);
      }
    });
  }

  /// Adds a task to [day]'s Tomorrow list while also rolling it into
  /// [today]'s live Today list (used when adding under "Today" while viewing Yesterday).
  TodoItem addPastTomorrowTodo(
    DateTime day,
    DateTime today,
    String text, {
    DateTime? dueDate,
    int? time,
    bool birthday = false,
    int reminders = 0,
    String? location,
  }) => transaction(() {
    _db.execute(
      'INSERT INTO todos (uid, scope, period, text, done, since, due_date, due_time, category, reminders, location) '
      'VALUES (lower(hex(randomblob(8))), ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)',
      [
        TodoScope.tomorrow.name,
        dateKey(day),
        text,
        dateKey(day),
        dueDate == null ? null : dateKey(dueDate),
        time == null ? null : clockKey(time),
        birthdayKind(birthday),
        _stored(reminders),
        _place(location),
      ],
    );
    final id = _db.lastInsertRowId;
    _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [id]), day);
    _db.execute('UPDATE todos SET scope = ?, period = ? WHERE id = ?', [
      TodoScope.today.name,
      dateKey(today),
      id,
    ]);
    final row = _db.select('SELECT * FROM todos WHERE id = ?', [id]).single;
    _recordTodos([row], today);
    return _todo(row);
  });

  void deleteTodo(int id, {DateTime? day, bool paused = false}) {
    transaction(() {
      _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [id]), day ?? _today, deleted: true, paused: paused);
      _db.execute('DELETE FROM todos WHERE id = ?', [id]);
    });
  }

  void editTodo(
    int id,
    String text,
    DateTime? dueDate,
    DateTime day, {
    int? time,
    bool birthday = false,
    int reminders = 0,
    String? location,
  }) {
    transaction(() {
      _db.execute(
        // On a new day, it goes after those put in order there.
        'UPDATE todos SET text = ?1, due_date = ?2, due_time = ?3, category = ?4, defer_promotion_day = NULL, '
        'position = CASE WHEN due_date IS ?2 THEN position END, reminders = ?6, location = ?7 WHERE id = ?5',
        [
          text,
          dueDate == null ? null : dateKey(dueDate),
          time == null ? null : clockKey(time),
          birthdayKind(birthday),
          id,
          _stored(reminders),
          _place(location),
        ],
      );
      _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [id]), day);
    });
  }

  /// Promote scheduled tasks on calendar dates, including days spent closed.
  void promoteDueTodos(DateTime today, {DateTime? earliest}) {
    transaction(() {
      // This month hands a task to This week once it's due within 7 days.
      final weekAhead = DateTime(today.year, today.month, today.day + 7);
      final monthRows = _db.select(
        "SELECT * FROM todos WHERE scope = 'month' AND done = 0 AND due_date <= ? "
        "AND (defer_promotion_day IS NULL OR defer_promotion_day != ?)",
        [dateKey(weekAhead), dateKey(today)],
      );
      for (final r in monthRows) {
        final due = DateTime.tryParse(r['due_date'] as String);
        if (due == null) continue;
        final enters = _promotionDay(r, DateTime(due.year, due.month, due.day - 7), earliest);
        // A task already due tomorrow goes straight to Tomorrow below.
        if (enters.isBefore(DateTime(due.year, due.month, due.day - 1))) {
          _db.execute('UPDATE todos SET scope = ?, period = ? WHERE id = ?', [
            TodoScope.week.name,
            TodoScope.week.period(enters),
            r['id'],
          ]);
          _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [r['id']]), enters);
        }
      }
      final tomorrow = DateTime(today.year, today.month, today.day + 1);
      final rows = _db.select(
        "SELECT * FROM todos WHERE scope IN ('week', 'month') AND done = 0 AND due_date <= ? "
        "AND (defer_promotion_day IS NULL OR defer_promotion_day != ?)",
        [dateKey(tomorrow), dateKey(today)],
      );
      for (final r in rows) {
        final due = DateTime.tryParse(r['due_date'] as String);
        if (due == null) continue;
        final enters = _promotionDay(r, DateTime(due.year, due.month, due.day - 1), earliest);
        if (enters.isBefore(due)) {
          _db.execute('UPDATE todos SET scope = ?, period = ? WHERE id = ?', [
            TodoScope.tomorrow.name,
            dateKey(enters),
            r['id'],
          ]);
          _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [r['id']]), enters);
        }
        if (!due.isAfter(today)) {
          final firstToday = due.isBefore(enters) ? enters : due;
          _db.execute('UPDATE todos SET scope = ?, period = ? WHERE id = ?', [
            TodoScope.today.name,
            dateKey(today),
            r['id'],
          ]);
          final updated = _db.select('SELECT * FROM todos WHERE id = ?', [r['id']]);
          _recordTodos(updated, firstToday);
          _recordTodos(updated, today);
        }
      }
    });
  }

  /// The day a task reaches its next list: [ready], but never before it was
  /// added, while it's held back after an untick, or before [earliest].
  DateTime _promotionDay(Row r, DateTime ready, DateTime? earliest) {
    final since = DateTime.parse(r['since'] as String);
    var enters = ready.isBefore(since) ? since : ready;
    final deferred = DateTime.tryParse(r['defer_promotion_day'] as String? ?? '');
    if (deferred != null) {
      final resumes = DateTime(deferred.year, deferred.month, deferred.day + 1);
      if (enters.isBefore(resumes)) enters = resumes;
    }
    if (earliest != null && enters.isBefore(earliest)) enters = earliest;
    return enters;
  }

  /// The bounds of the uids of repeat [uid]'s times, from [from] on when
  /// given: `uid@day` sorts after `uid@` and before `uidA`, so a
  /// lookup by them uses each table's index on uid.
  static List<String> occurrenceRange(String uid, {DateTime? from}) => [
    '$uid@${from == null ? '' : dateKey(from)}',
    '${uid}A',
  ];

  /// Where [makeRepeats] has got to with each repeat, on this computer
  /// only: by uid, the repeat's start, rule and end as it was walked, and
  /// the last day walked. A repeat changed since is walked from its start
  /// again.
  static const walkedSetting = 'repeatsWalked';

  /// The holidays [makeRepeats] last looked at, on this computer only.
  static const walkedHolidaysSetting = 'repeatsWalkedHolidays';

  /// Times a holiday took away here, by uid, to bring back if it's removed.
  static const pausedTimesSetting = 'repeatsPausedTimes';

  /// Whether a holiday pauses [repeat] on [day]: every repeat but birthdays.
  static bool pausedOn(Repeat repeat, DateTime day, List<Holiday> holidays) =>
      !repeat.birthday && holidayOn(holidays, day) != null;


  /// The days [makeRepeats] has looked at, for tests: each later call looks
  /// only at the days after those it looked at before.
  static int debugRepeatDaysWalked = 0;

  /// Tasks from before every task had a day: anything open in This week or
  /// This month without a due date goes to Today.
  void dateUndatedTodos(DateTime today) {
    for (final r in _db.select(
      "SELECT id FROM todos WHERE scope IN ('week', 'month') AND done = 0 AND due_date IS NULL",
    )) {
      moveTodo(r['id'] as int, TodoScope.today, today);
    }
  }
}

TodoItem _todo(Row r) => TodoItem(
  r['id'] as int,
  curlyQuotes(r['text'] as String),
  since: DateTime.parse(r['since'] as String),
  done: r['done'] == 1,
  carried: r['carried'] as int,
  uid: r['uid'] as String,
  dueDate: DateTime.tryParse(r['due_date'] as String? ?? ''),
  dueTime: parseClock(r['due_time'] as String? ?? ''),
  birthday: isBirthday(r['category']),
  doneAt: DateTime.tryParse(r['done_at'] as String? ?? ''),
  subtasks: TodoSubtask.decode(r['subtasks'] as String?),
  position: _position(r['position']),
  reminders: _bits(r['reminders']),
  location: _place(r['location']),
  note: cleanNote(r['note']),
);
/// A stored set of reminders, or none for anything else.
int _bits(Object? value) => value is int ? value & 31 : 0;

/// A stored place among a day's tasks, or none for anything else.
int? _position(Object? value) => value is int ? value : null;

/// How [reminders] are kept: null for none, as before there were any.
int? _stored(int reminders) => reminders == 0 ? null : reminders;

/// A stored location, or none for a blank or anything else.
String? _place(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

String _tickTime() => DateTime.now().toUtc().toIso8601String();
