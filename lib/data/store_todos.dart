part of 'store.dart';

/// Task persistence and historical routing share atomic write operations.
extension StoreTodos on Store {
  /// Moves tasks on for [day]. These moves aren't synced: each computer
  /// makes them itself from the edits it has, so one that hasn't heard of
  /// a tick yet can't overwrite it by carrying the task forward.
  Map<TodoScope, List<TodoItem>> startDay(DateTime day) => transaction(() {
    String key(Row r) => '${r['kind']}/${r['rowkey']}';
    final pending = {for (final r in _db.select('SELECT kind, rowkey FROM sync_dirty')) key(r)};
    captureTodoBaseline(day);
    promoteDueTodos(day);
    rollTomorrowToToday(dateKey(day));
    final lists = <TodoScope, List<TodoItem>>{};
    for (final scope in TodoScope.values) {
      carryForward(scope, scope.period(day), day: day);
      lists[scope] = todos(scope, scope.period(day));
    }
    for (final r in _db.select('SELECT kind, rowkey FROM sync_dirty')) {
      if (!pending.contains(key(r))) {
        _db.execute('DELETE FROM sync_dirty WHERE kind = ? AND rowkey = ?', [r['kind'], r['rowkey']]);
      }
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
    final snapshots = _db.select(
      '''
      WITH latest AS (
        SELECT uid, MAX(day) AS day FROM todo_history WHERE day <= ? GROUP BY uid
      )
      SELECT h.rowid AS history_id, h.uid, h.snapshot, t.id FROM latest l
      JOIN todo_history h ON h.uid = l.uid AND h.day = l.day
      LEFT JOIN todos t ON t.uid = h.uid
      ORDER BY COALESCE(t.id, h.rowid)
    ''',
      [key],
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
      final scope = TodoScope.values.byName(s['scope'] as String);
      if (s['deleted'] == true ||
          (s['since'] as String).compareTo(key) > 0 ||
          (s['done'] == 1 && s['period'] != scope.period(day))) {
        continue;
      }
      lists[scope]!.add(
        TodoItem(
          r['id'] as int? ?? -(r['history_id'] as int),
          s['text'] as String,
          since: DateTime.parse(s['since'] as String),
          done: s['done'] == 1,
          carried: s['carried'] as int,
          uid: r['uid'] as String,
          dueDate: DateTime.tryParse(s['due_date'] as String? ?? ''),
          doneAt: DateTime.tryParse(s['done_at'] as String? ?? ''),
          subtasks: TodoSubtask.decode(s['subtasks'] as String?),
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
    r['text'] as String,
    since: DateTime.parse(r['since'] as String),
    done: r['done'] == 1,
    carried: r['carried'] as int,
    uid: r['uid'] as String,
    dueDate: DateTime.tryParse(r['due_date'] as String? ?? ''),
    doneAt: DateTime.tryParse(r['done_at'] as String? ?? ''),
    subtasks: TodoSubtask.decode(r['subtasks'] as String?),
  );

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
        final previous = DateTime.parse(r['period'] as String);
        // The task belongs to Today from the next calendar day, even if the
        // application was closed for several days.
        final updated = [now[r['id']]!];
        _recordTodos(updated, DateTime(previous.year, previous.month, previous.day + 1));
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

  void setTodoSubtasks(TodoScope scope, TodoItem item, List<TodoSubtask> children, DateTime day, {required bool live}) {
    transaction(() => _setTodoSubtasks(scope, item, children, day, live: live));
  }

  void _setTodoSubtasks(
    TodoScope scope,
    TodoItem item,
    List<TodoSubtask> children,
    DateTime day, {
    required bool live,
  }) {
    final encoded = TodoSubtask.encode(children);
    final done = children.isEmpty ? item.done : children.every((child) => child.done);
    if (live) {
      _db.execute('UPDATE todos SET subtasks = ? WHERE id = ?', [encoded, item.id]);
      setTodoDone(item.id, done, day: day, cascade: false);
    } else {
      _editPastTodo(scope, day, item: item, subtasks: encoded, done: done);
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
        live: true,
      );
      deleteTodo(source.id, day: day);
    });
  }

  /// A manual move keeps identity/history and clears all automatic routing.
  void moveTodo(int id, TodoScope destination, DateTime day) {
    transaction(() {
      _db.execute(
        'UPDATE todos SET scope = ?, period = ?, due_date = NULL, '
        'return_scope = NULL, return_to_tomorrow = 0, defer_promotion_day = NULL '
        'WHERE id = ? AND done = 0',
        [destination.name, destination.period(day), id],
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

  void editTodo(int id, String text, DateTime? dueDate, DateTime day) {
    transaction(() {
      _db.execute('UPDATE todos SET text = ?, due_date = ?, defer_promotion_day = NULL WHERE id = ?', [
        text,
        dueDate == null ? null : dateKey(dueDate),
        id,
      ]);
      _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [id]), day);
    });
  }

  /// Promote scheduled tasks on calendar dates, including days spent closed.
  void promoteDueTodos(DateTime today, {DateTime? earliest}) {
    transaction(() {
      final tomorrow = DateTime(today.year, today.month, today.day + 1);
      final rows = _db.select(
        "SELECT * FROM todos WHERE scope IN ('week', 'month') AND done = 0 AND due_date <= ? "
        "AND (defer_promotion_day IS NULL OR defer_promotion_day != ?)",
        [dateKey(tomorrow), dateKey(today)],
      );
      for (final r in rows) {
        final due = DateTime.parse(r['due_date'] as String);
        final ready = DateTime(due.year, due.month, due.day - 1);
        final since = DateTime.parse(r['since'] as String);
        var enters = ready.isBefore(since) ? since : ready;
        final deferred = DateTime.tryParse(r['defer_promotion_day'] as String? ?? '');
        if (deferred != null) {
          final resumes = DateTime(deferred.year, deferred.month, deferred.day + 1);
          if (enters.isBefore(resumes)) enters = resumes;
        }
        if (earliest != null && enters.isBefore(earliest)) enters = earliest;
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

  /// Correct a completion and keep the live task in the appropriate period.
  /// Deleted tasks remain deleted; editing their history must not restore them.
  void setPastTodoDone(TodoScope scope, DateTime day, TodoItem item, bool done, DateTime today) {
    transaction(() {
      _editPastTodo(scope, day, item: item, done: done);
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
    bool deleted = false,
  }) {
    transaction(
      () => _editPastTodo(scope, day, item: item, text: text, done: done, dueDate: dueDate, deleted: deleted),
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
      _db.execute('INSERT INTO todo_history VALUES (?, ?, ?)', [uid, next, jsonEncode(snapshot)]);
    }
    snapshot['deleted'] = deleted;
    if (text != null) {
      snapshot['text'] = text;
      snapshot['due_date'] = dueDate == null ? null : dateKey(dueDate);
    }
    if (subtasks != null) snapshot['subtasks'] = subtasks;
    if (done != null) {
      _toggleTodoSnapshot(snapshot, done, day);
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
}
