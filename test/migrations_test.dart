import 'dart:convert';
import 'dart:io';

import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('eclipse_migrations');
    path = '${dir.path}/productivity.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a first run cut short part way through doesn\'t lock the database for good', () {
    // Version 1's statements once ran one at a time outside a transaction:
    // a crash after the first left this.
    sqlite3.open(path)
      ..execute('CREATE TABLE habits (id INTEGER PRIMARY KEY AUTOINCREMENT)')
      ..close();
    final store = Store.open(path);
    addTearDown(store.close);
    expect(store.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion);
    expect(store.addHabit(2026, 11, 'Read').name, 'Read');
  });

  test('the first steps made but their version not set run again', () {
    // Each of versions 1, 2, 4 and 7 cut short after its tables or column
    // were made, before the version was set.
    final db = sqlite3.open(path)
      ..execute('''
        CREATE TABLE habits (id INTEGER PRIMARY KEY AUTOINCREMENT);
        CREATE TABLE month_habits (year INTEGER NOT NULL, month INTEGER NOT NULL,
          habit_id INTEGER NOT NULL REFERENCES habits(id), name TEXT NOT NULL, position INTEGER NOT NULL,
          PRIMARY KEY (year, month, habit_id));
        CREATE TABLE entries (day TEXT NOT NULL, habit_id INTEGER NOT NULL REFERENCES habits(id),
          status INTEGER NOT NULL, note TEXT, PRIMARY KEY (day, habit_id));
        CREATE TABLE todos (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, period TEXT NOT NULL,
          text TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, carried INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX todos_scope_period ON todos (scope, period);
        CREATE TABLE journal (day TEXT PRIMARY KEY, text TEXT NOT NULL);
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        PRAGMA user_version = 1;
      ''');
    db.close();
    expect(() => Store.open(path).close(), returnsNormally, reason: 'version 2 again');
    for (final (version, made) in [
      (3, 'ALTER TABLE habits ADD COLUMN note TEXT'),
      (
        6,
        'CREATE TABLE sleep_notes (year INTEGER NOT NULL, month INTEGER NOT NULL, item TEXT NOT NULL, '
            'note TEXT NOT NULL, PRIMARY KEY (year, month, item))',
      ),
    ]) {
      final file = '${dir.path}/v$version.db';
      final before = sqlite3.open(file);
      // Version 1 to [version] as they were, then the next step's start.
      before.execute('''
        CREATE TABLE habits (id INTEGER PRIMARY KEY AUTOINCREMENT);
        CREATE TABLE month_habits (year INTEGER NOT NULL, month INTEGER NOT NULL,
          habit_id INTEGER NOT NULL REFERENCES habits(id), name TEXT NOT NULL, position INTEGER NOT NULL,
          PRIMARY KEY (year, month, habit_id));
        CREATE TABLE entries (day TEXT NOT NULL, habit_id INTEGER NOT NULL REFERENCES habits(id),
          status INTEGER NOT NULL, note TEXT, PRIMARY KEY (day, habit_id));
        CREATE TABLE todos (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, period TEXT NOT NULL,
          text TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, carried INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE journal (day TEXT PRIMARY KEY, text TEXT NOT NULL);
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE sleep_habits (item TEXT PRIMARY KEY, habit_id INTEGER NOT NULL REFERENCES habits(id));
      ''');
      if (version == 6) {
        before.execute('''
          ALTER TABLE month_habits ADD COLUMN note TEXT;
          ALTER TABLE todos ADD COLUMN since TEXT;
        ''');
      }
      before
        ..execute(made)
        ..execute('PRAGMA user_version = $version')
        ..close();
      final store = Store.open(file);
      expect(store.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion, reason: 'from $version');
      store.close();
    }
  });

  test('rebuilding the settings triggers keeps pending changes and sees holidays', () {
    var store = Store.open(path);
    final engine = SyncEngine(store, 'pc')..claimAll();
    store.setSetting('restWeekends', '1');
    final pending = store.raw.select('SELECT kind, rowkey FROM sync_dirty').length;
    expect(pending, greaterThan(0));
    store.raw.execute('PRAGMA user_version = 32');
    store.close();
    store = Store.open(path);
    addTearDown(store.close);
    expect(store.raw.select('SELECT kind, rowkey FROM sync_dirty').length, pending);
    store.setSetting('holidays', '[["2026-12-20","2026-12-27"]]');
    store.setSetting('theme', 'Sunrise');
    expect(
      {for (final r in store.raw.select("SELECT rowkey FROM sync_dirty WHERE kind = 'setting'")) r['rowkey']},
      {'restWeekends', 'holidays'},
    );
    expect(engine.me, 'pc');
  });

  test('upgrading to 34 takes in the holidays a newer computer sent one by one', () {
    var store = Store.open(path);
    SyncEngine(store, 'pc').claimAll();
    // Kept only as registers while this computer was on version 33.
    store.raw.execute(
      'INSERT INTO sync_reg (kind, rowkey, field, value, ts, origin, vv, seq) VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
      [
        'holiday',
        '2026-12-20/2026-12-27',
        '_',
        'true',
        9000000,
        'laptop',
        jsonEncode({'laptop': 3}),
      ],
    );
    store.raw.execute('PRAGMA user_version = 33');
    store.close();
    store = Store.open(path);
    addTearDown(store.close);
    SyncEngine(store, 'pc');
    expect(decodeHolidays(store.setting('holidays')), [(start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 27))]);
  });
}
