part of 'store.dart';

/// Copies of the database: saving one, and restoring from one after
/// checking it through.
extension StoreBackups on Store {
  /// Writes a consistent, compacted copy of the whole database to [path].
  /// Written beside it first and renamed, so a crash never leaves half a file.
  void saveCopy(String path) => replaceSafelySync(path, (part) => _db.execute('VACUUM INTO ?', [part.path]));

  /// Replaces everything in this database with the copy at [path], except
  /// that journal writing is never lost: a day the copy has no entry for
  /// keeps its text, and one written differently since keeps both.
  ///
  /// What sync knows of your other computers stays as it was, and every
  /// row is marked changed, so the restored data is sent to them as new
  /// edits rather than being overwritten by their newer copies.
  Future<void> restoreFrom(String path) async {
    // Migrate and validate away from the live connection. A readable SQLite
    // file is not necessarily an Eclipse backup.
    final source = sqlite3.open(path, mode: OpenMode.readOnly);
    final stagedDb = sqlite3.openInMemory();
    Store? staged;
    try {
      final version = source.select('PRAGMA user_version').first.columnAt(0) as int;
      if (version < 1 || version > Store.schemaVersion) throw StateError('Unsupported backup version: $version');
      if (source.select('PRAGMA quick_check').first.columnAt(0) != 'ok') throw StateError('Backup is damaged');
      await source.backup(stagedDb, nPage: -1).drain<void>();
      staged = Store._(stagedDb);
      staged._validate();
      _prepareRestore(staged);
      staged._validate();
      final original = sqlite3.openInMemory();
      try {
        await _db.backup(original, nPage: -1).drain<void>();
        try {
          await staged.raw.backup(_db, nPage: -1).drain<void>();
        } catch (_) {
          await original.backup(_db, nPage: -1).drain<void>();
          rethrow;
        }
      } finally {
        original.close();
      }
    } finally {
      source.close();
      if (staged == null) {
        stagedDb.close();
      } else {
        staged.close();
      }
    }
  }

