part of 'sync.dart';

(int, int) _month(String key) {
    final [y, m] = key.split('-');
    return (int.parse(y), int.parse(m));
  }


  /// What a row of a kind that can be removed can't be without: until it's
  /// come (in a file not read yet), an edit of it waits, the row not there.
const _made = <String, List<String>>{
    'todo': ['since'],
    'month_habit': ['name'],
    'routine':['name','sets'],
    'weigh_in':['kg'],
    'exercise': ['name'],
    'training_set': ['day', 'exercise'],
    'todo_repeat': ['start'],
  };


/// A holiday's rowkey: its first and last days.
String _holidayKey(Holiday h) => '${dateKey(h.start)}/${dateKey(h.end)}';

Set<String> _holidayKeys(String? encoded) => {for (final h in decodeHolidays(encoded)) _holidayKey(h)};


extension _SyncCodec on SyncEngine {
  /// The row's fields as they are now, with [SyncEngine._present] for removable kinds.
  Map<String, Object?> _read(String kind, String rowkey) {
    Map<String, Object?>? row(String sql, List<Object?> args) {
      final r = _db.select(sql, args);
      return r.isEmpty ? null : Map.of(r.first);
    }

    final Map<String, Object?>? fields;
    switch (kind) {
      case 'habit_month':
        final (y, m) = _month(rowkey);
        return {'initialized': store.hasMonth(y, m)};
      case 'todo_history':
        final (day, uid) = SyncEngine._split(rowkey);
        return {
          'snapshot': row('SELECT snapshot FROM todo_history WHERE uid = ? AND day = ?', [uid, day])?['snapshot'],
        };
      case 'month_habit':
        final (month, uid) = SyncEngine._split(rowkey);
        final (y, m) = _month(month);
        fields = row(
          'SELECT name, position, note, added_on, days,weekly,target,unit FROM month_habits JOIN habits h ON h.id = habit_id '
          'WHERE year = ? AND month = ? AND h.uid = ?',
          [y, m, uid],
        );
      case 'entry':
        final (day, uid) = SyncEngine._split(rowkey);
        return row('SELECT status, note,amount FROM entries JOIN habits h ON h.id = habit_id WHERE day = ? AND h.uid = ?', [
              day,
              uid,
            ]) ??
            {'status': 0, 'note': null,'amount':null};
      case 'todo':
        fields = row(
          'SELECT scope, period, text, done, carried, since, due_date, return_to_tomorrow, return_scope, defer_promotion_day, subtasks, done_at, due_time, category, position, reminders, location, note FROM todos WHERE uid = ?',
          [rowkey],
        );
      case 'journal':
        return {
          'text': row('SELECT text FROM journal WHERE day = ?', [rowkey])?['text'] ?? '',
        };
      case 'sleep_note':
        final (month, item) = SyncEngine._split(rowkey);
        final (y, m) = _month(month);
        return {
          'note': row('SELECT note FROM sleep_notes WHERE year = ? AND month = ? AND item = ?', [y, m, item])?['note'],
        };
      case 'setting':
        return {
          'value': row('SELECT value FROM settings WHERE key = ?', [rowkey])?['value'],
        };
      case 'holiday':
        return {SyncEngine._present: _holidays().contains(rowkey)};
      case 'routine':
        fields = row('SELECT name,sets FROM routines WHERE uid=?',[rowkey]);
      case 'weigh_in':
        fields = row('SELECT kg FROM weigh_ins WHERE uid=?',[rowkey]);
      case 'exercise':
        fields = row('SELECT name, muscle, bodyweight FROM exercises WHERE uid = ?', [rowkey]);
      case 'training_set':
        fields = row('SELECT day, exercise, position, weight, reps,note,rpe FROM training_sets WHERE uid = ?', [rowkey]);
      case 'todo_repeat':
        fields = row(
          'SELECT text, rule, start, until, time, category, reminders, subtasks, location FROM todo_repeats WHERE uid = ?',
          [rowkey],
        );
      default:
        // From a newer version: kept as registers until this one is updated.
        return const {};
    }
    return fields == null ? {SyncEngine._present: false} : {...fields, SyncEngine._present: true};
  }

  int _habit(String uid) {
    _db.execute('INSERT OR IGNORE INTO habits (uid) VALUES (?)', [uid]);
    return _db.select('SELECT id FROM habits WHERE uid = ?', [uid]).first['id'] as int;
  }


