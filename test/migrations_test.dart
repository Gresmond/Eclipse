import 'dart:io';

import 'package:eclipse/data/store.dart';
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

  test('a fresh database initializes schema v38 atomically with sleep habits and sync triggers', () {
    final store = Store.open(path);
    addTearDown(store.close);
    expect(store.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion);
    expect(store.upgradedFrom, isNull);
    expect(store.addHabit(2026, 11, 'Read').name, 'Read');
    expect(store.sleepHabits(2026, 11).map((h) => h.name), [
      'Rise Early',
      'Unwind',
      'Screen Curfew',
      'Sleep Early',
    ]);
    final indexes = {
      for (final row in store.raw.select("SELECT name FROM sqlite_master WHERE type = 'index'"))
        row['name'] as String,
    };
    expect(
      indexes,
      containsAll(['todos_done_reminders', 'todos_since', 'todos_done_due_date', 'month_habits_habit_id']),
    );
    final triggers = {
      for (final row in store.raw.select("SELECT name FROM sqlite_master WHERE type = 'trigger'"))
        row['name'] as String,
    };
    expect(triggers, containsAll(['todo_history_delete', 'routines_INSERT', 'weigh_ins_INSERT']));
  });

  test('upgrades a v37 database to v38 while preserving existing data', () {
    var store = Store.open(path);
    final habit = store.addHabit(2026, 11, 'Read');
    store.setEntry('2026-11-01', habit.id, HabitStatus.done);
    store.setJournal('2026-11-01', 'Kept entry');
    store.raw.execute('''
      DROP TABLE routines;
      DROP TABLE weigh_ins;
      ALTER TABLE month_habits DROP COLUMN weekly;
      ALTER TABLE month_habits DROP COLUMN target;
      ALTER TABLE month_habits DROP COLUMN unit;
      ALTER TABLE entries DROP COLUMN amount;
      ALTER TABLE training_sets DROP COLUMN note;
      ALTER TABLE training_sets DROP COLUMN rpe;
      PRAGMA user_version = 37;
    ''');
    store.close();

    store = Store.open(path);
    addTearDown(store.close);
    expect(store.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion);
    expect(store.upgradedFrom, 37);
    expect(store.monthHabits(2026, 11).single.name, 'Read');
    expect(store.journal('2026-11-01'), 'Kept entry');
    expect(
      store.raw.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('routines', 'weigh_ins')"),
      hasLength(2),
    );
  });

  test('rejects databases from newer schema versions', () {
    sqlite3.open(path)
      ..execute('PRAGMA user_version = ${Store.schemaVersion + 1}')
      ..close();
    expect(() => Store.open(path), throwsA(isA<DatabaseTooNewException>()));
  });

  test('rejects databases older than v37', () {
    sqlite3.open(path)
      ..execute('PRAGMA user_version = 36')
      ..close();
    expect(() => Store.open(path), throwsStateError);
  });
}
