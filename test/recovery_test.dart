import 'dart:convert';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/app_log.dart';
import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/screens/startup_error.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/backup_card.dart';
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
    test('a good copy is checked and saved, and the oldest dropped', () {
      final dir = temporary();
      final store = Store.open(database(dir));
      addTearDown(store.close);
      final backups = Backups(Directory(p.join(dir.path, 'backups')), keep: 2);
      for (final day in [1, 2, 3]) {
        backups.daily(store, DateTime(2026, 11, day));
      }
      expect(backups.list().map((b) => b.day), [DateTime(2026, 11, 3), DateTime(2026, 11, 2)]);
      expect(Backups.isHealthy(backups.list().first.file), isTrue);
    });

    test('damaged data makes no copy and drops none', () {
      final dir = temporary();
      final path = database(dir);
      final backups = Backups(Directory(p.join(dir.path, 'backups')), keep: 1);
      final good = Store.open(path);
      backups.daily(good, DateTime(2026, 11, 1));
      good.close();
      damage(path, lightly: true);
      final store = Store.open(path);
      addTearDown(store.close);
      expect(store.isHealthy, isFalse);
      expect(() => backups.daily(store, DateTime(2026, 11, 2)), throwsA(isA<DataDamaged>()));
      expect(backups.list().map((b) => b.day), [DateTime(2026, 11, 1)]);
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

    test('the app says when a backup failed, and when data is damaged', () {
      final dir = temporary();
      final store = Store.open(database(dir));
      addTearDown(store.close);
      // A file where the backups folder should be: copies can't be saved.
      final blocked = File(p.join(dir.path, 'blocked'))..writeAsStringSync('');
      final failing = AppState(store, backups: Backups(Directory(blocked.path)), clock: () => DateTime(2026, 11, 4));
      addTearDown(failing.dispose);
      expect(failing.backupProblem, BackupProblem.failed);

      final working = AppState(
        store,
        backups: Backups(Directory(p.join(dir.path, 'backups'))),
        clock: () => DateTime(2026, 11, 4),
      );
      addTearDown(working.dispose);
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

    setUp(() {
      dir = Directory.systemTemp.createTempSync('eclipse-recover');
      path = database(dir);
      backups = Backups(Directory(p.join(dir.path, 'backups')));
      final store = Store.open(path);
      backups.daily(store, DateTime(2026, 11, 1));
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
      old.daily(store, DateTime(2026, 11, 1));
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
}