  /// Makes the row match [f], its fields from the registers.
  void _write(String kind, String rowkey, Map<String, Object?> f) {
    final gone =
        SyncEngine._removable.contains(kind) && (f[SyncEngine._present] != true || (_made[kind]?.any((k) => f[k] == null) ?? false));
    switch (kind) {
      case 'habit_month':
        final (y, m) = _month(rowkey);
        if (f['initialized'] == true) store.initializeMonth(y, m);
      case 'todo_history':
        final (day, uid) = SyncEngine._split(rowkey);
        if (f['snapshot'] == null) {
          _db.execute('DELETE FROM todo_history WHERE uid = ? AND day = ?', [uid, day]);
        } else {
          _db.execute(
            'INSERT INTO todo_history VALUES (?, ?, ?) ON CONFLICT (uid, day) DO UPDATE SET snapshot = excluded.snapshot',
            [uid, day, f['snapshot']],
          );
        }
      case 'month_habit':
        final (month, uid) = SyncEngine._split(rowkey);
        final (y, m) = _month(month);
        store.initializeMonth(y, m);
        final id = _habit(uid);
        if (gone) {
          _db.execute('DELETE FROM month_habits WHERE year = ? AND month = ? AND habit_id = ?', [y, m, id]);
        } else {
          _db.execute(
            'INSERT INTO month_habits (year, month, habit_id, name, position, note, added_on, days,weekly,target,unit) VALUES (?, ?, ?, ?, ?, ?, ?, ?,?,?,?) '
            'ON CONFLICT (year, month, habit_id) DO UPDATE SET name = excluded.name, position = excluded.position, '
            'note = excluded.note, added_on = excluded.added_on, days = excluded.days, weekly=excluded.weekly,target=excluded.target,unit=excluded.unit',
            [y, m, id, f['name'] ?? '', f['position'] ?? 0, f['note'], f['added_on'], f['days'],f['weekly'],f['target'],f['unit']],
          );
        }
      case 'entry':
        final (day, uid) = SyncEngine._split(rowkey);
        final id = _habit(uid);
        final status = f['status'] as int? ?? 0;
        if (status == 0 && f['amount'] == null) {
          _db.execute('DELETE FROM entries WHERE day = ? AND habit_id = ?', [day, id]);
        } else {
          _db.execute(
            'INSERT INTO entries (day, habit_id, status, note,amount) VALUES (?, ?, ?, ?,?) '
            'ON CONFLICT (day, habit_id) DO UPDATE SET status = excluded.status, note = excluded.note, amount=excluded.amount',
            [day, id, status, f['note'],f['amount']],
          );
        }
      case 'todo':
        if (gone) {
          _db.execute('DELETE FROM todos WHERE uid = ?', [rowkey]);
        } else {
          _db.execute(
            'INSERT INTO todos (uid, scope, period, text, done, carried, since, due_date, return_to_tomorrow, return_scope, defer_promotion_day, subtasks, done_at, due_time, category, position, reminders, location, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT (uid) DO UPDATE SET scope = excluded.scope, period = excluded.period, text = excluded.text, '
            'done = excluded.done, carried = excluded.carried, since = excluded.since, due_date = excluded.due_date, '
            'return_to_tomorrow = excluded.return_to_tomorrow, return_scope = excluded.return_scope, '
            'defer_promotion_day = excluded.defer_promotion_day, subtasks = excluded.subtasks, done_at = excluded.done_at, '
            'due_time = excluded.due_time, category = excluded.category, position = excluded.position, '
            'reminders = excluded.reminders, location = excluded.location, note = excluded.note',
            [
              rowkey,
              f['scope'] ?? 'today',
              f['period'] ?? f['since'] ?? '',
              f['text'] ?? '',
              f['done'] ?? 0,
              f['carried'] ?? 0,
              f['since'] ?? f['period'] ?? '',
              f['due_date'],
              f['return_to_tomorrow'] ?? 0,
              f['return_scope'] ?? (f['return_to_tomorrow'] == 1 ? 'tomorrow' : null),
              f['defer_promotion_day'],
              f['subtasks'] ?? '[]',
              f['done_at'],
              f['due_time'],
              f['category'],
              f['position'],
              f['reminders'],
              f['location'],
              f['note'],
            ],
          );
        }
      case 'journal':
        store.setJournal(rowkey, f['text'] as String? ?? '');
      case 'sleep_note':
        final (month, item) = SyncEngine._split(rowkey);
        final (y, m) = _month(month);
        final note = f['note'] as String?;
        if (note == null) {
          _db.execute('DELETE FROM sleep_notes WHERE year = ? AND month = ? AND item = ?', [y, m, item]);
        } else {
          _db.execute(
            'INSERT INTO sleep_notes (year, month, item, note) VALUES (?, ?, ?, ?) '
            'ON CONFLICT (year, month, item) DO UPDATE SET note = excluded.note',
            [y, m, item, note],
          );
        }
      case 'setting' when rowkey == SyncEngine._holidaysKey:
        // All the holidays at once, as versions before 34 send them: each
        // one this computer has a register of goes by that, the rest by
        // this list.
        final listed = _holidayKeys(f['value'] as String?);
        final kept = _holidayRegisters();
        _setHolidays({
          for (final key in {..._holidays(), ...listed, ...kept.keys})
            if (kept[key] ?? listed.contains(key)) key,
        });
      case 'setting':
        final value = f['value'] as String?;
        if (value == null) {
          _db.execute('DELETE FROM settings WHERE key = ?', [rowkey]);
        } else {
          store.setSetting(rowkey, value);
        }
      case 'holiday':
        _setHolidays({..._holidays()..remove(rowkey), if (f[SyncEngine._present] == true) rowkey});
      case 'routine':
        if (gone) {
          _db.execute('DELETE FROM routines WHERE uid=?',[rowkey]);
        } else {
          _db.execute('INSERT INTO routines(uid,name,sets) VALUES(?,?,?) ON CONFLICT(uid) DO UPDATE SET name=excluded.name,sets=excluded.sets',[rowkey,f['name'],f['sets']]);
        }
      case 'weigh_in':
        if (gone) {
          _db.execute('DELETE FROM weigh_ins WHERE uid=?',[rowkey]);
        } else {
          _db.execute('INSERT INTO weigh_ins(uid,kg) VALUES(?,?) ON CONFLICT(uid) DO UPDATE SET kg=excluded.kg',[rowkey,f['kg']]);
        }
      case 'exercise':
        if (gone) {
          _db.execute('DELETE FROM exercises WHERE uid = ?', [rowkey]);
        } else {
          _db.execute(
            'INSERT INTO exercises (uid, name, muscle, bodyweight) VALUES (?, ?, ?, ?) '
            'ON CONFLICT (uid) DO UPDATE SET name = excluded.name, muscle = excluded.muscle, bodyweight = excluded.bodyweight',
            [rowkey, f['name'] ?? '', f['muscle'] ?? 'chest', f['bodyweight'] ?? 0],
          );
        }
      case 'training_set':
        if (gone) {
          _db.execute('DELETE FROM training_sets WHERE uid = ?', [rowkey]);
        } else {
          _db.execute(
            'INSERT INTO training_sets (uid, day, exercise, position, weight, reps,note,rpe) VALUES (?, ?, ?, ?, ?, ?,?,?) '
            'ON CONFLICT (uid) DO UPDATE SET day = excluded.day, exercise = excluded.exercise, '
            'position = excluded.position, weight = excluded.weight, reps = excluded.reps,note=excluded.note,rpe=excluded.rpe',
            [rowkey, f['day'] ?? '', f['exercise'] ?? '', f['position'] ?? 0, f['weight'], f['reps'] ?? 0,f['note'],f['rpe']],
          );
        }
      case 'todo_repeat':
        if (gone || RepeatRule.decode(f['rule'] as String? ?? '') == null) {
          _db.execute('DELETE FROM todo_repeats WHERE uid = ?', [rowkey]);
        } else {
          _db.execute(
            'INSERT INTO todo_repeats (uid, text, rule, start, until, time, category, reminders, subtasks, location) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT (uid) DO UPDATE SET text = excluded.text, rule = excluded.rule, '
            'start = excluded.start, until = excluded.until, time = excluded.time, category = excluded.category, '
            'reminders = excluded.reminders, subtasks = excluded.subtasks, location = excluded.location',
            [
              rowkey,
              f['text'] ?? '',
              f['rule'],
              f['start'],
              f['until'],
              f['time'],
              f['category'],
              f['reminders'],
              f['subtasks'],
              f['location'],
            ],
          );
        }
    }
  }


