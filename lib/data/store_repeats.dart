part of 'store.dart';

/// Repeating task rules and occurrence generation.
extension StoreRepeats on Store {
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
      until: until == null ? null : dateOnly(until),
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

  /// A repeat's checklist: each time starts with its steps open and
  /// without the notes kept on one time.
  static List<TodoSubtask> _unticked(List<TodoSubtask> children) => [
    for (final child in children) TodoSubtask(child.text, numbered: child.numbered),
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
        // Each step keeps its tick and note on this time.
        final had = {for (final child in TodoSubtask.decode(r['subtasks'] as String?)) child.text: child};
        final next = [
          for (final child in children)
            TodoSubtask(
              child.text,
              done: had[child.text]?.done ?? false,
              numbered: child.numbered,
              note: had[child.text]?.note ?? child.note,
            ),
        ];
        _db.execute('UPDATE todos SET subtasks = ? WHERE id = ?', [TodoSubtask.encode(next), r['id']]);
        _recordTodos(_db.select('SELECT * FROM todos WHERE id = ?', [r['id']]), today);
      }
    });
  }

  /// The open to-dos of repeat [uid] for [from] on.
  List<Row> _openOccurrences(String uid, DateTime from) =>
      _db.select('SELECT * FROM todos WHERE uid >= ? AND uid < ? AND done = 0', StoreTodos.occurrenceRange(uid, from: from));

  /// The open to-do of repeat [uid] for [day], if materialized and open.
  TodoItem? openOccurrence(String uid, DateTime day) {
    final rows = _db.select('SELECT * FROM todos WHERE uid = ? AND done = 0', ['$uid@${dateKey(day)}']);
    return rows.isEmpty ? null : _todo(rows.single);
  }


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
      StoreTodos.occurrenceRange(uid, from: from),
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

  /// After you change the holidays: takes away the open times they now
  /// cover, and brings back from [today] on those they took away and no
  /// longer cover. Your own edits, so sync sends them as any others.
  void applyHolidays(DateTime today) => transaction(() {
    final holidays = decodeHolidays(setting('holidays'));
    final byUid = {for (final repeat in repeats()) repeat.uid: repeat};
    final paused = switch (_decodeJson(setting(StoreTodos.pausedTimesSetting))) {
      final List<dynamic> l => l.whereType<String>().toSet(),
      _ => <String>{},
    };
    // Also discover occurrences paused by a holiday on another synced device.
    for (final r in _db.select('''
      WITH latest AS (
        SELECT uid, MAX(day) AS day FROM todo_history GROUP BY uid
      )
      SELECT h.uid FROM latest l
      JOIN todo_history h ON h.uid = l.uid AND h.day = l.day
      WHERE json_extract(h.snapshot, '\$.deleted') = 1
        AND json_extract(h.snapshot, '\$.paused') = 1
    ''')) {
      paused.add(r['uid'] as String);
    }
    for (final uid in paused.toList()) {
      final at = uid.lastIndexOf('@');
      final repeat = at < 0 ? null : byUid[uid.substring(0, at)];
      final day = at < 0 ? null : DateTime.tryParse(uid.substring(at + 1));
      if (repeat == null || day == null || day.isBefore(today) || !repeat.on(day)) {
        paused.remove(uid);
      } else if (holidayOn(holidays, day) == null) {
        paused.remove(uid);
        if (_db.select('SELECT 1 FROM todos WHERE uid = ?', [uid]).isEmpty) {
          _makeOccurrence(repeat, day);
          _recordTodos(_db.select('SELECT * FROM todos WHERE uid = ?', [uid]), today);
        }
      }
    }
    paused.addAll(_takeAwayPaused(today, holidays));
    setSetting(StoreTodos.pausedTimesSetting, jsonEncode(paused.toList()));
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
        deleteTodo(r['id'] as int, day: today, paused: true);
        gone.add(r['uid'] as String);
      }
    }
    return gone;
  }


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
    final before = switch (_decodeJson(setting(StoreTodos.walkedSetting))) {
      final Map<String, dynamic> m => m,
      _ => const <String, dynamic>{},
    };
    final walked = <String, List<String>>{};
    final all = repeats();
    final holidays = decodeHolidays(setting('holidays'));
    // Holidays changed: days they've let go of are walked again, today on.
    final holidaysMark = encodeHolidays(holidays);
    final holidaysMoved = holidaysMark != (setting(StoreTodos.walkedHolidaysSetting) ?? encodeHolidays(const []));
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
          StoreTodos.debugRepeatDaysWalked++;
          if (!made.contains('${repeat.uid}@${dateKey(day)}') && !StoreTodos.pausedOn(repeat, day, holidays)) {
            _makeOccurrence(repeat, day);
          }
        }
      }
      walked[repeat.uid] = [...mark, dateKey(through != null && through.isAfter(last) ? through : last)];
    }
    _takeAwayEnded(today);
    // Made on another computer before it heard of the holiday.
    final gone = _takeAwayPaused(today, holidays);
    if (gone.isNotEmpty) {
      final paused = switch (_decodeJson(setting(StoreTodos.pausedTimesSetting))) {
        final List<dynamic> l => l.whereType<String>().toSet(),
        _ => <String>{},
      }..addAll(gone);
      setSetting(StoreTodos.pausedTimesSetting, jsonEncode(paused.toList()));
    }
    if (holidaysMoved) setSetting(StoreTodos.walkedHolidaysSetting, holidaysMark);
    final encoded = jsonEncode(walked);
    if (encoded != setting(StoreTodos.walkedSetting)) setSetting(StoreTodos.walkedSetting, encoded);
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

}
