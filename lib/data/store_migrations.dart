part of 'store.dart';

/// Brings an older database up to [Store.schemaVersion].
extension on Store {
  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version > Store.schemaVersion) throw StateError('This database needs a newer version of Eclipse');
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
          'setting': ('settings', 'R.key', 'R.key IN (${Store.syncedSettings.map((k) => "'$k'").join(', ')})'),
        };
        for (final MapEntry(key: kind, value: (table, rowkey, filter)) in keys.entries) {
          // Not INSERT OR IGNORE: an upsert's own conflict handling overrides
          // a trigger's.
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
              "INSERT INTO sync_dirty VALUES ('$kind', $key, ${Store._now}) "
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
            for (final child in children) child.copyWith(text: normaliseNote(child.text)),
          ]);
          if (text != row['subtasks']) _db.execute('UPDATE todos SET subtasks = ? WHERE id = ?', [text, row['id']]);
        }
        for (final row in _db.select('SELECT uid, day, snapshot FROM todo_history')) {
          final snapshot = jsonDecode(row['snapshot'] as String) as Map<String, dynamic>;
          if (snapshot['text'] is String) snapshot['text'] = normaliseNote(snapshot['text'] as String);
          snapshot['subtasks'] = TodoSubtask.encode([
            for (final child in TodoSubtask.decode(snapshot['subtasks'] as String?))
              child.copyWith(text: normaliseNote(child.text)),
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
    if (version < 17) {
      if (!_db.select('PRAGMA table_info(todos)').any((r) => r['name'] == 'done_at')) {
        _db.execute('ALTER TABLE todos ADD COLUMN done_at TEXT');
      }
      _db.execute('PRAGMA user_version = 17');
    }
    if (version < 18) {
      if (!_db.select('PRAGMA table_info(month_habits)').any((r) => r['name'] == 'days')) {
        _db.execute('ALTER TABLE month_habits ADD COLUMN days TEXT');
      }
      _db.execute('PRAGMA user_version = 18');
    }
    // Version 19 moved every ritual to weekdays only while weekends were
    // rest days, and a build that dropped ritual days entirely took version
    // 20 for removing the column. Either way, every ritual starts on every
    // day again, with the column back where it was dropped; days are only
    // what you choose.
    if (version < 21) {
      transaction(() {
        if (_db.select('PRAGMA table_info(month_habits)').any((r) => r['name'] == 'days')) {
          _db.execute('UPDATE month_habits SET days = NULL WHERE days IS NOT NULL');
        } else {
          _db.execute('ALTER TABLE month_habits ADD COLUMN days TEXT');
        }
        _db.execute('PRAGMA user_version = 21');
      });
    }
    if (version < 22) {
      transaction(() {
        _db.execute('''
          -- Gym training: your exercises, and every set you log of them.
          CREATE TABLE IF NOT EXISTS exercises (
            uid TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            muscle TEXT NOT NULL,
            bodyweight INTEGER NOT NULL DEFAULT 0
          );
          CREATE TABLE IF NOT EXISTS training_sets (
            uid TEXT PRIMARY KEY,
            day TEXT NOT NULL,
            exercise TEXT NOT NULL,
            position INTEGER NOT NULL,
            weight REAL,
            reps INTEGER NOT NULL
          );
          CREATE INDEX IF NOT EXISTS training_sets_day ON training_sets(day);
        ''');
        for (final (table, kind) in [('exercises', 'exercise'), ('training_sets', 'training_set')]) {
          for (final (event, row) in [('INSERT', 'NEW'), ('UPDATE', 'NEW'), ('DELETE', 'OLD')]) {
            _db.execute(
              'CREATE TRIGGER IF NOT EXISTS ${table}_${event.toLowerCase()} AFTER $event ON $table BEGIN '
              "INSERT INTO sync_dirty VALUES ('$kind', $row.uid, ${Store._now}) "
              'ON CONFLICT (kind, rowkey) DO UPDATE SET at = excluded.at; END',
            );
          }
        }
        _db.execute('PRAGMA user_version = 22');
      });
    }
    // Version 23 changes nothing itself: upgrading to it runs the check below
    // once, sending the ritual days that versions 20 and 21 changed without
    // sync seeing.
    if (version < 23) _db.execute('PRAGMA user_version = 23');
    // Version 24 puts every ritual back on every day, in every month, once.
    // Through the sync triggers, so the other computer follows.
    if (version < 24) {
      transaction(() {
        _db.execute('UPDATE month_habits SET days = NULL WHERE days IS NOT NULL');
        _db.execute('PRAGMA user_version = 24');
      });
    }
    // Version 25 takes rituals out of months before the one they were added
    // in, where copying a later month's list back had put them.
    if (version < 25) {
      transaction(() {
        _db.execute('''
          DELETE FROM month_habits WHERE EXISTS (
            SELECT 1 FROM month_habits a WHERE a.habit_id = month_habits.habit_id AND a.added_on IS NOT NULL
              AND a.year * 12 + a.month > month_habits.year * 12 + month_habits.month)
        ''');
        _db.execute('PRAGMA user_version = 25');
      });
    }
    if (version < 26) {
      _db.execute('''
        -- What a day start moved on this computer, field by field: the
        -- value it left, which sync doesn't send as an edit.
        CREATE TABLE IF NOT EXISTS sync_local (
          kind TEXT NOT NULL,
          rowkey TEXT NOT NULL,
          field TEXT NOT NULL,
          value TEXT NOT NULL,
          PRIMARY KEY (kind, rowkey, field)
        ) WITHOUT ROWID;
        PRAGMA user_version = 26;
      ''');
    }
    if (version < 27) {
      transaction(() {
        // Each of this computer's edits gets a number, always higher than
        // the last, whatever the clock does: what's been sent counts in them.
        // Until now an edit's time was its number.
        if (!_db.select('PRAGMA table_info(sync_reg)').any((c) => c['name'] == 'seq')) {
          _db.execute('ALTER TABLE sync_reg ADD COLUMN seq INTEGER NOT NULL DEFAULT 0');
          _db.execute('UPDATE sync_reg SET seq = ts');
        }
        _db.execute('CREATE INDEX IF NOT EXISTS sync_reg_seq ON sync_reg (origin, seq)');
        _db.execute('PRAGMA user_version = 27');
      });
    }
    if (version < 28) {
      transaction(() {
        _db.execute('''
          -- Repeating tasks: each time one comes round is an ordinary to-do,
          -- made a week ahead (see StoreTodos.makeRepeats).
          CREATE TABLE IF NOT EXISTS todo_repeats (
            uid TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            rule TEXT NOT NULL,
            start TEXT NOT NULL,
            until TEXT
          );
        ''');
        for (final (event, row) in [('INSERT', 'NEW'), ('UPDATE', 'NEW'), ('DELETE', 'OLD')]) {
          _db.execute(
            'CREATE TRIGGER IF NOT EXISTS todo_repeats_${event.toLowerCase()} AFTER $event ON todo_repeats BEGIN '
            "INSERT INTO sync_dirty VALUES ('todo_repeat', $row.uid, ${Store._now}) "
            'ON CONFLICT (kind, rowkey) DO UPDATE SET at = excluded.at; END',
          );
        }
        _db.execute('PRAGMA user_version = 28');
      });
    }
    if (version < 29) {
      transaction(() {
        // A task's time of day ('15:30') and category; a repeat gives its
        // times both.
        for (final (table, column) in [
          ('todos', 'due_time'),
          ('todos', 'category'),
          ('todo_repeats', 'time'),
          ('todo_repeats', 'category'),
        ]) {
          if (!_db.select('PRAGMA table_info($table)').any((r) => r['name'] == column)) {
            _db.execute('ALTER TABLE $table ADD COLUMN $column TEXT');
          }
        }
        _db.execute('PRAGMA user_version = 29');
      });
    }
    if (version < 30) {
      transaction(() {
        // Where an open task was dragged to among its day's others: they
        // sort by it within their group; null for none, after the rest.
        if (!_db.select('PRAGMA table_info(todos)').any((r) => r['name'] == 'position')) {
          _db.execute('ALTER TABLE todos ADD COLUMN position INTEGER');
        }
        _db.execute('PRAGMA user_version = 30');
      });
    }
    if (version < 31) {
      transaction(() {
        // Which reminders a task gives, as Reminder bits; a repeat gives
        // its times them.
        for (final table in ['todos', 'todo_repeats']) {
          if (!_db.select('PRAGMA table_info($table)').any((r) => r['name'] == 'reminders')) {
            _db.execute('ALTER TABLE $table ADD COLUMN reminders INTEGER');
          }
        }
        _db.execute('PRAGMA user_version = 31');
      });
    }

    if (version >= 1 && version < Store.schemaVersion) upgradedFrom = version;
    // Versions before 25 changed synced rows where the sync triggers
    // couldn't see it (a column dropped and added back), so upgrading from
    // one compares every row with what sync last sent and sends what
    // differs. Since then, a migration that changes synced rows does it
    // through the triggers (weakly, see [weak]), and sync takes in what an
    // older version couldn't keep rather than sending its blanks (see
    // SyncEngine.fields); comparing every row would send each day start.
    if (version >= 1 && version < 25) {
      transaction(() {
        _db.execute('INSERT OR IGNORE INTO sync_dirty SELECT DISTINCT kind, rowkey, ${Store._now} FROM sync_reg');
        markAllChanged();
      });
    }
  }
}
