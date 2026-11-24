import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/app_log.dart';
import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/journal_drive.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/sqlite.dart' show Database, OpenMode, checkedCopyOf, offThread;
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/training_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3;

void main() {
  Directory tempDir([String prefix = 'eclipse_safety']) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  /// A real database file spanning multiple pages so partial corruption behaves realistically.
  String sampleDb(Directory dir, {String journal = 'From the copy'}) {
    final path = p.join(dir.path, 'productivity.db');
    final store = Store.open(path);
    store.raw.execute('BEGIN');
    store.setJournal('2026-10-25', journal);
    for (var i = 1; i <= 15; i++) {
      store.setJournal('2026-09-${i.toString().padLeft(2, '0')}', 'A long entry. ' * 250);
    }
    store.raw.execute('COMMIT');
    store.close();
    return path;
  }

  void damage(String path, {bool lightly = false}) {
    final bytes = File(path).readAsBytesSync();
    final (from, to) = lightly
        ? (bytes.length * 7 ~/ 8, bytes.length * 15 ~/ 16)
        : (bytes.length ~/ 3, bytes.length * 2 ~/ 3);
    for (var i = from; i < to; i++) {
      bytes[i] = 0xAB;
    }
    File(path).writeAsBytesSync(bytes);
  }

  group('schema & persistence', () {
    test('fresh database initializes current schema, sleep habits, indexes and sync triggers', () {
      final dir = tempDir('eclipse_schema');
      final store = Store.open(p.join(dir.path, 'app.db'));
      addTearDown(store.close);
      expect(store.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion);
      expect(store.upgradedFrom, isNull);
      expect(store.sleepHabits(2026, 11).map((h) => h.name), [
        'Rise Early',
        'Unwind',
        'Screen Curfew',
        'Sleep Early',
      ]);
      final indexes = {
        for (final r in store.raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name'] as String,
      };
      expect(indexes, containsAll(['todos_done_reminders', 'todos_since', 'todos_done_due_date', 'month_habits_habit_id']));
      final triggers = {
        for (final r in store.raw.select("SELECT name FROM sqlite_master WHERE type = 'trigger'")) r['name'] as String,
      };
      expect(triggers, containsAll(['todo_history_delete', 'routines_INSERT', 'weigh_ins_INSERT']));
    });

    test('upgrades v37 database preserving data and rejects incompatible schema versions', () {
      final dir = tempDir('eclipse_migrate');
      final path = p.join(dir.path, 'app.db');
      var store = Store.open(path);
      final habit = store.addHabit(2026, 11, 'Read');
      store.setEntry('2026-11-01', habit.id, HabitStatus.done);
      store.setJournal('2026-11-01', 'Kept entry');
      store.raw.execute('''
        DROP TABLE routines; DROP TABLE weigh_ins;
        ALTER TABLE month_habits DROP COLUMN weekly; ALTER TABLE month_habits DROP COLUMN target;
        ALTER TABLE month_habits DROP COLUMN unit; ALTER TABLE entries DROP COLUMN amount;
        ALTER TABLE training_sets DROP COLUMN note; ALTER TABLE training_sets DROP COLUMN rpe;
        PRAGMA user_version = 37;
      ''');
      store.close();

      store = Store.open(path);
      addTearDown(store.close);
      expect(store.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion);
      expect(store.upgradedFrom, 37);
      expect(store.monthHabits(2026, 11).single.name, 'Read');
      expect(store.journal('2026-11-01'), 'Kept entry');

      final newer = p.join(dir.path, 'newer.db');
      sqlite3.open(newer)
        ..execute('PRAGMA user_version = ${Store.schemaVersion + 1}')
        ..close();
      expect(() => Store.open(newer), throwsA(isA<DatabaseTooNewException>()));

      final older = p.join(dir.path, 'older.db');
      sqlite3.open(older)
        ..execute('PRAGMA user_version = 36')
        ..close();
      expect(() => Store.open(older), throwsStateError);
    });

    test('habits, notes, to-dos, journal and theme survive reopen', () async {
      final dir = tempDir('eclipse_persist');
      final path = p.join(dir.path, 'test.db');
      final day = DateTime(2026, 10, 23);

      var store = Store.open(path);
      final read = store.addHabit(2026, 10, 'Read');
      var state = AppState(store, clock: () => day);
      state.selectStatus(day, read, HabitStatus.done);
      state.setNote(day, read, '20 pages');
      state.addTodo(TodoScope.week, 'Book dentist', dueDate: DateTime(2026, 10, 28));
      await state.setJournal(day, 'A good day.');
      state.setTheme('Sunset');
      state.dispose();
      store.close();

      store = Store.open(path);
      addTearDown(store.close);
      state = AppState(store, clock: () => day);
      addTearDown(state.dispose);
      final again = state.habits.firstWhere((h) => h.name == 'Read');
      expect(state.statusOf(day, again), HabitStatus.done);
      expect(state.noteOf(day, again), '20 pages');
      expect(state.todos[TodoScope.week]!.map((t) => t.text), contains('Book dentist'));
      expect(state.journalOf(day), 'A good day.');
      expect(state.themeName, 'Sunset');
    });

    test('SQLite busy_timeout, flushToDisk, offThread copy and atomic addHabit work', () async {
      final dir = tempDir('eclipse_sqlite');
      final store = Store.open(p.join(dir.path, 'app.db'));
      addTearDown(store.close);
      expect(store.raw.select('PRAGMA busy_timeout').single.columnAt(0), 5000);
      expect(await offThread(store.raw, (db) => db.select('PRAGMA busy_timeout').single.columnAt(0) as int), 5000);
      expect(store.flushToDisk(), isTrue);

      store.setJournal('2026-11-10', 'Written today');
      _here = true;
      expect(await offThread(store.raw, _onThisIsolate), isFalse);
      final copy = File(p.join(dir.path, 'copy.db'))..writeAsBytesSync((await offThread(store.raw, checkedCopyOf))!);
      final saved = sqlite3.open(copy.path, mode: OpenMode.readOnly);
      addTearDown(saved.close);
      expect(saved.select('SELECT text FROM journal').single['text'], 'Written today');

      store.raw.execute(
        "CREATE TRIGGER fail_mh BEFORE INSERT ON month_habits BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      final before = store.raw.select('SELECT COUNT(*) FROM habits').single.columnAt(0) as int;
      expect(() => store.addHabit(2026, 11, 'Blocked'), throwsA(anything));
      expect(store.raw.select('SELECT COUNT(*) FROM habits').single.columnAt(0), before);
    });
  });

  group('backups & recovery', () {
    test('daily backup keeps newest copies, preserves beforeJoining and skips damaged data', () async {
      final dir = tempDir('eclipse_daily');
      final path = sampleDb(dir);
      final backups = Backups(Directory(p.join(dir.path, 'backups')), keep: 2);
      final good = Store.open(path);
      for (final day in [1, 2, 3]) {
        await backups.daily(good, DateTime(2026, 11, day));
      }
      expect(backups.list().map((b) => b.day), [DateTime(2026, 11, 3), DateTime(2026, 11, 2)]);
      expect(Backups.isHealthy(backups.list().first.file), isTrue);

      backups.beforeJoining(good);
      good.close();
      damage(path, lightly: true);
      final damaged = Store.open(path);
      addTearDown(damaged.close);
      expect(damaged.isHealthy, isFalse);
      await expectLater(backups.daily(damaged, DateTime(2026, 11, 4)), throwsA(isA<DataDamaged>()));
      backups.dropDaily();
      expect(backups.list().single.isBeforeJoin, isTrue);
    });

    test('Backups.recover restores healthy copy, sets aside bad DB, preserves journal files and rejects bad files', () async {
      final dir = tempDir('eclipse_recover');
      final path = sampleDb(dir);
      final backups = Backups(Directory(p.join(dir.path, 'backups')));
      final store = Store.open(path);
      await backups.daily(store, DateTime(2026, 11, 1));
      store.close();
      final copy = backups.list().single;

      final journal = JournalFiles(Directory(p.join(dir.path, 'journal')));
      await journal.write(DateTime(2026, 11, 3), 'Written after the copy');
      await journal.write(DateTime(2026, 10, 25), 'From the copy');
      damage(path);
      backups.recover(copy, path, journal: journal);

      final restored = Store.open(path);
      addTearDown(restored.close);
      expect(restored.isHealthy, isTrue);
      expect(restored.journal('2026-10-25'), 'From the copy');
      expect(restored.journal('2026-11-03'), 'Written after the copy');
      final aside = backups.dir.listSync().whereType<Directory>().single;
      expect(p.basename(aside.path), startsWith('set-aside-'));

      final fake = p.join(dir.path, 'fake.db');
      sqlite3.open(fake)
        ..execute('CREATE TABLE stray (x INTEGER); PRAGMA user_version = ${Store.schemaVersion};')
        ..close();
      final before = File(path).readAsBytesSync();
      expect(() => backups.recover(Backup(File(fake), null), path), throwsA(anything));
      expect(File(path).readAsBytesSync(), before);
    });

    test('restore reloads Training prefs, clears undo/reminders, and failed restore rolls back cleanly', () async {
      final dir = tempDir('eclipse_restore_state');
      final backups = Backups(Directory(p.join(dir.path, 'backups')));
      final store = Store.open(p.join(dir.path, 'live.db'));
      addTearDown(store.close);
      final drive = _RecoveryDrive();
      final sync = SyncService.load(Directory(p.join(dir.path, 'home'))..createSync(), store, connect: (_) => drive);
      addTearDown(sync.dispose);
      const account = GoogleAccount(email: 'a@example.com', id: 'a', refreshToken: 'R');
      await sync.look(account);
      await sync.turnOn(account, join: false);

      final state = AppState(store, backups: backups, sync: sync, clock: () => DateTime(2026, 11, 19, 10));
      addTearDown(state.dispose);
      final bench = state.training.createExercise('Bench', MuscleGroup.chest, bodyweight: false);
      state.training.setAxis(TrainingAxis.change);
      state.training.setLayout(TrainingLayout.muscles);
      state.training.setRange(TrainingRange.year);
      state.training.toggleHidden(bench.uid);
      await sync.run();
      final goodPath = p.join(dir.path, 'good.db');
      store.saveCopy(goodPath);

      state.training.setAxis(TrainingAxis.kg);
      state.training.setLayout(TrainingLayout.all);
      state.training.setRange(TrainingRange.month);
      state.training.toggleHidden(bench.uid);
      state.addTodo(TodoScope.today, 'Delete me');
      state.removeTodo(TodoScope.today, state.todos[TodoScope.today]!.last);
      state.reminderCards.add(
        ReminderAlert(
          uid: 'u1',
          text: 'Old reminder',
          day: DateTime(2026, 11, 19),
          time: 600,
          birthday: false,
          reminder: Reminder.quarterBefore,
        ),
      );
      await state.restore(Backup(File(goodPath), DateTime(2026, 11, 19)));
      expect(state.training.axis, TrainingAxis.change);
      expect(state.training.layout, TrainingLayout.muscles);
      expect(state.training.range, TrainingRange.year);
      expect(state.training.hidden, {bench.uid});
      expect(state.canUndo, isFalse);
      expect(state.reminderCards, isEmpty);

      final badPath = p.join(dir.path, 'other.db');
      Store.open(badPath)
        ..setJournal('2026-11-17', 'From failed restore')
        ..close();
      final regsBefore = store.raw.select('SELECT kind, rowkey, field, value, ts, origin FROM sync_reg').toList();
      await expectLater(
        backups.restore(store, Backup(File(badPath), DateTime(2026, 11, 17)), check: () => throw StateError('fail')),
        throwsStateError,
      );
      expect(store.journal('2026-11-17'), '');
      expect(store.raw.select('SELECT kind, rowkey, field, value, ts, origin FROM sync_reg').toList(), regsBefore);
    });

    test('restoreFrom rejects corrupt, invalid-schema and future-schema backups without touching live data', () async {
      final dir = tempDir('eclipse_restore_reject');
      final live = Store.memory();
      addTearDown(live.close);
      live.addHabit(2026, 10, 'Keep me');
      live.setJournal('2026-10-25', 'Current journal');

      final corrupt = Store.memory()..addHabit(2026, 10, 'Bad');
      corrupt.raw.execute("UPDATE month_habits SET days = 'not json'");
      corrupt.saveCopy(p.join(dir.path, 'corrupt.db'));
      corrupt.close();
      await expectLater(live.restoreFrom(p.join(dir.path, 'corrupt.db')), throwsA(anything));

      Store.open(p.join(dir.path, 'missing.db'))
        ..raw.execute('DROP TABLE todos')
        ..close();
      await expectLater(live.restoreFrom(p.join(dir.path, 'missing.db')), throwsA(anything));

      Store.open(p.join(dir.path, 'future.db'))
        ..raw.execute('PRAGMA user_version = 100')
        ..close();
      await expectLater(live.restoreFrom(p.join(dir.path, 'future.db')), throwsStateError);

      expect(live.monthHabits(2026, 10).single.name, 'Keep me');
      expect(live.journal('2026-10-25'), 'Current journal');
    });
  });

  group('journal files & log', () {
    test('failed journal write stays stale and catches up on reopen', () async {
      final dir = tempDir('eclipse_journal');
      final store = Store.memory();
      addTearDown(store.close);
      store.addHabit(2026, 11, 'Read');
      store.setJournal('2026-11-01', 'Old');
      store.setSetting('journalExported', '1');
      final files = _FailingJournalFiles(Directory(p.join(dir.path, 'files')))..fail = true;
      final state = AppState(store, journalFiles: files, clock: () => DateTime(2026, 11, 3, 9));
      await state.setJournal(DateTime(2026, 11, 1), 'New');
      await state.flushFiles();
      state.dispose();
      expect(store.setting('journalFilesStale'), '1');

      final again = AppState(store, journalFiles: JournalFiles(files.dir), clock: () => DateTime(2026, 11, 3, 10));
      addTearDown(again.dispose);
      await again.flushFiles();
      expect(files.fileFor(DateTime(2026, 11, 1)).readAsStringSync(), contains('New'));
    });

    test('JournalFolder hourly check detects MD5 drift in Drive and re-uploads reverted edits', () async {
      final drive = _FakeJournalDrive();
      final config = <String, dynamic>{};
      var now = DateTime(2026, 11, 19, 9);
      final folder = JournalFolder(config, () async {}, now: () => now);
      await folder.copy(
        drive,
        machine: 'pc',
        stamp: 's1',
        writers: () => {'2026-11-19': 'pc'},
        texts: () => {'2026-11-19': 'My real entry'},
        stopped: () => false,
      );
      final yearId = (config['journalYears'] as Map)['2026'] as String;
      final fileId = (config['journalUp'] as Map)['2026-11-19'][0] as String;
      await drive.writeFile('2026-11-19.md', yearId, [1, 2, 3], id: fileId);
      now = now.add(const Duration(hours: 2));
      await folder.copy(
        drive,
        machine: 'pc',
        stamp: 's1',
        writers: () => {'2026-11-19': 'pc'},
        texts: () => {'2026-11-19': 'My real entry'},
        stopped: () => false,
      );
      expect(String.fromCharCodes(drive.journalFiles[fileId]!.$3), contains('My real entry'));
    });

    test('AppLog scrubs personal text, emails and tokens', () {
      expect(AppLog.clean('Refused for me@example.com'), 'Refused for <email>');
      expect(AppLog.clean('Token 1//0eLhe8Mu-Juk_x was refused'), 'Token <token> was refused');
      expect(AppLog.clean(const FormatException('Bad file', 'Dear diary')), 'Bad file');
    });
  });
}

class _FailingJournalFiles extends JournalFiles {
  _FailingJournalFiles(super.dir);
  bool fail = false;

  @override
  Future<void> write(DateTime day, String text) {
    if (fail) return Future.error(const FileSystemException('Disk full'));
    return super.write(day, text);
  }
}

class _FakeJournalDrive implements JournalDrive {
  final journalFiles = <String, (String name, String parent, List<int> bytes, String md5)>{};
  final folders = <String, (String name, String? parent)>{};
  int _seq = 0;

  @override
  Future<bool> exists(String id) async => folders.containsKey(id);

  @override
  Future<String?> findFolder(String name, {String? parent}) async {
    for (final e in folders.entries) {
      if (e.value.$1 == name && e.value.$2 == parent) return e.key;
    }
    return null;
  }

  @override
  Future<String> makeFolder(String name, {String? parent}) async {
    final id = 'dir${_seq++}';
    folders[id] = (name, parent);
    return id;
  }

  @override
  Future<(String, String)?> findFile(String name, String folder) async {
    for (final e in journalFiles.entries) {
      if (e.value.$1 == name && e.value.$2 == folder) return (e.key, e.value.$4);
    }
    return null;
  }

  @override
  Future<(Map<String, (String, String)>, Map<String, String>)> listJournal(String folder) async {
    final years = {
      for (final e in folders.entries)
        if (e.value.$2 == folder) e.value.$1: e.key,
    };
    final filesOut = {
      for (final y in years.entries)
        for (final f in journalFiles.entries)
          if (f.value.$2 == y.value) '${y.key}/${f.value.$1}': (f.key, f.value.$4),
    };
    return (filesOut, years);
  }

  @override
  Future<(String, String)> writeFile(String name, String folder, List<int> bytes, {String? id}) async {
    final key = id ?? 'j${_seq++}';
    final sum = '${bytes.length}-${bytes.fold<int>(0, (a, b) => a + b)}';
    journalFiles[key] = (name, folder, bytes, sum);
    return (key, sum);
  }

  @override
  Future<void> bin(String id) async {
    folders.remove(id);
    journalFiles.remove(id);
  }
}

class _RecoveryDrive implements SyncDrive, JournalDrive, CopiesDrive {
  final files = <String, (String name, List<int> bytes, String modified)>{};
  int _seq = 0;

  @override
  Future<List<DriveFile>> list() async => [
    for (final e in files.entries) DriveFile(id: e.key, name: e.value.$1, modified: e.value.$3),
  ];

  @override
  Future<List<int>> download(String id) async => files[id]!.$2;

  @override
  Future<DriveFile> upload(String name, List<int> bytes, {String? id}) async {
    final key = id ?? 'f${_seq++}';
    final modified = '${++_seq}';
    files[key] = (name, bytes, modified);
    return DriveFile(id: key, name: name, modified: modified);
  }

  @override
  Future<void> delete(String id) async => files.remove(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

var _here = false;
bool _onThisIsolate(Database _) => _here;
