import 'dart:convert';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/app_log.dart';
import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/sqlite.dart' show Database, OpenMode, checkedCopyOf, offThread;
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/startup_error.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/training_log.dart';
import 'package:eclipse/widgets/backup_card.dart';
import 'package:eclipse/widgets/backup_row.dart';
import 'package:eclipse/widgets/sync_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3;

class _Drive implements SyncDrive {
  final files = <String, (String, List<int>, int)>{};
  int serial = 0;
  DriveError? failing;

  @override
  Future<List<DriveFile>> list() async {
    if (failing case final error?) throw error;
    return [for (final e in files.entries) DriveFile(id: e.key, name: e.value.$1, modified: '${e.value.$3}')];
  }

  @override
  Future<List<int>> download(String id) async => files[id]!.$2;

  @override
  Future<DriveFile> upload(String name, List<int> bytes, {String? id}) async {
    final key = id ?? 'file${serial++}';
    files[key] = (name, bytes, serial++);
    return DriveFile(id: key, name: name, modified: '${files[key]!.$3}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Directory temporary() {
    final temp = Directory.systemTemp.createTempSync('eclipse-recovery');
    addTearDown(() => temp.deleteSync(recursive: true));
    return temp;
  }

  /// A real database file with enough in it to span many pages.
  String database(Directory dir, {String journal = 'From the copy'}) {
    final path = p.join(dir.path, 'productivity.db');
    final store = Store.open(path);
    store.setJournal('2026-10-25', journal);
    for (var i = 1; i < 28; i++) {
      store.setJournal('2026-09-${i.toString().padLeft(2, '0')}', 'A long entry. ' * 400);
    }
    store.close();
    return path;
  }

  /// Scribbles over the file's middle, so it won't open at all; or only
  /// near its end, among the writing, so it opens and looks fine at first.
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

  group('the daily check', () {
    test('a good copy is checked and saved, and the oldest dropped', () async {
      final dir = temporary();
      final store = Store.open(database(dir));
      addTearDown(store.close);
      final backups = Backups(Directory(p.join(dir.path, 'backups')), keep: 2);
      for (final day in [1, 2, 3]) {
        await backups.daily(store, DateTime(2026, 11, day));
      }
      expect(backups.list().map((b) => b.day), [DateTime(2026, 11, 3), DateTime(2026, 11, 2)]);
      expect(Backups.isHealthy(backups.list().first.file), isTrue);
    });

    test('damaged data makes no copy and drops none', () async {
      final dir = temporary();
      final path = database(dir);
      final backups = Backups(Directory(p.join(dir.path, 'backups')), keep: 1);
      final good = Store.open(path);
      await backups.daily(good, DateTime(2026, 11, 1));
      good.close();
      damage(path, lightly: true);
      final store = Store.open(path);
      addTearDown(store.close);
      expect(store.isHealthy, isFalse);
      await expectLater(backups.daily(store, DateTime(2026, 11, 2)), throwsA(isA<DataDamaged>()));
      expect(backups.list().map((b) => b.day), [DateTime(2026, 11, 1)]);
    });

    test('dropping the daily copies keeps the one-off ones', () async {
      final dir = temporary();
      final store = Store.open(database(dir));
      addTearDown(store.close);
      final backups = Backups(Directory(p.join(dir.path, 'backups')));
      await backups.daily(store, DateTime(2026, 11, 1));
      await backups.daily(store, DateTime(2026, 11, 2));
      backups.beforeJoining(store);
      backups.dropDaily();
      expect(backups.list().single.isBeforeJoin, isTrue);
    });

    test('a file that is damaged or not a database fails the check', () {
      final dir = temporary();
      final path = database(dir);
      expect(Backups.isHealthy(File(path)), isTrue);
      damage(path);
      expect(Backups.isHealthy(File(path)), isFalse);
      expect(Backups.isHealthy(File(p.join(dir.path, 'nothing.db'))), isFalse);
      final text = File(p.join(dir.path, 'text.db'))..writeAsStringSync('Not a database');
      expect(Backups.isHealthy(text), isFalse);
    });

    test('the app says when a backup failed, and when data is damaged', () async {
      final dir = temporary();
      final store = Store.open(database(dir));
      addTearDown(store.close);
      // A file where the backups folder should be: copies can't be saved.
      final blocked = File(p.join(dir.path, 'blocked'))..writeAsStringSync('');
      final failing = AppState(store, backups: Backups(Directory(blocked.path)), clock: () => DateTime(2026, 11, 4));
      addTearDown(failing.dispose);
      await failing.backedUp;
      expect(failing.backupProblem, BackupProblem.failed);

      final working = AppState(
        store,
        backups: Backups(Directory(p.join(dir.path, 'backups'))),
        clock: () => DateTime(2026, 11, 4),
      );
      addTearDown(working.dispose);
      await working.backedUp;
      expect(working.backupProblem, isNull);
    });

    testWidgets('the card offers the backups only when data is damaged', (tester) async {
      var opened = 0;
      Future<void> show(BackupProblem? problem) => tester.pumpWidget(
        MaterialApp(
          theme: themeNamed(null),
          home: Scaffold(
            body: BackupCard(problem: problem, onSeeBackups: () => opened++),
          ),
        ),
      );
      await show(BackupProblem.failed);
      expect(find.text('A backup couldn’t be saved'), findsOneWidget);
      expect(find.text('See backups'), findsNothing);
      await show(BackupProblem.damaged);
      await tester.pumpAndSettle();
      expect(find.text('Your data may be damaged'), findsOneWidget);
      await tester.tap(find.text('See backups'));
      expect(opened, 1);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Your data may be damaged'), findsNothing);
    });
  });

  group('before an update', () {
    test('a format change saves a copy first, listed for restoring', () {
      final dir = temporary();
      final path = database(dir);
      final raw = sqlite3.open(path);
      raw.execute('PRAGMA user_version = ${Store.schemaVersion - 1}');
      raw.close();
      final backups = Backups(Directory(p.join(dir.path, 'backups')))..beforeUpdating(path);
      final copy = backups.list().single;
      expect(copy.isBeforeUpdate, isTrue);
      expect(copy.isBeforeRestore, isFalse);
      final saved = sqlite3.open(copy.file.path);
      addTearDown(saved.close);
      expect(saved.select('PRAGMA user_version').first.columnAt(0), Store.schemaVersion - 1);
    });

    test('nothing is saved at the current format, or with no database yet', () {
      final dir = temporary();
      final backups = Backups(Directory(p.join(dir.path, 'backups')));
      backups.beforeUpdating(p.join(dir.path, 'productivity.db'));
      expect(backups.list(), isEmpty);
      backups.beforeUpdating(database(dir));
      expect(backups.list(), isEmpty);
      expect(backups.updateCopyFailed, isFalse);
    });
  });

  group('recovering', () {
    late Directory dir;
    late String path;
    late Backups backups;
    late Backup copy;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('eclipse-recover');
      path = database(dir);
      backups = Backups(Directory(p.join(dir.path, 'backups')));
      final store = Store.open(path);
      await backups.daily(store, DateTime(2026, 11, 1));
      store.close();
      copy = backups.list().single;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('the copy comes back, the bad data is set aside and newer writing is kept', () async {
      final journal = JournalFiles(Directory(p.join(dir.path, 'journal')));
      await journal.write(DateTime(2026, 11, 3), 'Written after the copy');
      await journal.write(DateTime(2026, 10, 25), 'From the copy');
      damage(path);

      backups.recover(copy, path, journal: journal);

      final store = Store.open(path);
      addTearDown(store.close);
      expect(store.isHealthy, isTrue);
      expect(store.journal('2026-10-25'), 'From the copy');
      expect(store.journal('2026-11-03'), 'Written after the copy');
      final aside = backups.dir.listSync().whereType<Directory>().single;
      expect(p.basename(aside.path), startsWith('set-aside-'));
      expect(File(p.join(aside.path, 'productivity.db')).existsSync(), isTrue);
    });

    test('a damaged copy is refused and nothing moves', () {
      damage(copy.file.path);
      final before = File(path).readAsBytesSync();
      expect(() => backups.recover(copy, path), throwsStateError);
      expect(File(path).readAsBytesSync(), before);
      expect(backups.dir.listSync().whereType<Directory>(), isEmpty);
    });

    testWidgets('the error screen lists the copies, marks damaged ones and asks first', (tester) async {
      await tester.runAsync(() async {
        File(p.join(backups.dir.path, 'productivity-2026-10-31.db')).writeAsStringSync('Not a database');
      });
      var reopened = 0;
      await tester.pumpWidget(
        StartupErrorApp(
          error: const FileSystemException('Disk is damaged'),
          recovery: StartupRecovery(backups: backups, database: path, reopen: () async => reopened++),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('This copy is damaged.'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.text('Sets aside what’s there and goes back to this copy.'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Restore'));
        await tester.pump();
      });
      expect(reopened, 1);
    });

    group('copies in Drive', () {
      late Directory home;
      setUp(() {
        home = Directory(p.join(dir.path, 'home'))..createSync();
        File(p.join(home.path, 'sync.json')).writeAsStringSync(
          jsonEncode({
            'refresh': 'A',
            'machine': 'one',
            'names': {'two': 'Laptop'},
          }),
        );
      });

      testWidgets('are offered when the data won\'t open, and one comes back', (tester) async {
        final drive = _Drive();
        var reopened = 0;
        await tester.runAsync(() async {
          await drive.upload('backup_two_2026-11-01.db', File(copy.file.path).readAsBytesSync());
          await drive.upload('sync_change.json', [1]);
          backups.dropDaily();
          damage(path);
        });
        await tester.pumpWidget(
          StartupErrorApp(
            error: const FileSystemException('Disk is damaged'),
            recovery: StartupRecovery(
              backups: backups,
              database: path,
              driveCopies: SyncService.copiesAt(home, connect: (_) => drive),
              reopen: () async => reopened++,
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pumpAndSettle();
        expect(find.textContaining('in Google Drive from Laptop'), findsOneWidget);
        await tester.tap(find.text('Restore'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('Restore'));
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        expect(reopened, 1);
        expect(Backups.isHealthy(File(path)), isTrue);
      });

      testWidgets('say so when they can\'t be reached', (tester) async {
        final drive = _Drive()..failing = const DriveError('Offline');
        await tester.runAsync(() async => backups.dropDaily());
        await tester.pumpWidget(
          StartupErrorApp(
            error: const FileSystemException('Disk is damaged'),
            recovery: StartupRecovery(
              backups: backups,
              database: path,
              driveCopies: SyncService.copiesAt(home, connect: (_) => drive),
              reopen: () async {},
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pumpAndSettle();
        expect(find.textContaining('couldn’t be reached'), findsOneWidget);
        expect(find.text('Restore'), findsNothing);
      });

      test('aren\'t looked for without a sign-in', () {
        final empty = Directory(p.join(dir.path, 'empty'))..createSync();
        expect(SyncService.copiesAt(empty), isNull);
      });
    });

    testWidgets('data too new is no reason to restore', (tester) async {
      await tester.pumpWidget(
        StartupErrorApp(
          error: const DatabaseTooNewException(),
          recovery: StartupRecovery(backups: backups, database: path, reopen: () async {}),
        ),
      );
      expect(find.text('Restore'), findsNothing);
    });

    test('this computer\'s synced edits come back after going back to an old copy', () async {
      final home = Directory(p.join(dir.path, 'home'))..createSync();
      final drive = _Drive();
      var store = Store.open(path);
      var sync = SyncService.load(home, store, connect: (_) => drive);
      const account = GoogleAccount(email: 'a@example.com', id: 'a', refreshToken: 'A', journalAccess: false);
      await sync.look(account);
      await sync.turnOn(account, join: false);
      store.flushToDisk();
      // A copy from before the edit, as the backup would be.
      final old = Backups(Directory(p.join(dir.path, 'older')));
      await old.daily(store, DateTime(2026, 11, 1));
      store.setJournal('2026-11-03', 'Synced before the damage');
      await sync.run();
      sync.stop();
      sync.dispose();
      store.close();

      damage(path);
      old.recover(old.list().single, path);
      store = Store.open(path);
      addTearDown(store.close);
      expect(store.journal('2026-11-03'), '');
      sync = SyncService.load(home, store, connect: (_) => drive);
      addTearDown(sync.dispose);
      await sync.run();
      sync.stop();
      expect(store.journal('2026-11-03'), 'Synced before the damage');
    });
  });

  group('sync trouble', () {
    Map<String, dynamic> saved(Directory home) =>
        jsonDecode(File(p.join(home.path, 'sync.json')).readAsStringSync()) as Map<String, dynamic>;

    (SyncService, _Drive, Store) start(Directory home, {String? syncedAt}) {
      File(p.join(home.path, 'sync.json')).writeAsStringSync(
        jsonEncode({'refresh': 'A', 'email': 'a@example.com', 'journalDrive': true, 'syncedAt': ?syncedAt}),
      );
      final store = Store.memory();
      final drive = _Drive();
      final sync = SyncService.load(home, store, connect: (_) => drive);
      addTearDown(() {
        sync.dispose();
        store.close();
      });
      return (sync, drive, store);
    }

    String ago(int days) => DateTime.now().subtract(Duration(days: days, hours: 1)).toIso8601String();

    test('days of failures count; being off before a good try doesn\'t', () async {
      final (sync, drive, _) = start(temporary(), syncedAt: ago(5));
      expect(sync.staleDays, isNull, reason: 'it has only been off');
      drive.failing = const DriveError('No connection');
      await sync.run();
      expect(sync.staleDays, 5);
      drive.failing = null;
      await sync.run();
      expect(sync.staleDays, isNull);
    });

    test('under three days stays quiet', () async {
      final (sync, drive, _) = start(temporary(), syncedAt: ago(2));
      drive.failing = const DriveError('No connection');
      await sync.run();
      expect(sync.error, 'No connection');
      expect(sync.staleDays, isNull);
    });

    test('a first failure with no record starts the count, and it lasts', () async {
      final home = temporary();
      final (sync, drive, _) = start(home);
      drive.failing = const DriveError('No connection');
      await sync.run();
      expect(sync.staleDays, isNull);
      expect(DateTime.parse(saved(home)['syncedAt'] as String).day, DateTime.now().day);
    });

    test('being signed out says so, even after a restart, until signed in', () async {
      final home = temporary();
      final (sync, drive, store) = start(home);
      drive.failing = const DriveError('Google signed Eclipse out. Sign in again.', signedOut: true);
      await sync.run();
      expect(sync.isOn, isFalse);
      expect(sync.stoppedWhy, contains('signed Eclipse out'));
      final later = SyncService.load(home, store, connect: (_) => drive);
      addTearDown(later.dispose);
      expect(later.stoppedWhy, contains('signed Eclipse out'));
      await later.turnOff();
      expect(later.stoppedWhy, isNull);
    });

    testWidgets('the card names the days and goes until the next start', (tester) async {
      late SyncService sync;
      await tester.runAsync(() async {
        final (s, drive, _) = start(temporary(), syncedAt: ago(4));
        sync = s;
        drive.failing = const DriveError('No connection');
        await sync.run();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: themeNamed(null),
          home: Scaffold(body: SyncBanner(sync: sync)),
        ),
      );
      await tester.pump(Motion.morph);
      expect(find.text('Sync hasn’t worked for 4 days'), findsOneWidget);
      expect(find.text('No connection'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Sync hasn’t worked for 4 days'), findsNothing);
    });
  });

  group('the log', () {
    test('keeps out what you wrote, your address and sign-in', () {
      expect(
        AppLog.clean('SqliteException(1): failed\n  Causing statement: INSERT, parameters: 2026, Dear diary'),
        isNot(contains('Dear diary')),
      );
      expect(AppLog.clean(const FormatException('Bad file', 'Dear diary, today')), 'Bad file');
      expect(AppLog.clean('Refused for me@example.com'), 'Refused for <email>');
      expect(AppLog.clean('Token 1//0eLhe8Mu-Juk_x was refused'), 'Token <token> was refused');
      expect(AppLog.clean('x' * 900).length, 501);
    });

    test('it stays small and never gets in the way', () {
      final home = temporary();
      AppLog.start(home);
      addTearDown(() => AppLog.file = null);
      AppLog.note('Opened');
      expect(AppLog.file!.readAsStringSync(), endsWith(' Opened\n'));
      AppLog.file!.writeAsStringSync('x' * (AppLog.maxBytes + 1));
      AppLog.failure('Backup failed', StateError('Disk full'));
      expect(AppLog.file!.lengthSync(), lessThan(AppLog.maxBytes));
      expect(File('${AppLog.file!.path}.old').existsSync(), isTrue);

      AppLog.file = File(p.join(home.path, 'no', 'such', 'folder', 'eclipse.log'));
      AppLog.note('Goes nowhere');
    });
  });

  test('saved copies and the last sync give the time as the rest of the app does', () {
    final saved = DriveBackup(
      id: 'x',
      name: 'backup_pc_before-restore.db',
      day: null,
      saved: DateTime(2026, 11, 9, 14, 5),
      from: 'this computer',
    );
    expect(BackupRow.describe(saved, DateTime(2026, 11, 10)).$2, 'Saved 9 November, 2:05 pm, in Google Drive');
    expect(BackupRow.describe(saved, DateTime(2026, 11, 10)).$2, isNot(contains('14:05')));
    // The same clock a task's time reads on.
    expect(clockLabel(14 * 60 + 5), '2:05 pm');
  });

  test('the daily copy and the copy for Drive are made away from the UI', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse-off-thread');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/app.db');
    addTearDown(store.close);
    store.setJournal('2026-11-10', 'Written today');
    _here = true;
    expect(await offThread(store.raw, _onThisIsolate), isFalse, reason: 'a file is read on an isolate of its own');
    expect(await offThread(Store.memory().raw, _onThisIsolate), isTrue, reason: 'one in memory has no file to open');

    final copy = File('${dir.path}/copy.db')..writeAsBytesSync((await offThread(store.raw, checkedCopyOf))!);
    final saved = sqlite3.open(copy.path, mode: OpenMode.readOnly);
    addTearDown(saved.close);
    expect(saved.select('SELECT text FROM journal').single['text'], 'Written today');

    final backups = Backups(Directory('${dir.path}/backups'));
    await backups.daily(store, DateTime(2026, 11, 10));
    expect(Backups.isHealthy(backups.list().single.file), isTrue);
  });

  test('restore reloads Training prefs, clears undo/reminders, and failed restore rolls back cleanly', () async {
    final dir = temporary();
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
    state.store.setJournal('2026-11-18', 'Backup day');
    await sync.run();
    final goodBackupPath = p.join(dir.path, 'good.db');
    store.saveCopy(goodBackupPath);

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
    expect(state.canUndo, isTrue);
    expect(state.reminderCards, isNotEmpty);

    await state.restore(Backup(File(goodBackupPath), DateTime(2026, 11, 19)));
    expect(state.training.axis, TrainingAxis.change);
    expect(state.training.layout, TrainingLayout.muscles);
    expect(state.training.range, TrainingRange.year);
    expect(state.training.hidden, {bench.uid});
    expect(state.canUndo, isFalse);
    expect(state.shownRemoval, isNull);
    expect(state.reminderCards, isEmpty);

    final badBackupPath = p.join(dir.path, 'other.db');
    final other = Store.open(badBackupPath);
    other.setJournal('2026-11-17', 'From failed restore');
    other.close();
    final regsBefore = store.raw.select('SELECT kind, rowkey, field, value, ts, origin FROM sync_reg').toList();

    final beforePath = p.join(dir.path, 'before.db');
    store.saveCopy(beforePath);
    await expectLater(
      backups.restore(
        store,
        Backup(File(badBackupPath), DateTime(2026, 11, 17)),
        check: () => throw StateError('check failed'),
      ),
      throwsStateError,
    );
    expect(store.journal('2026-11-17'), '');
    expect(store.raw.select('SELECT kind, rowkey, field, value, ts, origin FROM sync_reg').toList(), regsBefore);
    sync.engine.flush();
  });

  test('Backups.recover rejects invalid-schema SQLite files and restores original intact', () {
    final dir = temporary();
    final dbPath = p.join(dir.path, 'live.db');
    final live = Store.open(dbPath);
    live.setJournal('2026-11-19', 'Original live');
    live.close();
    final originalBytes = File(dbPath).readAsBytesSync();

    final fakeBackup = p.join(dir.path, 'not-eclipse.db');
    final raw = sqlite3.open(fakeBackup);
    raw.execute('CREATE TABLE stray (x INTEGER); PRAGMA user_version = ${Store.schemaVersion};');
    raw.close();

    final backups = Backups(Directory(p.join(dir.path, 'backups')));
    expect(() => backups.recover(Backup(File(fakeBackup), null), dbPath), throwsA(anything));
    expect(File(dbPath).readAsBytesSync(), originalBytes);
    expect(backups.dir.listSync(), isEmpty);
  });

  test('SQLite busy_timeout, flushToDisk result, and atomic addHabit work as expected', () async {
    final dir = temporary();
    final path = p.join(dir.path, 'busy.db');
    final store = Store.open(path);
    addTearDown(store.close);
    expect(store.raw.select('PRAGMA busy_timeout').single.columnAt(0), 5000);
    final offTimeout = await offThread(store.raw, (db) => db.select('PRAGMA busy_timeout').single.columnAt(0) as int);
    expect(offTimeout, 5000);
    expect(store.flushToDisk(), isTrue);

    store.raw.execute(
      "CREATE TRIGGER fail_mh BEFORE INSERT ON month_habits BEGIN SELECT RAISE(ABORT, 'boom'); END;",
    );
    final beforeHabits = store.raw.select('SELECT COUNT(*) FROM habits').single.columnAt(0) as int;
    expect(() => store.addHabit(2026, 11, 'Blocked'), throwsA(anything));
    final afterHabits = store.raw.select('SELECT COUNT(*) FROM habits').single.columnAt(0) as int;
    expect(afterHabits, beforeHabits);
  });

  test('a backup the app could not read back is refused before anything is replaced', () async {
    final source = Store.memory();
    addTearDown(source.close);
    source.addHabit(2026, 10, 'Read');
    source.raw.execute("UPDATE month_habits SET days = 'not json'");
    final path = '${temporary().path}/bad.db';
    source.saveCopy(path);
    final live = Store.memory();
    addTearDown(live.close);
    live.addHabit(2026, 10, 'Keep me');
    await expectLater(live.restoreFrom(path), throwsA(anything));
    expect(live.monthHabits(2026, 10).single.name, 'Keep me');
  });

  test('a restore the app then fails to load goes back to what was there', () async {
    final source = Store.memory();
    addTearDown(source.close);
    source.addHabit(2026, 10, 'From the copy');
    final dir = temporary();
    source.saveCopy('${dir.path}/good.db');
    final live = Store.memory();
    addTearDown(live.close);
    live.addHabit(2026, 10, 'Keep me');
    final backups = Backups(Directory('${dir.path}/backups'));
    final copy = Backup(File('${dir.path}/good.db'), DateTime(2026, 10, 30));
    await expectLater(backups.restore(live, copy, check: () => throw StateError('Won’t load')), throwsStateError);
    expect(live.monthHabits(2026, 10).single.name, 'Keep me');
  });

  test('an invalid schema backup is rejected without replacing live data', () async {
    final temp = temporary();
    final store = Store.memory();
    addTearDown(store.close);
    store.setJournal('2026-10-25', 'Current journal');
    final source = Store.open('${temp.path}/bad.db');
    source.raw.execute('DROP TABLE todos');
    source.close();
    await expectLater(store.restoreFrom('${temp.path}/bad.db'), throwsA(anything));
    expect(store.journal('2026-10-25'), 'Current journal');
    expect(store.raw.select("SELECT name FROM sqlite_master WHERE name = 'todos'"), hasLength(1));
  });

  test('future-schema backups are rejected before touching the database', () async {
    final temp = temporary();
    final store = Store.memory();
    addTearDown(store.close);
    store.setJournal('2026-10-25', 'Current journal');
    final source = Store.open('${temp.path}/future.db');
    source.raw.execute('PRAGMA user_version = 100');
    source.close();
    await expectLater(store.restoreFrom('${temp.path}/future.db'), throwsStateError);
    expect(store.journal('2026-10-25'), 'Current journal');
  });

  test('v37 databases migrate to v38 and restore without losing data', () async {
    final temp = temporary();
    final path = '${temp.path}/old.db';
    final old = Store.open(path);
    final habit = old.addHabit(2026, 10, 'Read');
    old.setEntry('2026-10-24', habit.id, HabitStatus.done);
    old.setJournal('2026-10-24', 'Older journal');
    SyncEngine(old, 'old').claimAll();
    old.raw.execute('''
      DROP TABLE routines; DROP TABLE weigh_ins;
      ALTER TABLE month_habits DROP COLUMN weekly; ALTER TABLE month_habits DROP COLUMN target;
      ALTER TABLE month_habits DROP COLUMN unit; ALTER TABLE entries DROP COLUMN amount;
      ALTER TABLE training_sets DROP COLUMN note; ALTER TABLE training_sets DROP COLUMN rpe;
      PRAGMA user_version = 37;
    ''');
    old.close();
    final current = Store.memory();
    addTearDown(current.close);
    await current.restoreFrom(path);
    expect(current.raw.select('PRAGMA user_version').first.columnAt(0), Store.schemaVersion);
    expect(current.monthHabits(2026, 10).single.name, 'Read');
    expect(current.journal('2026-10-24'), 'Older journal');
    expect(current.entriesInMonth(2026, 10).single.status, HabitStatus.done);
    expect(current.hasMonth(2026, 10), isTrue);
    final upgraded = Store.open(path);
    expect(upgraded.journal('2026-10-24'), 'Older journal');
    expect(upgraded.hasMonth(2026, 10), isTrue);
    upgraded.close();
  });
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

/// Set on the test's isolate only; another isolate starts with it unset.
var _here = false;

bool _onThisIsolate(Database _) => _here;
