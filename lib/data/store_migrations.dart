part of 'store.dart';

/// The database was written by a newer build than this one: updating
/// Eclipse opens it.
class DatabaseTooNewException implements Exception {
  const DatabaseTooNewException();

  @override
  String toString() => 'This database needs a newer version of Eclipse';
}

/// Initializes new v38 databases and brings v37 databases up to [Store.schemaVersion].
extension on Store {
  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version > Store.schemaVersion) throw const DatabaseTooNewException();
    if (version == 0) {
      transaction(() {
        _createV38();
        _db.execute('PRAGMA user_version = ${Store.schemaVersion}');
      });
      return;
    }
    if (version < 37) {
      throw StateError('Database schema v$version is too old for this build');
    }
    if (version < 38) {
      transaction(() {
        _upgradeV37ToV38();
        _db.execute('PRAGMA user_version = 38');
      });
    }
    if (version < Store.schemaVersion) upgradedFrom = version;
  }

  void _createV38() {
    _db.execute('''
      CREATE TABLE habits (id INTEGER PRIMARY KEY AUTOINCREMENT, uid TEXT);
      CREATE UNIQUE INDEX habits_uid ON habits (uid);

      CREATE TABLE sleep_habits (
        item TEXT PRIMARY KEY,
        habit_id INTEGER NOT NULL REFERENCES habits(id)
      );

      CREATE TABLE month_habits (
        year INTEGER NOT NULL,
        month INTEGER NOT NULL,
        habit_id INTEGER NOT NULL REFERENCES habits(id),
        name TEXT NOT NULL,
        position INTEGER NOT NULL,
        note TEXT,
        added_on TEXT,
        days TEXT,
        weekly INTEGER,
        target INTEGER,
        unit TEXT,
        PRIMARY KEY (year, month, habit_id)
      );
      CREATE INDEX month_habits_habit_id ON month_habits (habit_id);

      CREATE TABLE habit_months (
        year INTEGER NOT NULL,
        month INTEGER NOT NULL,
        PRIMARY KEY (year, month)
      );

      CREATE TABLE entries (
        day TEXT NOT NULL,
        habit_id INTEGER NOT NULL REFERENCES habits(id),
        status INTEGER NOT NULL,
        note TEXT,
        amount INTEGER,
        PRIMARY KEY (day, habit_id)
      );
      CREATE INDEX entries_habit_day ON entries(habit_id, day);

      CREATE TABLE todos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scope TEXT NOT NULL,
        period TEXT NOT NULL,
        text TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0,
        carried INTEGER NOT NULL DEFAULT 0,
        since TEXT,
        uid TEXT,
        due_date TEXT,
        return_to_tomorrow INTEGER NOT NULL DEFAULT 0,
        return_scope TEXT,
        defer_promotion_day TEXT,
        subtasks TEXT NOT NULL DEFAULT '[]',
        done_at TEXT,
        due_time TEXT,
        category TEXT,
        position INTEGER,
        reminders INTEGER,
        location TEXT,
        note TEXT
      );
      CREATE INDEX todos_scope_period ON todos (scope, period);
      CREATE UNIQUE INDEX todos_uid ON todos (uid);
      CREATE INDEX todos_done_due_date ON todos (done, due_date);
      CREATE INDEX todos_done_reminders ON todos (done, reminders);
      CREATE INDEX todos_since ON todos (since);

      CREATE TABLE todo_history (
        uid TEXT NOT NULL,
        day TEXT NOT NULL,
        snapshot TEXT NOT NULL,
        PRIMARY KEY (uid, day)
      );
      CREATE INDEX todo_history_day ON todo_history(day);

      CREATE TABLE todo_repeats (
        uid TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        rule TEXT NOT NULL,
        start TEXT NOT NULL,
        until TEXT,
        time TEXT,
        category TEXT,
        reminders INTEGER,
        subtasks TEXT,
        location TEXT
      );

      CREATE TABLE journal (day TEXT PRIMARY KEY, text TEXT NOT NULL);
      CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

      CREATE TABLE sleep_notes (
        year INTEGER NOT NULL,
        month INTEGER NOT NULL,
        item TEXT NOT NULL,
        note TEXT NOT NULL,
        PRIMARY KEY (year, month, item)
      );
      CREATE INDEX sleep_notes_item_month ON sleep_notes(item, year * 12 + month);

      CREATE TABLE exercises (
        uid TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        muscle TEXT NOT NULL,
        bodyweight INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE training_sets (
        uid TEXT PRIMARY KEY,
        day TEXT NOT NULL,
        exercise TEXT NOT NULL,
        position INTEGER NOT NULL,
        weight REAL,
        reps INTEGER NOT NULL,
        note TEXT,
        rpe REAL
      );
      CREATE INDEX training_sets_day ON training_sets(day);

      CREATE TABLE sync_reg (
        kind TEXT NOT NULL,
        rowkey TEXT NOT NULL,
        field TEXT NOT NULL,
        value TEXT,
        ts INTEGER NOT NULL,
        origin TEXT NOT NULL,
        vv TEXT NOT NULL,
        journal_versions TEXT,
        seq INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (kind, rowkey, field)
      ) WITHOUT ROWID;
      CREATE INDEX sync_reg_origin ON sync_reg (origin, ts);
      CREATE INDEX sync_reg_seq ON sync_reg (origin, seq);

      CREATE TABLE sync_dirty (
        kind TEXT NOT NULL,
        rowkey TEXT NOT NULL,
        at INTEGER NOT NULL,
        PRIMARY KEY (kind, rowkey)
      ) WITHOUT ROWID;

      CREATE TABLE sync_seen (file TEXT PRIMARY KEY, stamp TEXT NOT NULL);

      CREATE TABLE sync_local (
        kind TEXT NOT NULL,
        rowkey TEXT NOT NULL,
        field TEXT NOT NULL,
        value TEXT NOT NULL,
        PRIMARY KEY (kind, rowkey, field)
      ) WITHOUT ROWID;
    ''');

    for (final item in SleepItem.values) {
      _db.execute('INSERT INTO habits (uid) VALUES (?)', ['sleep-${item.name}']);
      _db.execute('INSERT INTO sleep_habits (item, habit_id) VALUES (?, ?)', [item.name, _db.lastInsertRowId]);
    }

    const habit = '(SELECT uid FROM habits WHERE id = R.habit_id)';
    final legacyTriggers = {
      'month_habit': ('month_habits', "R.year || '-' || R.month || '/' || $habit", null),
      'entry': ('entries', "R.day || '/' || $habit", null),
      'todo': ('todos', 'R.uid', null),
      'journal': ('journal', 'R.day', null),
      'sleep_note': ('sleep_notes', "R.year || '-' || R.month || '/' || R.item", null),
      'setting': ('settings', 'R.key', 'R.key IN (${Store.syncedSettings.map((k) => "'$k'").join(', ')})'),
    };
    for (final MapEntry(key: kind, value: (table, rowkey, filter)) in legacyTriggers.entries) {
      String mark(String row) {
        final key = rowkey.replaceAll('R.', '$row.');
        return "UPDATE sync_dirty SET at = ${Store._now} WHERE kind = '$kind' AND rowkey = $key; "
            "INSERT INTO sync_dirty SELECT '$kind', $key, ${Store._now} "
            "WHERE $key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sync_dirty WHERE kind = '$kind' AND rowkey = $key);";
      }

      String only(String row) => filter == null ? '' : 'WHEN ${filter.replaceAll('R.', '$row.')} ';
      _db.execute('CREATE TRIGGER ${table}_ins AFTER INSERT ON $table ${only('NEW')}BEGIN ${mark('NEW')} END');
      _db.execute(
        'CREATE TRIGGER ${table}_upd AFTER UPDATE ON $table ${filter == null ? '' : 'WHEN ${filter.replaceAll('R.', 'NEW.')} OR ${filter.replaceAll('R.', 'OLD.')} '}'
        'BEGIN ${mark('OLD')} ${mark('NEW')} END',
      );
      _db.execute('CREATE TRIGGER ${table}_del AFTER DELETE ON $table ${only('OLD')}BEGIN ${mark('OLD')} END');
    }

    for (final (table, kind, key, events) in [
      ('habit_months', 'habit_month', "R.year || '-' || R.month", ['INSERT', 'UPDATE']),
      ('todo_history', 'todo_history', "R.day || '/' || R.uid", ['INSERT', 'UPDATE', 'DELETE']),
      ('exercises', 'exercise', 'R.uid', ['INSERT', 'UPDATE', 'DELETE']),
      ('training_sets', 'training_set', 'R.uid', ['INSERT', 'UPDATE', 'DELETE']),
      ('todo_repeats', 'todo_repeat', 'R.uid', ['INSERT', 'UPDATE', 'DELETE']),
    ]) {
      for (final event in events) {
        final row = event == 'DELETE' ? 'OLD' : 'NEW';
        final expr = key.replaceAll('R.', '$row.');
        _db.execute(
          'CREATE TRIGGER ${table}_${event.toLowerCase()} AFTER $event ON $table BEGIN '
          "INSERT INTO sync_dirty VALUES ('$kind', $expr, ${Store._now}) "
          'ON CONFLICT (kind, rowkey) DO UPDATE SET at = excluded.at; END',
        );
      }
    }

    _upgradeV37ToV38();
  }

  void _upgradeV37ToV38() {
    for (final (table, columns) in [
      ('month_habits', ['weekly INTEGER', 'target INTEGER', 'unit TEXT']),
      ('entries', ['amount INTEGER']),
      ('training_sets', ['note TEXT', 'rpe REAL']),
    ]) {
      final present = {for (final row in _db.select('PRAGMA table_info($table)')) row['name']};
      for (final column in columns) {
        if (!present.contains(column.split(' ').first)) _db.execute('ALTER TABLE $table ADD COLUMN $column');
      }
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS routines(uid TEXT PRIMARY KEY, name TEXT NOT NULL, sets TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS weigh_ins(uid TEXT PRIMARY KEY, kg REAL NOT NULL CHECK(kg > 0));
    ''');
    for (final (table, kind) in [('routines', 'routine'), ('weigh_ins', 'weigh_in')]) {
      for (final (event, row) in [('INSERT', 'NEW'), ('UPDATE', 'NEW'), ('DELETE', 'OLD')]) {
        _db.execute(
          'CREATE TRIGGER IF NOT EXISTS ${table}_$event AFTER $event ON $table BEGIN '
          "INSERT INTO sync_dirty VALUES ('$kind', $row.uid, ${Store._now}) "
          'ON CONFLICT(kind,rowkey) DO UPDATE SET at=excluded.at; END',
        );
      }
    }
  }
}