  /// The holidays here, by rowkey.
  Set<String> _holidays() => _holidayKeys(store.setting(SyncEngine._holidaysKey));

  void _setHolidays(Set<String> keys) {
    final next = encodeHolidays([
      for (final key in keys)
        if (SyncEngine._split(key) case (final a, final b))
          if ((DateTime.tryParse(a), DateTime.tryParse(b)) case (final start?, final end?)) (start: start, end: end),
    ]);
    final value = encodeHolidays(decodeHolidays(next));
    if (value != (store.setting(SyncEngine._holidaysKey) ?? encodeHolidays(const []))) store.setSetting(SyncEngine._holidaysKey, value);
  }

  /// Whether each holiday with a register of its own is there, by rowkey.
  Map<String, bool> _holidayRegisters() => {
    for (final r in _db.select("SELECT rowkey, value FROM sync_reg WHERE kind = 'holiday' AND field = ?", [SyncEngine._present]))
      r['rowkey'] as String: r['value'] == 'true',
  };

  /// What a holiday without a register of its own was last synced as: in
  /// the 'holidays' list sync had, or not.
  Map<String, String> _holidaysSynced() {
    final listed = _holidayKeys(switch (_reg('setting', SyncEngine._holidaysKey, 'value')) {
      final r? => jsonDecode(r.value) as String?,
      null => null,
    });
    return {for (final key in listed) key: jsonEncode(true)};
  }

}
