part of 'store.dart';

typedef DayTaskStats = ({
  int planned,
  int done,
  int unfinished,
  int freshPlanned,
  int freshDone,
  int carriedPlanned,
  int carriedDone,
});

/// Historical to-do snapshots and past-day corrections.
extension StoreTodoHistory on Store {
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
          note: cleanNote(s['note']),
        ),
      );
    }
    return lists;
  }


  void _recordTodos(List<Row> rows, DateTime day, {bool deleted = false, bool paused = false}) {
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
            'note',
          ])
            key: r[key],
          'deleted': deleted,
          if (paused) 'paused': true,
        });
        statement.execute([r['uid'], dateKey(day), snapshot]);
      }
    } finally {
      statement.close();
    }
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
      final live = subtasks == null ? _db.select('SELECT subtasks FROM todos WHERE uid = ?', [item.uid]) : const <Row>[];
      final liveSubtasks = live.isEmpty
          ? (snapshot['subtasks'] ?? '[]')
          : TodoSubtask.encode([
              for (final child in TodoSubtask.decode(live.single['subtasks'] as String?))
                child.copyWith(done: done),
            ]);
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
          liveSubtasks,
          item.uid,
        ],
      );
      _recordTodos(_db.select('SELECT * FROM todos WHERE uid = ?', [item.uid]), today);
      if (!done) {
        local(day: dateKey(today), () {
          promoteDueTodos(today, earliest: today);
          rollTomorrowToToday(dateKey(today));
        });
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
    ({String? value})? note,
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
    if (note != null) snapshot['note'] = note.value;
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

  /// Per-day Today task counts across past days in [year] (strictly before
  /// [today]), reconstructed in a single pass over `todo_history` and legacy
  /// `todos` rows. Birthdays and deleted snapshots are excluded.
  Map<String, DayTaskStats> yearTaskStats(int year, DateTime today) {
    final yearStart = DateTime(year, 1, 1);
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final yearEnd = DateTime(year, 12, 31);
    final limit = yesterday.isBefore(yearEnd) ? yesterday : yearEnd;
    if (limit.isBefore(yearStart)) return const {};

    final limitKey = dateKey(limit);
    final stats = <String, _MutableDayTaskStats>{};

    void recordDay(String key, {required bool isDone, required bool isCarried}) {
      final entry = stats.putIfAbsent(key, _MutableDayTaskStats.new);
      entry.planned++;
      if (isDone) {
        entry.done++;
      } else {
        entry.unfinished++;
      }
      if (isCarried) {
        entry.carriedPlanned++;
        if (isDone) entry.carriedDone++;
      } else {
        entry.freshPlanned++;
        if (isDone) entry.freshDone++;
      }
    }

    final snapshots = _db.select(
      '''
      SELECT h.uid, h.day,
        json_extract(h.snapshot, '\$.scope') AS scope,
        json_extract(h.snapshot, '\$.period') AS period,
        json_extract(h.snapshot, '\$.since') AS since,
        json_extract(h.snapshot, '\$.done') AS done,
        json_extract(h.snapshot, '\$.carried') AS carried,
        json_extract(h.snapshot, '\$.deleted') AS deleted,
        json_extract(h.snapshot, '\$.category') AS category,
        CASE WHEN t.done = 1 AND t.scope = 'today' THEN t.period END AS ticked,
        t.carried AS live_carried,
        t.since AS live_since,
        t.category AS live_category
      FROM todo_history h
      LEFT JOIN todos t ON t.uid = h.uid
      WHERE h.day <= ?1
      ORDER BY h.uid, h.day
      ''',
      [limitKey],
    );

    bool flag(Object? v) => v == true || v == 1;
    DateTime earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
    DateTime later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

    // Reconstruct per-uid timelines in one linear sweep.
    for (var i = 0; i < snapshots.length;) {
      final uid = snapshots[i]['uid'] as String;
      var j = i + 1;
      while (j < snapshots.length && snapshots[j]['uid'] == uid) {
        j++;
      }

      final firstRow = snapshots[i];
      final tickedDay = DateTime.tryParse(firstRow['ticked'] as String? ?? '');
      final liveCarried = (firstRow['live_carried'] as int?) ?? 0;
      final liveSinceDay = DateTime.tryParse(firstRow['live_since'] as String? ?? '');
      final liveCategory = firstRow['live_category'];
      Object? lastCategory = liveCategory;
      DateTime? firstOpenTodayDay;
      final countedDays = <String>{};

      for (var k = i; k < j; k++) {
        final row = snapshots[k];
        lastCategory = row['category'] ?? lastCategory;
        final snapDay = DateTime.tryParse(row['day'] as String? ?? '');
        if (snapDay == null) continue;

        final nextSnapDay = (k + 1 < j) ? DateTime.tryParse(snapshots[k + 1]['day'] as String? ?? '') : null;
        if (flag(row['deleted']) || isBirthday(row['category']) || row['scope'] != TodoScope.today.name) {
          continue;
        }
        final sinceDay = DateTime.tryParse(row['since'] as String? ?? '');
        if (sinceDay == null) continue;
        final carried = (row['carried'] as int?) ?? 0;
        final isDone = flag(row['done']);
        final periodDay = DateTime.tryParse(row['period'] as String? ?? '');
        firstOpenTodayDay ??= periodDay != null && periodDay.isBefore(snapDay) ? periodDay : snapDay;

        if (isDone) {
          if (periodDay != null &&
              !periodDay.isBefore(yearStart) &&
              !periodDay.isAfter(limit) &&
              !periodDay.isBefore(sinceDay) &&
              (tickedDay != null
                  ? periodDay == tickedDay
                  : (!periodDay.isBefore(snapDay) && (nextSnapDay == null || periodDay.isBefore(nextSnapDay))))) {
            final key = dateKey(periodDay);
            if (countedDays.add(key)) {
              recordDay(
                key,
                isDone: true,
                isCarried: carried > 0 || periodDay.isAfter(firstOpenTodayDay),
              );
            }
          }
        } else {
          var end = nextSnapDay == null ? limit : earlier(limit, DateTime(nextSnapDay.year, nextSnapDay.month, nextSnapDay.day - 1));
          if (tickedDay != null) {
            end = earlier(end, DateTime(tickedDay.year, tickedDay.month, tickedDay.day - 1));
          }
          final start = later(later(snapDay, sinceDay), yearStart);
          for (var d = start; !d.isAfter(end); d = DateTime(d.year, d.month, d.day + 1)) {
            final key = dateKey(d);
            if (countedDays.add(key)) {
              recordDay(
                key,
                isDone: false,
                isCarried: carried > 0 || d.isAfter(firstOpenTodayDay),
              );
            }
          }
        }
      }

      if (tickedDay != null &&
          !tickedDay.isBefore(yearStart) &&
          !tickedDay.isAfter(limit) &&
          !isBirthday(liveCategory ?? lastCategory)) {
        final key = dateKey(tickedDay);
        if (countedDays.add(key)) {
          final isCarried = liveCarried > 0 ||
              (firstOpenTodayDay != null
                  ? tickedDay.isAfter(firstOpenTodayDay)
                  : (liveSinceDay != null && tickedDay.isAfter(liveSinceDay)));
          recordDay(key, isDone: true, isCarried: isCarried);
        }
      }

      i = j;
    }

    // Legacy tasks without snapshots by limit.
    for (final r in _db.select(
      '''
      SELECT scope, period, since, done, carried, category
      FROM todos t
      WHERE t.scope = 'today' AND t.since <= ?1 AND NOT EXISTS (
        SELECT 1 FROM todo_history h WHERE h.uid = t.uid AND h.day <= ?1
      )
      ''',
      [limitKey],
    )) {
      if (isBirthday(r['category'])) continue;
      final sinceDay = DateTime.tryParse(r['since'] as String? ?? '');
      final periodDay = DateTime.tryParse(r['period'] as String? ?? '');
      if (sinceDay == null || periodDay == null) continue;
      final carried = (r['carried'] as int?) ?? 0;
      final isDone = r['done'] == 1;
      if (isDone) {
        final openEnd = earlier(limit, DateTime(periodDay.year, periodDay.month, periodDay.day - 1));
        for (var d = later(sinceDay, yearStart); !d.isAfter(openEnd); d = DateTime(d.year, d.month, d.day + 1)) {
          recordDay(dateKey(d), isDone: false, isCarried: d.isAfter(sinceDay));
        }
        if (!periodDay.isBefore(yearStart) && !periodDay.isAfter(limit)) {
          recordDay(dateKey(periodDay), isDone: true, isCarried: carried > 0 || periodDay.isAfter(sinceDay));
        }
      } else {
        for (var d = later(sinceDay, yearStart); !d.isAfter(limit); d = DateTime(d.year, d.month, d.day + 1)) {
          recordDay(dateKey(d), isDone: false, isCarried: carried > 0 || d.isAfter(sinceDay));
        }
      }
    }

    return {
      for (final e in stats.entries) e.key: e.value.freeze(),
    };
  }
}

class _MutableDayTaskStats {
  int planned = 0;
  int done = 0;
  int unfinished = 0;
  int freshPlanned = 0;
  int freshDone = 0;
  int carriedPlanned = 0;
  int carriedDone = 0;

  DayTaskStats freeze() => (
    planned: planned,
    done: done,
    unfinished: unfinished,
    freshPlanned: freshPlanned,
    freshDone: freshDone,
    carriedPlanned: carriedPlanned,
    carriedDone: carriedDone,
  );
}

/// Move completed plans into the day's record, retaining their undo destination.
void _toggleTodoSnapshot(Map<String, dynamic> snapshot, bool done, DateTime day) {
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

