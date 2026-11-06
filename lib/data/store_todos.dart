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

  /// The lists as they stood on [day]: everything added by then and still
  /// open that day. An item ticked off later shows unticked, as it was.
  Map<TodoScope, List<TodoItem>> todoListsOn(DateTime day) {
    final key = dateKey(day);
    // Every task ever has a latest snapshot by then, nearly all of them
    // ticked or taken away long before: those are left out here, so only
    // the few that can be on the day's lists are read (the checks below
    // still decide).
    final snapshots = _db.select(
      '''
      WITH latest AS (
        SELECT uid, MAX(day) AS day FROM todo_history WHERE day <= ?1 GROUP BY uid
      )
      SELECT h.rowid AS history_id, h.uid, h.snapshot, t.id,
        CASE WHEN t.done = 1 AND t.scope = 'today' THEN t.period END AS ticked
      FROM latest l
      JOIN todo_history h ON h.uid = l.uid AND h.day = l.day
      LEFT JOIN todos t ON t.uid = h.uid
      WHERE NOT (t.done IS 1 AND t.scope IS 'today' AND t.period < ?1)
        AND (t.done IS 1 AND t.scope IS 'today' AND t.period = ?1
          OR json_extract(h.snapshot, '\$.deleted') IS NOT 1
            AND json_extract(h.snapshot, '\$.since') <= ?1
            AND NOT (json_extract(h.snapshot, '\$.done') IS 1
              AND json_extract(h.snapshot, '\$.period') IS NOT CASE json_extract(h.snapshot, '\$.scope')
                WHEN 'week' THEN ?2 WHEN 'month' THEN ?3 ELSE ?1 END))
      ORDER BY COALESCE(t.id, h.rowid)
    ''',
      [key, TodoScope.week.period(day), TodoScope.month.period(day)],
    );
    final lists = {for (final scope in TodoScope.values) scope: <TodoItem>[]};
    // Only legacy tasks without a snapshot need the old approximation.
    for (final r in _db.select(
      '''
      SELECT * FROM todos t WHERE since <= ? AND NOT EXISTS (
        SELECT 1 FROM todo_history h WHERE h.uid = t.uid AND h.day <= ?
      ) ORDER BY id
    ''',
      [key, key],
    )) {
      final scope = TodoScope.values.byName(r['scope'] as String);
      final period = scope.period(day);
      if ((r['period'] as String).compareTo(period) >= 0) {
        lists[scope]!.add(_todo(r)..done = r['done'] == 1 && r['period'] == period);
      }
    }
    for (final r in snapshots) {
      final s = jsonDecode(r['snapshot'] as String) as Map<String, dynamic>;
      // Ticked, and still: done on the day it was ticked (unless taken off
      // that day's record) and open on none after, whatever another
      // computer that hadn't heard of the tick wrote for those days.
      if (r['ticked'] case final String ticked when ticked.compareTo(key) <= 0) {
        if (ticked != key) continue;
        s
          ..['scope'] = TodoScope.today.name
          ..['period'] = key
          ..['done'] = 1;
      }
      final scope = TodoScope.values.byName(s['scope'] as String);
      if (s['deleted'] == true ||
          (s['since'] as String).compareTo(key) > 0 ||
          (s['done'] == 1 && s['period'] != scope.period(day))) {
        continue;
      }
      lists[scope]!.add(
        TodoItem(
          r['id'] as int? ?? -(r['history_id'] as int),
          curlyQuotes(s['text'] as String),
          since: DateTime.parse(s['since'] as String),
          done: s['done'] == 1,
          carried: s['carried'] as int,
          uid: r['uid'] as String,
          dueDate: DateTime.tryParse(s['due_date'] as String? ?? ''),
          dueTime: parseClock(s['due_time'] as String? ?? ''),
          birthday: isBirthday(s['category']),
          doneAt: DateTime.tryParse(s['done_at'] as String? ?? ''),
          subtasks: TodoSubtask.decode(s['subtasks'] as String?),
          position: _position(s['position']),
          reminders: _bits(s['reminders']),
          location: _place(s['location']),
        ),
      );
    }
    return lists;
  }

  DateTime get _today => dayOf(DateTime.now(), int.tryParse(setting('dayStartHour') ?? '') ?? 0);

  /// Establish the first known daily state for tasks from older versions.
  /// Once a task has history, its last snapshot already covers unchanged days.
  void captureTodoBaseline(DateTime day) => _recordTodos(
    _db.select('SELECT * FROM todos t WHERE NOT EXISTS (SELECT 1 FROM todo_history h WHERE h.uid = t.uid)'),
    day,
  );

  void _recordTodos(List<Row> rows, DateTime day, {bool deleted = false}) {
    if (rows.isEmpty) return;
    final statement = _db.prepare(
      'INSERT INTO todo_history (uid, day, snapshot) VALUES (?, ?, ?) '
      'ON CONFLICT (uid, day) DO UPDATE SET snapshot = excluded.snapshot',
    );
    try {
      for (final r in rows) {
        final snapshot = jsonEncode({
          for (final key in [
            'scope',
            'period',
            'text',
            'done',
            'carried',
            'since',
            'due_date',
            'return_to_tomorrow',
            'return_scope',
            'defer_promotion_day',
            'subtasks',
            'done_at',
            'due_time',
            'category',
            'position',
            'reminders',
            'location',
          ])
            key: r[key],
          'deleted': deleted,
        });
        statement.execute([r['uid'], dateKey(day), snapshot]);
      }
    } finally {
      statement.close();
    }
  }

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

  static TodoItem _todo(Row r) => TodoItem(
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
  );

  /// Open tasks that give reminders, each with the day it's on: its due
  /// day, or, in Tomorrow without one, tomorrow; in Today without one, the
  /// day it came into Today. A task carried on from an earlier day is still
  /// on that day, as one with a due date is, so its time doesn't remind again.
  List<(TodoItem, DateTime)> remindingTodos(DateTime today) => [
    for (final r in _db.select('SELECT * FROM todos WHERE done = 0 AND reminders > 0'))
      if (DateTime.tryParse(r['due_date'] as String? ?? '') ??
              switch (r['scope']) {
                'today' => _inTodaySince(r['uid'] as String, today),
                'tomorrow' => DateTime(today.year, today.month, today.day + 1),
                _ => null,
              }
          case final day?)
        (_todo(r), day),
  ];

  /// The first day of the stay in Today that [uid] is on now: the day after
  /// the last its record shows it in another list, or its first record.
  DateTime _inTodaySince(String uid, DateTime today) {
    final first = _db.select(
      "SELECT MIN(day) AS day FROM todo_history WHERE uid = ?1 AND json_extract(snapshot, '\$.scope') = 'today' "
      "AND day > COALESCE((SELECT MAX(day) FROM todo_history WHERE uid = ?1 AND json_extract(snapshot, '\$.scope') != 'today'), '')",
      [uid],
    ).first['day'];
    final day = DateTime.tryParse(first as String? ?? '');
    return day == null || day.isAfter(today) ? today : day;
  }

  /// A stored set of reminders, or none for anything else.
  static int _bits(Object? value) => value is int ? value & 15 : 0;

  /// A stored place among a day's tasks, or none for anything else.
  static int? _position(Object? value) => value is int ? value : null;

  /// How [reminders] are kept: null for none, as before there were any.
  static int? _stored(int reminders) => reminders == 0 ? null : reminders;

  /// A stored location, or none for a blank or anything else.
  static String? _place(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

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

  void setTodoDone(int id, bool done, {DateTime? day, bool cascade = true}) {
    transaction(() {
      final rows = _db.select('SELECT * FROM todos WHERE id = ?', [id]);
      if (rows.isEmpty) return;
      final snapshot = Map<String, dynamic>.from(rows.single);
      _toggleTodoSnapshot(snapshot, done, day ?? _today);
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
        [...target.subtasks, TodoSubtask(source.text, done: source.done, numbered: target.numbered)],
        day,
        today: day,
      );
      deleteTodo(source.id, day: day);
    });
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

  void deleteTodo(int id, {DateTime? day}) {
    transaction(() {
      _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [id]), day ?? _today, deleted: true);
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

  /// Correct a completion and keep the live task in the appropriate period.
  /// Deleted tasks remain deleted; editing their history must not restore them.
  void setPastTodoDone(TodoScope scope, DateTime day, TodoItem item, bool done, DateTime today, {String? subtasks}) {
    transaction(() {
      _editPastTodo(scope, day, item: item, subtasks: subtasks, done: done);
      final snapshot = jsonDecode(
        _db.select('SELECT snapshot FROM todo_history WHERE uid = ? AND day = ?', [
              item.uid,
              dateKey(day),
            ]).single['snapshot']
            as String,
      ) as Map<String, dynamic>;
      final historicalScope = TodoScope.values.byName(snapshot['scope'] as String);
      final liveScope = !done && historicalScope == TodoScope.tomorrow ? TodoScope.today : historicalScope;
      _db.execute(
        'UPDATE todos SET done = ?, done_at = ?, scope = ?, period = ?, return_to_tomorrow = ?, return_scope = ?, defer_promotion_day = ?, subtasks = ? WHERE uid = ?',
        [
          done ? 1 : 0,
          snapshot['done_at'],
          liveScope.name,
          liveScope.period(done ? day : today),
          snapshot['return_to_tomorrow'] ?? 0,
          snapshot['return_scope'],
          !done && (historicalScope == TodoScope.week || historicalScope == TodoScope.month) ? dateKey(today) : null,
          snapshot['subtasks'] ?? '[]',
          item.uid,
        ],
      );
      _recordTodos(_db.select('SELECT * FROM todos WHERE uid = ?', [item.uid]), today);
      if (!done) {
        promoteDueTodos(today, earliest: today);
        rollTomorrowToToday(dateKey(today));
      }
    });
  }

  /// Correct only this day's snapshot. Preserve the next day's original
  /// record so an edit never leaks forward into later records or live tasks.
  void editPastTodo(
    TodoScope scope,
    DateTime day, {
    TodoItem? item,
    String? text,
    bool? done,
    DateTime? dueDate,
    int? time,
    bool birthday = false,
    int reminders = 0,
    String? location,
    bool deleted = false,
  }) {
    transaction(
      () => _editPastTodo(
        scope,
        day,
        item: item,
        text: text,
        done: done,
        dueDate: dueDate,
        time: time,
        birthday: birthday,
        reminders: reminders,
        location: location,
        deleted: deleted,
      ),
    );
  }

  void _editPastTodo(
    TodoScope scope,
    DateTime day, {
    TodoItem? item,
    String? text,
    String? subtasks,
    bool? done,
    DateTime? dueDate,
    int? time,
    bool birthday = false,
    int reminders = 0,
    String? location,
    bool deleted = false,
  }) {
    final uid = item?.uid ?? _db.select('SELECT lower(hex(randomblob(8))) AS uid').single['uid'] as String;
    final key = dateKey(day);
    final next = dateKey(DateTime(day.year, day.month, day.day + 1));
    final previous = _db.select(
      'SELECT snapshot FROM todo_history WHERE uid = ? AND day <= ? ORDER BY day DESC LIMIT 1',
      [uid, key],
    );
    final snapshot = previous.isEmpty
        ? <String, dynamic>{
            'scope': scope.name,
            'period': scope.period(day),
            'text': item?.text ?? text ?? '',
            'done': item?.done == true ? 1 : 0,
            'since': dateKey(item?.since ?? day),
            'carried': item?.carried ?? 0,
            'due_date': null,
            'deleted': item == null,
          }
        : jsonDecode(previous.single['snapshot'] as String) as Map<String, dynamic>;
    final following = _db.select('SELECT 1 FROM todo_history WHERE uid = ? AND day = ?', [uid, next]);
    if (following.isEmpty) {
      // Filled in, not an edit: one made to that day on another computer
      // wins over it.
      weak(() => _db.execute('INSERT INTO todo_history VALUES (?, ?, ?)', [uid, next, jsonEncode(snapshot)]));
    }
    snapshot['deleted'] = deleted;
    if (text != null) {
      snapshot['text'] = text;
      snapshot['due_date'] = dueDate == null ? null : dateKey(dueDate);
      snapshot['due_time'] = time == null ? null : clockKey(time);
      snapshot['category'] = birthdayKind(birthday);
      snapshot['reminders'] = _stored(reminders);
      snapshot['location'] = _place(location);
    }
    if (subtasks != null) snapshot['subtasks'] = subtasks;
    if (done != null) {
      _toggleTodoSnapshot(snapshot, done, day);
      // Ticked, it's on that day's list: the day before's record may have
      // it on the day it was carried from.
      if (done) snapshot['period'] = TodoScope.values.byName(snapshot['scope'] as String).period(day);
      if (subtasks == null) {
        snapshot['subtasks'] = TodoSubtask.encode([
          for (final child in TodoSubtask.decode(snapshot['subtasks'] as String?)) child.copyWith(done: done),
        ]);
      }
    }
    _db.execute(
      'INSERT INTO todo_history VALUES (?, ?, ?) '
      'ON CONFLICT (uid, day) DO UPDATE SET snapshot = excluded.snapshot',
      [uid, key, jsonEncode(snapshot)],
    );
  }

  /// Move completed plans into the day's record, retaining their undo destination.
  static void _toggleTodoSnapshot(Map<String, dynamic> snapshot, bool done, DateTime day) {
    final scope = TodoScope.values.byName(snapshot['scope'] as String);
    final returnScope =
        snapshot['return_scope'] ?? (snapshot['return_to_tomorrow'] == 1 ? TodoScope.tomorrow.name : null);
    snapshot['defer_promotion_day'] = null;
    if (done && scope != TodoScope.today) {
      snapshot['return_scope'] = scope.name;
      snapshot['scope'] = TodoScope.today.name;
      snapshot['period'] = dateKey(day);
    } else if (!done && returnScope != null) {
      final restored = TodoScope.values.byName(returnScope as String);
      snapshot['scope'] = restored.name;
      snapshot['period'] = restored.period(day);
      snapshot['return_scope'] = null;
      if (restored == TodoScope.week || restored == TodoScope.month) {
        snapshot['defer_promotion_day'] = dateKey(day);
      }
    }
    snapshot['return_to_tomorrow'] = snapshot['return_scope'] == TodoScope.tomorrow.name ? 1 : 0;
    // A ticked item that stays ticked (a checklist step changed) keeps its
    // place among the ticked ones.
    if (!done) {
      snapshot['done_at'] = null;
    } else if (snapshot['done'] != 1) {
      snapshot['done_at'] = _tickTime();
    }
    snapshot['done'] = done ? 1 : 0;
  }

  static String _tickTime() => DateTime.now().toUtc().toIso8601String();

  // Repeating tasks

  List<Repeat> repeats() => [
    for (final r in _db.select('SELECT * FROM todo_repeats ORDER BY start, uid'))
      if (RepeatRule.decode(r['rule'] as String) case final rule?)
        Repeat(
          uid: r['uid'] as String,
          text: curlyQuotes(r['text'] as String),
          rule: rule,
          start: DateTime.parse(r['start'] as String),
          until: DateTime.tryParse(r['until'] as String? ?? ''),
          time: parseClock(r['time'] as String? ?? ''),
          birthday: isBirthday(r['category']),
          reminders: _bits(r['reminders']),
          location: _place(r['location']),
          subtasks: TodoSubtask.decode(r['subtasks'] as String?),
        ),
  ];

  Repeat addRepeat(
    String text,
    RepeatRule rule,
    DateTime start, {
    DateTime? until,
    int? time,
    bool birthday = false,
    int reminders = 0,
    String? location,
    List<TodoSubtask> subtasks = const [],
  }) {
    final repeat = Repeat(
      uid: _newUid(),
      text: text,
      rule: rule,
      start: dateOnly(start),
      until: until,
      time: time,
      birthday: birthday,
      reminders: reminders,
      location: _place(location),
      subtasks: _unticked(subtasks),
    );
    saveRepeat(repeat);
    return repeat;
  }

  void saveRepeat(Repeat r) => _db.execute(
    'INSERT INTO todo_repeats (uid, text, rule, start, until, time, category, reminders, subtasks, location) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
    'ON CONFLICT (uid) DO UPDATE SET text = excluded.text, rule = excluded.rule, start = excluded.start, '
    'until = excluded.until, time = excluded.time, category = excluded.category, reminders = excluded.reminders, '
    'subtasks = excluded.subtasks, location = excluded.location',
    [
      r.uid,
      r.text,
      r.rule.encode(),
      dateKey(r.start),
      r.until == null ? null : dateKey(r.until!),
      r.time == null ? null : clockKey(r.time!),
      birthdayKind(r.birthday),
      _stored(r.reminders),
      r.subtasks.isEmpty ? null : TodoSubtask.encode(r.subtasks),
      r.location,
    ],
  );

  static List<TodoSubtask> _unticked(List<TodoSubtask> children) => [
    for (final child in children) child.copyWith(done: false),
  ];

  /// Gives repeat [uid] the checklist [children], unticked, and the open
  /// to-dos it has made for after [from] too; a step they already had keeps
  /// its tick.
  void setRepeatSubtasks(String uid, List<TodoSubtask> children, DateTime from, DateTime today) {
    final template = _unticked(children);
    transaction(() {
      _db.execute('UPDATE todo_repeats SET subtasks = ? WHERE uid = ?', [
        template.isEmpty ? null : TodoSubtask.encode(template),
        uid,
      ]);
      for (final r in _openOccurrences(uid, DateTime(from.year, from.month, from.day + 1))) {
        final had = {
          for (final child in TodoSubtask.decode(r['subtasks'] as String?))
            if (child.done) child.text,
        };
        final next = [for (final child in template) child.copyWith(done: had.contains(child.text))];
        _db.execute('UPDATE todos SET subtasks = ? WHERE id = ?', [TodoSubtask.encode(next), r['id']]);
        _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [r['id']]), today);
      }
    });
  }

  /// The open to-dos of repeat [uid] for [from] on.
  List<Row> _openOccurrences(String uid, DateTime from) =>
      _db.select('SELECT * FROM todos WHERE uid >= ? AND uid < ? AND done = 0', occurrenceRange(uid, from: from));

  /// The bounds of the uids of repeat [uid]'s times, from [from] on when
  /// given: `uid@day` sorts after `uid@` and before `uidA`, so a
  /// lookup by them uses each table's index on uid.
  static List<String> occurrenceRange(String uid, {DateTime? from}) => [
    '$uid@${from == null ? '' : dateKey(from)}',
    '${uid}A',
  ];

  /// Stops repeat [uid] coming round from [from] on, and takes away the
  /// open to-dos it had made for then.
  void endRepeat(String uid, DateTime from, DateTime today) {
    transaction(() {
      final rows = _db.select('SELECT start FROM todo_repeats WHERE uid = ?', [uid]);
      if (rows.isEmpty) return;
      if (DateTime.parse(rows.single['start'] as String).isBefore(from)) {
        _db.execute('UPDATE todo_repeats SET until = ? WHERE uid = ?', [
          dateKey(DateTime(from.year, from.month, from.day - 1)),
          uid,
        ]);
      } else {
        _db.execute('DELETE FROM todo_repeats WHERE uid = ?', [uid]);
      }
      for (final r in _openOccurrences(uid, from)) {
        deleteTodo(r['id'] as int, day: today);
      }
    });
  }

  /// Renames repeat [uid], and the open to-dos it has made for [from] on,
  /// and gives them its [time], whether it's a [birthday], its
  /// [reminders] and its [location].
  void renameRepeat(
    String uid,
    String text,
    DateTime from,
    DateTime today, {
    int? time,
    bool birthday = false,
    int reminders = 0,
    String? location,
  }) {
    final (clock, kind, bits, place) = (
      time == null ? null : clockKey(time),
      birthdayKind(birthday),
      _stored(reminders),
      _place(location),
    );
    transaction(() {
      _db.execute(
        'UPDATE todo_repeats SET text = ?, time = ?, category = ?, reminders = ?, location = ? WHERE uid = ?',
        [text, clock, kind, bits, place, uid],
      );
      for (final r in _openOccurrences(uid, from)) {
        _db.execute('UPDATE todos SET text = ?, due_time = ?, category = ?, reminders = ?, location = ? WHERE id = ?', [
          text,
          clock,
          kind,
          bits,
          place,
          r['id'],
        ]);
        _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [r['id']]), today);
      }
    });
  }

  /// The uids of every to-do repeat [uid] has made, here or (taken away
  /// since) on another computer; with [from], only those for then on.
  Set<String> madeOccurrences(String uid, {DateTime? from}) => {
    for (final r in _db.select(
      'SELECT uid FROM todos WHERE uid >= ?1 AND uid < ?2 '
      'UNION SELECT uid FROM todo_history WHERE uid >= ?1 AND uid < ?2 '
      "UNION SELECT rowkey FROM sync_reg WHERE kind = 'todo' AND rowkey >= ?1 AND rowkey < ?2",
      occurrenceRange(uid, from: from),
    ))
      r.columnAt(0) as String,
  };

  /// [madeOccurrences] for every repeat at once, from [from] on, by repeat
  /// uid: one statement, each repeat still looked up by its index.
  Map<String, Set<String>> madeOccurrencesFrom(DateTime from) {
    final made = <String, Set<String>>{};
    for (final r in _db.select(
      '''
      SELECT r.uid AS repeat, t.uid FROM todo_repeats r
        JOIN todos t ON t.uid >= r.uid || '@' || ?1 AND t.uid < r.uid || 'A'
      UNION SELECT r.uid, h.uid FROM todo_repeats r
        JOIN todo_history h ON h.uid >= r.uid || '@' || ?1 AND h.uid < r.uid || 'A'
      UNION SELECT r.uid, s.rowkey FROM todo_repeats r
        JOIN sync_reg s ON s.kind = 'todo' AND s.rowkey >= r.uid || '@' || ?1 AND s.rowkey < r.uid || 'A'
    ''',
      [dateKey(from)],
    )) {
      (made[r['repeat'] as String] ??= {}).add(r['uid'] as String);
    }
    return made;
  }

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

  /// After you change the holidays: takes away the open times they now
  /// cover, and brings back from [today] on those they took away and no
  /// longer cover. Your own edits, so sync sends them as any others.
  void applyHolidays(DateTime today) => transaction(() {
    final holidays = decodeHolidays(setting('holidays'));
    final byUid = {for (final repeat in repeats()) repeat.uid: repeat};
    final paused = switch (_decodeJson(setting(pausedTimesSetting))) {
      final List<dynamic> l => l.whereType<String>().toSet(),
      _ => <String>{},
    };
    for (final uid in paused.toList()) {
      final at = uid.lastIndexOf('@');
      final repeat = at < 0 ? null : byUid[uid.substring(0, at)];
      final day = at < 0 ? null : DateTime.tryParse(uid.substring(at + 1));
      if (repeat == null || day == null || day.isBefore(today)) {
        paused.remove(uid);
      } else if (holidayOn(holidays, day) == null) {
        paused.remove(uid);
        if (_db.select('SELECT 1 FROM todos WHERE uid = ?', [uid]).isEmpty) _makeOccurrence(repeat, day);
      }
    }
    paused.addAll(_takeAwayPaused(today, holidays));
    setSetting(pausedTimesSetting, jsonEncode(paused.toList()));
  });

  /// Takes away the open times of repeats, not moved to another day, on a
  /// holiday, and says which.
  List<String> _takeAwayPaused(DateTime today, List<Holiday> holidays) {
    if (holidays.isEmpty) return const [];
    final gone = <String>[];
    for (final r in _db.select('''
      SELECT t.id, t.uid, substr(t.uid, length(p.uid) + 2) AS day FROM todo_repeats p
        JOIN todos t ON t.uid >= p.uid || '@' AND t.uid < p.uid || 'A'
      WHERE t.done = 0 AND t.category IS NOT 'birthday' AND t.due_date = substr(t.uid, length(p.uid) + 2)
    ''')) {
      final day = DateTime.tryParse(r['day'] as String);
      if (day != null && holidayOn(holidays, day) != null) {
        deleteTodo(r['id'] as int, day: today);
        gone.add(r['uid'] as String);
      }
    }
    return gone;
  }

  /// The days [makeRepeats] has looked at, for tests: each later call looks
  /// only at the days after those it looked at before.
  static int debugRepeatDaysWalked = 0;

  /// Makes the to-do for each time a repeat comes round, up to a week
  /// after [today], that hasn't been made (or made and taken away) yet.
  /// Each repeat is walked on from the last day walked before, so a repeat
  /// begun years ago costs no more than a new one; and the times of one
  /// that has ended, made by another computer that hadn't heard, go.
  ///
  /// Filled in, not edited: each computer makes the same ones, with the
  /// same uids, so they meet in sync rather than doubling up. They start in
  /// This month, by their day, and a day start moves them on from there.
  void makeRepeats(DateTime today) => weak(() {
    final last = DateTime(today.year, today.month, today.day + 7);
    final before = switch (_decodeJson(setting(walkedSetting))) {
      final Map<String, dynamic> m => m,
      _ => const <String, dynamic>{},
    };
    final walked = <String, List<String>>{};
    final all = repeats();
    final holidays = decodeHolidays(setting('holidays'));
    // Holidays changed: days they've let go of are walked again, today on.
    final holidaysMark = encodeHolidays(holidays);
    final holidaysMoved = holidaysMark != (setting(walkedHolidaysSetting) ?? encodeHolidays(const []));
    final marks = {
      for (final repeat in all)
        repeat.uid: [
          dateKey(repeat.start),
          repeat.rule.encode(),
          if (repeat.until case final until?) dateKey(until) else '',
        ],
    };
    DateTime? walkedThrough(Repeat repeat) => switch (before[repeat.uid]) {
      [final String start, final String rule, final String until, final String day]
          when start == marks[repeat.uid]![0] && rule == marks[repeat.uid]![1] && until == marks[repeat.uid]![2] =>
        DateTime.tryParse(day),
      _ => null,
    };
    // On a new day most repeats go on from the same day: their times made
    // already are read at once.
    final froms = <String, int>{};
    for (final repeat in all) {
      if (walkedThrough(repeat) case final through?) {
        final key = dateKey(DateTime(through.year, through.month, through.day + 1));
        froms[key] = (froms[key] ?? 0) + 1;
      }
    }
    final common = froms.entries.where((e) => e.value > 1).map((e) => e.key).toSet();
    final batches = <String, Map<String, Set<String>>>{};
    for (final repeat in all) {
      final mark = marks[repeat.uid]!;
      final through = walkedThrough(repeat);
      final after = through == null ? repeat.start : DateTime(through.year, through.month, through.day + 1);
      final from = holidaysMoved && through != null && after.isAfter(today) ? today : after;
      if (!from.isAfter(last)) {
        final key = dateKey(from);
        final made = !holidaysMoved && common.contains(key) && through != null
            ? batches.putIfAbsent(key, () => madeOccurrencesFrom(from))[repeat.uid] ?? const <String>{}
            : madeOccurrences(repeat.uid, from: from);
        for (
          var day = repeat.next(from);
          day != null && !day.isAfter(last);
          day = repeat.next(DateTime(day.year, day.month, day.day + 1))
        ) {
          debugRepeatDaysWalked++;
          if (!made.contains('${repeat.uid}@${dateKey(day)}') && !pausedOn(repeat, day, holidays)) {
            _makeOccurrence(repeat, day);
          }
        }
      }
      walked[repeat.uid] = [...mark, dateKey(through != null && through.isAfter(last) ? through : last)];
    }
    _takeAwayEnded(today);
    // Made on another computer before it heard of the holiday.
    _takeAwayPaused(today, holidays);
    if (holidaysMoved) setSetting(walkedHolidaysSetting, holidaysMark);
    final encoded = jsonEncode(walked);
    if (encoded != setting(walkedSetting)) setSetting(walkedSetting, encoded);
  });

  static Object? _decodeJson(String? value) {
    if (value == null) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  /// Takes away the open times of repeats that have ended before them, or
  /// been taken away altogether: made by another computer that hadn't heard
  /// yet, or made there since. A time that was ticked stays.
  void _takeAwayEnded(DateTime today) {
    for (final r in _db.select('''
      SELECT t.id FROM todo_repeats r JOIN todos t ON t.uid >= r.uid || '@' AND t.uid < r.uid || 'A'
      WHERE r.until IS NOT NULL AND t.done = 0 AND substr(t.uid, length(r.uid) + 2) > r.until
      UNION
      SELECT t.id FROM sync_reg s JOIN todos t ON t.uid >= s.rowkey || '@' AND t.uid < s.rowkey || 'A'
      WHERE s.kind = 'todo_repeat' AND s.field = '_' AND s.value = 'false' AND t.done = 0
        AND NOT EXISTS (SELECT 1 FROM todo_repeats WHERE uid = s.rowkey)
    ''')) {
      deleteTodo(r['id'] as int, day: today);
    }
  }

  /// The to-do for [repeat] on [day], made now if it hasn't been: a time
  /// further ahead than [makeRepeats] reaches, to change or take away.
  TodoItem makeOccurrence(Repeat repeat, DateTime day) => weak(() {
    final uid = '${repeat.uid}@${dateKey(day)}';
    final rows = _db.select('SELECT * FROM todos WHERE uid = ?', [uid]);
    if (rows.isNotEmpty) return _todo(rows.single);
    _makeOccurrence(repeat, day);
    return _todo(_db.select('SELECT * FROM todos WHERE uid = ?', [uid]).single);
  });

  void _makeOccurrence(Repeat repeat, DateTime day) => _db.execute(
    'INSERT INTO todos (uid, scope, period, text, since, due_date, due_time, category, reminders, subtasks, location) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      '${repeat.uid}@${dateKey(day)}',
      TodoScope.month.name,
      TodoScope.month.period(day),
      repeat.text,
      dateKey(day),
      dateKey(day),
      repeat.time == null ? null : clockKey(repeat.time!),
      birthdayKind(repeat.birthday),
      _stored(repeat.reminders),
      TodoSubtask.encode(repeat.subtasks),
      repeat.location,
    ],
  );

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