  void _prepareRestore(Store target) {
    final known = _db.select('SELECT * FROM sync_reg').toList();
    final seen = _db.select('SELECT * FROM sync_seen').toList();
    final db = target.raw;
    target.transaction(() {
      for (final e in journalEntries()) {
        target.setJournal(e.day, Store.keepWriting(target.journal(e.day), e.text));
      }
      db.execute('DELETE FROM sync_reg');
      db.execute('DELETE FROM sync_seen');
      // The copy's own day starts are sent as it has them: it's restored exactly.
      db.execute('DELETE FROM sync_local');
      final reg = db.prepare(
        'INSERT INTO sync_reg (kind, rowkey, field, value, ts, origin, vv, journal_versions, seq) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      );
      for (final r in known) {
        reg.execute([
          r['kind'],
          r['rowkey'],
          r['field'],
          r['value'],
          r['ts'],
          r['origin'],
          r['vv'],
          r['journal_versions'],
          r['seq'],
        ]);
      }
      reg.close();
      final file = db.prepare('INSERT INTO sync_seen VALUES (?, ?)');
      for (final r in seen) {
        file.execute([r['file'], r['stamp']]);
      }
      file.close();
      db.execute('INSERT OR IGNORE INTO sync_dirty SELECT DISTINCT kind, rowkey, ${Store._now} FROM sync_reg');
    });
    target.markAllChanged();
  }

  void _validate() {
    const columns = {
      'habits': 'id, uid',
      'habit_months': 'year, month',
      'month_habits': 'year, month, habit_id, name, position, note, added_on, days',
      'entries': 'day, habit_id, status, note',
      'todos': 'id, uid, scope, period, text, done, carried, since, due_date, return_to_tomorrow, return_scope, defer_promotion_day, subtasks, done_at, due_time, category, position, reminders',
      'todo_history': 'uid, day, snapshot',
      'journal': 'day, text',
      'sleep_habits': 'item, habit_id',
      'sleep_notes': 'year, month, item, note',
      'settings': 'key, value',
      'exercises': 'uid, name, muscle, bodyweight',
      'training_sets': 'uid, day, exercise, position, weight, reps',
      'todo_repeats': 'uid, text, rule, start, until, time, category, reminders',
      'sync_reg': 'kind, rowkey, field, value, ts, origin, vv, journal_versions, seq',
      'sync_dirty': 'kind, rowkey, at',
      'sync_seen': 'file, stamp',
      'sync_local': 'kind, rowkey, field, value',
    };
    for (final e in columns.entries) {
      _db.select('SELECT ${e.value} FROM ${e.key} LIMIT 0');
    }
    if (_db.select('PRAGMA foreign_key_check').isNotEmpty ||
        _db.select('SELECT 1 FROM entries WHERE status NOT BETWEEN 0 AND 3 LIMIT 1').isNotEmpty ||
        _db.select('SELECT 1 FROM habits WHERE uid IS NULL LIMIT 1').isNotEmpty ||
        _db
            .select(
              "SELECT 1 FROM todos WHERE uid IS NULL OR scope NOT IN ('today', 'tomorrow', 'week', 'month') OR done NOT IN (0, 1) "
              "OR (position IS NOT NULL AND typeof(position) != 'integer') "
              "OR (reminders IS NOT NULL AND (typeof(reminders) != 'integer' OR reminders NOT BETWEEN 0 AND 15)) LIMIT 1",
            )
            .isNotEmpty ||
        _db.select('SELECT 1 FROM sleep_habits').length != SleepItem.values.length ||
        _db
            .select(
              'SELECT 1 FROM exercises WHERE muscle NOT IN (${MuscleGroup.values.map((g) => "'${g.name}'").join(', ')}) LIMIT 1',
            )
            .isNotEmpty ||
        _db.select('SELECT 1 FROM training_sets WHERE reps < 0 OR weight < 0 LIMIT 1').isNotEmpty) {
      throw StateError('Backup contains invalid data');
    }
    for (final r in _db.select(
      'SELECT day FROM entries UNION SELECT day FROM journal UNION SELECT since AS day FROM todos '
      'UNION SELECT due_date AS day FROM todos WHERE due_date IS NOT NULL UNION SELECT day FROM training_sets '
      'UNION SELECT start AS day FROM todo_repeats UNION SELECT until AS day FROM todo_repeats WHERE until IS NOT NULL',
    )) {
      final day = r['day'];
      if (!_validDay(day)) throw StateError('Backup contains an invalid date');
    }
    for (final r in _db.select('SELECT rule FROM todo_repeats')) {
      if (RepeatRule.decode(r['rule'] as String) == null) throw StateError('Backup contains an invalid repeat');
    }
    for (final r in _db.select('SELECT due_time AS time FROM todos UNION SELECT time FROM todo_repeats')) {
      if (!_validTime(r['time'])) throw StateError('Backup contains an invalid time');
    }
    for (final r in _db.select('SELECT subtasks FROM todos')) {
      if (!_validSubtasks(r['subtasks'])) throw StateError('Backup contains invalid subtasks');
    }
    for (final r in _db.select('SELECT day, snapshot FROM todo_history')) {
      final s = jsonDecode(r['snapshot'] as String);
      if (!_validDay(r['day']) ||
          s is! Map ||
          !TodoScope.values.any((scope) => scope.name == s['scope']) ||
          s['text'] is! String ||
          !_validSubtasks(s['subtasks']) ||
          s['period'] is! String ||
          !_validDay(s['since']) ||
          (s['due_date'] != null && !_validDay(s['due_date'])) ||
          ![0, 1].contains(s['done']) ||
          s['carried'] is! int ||
          s['deleted'] is! bool) {
        throw StateError('Invalid task history');
      }
    }
    for (final r in _db.select('SELECT value, vv, journal_versions FROM sync_reg')) {
      jsonDecode(r['value'] as String);
      final vv = jsonDecode(r['vv'] as String);
      if (vv is! Map || vv.values.any((v) => v is! int)) throw StateError('Invalid sync history');
      if (r['journal_versions'] != null && jsonDecode(r['journal_versions'] as String) is! List) {
        throw StateError('Invalid journal versions');
      }
    }
  }

  static bool _validSubtasks(Object? encoded) {
    if (encoded == null) return true; // Older snapshots have no subtasks.
    if (encoded is! String) return false;
    try {
      final items = jsonDecode(encoded);
      return items is List && items.every((item) => item is Map && item['text'] is String && item['done'] is bool);
    } catch (_) {
      return false;
    }
  }

  static bool _validTime(Object? value) =>
      value == null || value is String && RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value);

  static bool _validDay(Object? value) {
    if (value is! String) return false;
    final day = DateTime.tryParse(value);
    return day != null && dateKey(day) == value;
  }
}
