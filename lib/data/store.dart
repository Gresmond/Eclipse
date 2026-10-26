import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../models.dart';

part 'store_todos.dart';

/// SQLite persistence. Every method writes straight through; AppState keeps
/// an in-memory copy for drawing.
class Store {
  static const schemaVersion = 16;
  Store._(this._db) {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _migrate();
  }

  factory Store.open(String path) {
    final db = sqlite3.open(path);
    try {
      return Store._(db);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  Store.memory() : this._(sqlite3.openInMemory());

  /// The time in milliseconds, in SQL, for sync's triggers.
  static const _now = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

  final Database _db;

  /// The database itself, for the sync engine, which works below the
  /// level of rituals and to-dos.
  Database get raw => _db;

  void close() => _db.close();

  /// Writes a consistent, compacted copy of the whole database to [path].
  /// Written beside it first and renamed, so a crash never leaves half a file.
  void saveCopy(String path) {
    final part = File('$path.part');
    if (part.existsSync()) part.deleteSync();
    _db.execute('VACUUM INTO ?', [part.path]);
    part.renameSync(path);
  }

  /// Replaces everything in this database with the copy at [path].
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
      if (version < 1 || version > schemaVersion) throw StateError('Unsupported backup version: $version');
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
      db.execute('DELETE FROM sync_reg');
      db.execute('DELETE FROM sync_seen');
      final reg = db.prepare('INSERT INTO sync_reg VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
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
        ]);
      }
      reg.close();
      final file = db.prepare('INSERT INTO sync_seen VALUES (?, ?)');
      for (final r in seen) {
        file.execute([r['file'], r['stamp']]);
      }
      file.close();
      db.execute('INSERT OR IGNORE INTO sync_dirty SELECT DISTINCT kind, rowkey, $_now FROM sync_reg');
    });
    target.markAllChanged();
  }

  void _validate() {
    const columns = {
      'habits': 'id, uid',
      'habit_months': 'year, month',
      'month_habits': 'year, month, habit_id, name, position, note, added_on',
      'entries': 'day, habit_id, status, note',
      'todos': 'id, uid, scope, period, text, done, carried, since, due_date, return_to_tomorrow, return_scope, defer_promotion_day, subtasks',
      'todo_history': 'uid, day, snapshot',
      'journal': 'day, text',
      'sleep_habits': 'item, habit_id',
      'sleep_notes': 'year, month, item, note',
      'settings': 'key, value',
      'sync_reg': 'kind, rowkey, field, value, ts, origin, vv, journal_versions',
      'sync_dirty': 'kind, rowkey, at',
      'sync_seen': 'file, stamp',
    };
    for (final e in columns.entries) {
      _db.select('SELECT ${e.value} FROM ${e.key} LIMIT 0');
    }
    if (_db.select('PRAGMA foreign_key_check').isNotEmpty ||
        _db.select('SELECT 1 FROM entries WHERE status NOT BETWEEN 0 AND 3 LIMIT 1').isNotEmpty ||
        _db.select('SELECT 1 FROM habits WHERE uid IS NULL LIMIT 1').isNotEmpty ||
        _db
            .select(
              "SELECT 1 FROM todos WHERE uid IS NULL OR scope NOT IN ('today', 'tomorrow', 'week', 'month') OR done NOT IN (0, 1) LIMIT 1",
            )
            .isNotEmpty ||
        _db.select('SELECT 1 FROM sleep_habits').length != SleepItem.values.length) {
      throw StateError('Backup contains invalid data');
    }
    for (final r in _db.select(
      'SELECT day FROM entries UNION SELECT day FROM journal UNION SELECT since AS day FROM todos '
      'UNION SELECT due_date AS day FROM todos WHERE due_date IS NOT NULL',
    )) {
      final day = r['day'];
      if (!_validDay(day)) throw StateError('Backup contains an invalid date');
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

  static bool _validDay(Object? value) {
    if (value is! String) return false;
    final day = DateTime.tryParse(value);
    return day != null && dateKey(day) == value;
  }

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version > schemaVersion) throw StateError('This database needs a newer version of Eclipse');
    if (version < 1) {
      _db.execute('''
        CREATE TABLE habits (id INTEGER PRIMARY KEY AUTOINCREMENT);

        -- Each month has its own ordered list. habit_id ties a ritual across
        -- months (for streaks); the name can differ per month.
        CREATE TABLE month_habits (
          year INTEGER NOT NULL,
          month INTEGER NOT NULL,
          habit_id INTEGER NOT NULL REFERENCES habits(id),
          name TEXT NOT NULL,
          position INTEGER NOT NULL,
          PRIMARY KEY (year, month, habit_id)
        );

        CREATE TABLE entries (
          day TEXT NOT NULL,
          habit_id INTEGER NOT NULL REFERENCES habits(id),
          status INTEGER NOT NULL,
          note TEXT,
          PRIMARY KEY (day, habit_id)
        );

        -- period: yyyy-mm-dd for today, the Monday's date for week, yyyy-mm
        -- for month. All sort chronologically as strings.
        CREATE TABLE todos (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          scope TEXT NOT NULL,
          period TEXT NOT NULL,
          text TEXT NOT NULL,
          done INTEGER NOT NULL DEFAULT 0,
          carried INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX todos_scope_period ON todos (scope, period);

        CREATE TABLE journal (day TEXT PRIMARY KEY, text TEXT NOT NULL);

        PRAGMA user_version = 1;
      ''');
    }
    if (version < 2) {
      _db.execute('''
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        PRAGMA user_version = 2;
      ''');
    }
    if (version < 3) {
      transaction(() {
        _db.execute('''
          -- The sleep schedule's habits, by SleepItem name. In every month,
          -- so not in month_habits.
          CREATE TABLE sleep_habits (
            item TEXT PRIMARY KEY,
            habit_id INTEGER NOT NULL REFERENCES habits(id)
          )
        ''');
        // Rituals the sleep schedule replaces. These three keep their
        // history and streaks; Unwind starts fresh.
        const carried = {
          SleepItem.riseEarly: 'Get up at%',
          SleepItem.screenCurfew: 'Screens, shower%',
          SleepItem.sleepEarly: 'Bed by%',
        };
        for (final item in SleepItem.values) {
          final match = carried[item] == null
              ? const <Row>[]
              : _db.select(
                  'SELECT habit_id FROM month_habits WHERE name LIKE ? ORDER BY year DESC, month DESC LIMIT 1',
                  [carried[item]],
                );
          final int id;
          if (match.isNotEmpty) {
            id = match.first['habit_id'] as int;
          } else {
            _db.execute('INSERT INTO habits DEFAULT VALUES');
            id = _db.lastInsertRowId;
          }
          _db.execute('INSERT INTO sleep_habits (item, habit_id) VALUES (?, ?)', [item.name, id]);
          _db.execute('DELETE FROM month_habits WHERE habit_id = ?', [id]);
        }
        // Unwind covers these; their marks stay in entries, unseen.
        _db.execute("DELETE FROM month_habits WHERE name LIKE 'Wind down%' OR name IN ('Journal', 'Meditate')");
        _db.execute('PRAGMA user_version = 3');
      });
    }
    if (version < 4) {
      _db.execute('''
        -- A ritual's note, shown on hover. On the habit, not the month, so it
        -- follows the ritual through every month.
        ALTER TABLE habits ADD COLUMN note TEXT;
        PRAGMA user_version = 4;
      ''');
    }
    if (version < 5) {
      transaction(() {
        _db.execute('''
          -- Notes belong to a month, like names: a new month copies them, and
          -- an edit changes only its own month. Each month keeps the note it
          -- had.
          ALTER TABLE month_habits ADD COLUMN note TEXT;
          UPDATE month_habits SET note = (SELECT note FROM habits WHERE id = habit_id);
          ALTER TABLE habits DROP COLUMN note;
          PRAGMA user_version = 5;
        ''');
      });
    }
    if (version < 6) {
      transaction(() {
        _db.execute('''
          -- The day a to-do was added. With period (the last day, week or
          -- month it was on) it says which lists it was on. Older items get
          -- a guess, one period back per carry.
          ALTER TABLE todos ADD COLUMN since TEXT;
          UPDATE todos SET since = CASE scope
            WHEN 'today' THEN date(period, '-' || carried || ' days')
            WHEN 'week' THEN date(period, '-' || (7 * carried) || ' days')
            ELSE date(period || '-01', '-' || carried || ' months')
          END;
          PRAGMA user_version = 6;
        ''');
      });
    }
    if (version < 7) {
      _db.execute('''
        -- Your own text for a sleep item's tooltip, from this month on until
        -- a later month has its own. Empty: show just the name.
        CREATE TABLE sleep_notes (
          year INTEGER NOT NULL,
          month INTEGER NOT NULL,
          item TEXT NOT NULL,
          note TEXT NOT NULL,
          PRIMARY KEY (year, month, item)
        );
        PRAGMA user_version = 7;
      ''');
    }
    if (version < 8) {
      transaction(() {
        _db.execute('''
          -- Ids that mean the same ritual or to-do on every computer. Rows
          -- from before get one made from their id, so a backup from before
          -- names them the same way; the sleep schedule's are the same on
          -- every install.
          ALTER TABLE habits ADD COLUMN uid TEXT;
          UPDATE habits SET uid = 'h' || id;
          UPDATE habits SET uid = 'sleep-' || (SELECT item FROM sleep_habits WHERE habit_id = habits.id)
            WHERE id IN (SELECT habit_id FROM sleep_habits);
          CREATE UNIQUE INDEX habits_uid ON habits (uid);
          ALTER TABLE todos ADD COLUMN uid TEXT;
          UPDATE todos SET uid = 't' || id;
          CREATE UNIQUE INDEX todos_uid ON todos (uid);

          -- Sync. Each field of each row is a register: its value, when and
          -- where it was last set, and a version per computer, which says
          -- whether two edits saw each other.
          CREATE TABLE sync_reg (
            kind TEXT NOT NULL,
            rowkey TEXT NOT NULL,
            field TEXT NOT NULL,
            value TEXT,
            ts INTEGER NOT NULL,
            origin TEXT NOT NULL,
            vv TEXT NOT NULL,
            PRIMARY KEY (kind, rowkey, field)
          ) WITHOUT ROWID;
          CREATE INDEX sync_reg_origin ON sync_reg (origin, ts);

          -- Rows written since sync last looked, and when, filled by the
          -- triggers below.
          CREATE TABLE sync_dirty (
            kind TEXT NOT NULL,
            rowkey TEXT NOT NULL,
            at INTEGER NOT NULL,
            PRIMARY KEY (kind, rowkey)
          ) WITHOUT ROWID;

          -- Other computers' change files already read, by size and time.
          CREATE TABLE sync_seen (file TEXT PRIMARY KEY, stamp TEXT NOT NULL);
        ''');
        const habit = "(SELECT uid FROM habits WHERE id = R.habit_id)";
        final keys = {
          'month_habit': ('month_habits', "R.year || '-' || R.month || '/' || $habit", null),
          'entry': ('entries', "R.day || '/' || $habit", null),
          'todo': ('todos', 'R.uid', null),
          'journal': ('journal', 'R.day', null),
          'sleep_note': ('sleep_notes', "R.year || '-' || R.month || '/' || R.item", null),
          'setting': ('settings', 'R.key', 'R.key IN (${syncedSettings.map((k) => "'$k'").join(', ')})'),
        };
        for (final MapEntry(key: kind, value: (table, rowkey, filter)) in keys.entries) {
          // Not INSERT OR IGNORE: an upsert's own conflict handling overrides
          // a trigger's.
          String mark(String row) {
            final key = rowkey.replaceAll('R.', '$row.');
            return "UPDATE sync_dirty SET at = $_now WHERE kind = '$kind' AND rowkey = $key; "
                "INSERT INTO sync_dirty SELECT '$kind', $key, $_now "
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
        _db.execute('PRAGMA user_version = 8');
      });
    }
    if (version < 9) {
      transaction(() {
        _db.execute('''
          ALTER TABLE sync_reg ADD COLUMN journal_versions TEXT;
          CREATE TABLE habit_months (year INTEGER NOT NULL, month INTEGER NOT NULL,
            PRIMARY KEY (year, month));
          INSERT INTO habit_months SELECT DISTINCT year, month FROM month_habits;
          CREATE TABLE todo_history (uid TEXT NOT NULL, day TEXT NOT NULL, snapshot TEXT NOT NULL,
            PRIMARY KEY (uid, day));
          CREATE INDEX todo_history_day ON todo_history(day);
          CREATE INDEX entries_habit_day ON entries(habit_id, day);
          CREATE INDEX sleep_notes_item_month ON sleep_notes(item, year * 12 + month);
        ''');
        // Tombstones can recover intentionally empty months from older sync.
        for (final r in _db.select(
          "SELECT DISTINCT substr(rowkey, 1, instr(rowkey, '/') - 1) AS m FROM sync_reg WHERE kind = 'month_habit'",
        )) {
          final parts = (r['m'] as String).split('-');
          if (parts.length == 2) initializeMonth(int.parse(parts[0]), int.parse(parts[1]));
        }
        for (final (table, kind, key) in [
          ('habit_months', 'habit_month', "NEW.year || '-' || NEW.month"),
          ('todo_history', 'todo_history', "NEW.day || '/' || NEW.uid"),
        ]) {
          for (final event in ['INSERT', 'UPDATE']) {
            _db.execute(
              'CREATE TRIGGER ${table}_${event.toLowerCase()} AFTER $event ON $table BEGIN '
              "INSERT INTO sync_dirty VALUES ('$kind', $key, $_now) "
              'ON CONFLICT (kind, rowkey) DO UPDATE SET at = excluded.at; END',
            );
          }
        }
        _db.execute('PRAGMA user_version = 9');
      });
    }
    if (version < 10) {
      if (!_db.select('PRAGMA table_info(todos)').any((r) => r['name'] == 'due_date')) {
        _db.execute('ALTER TABLE todos ADD COLUMN due_date TEXT');
      }
      _db.execute('PRAGMA user_version = 10');
    }
    if (version < 11) {
      if (!_db.select('PRAGMA table_info(todos)').any((r) => r['name'] == 'return_to_tomorrow')) {
        _db.execute('ALTER TABLE todos ADD COLUMN return_to_tomorrow INTEGER NOT NULL DEFAULT 0');
      }
      _db.execute('PRAGMA user_version = 11');
    }
    if (version < 12) {
      if (!_db.select('PRAGMA table_info(todos)').any((r) => r['name'] == 'return_scope')) {
        _db.execute('ALTER TABLE todos ADD COLUMN return_scope TEXT');
        _db.execute("UPDATE todos SET return_scope = 'tomorrow' WHERE return_to_tomorrow = 1");
      }
      if (!_db.select('PRAGMA table_info(todos)').any((r) => r['name'] == 'defer_promotion_day')) {
        _db.execute('ALTER TABLE todos ADD COLUMN defer_promotion_day TEXT');
      }
      _db.execute('PRAGMA user_version = 12');
    }
    if (version < 13) {
      if (!_db.select('PRAGMA table_info(todos)').any((r) => r['name'] == 'subtasks')) {
        _db.execute("ALTER TABLE todos ADD COLUMN subtasks TEXT NOT NULL DEFAULT '[]'");
      }
      _db.execute('PRAGMA user_version = 13');
    }
    if (version < 14) {
      if (!_db.select('PRAGMA table_info(month_habits)').any((r) => r['name'] == 'added_on')) {
        _db.execute('ALTER TABLE month_habits ADD COLUMN added_on TEXT');
      }
      _db.execute('PRAGMA user_version = 14');
    }
    // Re-run the text migration for version 15 installs too: that version
    // only converted measurement marks, leaving dialogue quotes straight.
    if (version < 16) {
      transaction(() {
        for (final table in ['month_habits', 'entries', 'journal', 'todos', 'sleep_notes']) {
          final fields = switch (table) {
            'month_habits' => ['name', 'note'],
            'entries' || 'sleep_notes' => ['note'],
            _ => ['text'],
          };
          for (final row in _db.select('SELECT rowid AS format_row_id, ${fields.join(', ')} FROM $table')) {
            for (final field in fields) {
              final old = row[field] as String?;
              if (old == null) continue;
              final text = normaliseNote(old);
              if (text != old) {
                _db.execute('UPDATE $table SET $field = ? WHERE rowid = ?', [text, row['format_row_id']]);
              }
            }
          }
        }
        for (final row in _db.select('SELECT id, subtasks FROM todos')) {
          final children = TodoSubtask.decode(row['subtasks'] as String?);
          final text = TodoSubtask.encode([
            for (final child in children) TodoSubtask(normaliseNote(child.text), done: child.done),
          ]);
          if (text != row['subtasks']) _db.execute('UPDATE todos SET subtasks = ? WHERE id = ?', [text, row['id']]);
        }
        for (final row in _db.select('SELECT uid, day, snapshot FROM todo_history')) {
          final snapshot = jsonDecode(row['snapshot'] as String) as Map<String, dynamic>;
          if (snapshot['text'] is String) snapshot['text'] = normaliseNote(snapshot['text'] as String);
          snapshot['subtasks'] = TodoSubtask.encode([
            for (final child in TodoSubtask.decode(snapshot['subtasks'] as String?))
              TodoSubtask(normaliseNote(child.text), done: child.done),
          ]);
          _db.execute('UPDATE todo_history SET snapshot = ? WHERE uid = ? AND day = ?', [
            jsonEncode(snapshot),
            row['uid'],
            row['day'],
          ]);
        }
        _db.execute('PRAGMA user_version = 16');
      });
    }
  }

  /// Settings that are the same on every computer. The theme isn't: each
  /// follows its own night light.
  static const syncedSettings = ['dayStartHour', 'restWeekends'];

  /// Marks every row as changed, for sync to compare with what it knows.
  void markAllChanged() {
    _db.execute('''
      INSERT OR IGNORE INTO sync_dirty SELECT *, $_now FROM (
        SELECT 'month_habit', year || '-' || month || '/' || h.uid FROM month_habits JOIN habits h ON h.id = habit_id
        UNION ALL SELECT 'habit_month', year || '-' || month FROM habit_months
        UNION ALL SELECT 'todo_history', day || '/' || uid FROM todo_history
        UNION ALL SELECT 'entry', day || '/' || h.uid FROM entries JOIN habits h ON h.id = habit_id
        UNION ALL SELECT 'todo', uid FROM todos
        UNION ALL SELECT 'journal', day FROM journal
        UNION ALL SELECT 'sleep_note', year || '-' || month || '/' || item FROM sleep_notes
        UNION ALL SELECT 'setting', key FROM settings WHERE key IN (${syncedSettings.map((k) => "'$k'").join(', ')})
      )
    ''');
  }

  // Habits

  bool hasMonth(int year, int month) =>
      _db.select('SELECT 1 FROM habit_months WHERE year = ? AND month = ?', [year, month]).isNotEmpty;

  void initializeMonth(int year, int month) =>
      _db.execute('INSERT INTO habit_months VALUES (?, ?) ON CONFLICT DO NOTHING', [year, month]);

  /// No ritual has ever been added (the sleep schedule doesn't count).
  bool get isEmpty =>
      _db.select('SELECT 1 FROM habit_months LIMIT 1').isEmpty &&
      _db.select('SELECT 1 FROM habits WHERE id NOT IN (SELECT habit_id FROM sleep_habits) LIMIT 1').isEmpty;

  /// The sleep schedule as it reads in a month: each item's time is the
  /// one set for that month, or the nearest month before with its own, or
  /// the original time.
  List<Habit> sleepHabits(int year, int month) {
    final ids = {
      for (final r in _db.select('SELECT item, habit_id FROM sleep_habits')) r['item'] as String: r['habit_id'] as int,
    };
    return [
      for (final item in SleepItem.values)
        Habit(
          ids[item.name]!,
          item.label,
          minutes: switch (sleepNote(year, month, item)) {
            null => item.minutes,
            final note => parseClock(note),
          },
        ),
    ];
  }

  /// The time saved for [item] in force in this month ("21:00", empty for
  /// none, or a note from before times were picked); null if never set.
  /// With [own], only what was set for this very month.
  String? sleepNote(int year, int month, SleepItem item, {bool own = false}) {
    final r = _db.select(
      'SELECT note FROM sleep_notes WHERE item = ? AND year * 12 + month ${own ? '=' : '<='} ? '
      'ORDER BY year * 12 + month DESC LIMIT 1',
      [item.name, year * 12 + month],
    );
    return r.isEmpty ? null : r.first['note'] as String;
  }

  void setSleepNote(int year, int month, SleepItem item, String note) {
    _db.execute(
      'INSERT INTO sleep_notes (year, month, item, note) VALUES (?, ?, ?, ?) '
      'ON CONFLICT (year, month, item) DO UPDATE SET note = excluded.note',
      [year, month, item.name, note],
    );
  }

  List<Habit> monthHabits(int year, int month) => [
    for (final r in _db.select(
      'SELECT habit_id, name, note, added_on FROM month_habits WHERE year = ? AND month = ? ORDER BY position',
      [year, month],
    ))
      Habit(
        r['habit_id'] as int,
        r['name'] as String,
        description: r['note'] as String?,
        addedOn: DateTime.tryParse(r['added_on'] as String? ?? ''),
      ),
  ];

  /// The closest month that has a ritual list, preferring earlier months.
  (int, int)? nearestMonthWithHabits(int year, int month) {
    final index = year * 12 + month;
    for (final (cmp, order) in [('<', 'DESC'), ('>', 'ASC')]) {
      final r = _db.select(
        'SELECT year, month FROM habit_months WHERE year * 12 + month $cmp ? '
        'ORDER BY year * 12 + month $order LIMIT 1',
        [index],
      );
      if (r.isNotEmpty) return (r.first['year'] as int, r.first['month'] as int);
    }
    return null;
  }

  /// Whether the ritual was on any month's list before [year].
  bool habitBeforeYear(int habitId, int year) =>
      _db.select('SELECT 1 FROM month_habits WHERE habit_id = ? AND year < ? LIMIT 1', [habitId, year]).isNotEmpty;

  void copyMonth((int, int) from, (int, int) to) {
    initializeMonth(to.$1, to.$2);
    _db.execute(
      'INSERT INTO month_habits (year, month, habit_id, name, position, note) '
      'SELECT ?, ?, habit_id, name, position, note FROM month_habits WHERE year = ? AND month = ?',
      [to.$1, to.$2, from.$1, from.$2],
    );
  }

  Habit addHabit(int year, int month, String name, {DateTime? addedOn}) {
    initializeMonth(year, month);
    _db.execute('INSERT INTO habits (uid) VALUES (lower(hex(randomblob(8))))');
    final id = _db.lastInsertRowId;
    _db.execute(
      'INSERT INTO month_habits (year, month, habit_id, name, position, added_on) VALUES (?, ?, ?, ?, '
      '(SELECT COALESCE(MAX(position) + 1, 0) FROM month_habits WHERE year = ? AND month = ?), ?)',
      [year, month, id, name, year, month, addedOn == null ? null : dateKey(addedOn)],
    );
    return Habit(id, name, addedOn: addedOn);
  }

  void renameHabit(int year, int month, int habitId, String name) {
    _db.execute('UPDATE month_habits SET name = ? WHERE year = ? AND month = ? AND habit_id = ?', [
      name,
      year,
      month,
      habitId,
    ]);
  }

  void setHabitNote(int year, int month, int habitId, String? note) {
    _db.execute('UPDATE month_habits SET note = ? WHERE year = ? AND month = ? AND habit_id = ?', [
      note,
      year,
      month,
      habitId,
    ]);
  }

  void removeHabit(int year, int month, int habitId) {
    _db.execute('DELETE FROM month_habits WHERE year = ? AND month = ? AND habit_id = ?', [year, month, habitId]);
  }

  void reorderHabits(int year, int month, List<int> habitIds) {
    transaction(() {
      for (final (i, id) in habitIds.indexed) {
        _db.execute('UPDATE month_habits SET position = ? WHERE year = ? AND month = ? AND habit_id = ?', [
          i,
          year,
          month,
          id,
        ]);
      }
    });
  }

  // Entries

  Map<int, (int, int)> monthScores(int year, int month) => {
    for (final row in _db.select(
      // Days before a ritual was added that month don't count towards it.
      'SELECT e.habit_id, SUM(e.status = 1) AS done, SUM(e.status != 0) AS logged FROM entries e '
      'LEFT JOIN month_habits m ON m.year = ? AND m.month = ? AND m.habit_id = e.habit_id '
      'WHERE e.day >= ? AND e.day < ? AND (m.added_on IS NULL OR e.day >= m.added_on) GROUP BY e.habit_id',
      [year, month, dateKey(DateTime(year, month)), dateKey(DateTime(year, month + 1))],
    ))
      row['habit_id'] as int: (row['done'] as int, row['logged'] as int),
  };

  Iterable<({String day, int habitId, HabitStatus status, String? note})> entriesInMonth(int year, int month) => _db
      .select('SELECT day, habit_id, status, note FROM entries WHERE day >= ? AND day < ?', [
        dateKey(DateTime(year, month)),
        dateKey(DateTime(year, month + 1)),
      ])
      .map(
        (r) => (
          day: r['day'] as String,
          habitId: r['habit_id'] as int,
          status: HabitStatus.values[r['status'] as int],
          note: r['note'] as String?,
        ),
      );

  /// Work proportional to logged entries, rather than every calendar day.
  (int, int) streaks(int habitId, DateTime today, {required bool restWeekends}) {
    bool gapBreaks(DateTime from, DateTime until) {
      final gap =
          DateTime.utc(
            until.year,
            until.month,
            until.day,
          ).difference(DateTime.utc(from.year, from.month, from.day)).inDays -
          1;
      if (gap <= 0) return false;
      if (!restWeekends || gap > 2) return true;
      for (var i = 1; i <= gap; i++) {
        if (DateTime(from.year, from.month, from.day + i).weekday < DateTime.saturday) return true;
      }
      return false;
    }

    var run = 0, best = 0;
    DateTime? previous;
    for (final r in _db.select('SELECT day, status FROM entries WHERE habit_id = ? AND day <= ? ORDER BY day', [
      habitId,
      dateKey(today),
    ])) {
      final day = DateTime.parse(r['day'] as String);
      final status = HabitStatus.values[r['status'] as int];
      if (day == today && status == HabitStatus.none) continue;
      if (previous != null && gapBreaks(previous, day)) run = 0;
      if (status == HabitStatus.done) {
        run++;
        if (run > best) best = run;
      } else if (status != HabitStatus.other && !(status == HabitStatus.none && restWeekends && day.weekday >= 6)) {
        run = 0;
      }
      previous = day;
    }
    if (previous != null && gapBreaks(previous, today)) run = 0;
    return (run, best);
  }

  void setEntry(String day, int habitId, HabitStatus status, {bool clearNote = false}) {
    if (status == HabitStatus.none) {
      _db.execute('DELETE FROM entries WHERE day = ? AND habit_id = ?', [day, habitId]);
      return;
    }
    _db.execute(
      'INSERT INTO entries (day, habit_id, status) VALUES (?, ?, ?) '
      'ON CONFLICT (day, habit_id) DO UPDATE SET status = excluded.status, '
      'note = CASE WHEN ? THEN NULL ELSE entries.note END',
      [day, habitId, status.index, clearNote ? 1 : 0],
    );
  }

  void setNote(String day, int habitId, String? note) {
    _db.execute('UPDATE entries SET note = ? WHERE day = ? AND habit_id = ?', [note, day, habitId]);
  }

  // Settings

  String? setting(String key) {
    final r = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void setSetting(String key, String value) {
    _db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  // Journal

  Iterable<({String day, String text})> journalEntries({String? after, int? limit}) => _db
      .select('SELECT day, text FROM journal WHERE day > ? ORDER BY day LIMIT ?', [after ?? '', limit ?? -1])
      .map((r) => (day: r['day'] as String, text: r['text'] as String));

  String journal(String day) {
    final r = _db.select('SELECT text FROM journal WHERE day = ?', [day]);
    return r.isEmpty ? '' : r.first['text'] as String;
  }

  void setJournal(String day, String text) {
    if (text.trim().isEmpty) {
      _db.execute('DELETE FROM journal WHERE day = ?', [day]);
    } else {
      _db.execute(
        'INSERT INTO journal (day, text) VALUES (?, ?) '
        'ON CONFLICT (day) DO UPDATE SET text = excluded.text',
        [day, text],
      );
    }
  }

  /// Runs [body] atomically; nested calls are part of the outer one.
  T transaction<T>(T Function() body) {
    _db.execute('SAVEPOINT store_write');
    try {
      final result = body();
      _db.execute('RELEASE store_write');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK TO store_write');
      _db.execute('RELEASE store_write');
      rethrow;
    }
  }
}
