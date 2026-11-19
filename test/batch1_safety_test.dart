import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/journal_drive.dart';
import 'package:eclipse/data/sqlite.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/phone/phone_platform.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/training_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;

class _FakeSyncDrive implements SyncDrive, JournalDrive, CopiesDrive {
  final files = <String, (String name, List<int> bytes, String modified)>{};
  final journalFiles = <String, (String name, String parent, List<int> bytes, String md5)>{};
  final folders = <String, (String name, String? parent)>{};
  final deleted = <String>[];
  int _seq = 0;
  bool throwOnList = false;
  Completer<void>? backupUploadGate;

  @override
  Future<List<DriveFile>> list() async {
    if (throwOnList) throw const DriveError('Offline');
    return [for (final e in files.entries) DriveFile(id: e.key, name: e.value.$1, modified: e.value.$3)];
  }

  @override
  Future<List<int>> download(String id) async => files[id]!.$2;

  @override
  Future<DriveFile> upload(String name, List<int> bytes, {String? id}) async {
    if (name.startsWith('backup_') && backupUploadGate != null) {
      await backupUploadGate!.future;
    }
    final key = id ?? 'f${_seq++}';
    final modified = '${++_seq}';
    files[key] = (name, bytes, modified);
    return DriveFile(id: key, name: name, modified: modified);
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    files.remove(id);
  }

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
    final years = <String, String>{};
    for (final e in folders.entries) {
      if (e.value.$2 == folder) years.putIfAbsent(e.value.$1, () => e.key);
    }
    final filesOut = <String, (String, String)>{};
    for (final y in years.entries) {
      for (final f in journalFiles.entries) {
        if (f.value.$2 == y.value) {
          filesOut.putIfAbsent('${y.key}/${f.value.$1}', () => (f.key, f.value.$4));
        }
      }
    }
    return (filesOut, years);
  }

  @override
  Future<(String, String)> writeFile(String name, String folder, List<int> bytes, {String? id}) async {
    final key = id ?? 'j${_seq++}';
    final sum = md5.convert(bytes).toString();
    journalFiles[key] = (name, folder, bytes, sum);
    return (key, sum);
  }

  @override
  Future<void> bin(String id) async {
    folders.remove(id);
    journalFiles.remove(id);
  }
}

void main() {
  Directory tempDir() {
    final d = Directory.systemTemp.createTempSync('eclipse-batch1-');
    addTearDown(() {
      if (d.existsSync()) d.deleteSync(recursive: true);
    });
    return d;
  }

  test('migrating from v35 to v36 installs todo_history_delete and syncs undone task deletions', () async {
    final dir = tempDir();
    final pcPath = p.join(dir.path, 'pc.db');
    final pcStore = Store.open(pcPath);
    pcStore.raw.execute('DROP TRIGGER IF EXISTS todo_history_delete');
    pcStore.raw.execute('PRAGMA user_version = 35');
    pcStore.close();

    final migrated = Store.open(pcPath);
    addTearDown(migrated.close);
    expect(migrated.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion);
    expect(
      migrated.raw.select("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = 'todo_history_delete'"),
      hasLength(1),
    );

    final laptopStore = Store.memory();
    addTearDown(laptopStore.close);
    final drive = _FakeSyncDrive();
    final day1 = DateTime(2026, 11, 18);
    var currentDay = day1;
    final pcSync = SyncService.load(Directory(p.join(dir.path, 'pc-home'))..createSync(), migrated, connect: (_) => drive);
    final laptopSync = SyncService.load(
      Directory(p.join(dir.path, 'laptop-home'))..createSync(),
      laptopStore,
      connect: (_) => drive,
    );
    addTearDown(pcSync.dispose);
    addTearDown(laptopSync.dispose);

    const account = GoogleAccount(email: 'a@example.com', id: 'a', refreshToken: 'R');
    await pcSync.look(account);
    await pcSync.turnOn(account, join: false);
    await laptopSync.look(account);
    await laptopSync.turnOn(account, join: true);

    final pcState = AppState(migrated, sync: pcSync, clock: () => currentDay)..endTour();
    final laptopState = AppState(laptopStore, sync: laptopSync, clock: () => currentDay)..endTour();
    addTearDown(pcState.dispose);
    addTearDown(laptopState.dispose);

    pcState.addTodo(TodoScope.today, 'Buy milk');
    final item = pcState.todos[TodoScope.today]!.single;
    await pcSync.run();
    await laptopSync.run();
    expect(laptopStore.todoListsOn(day1)[TodoScope.today]!.map((t) => t.text), ['Buy milk']);

    // Delete on the next day, sync deletion, then undo and sync again.
    currentDay = DateTime(2026, 11, 19);
    pcState.checkDate();
    laptopState.checkDate();
    pcState.removeTodo(TodoScope.today, pcState.todos[TodoScope.today]!.single);
    await pcSync.run();
    await laptopSync.run();
    expect(laptopStore.todoListsOn(currentDay)[TodoScope.today], isEmpty);

    pcState.undo();
    expect(pcState.todos[TodoScope.today]!.map((t) => t.text), ['Buy milk']);
    await pcSync.run();
    await laptopSync.run();

    expect(laptopStore.todos(TodoScope.today, dateKey(currentDay)).map((t) => t.text), ['Buy milk']);
    final historyRows = laptopStore.raw.select('SELECT day, snapshot FROM todo_history WHERE uid = ?', [item.uid]);
    expect(historyRows.any((r) => r['day'] == dateKey(currentDay) && (jsonDecode(r['snapshot'] as String)['deleted'] == true)), isFalse);
  });

  test('restore reloads Training prefs, clears undo/reminders, and failed restore rolls back cleanly', () async {
    final dir = tempDir();
    final backups = Backups(Directory(p.join(dir.path, 'backups')));
    final store = Store.open(p.join(dir.path, 'live.db'));
    addTearDown(store.close);
    final drive = _FakeSyncDrive();
    final sync = SyncService.load(Directory(p.join(dir.path, 'home'))..createSync(), store, connect: (_) => drive);
    addTearDown(sync.dispose);
    const account = GoogleAccount(email: 'a@example.com', id: 'a', refreshToken: 'R');
    await sync.look(account);
    await sync.turnOn(account, join: false);

    final state = AppState(store, backups: backups, sync: sync, clock: () => DateTime(2026, 11, 19, 10))..endTour();
    addTearDown(state.dispose);

    // Save a clean backup with specific training settings.
    final bench = state.training.createExercise('Bench', MuscleGroup.chest, bodyweight: false);
    state.training.setAxis(TrainingAxis.change);
    state.training.setLayout(TrainingLayout.muscles);
    state.training.setRange(TrainingRange.year);
    state.training.toggleHidden(bench.uid);
    state.store.setJournal('2026-11-18', 'Backup day');
    await sync.run();
    final goodBackupPath = p.join(dir.path, 'good.db');
    store.saveCopy(goodBackupPath);

    // Mutate live state: change training prefs, add an undo removal, and add a reminder card.
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

    // Now simulate a failed restore (check throws after swap): failed backup's journal and sync_reg must NOT pollute live DB.
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
    // Ensure SyncEngine in-memory caches were reset and remain consistent.
    sync.engine.flush();
  });

  test('Backups.recover rejects invalid-schema SQLite files and restores original intact', () {
    final dir = tempDir();
    final dbPath = p.join(dir.path, 'live.db');
    final live = Store.open(dbPath);
    live.setJournal('2026-11-19', 'Original live');
    live.close();
    final originalBytes = File(dbPath).readAsBytesSync();

    final fakeBackup = p.join(dir.path, 'not-eclipse.db');
    final raw = raw_sqlite.sqlite3.open(fakeBackup);
    raw.execute('CREATE TABLE stray (x INTEGER); PRAGMA user_version = ${Store.schemaVersion};');
    raw.close();

    final backups = Backups(Directory(p.join(dir.path, 'backups')));
    expect(() => backups.recover(Backup(File(fakeBackup), null), dbPath), throwsA(anything));
    expect(File(dbPath).readAsBytesSync(), originalBytes);
    expect(backups.dir.listSync(), isEmpty);
  });

  test('SQLite busy_timeout, flushToDisk result, and atomic addHabit work as expected', () async {
    final dir = tempDir();
    final path = p.join(dir.path, 'busy.db');
    final store = Store.open(path);
    addTearDown(store.close);
    expect(store.raw.select('PRAGMA busy_timeout').single.columnAt(0), 5000);
    final offTimeout = await offThread(store.raw, (db) => db.select('PRAGMA busy_timeout').single.columnAt(0) as int);
    expect(offTimeout, 5000);
    expect(store.flushToDisk(), isTrue);

    // Force an error in month_habits insertion by adding a trigger that aborts it; habits row must roll back too.
    store.raw.execute(
      "CREATE TRIGGER fail_mh BEFORE INSERT ON month_habits BEGIN SELECT RAISE(ABORT, 'boom'); END;",
    );
    final beforeHabits = store.raw.select('SELECT COUNT(*) FROM habits').single.columnAt(0) as int;
    expect(() => store.addHabit(2026, 11, 'Blocked'), throwsA(anything));
    final afterHabits = store.raw.select('SELECT COUNT(*) FROM habits').single.columnAt(0) as int;
    expect(afterHabits, beforeHabits);
  });

  test('SyncEngine handles weak writes under clock skew, flushGradually, missing training_set day, rollback caches, and join cleanup', () async {
    // 1. Weak write clock skew convergence + real edit precedence.
    final pcStore = Store.memory();
    final laptopStore = Store.memory();
    addTearDown(pcStore.close);
    addTearDown(laptopStore.close);

    var pcClock = 5000;
    var laptopClock = 4500; // 500ms behind (<1000ms offset zeroed)
    final pc = SyncEngine(pcStore, 'pc', clock: () => pcClock);
    final laptop = SyncEngine(laptopStore, 'laptop', clock: () => laptopClock);

    pcStore.setSetting('restWeekends', '0');
    pc.claimAll();
    laptop.mergeAll([(pc.changesSince(0).values.expand((d) => d), 'pc')]);

    // First, PC makes a weak write (ts=5000).
    pcStore.weak(() => pcStore.ensureMonth(2026, 12));
    // Give PC a weak-written month_habit with ts=5000, synced to laptop.
    pcStore.weak(() {
      pcStore.initializeMonth(2026, 12);
    });
    laptop.mergeAll([(pc.changesSince(0).values.expand((d) => d), 'pc')]);

    // Now laptop makes a weak write on an existing register while laptopClock=4500 (< old.ts 5000).
    pcStore.setSleepNote(2026, 12, SleepItem.riseEarly, '07:00');
    pc.flush();
    laptop.mergeAll([(pc.changesSince(0).values.expand((d) => d), 'pc')]);
    laptopStore.weak(() => laptopStore.setSleepNote(2026, 12, SleepItem.riseEarly, '06:30'));
    pc.mergeAll([(laptop.changesSince(0).values.expand((d) => d), 'laptop')]);
    expect(pcStore.sleepNote(2026, 12, SleepItem.riseEarly), '06:30');
    expect(laptopStore.sleepNote(2026, 12, SleepItem.riseEarly), '06:30');

    // Concurrent real edit on PC still beats laptop's weak write via version vector.
    pcStore.setSleepNote(2026, 12, SleepItem.sleepEarly, '22:00');
    pc.flush();
    laptopStore.weak(() => laptopStore.setSleepNote(2026, 12, SleepItem.sleepEarly, '22:30'));
    final pcOut = pc.changesSince(0).values.expand((d) => d).toList();
    final laptopOut = laptop.changesSince(0).values.expand((d) => d).toList();
    pc.mergeAll([(laptopOut, 'laptop')]);
    laptop.mergeAll([(pcOut, 'pc')]);
    expect(pcStore.sleepNote(2026, 12, SleepItem.sleepEarly), '22:00');
    expect(laptopStore.sleepNote(2026, 12, SleepItem.sleepEarly), '22:00');

    // 2. flushGradually completes on large backlog without hanging.
    for (var i = 0; i < 60; i++) {
      pcStore.setJournal('2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}', 'Note $i');
    }
    await pc.flushGradually();
    expect(pcStore.raw.select('SELECT 1 FROM sync_dirty'), isEmpty);

    // 3. training_set missing 'day' is not materialized.
    final badSetReg = [
      ['training_set', 'ts1', '_', jsonEncode(true), 9000, 'other', {'other': 1}],
      ['training_set', 'ts1', 'exercise', jsonEncode('ex1'), 9000, 'other', {'other': 1}],
      ['training_set', 'ts1', 'position', jsonEncode(0), 9000, 'other', {'other': 1}],
      ['training_set', 'ts1', 'reps', jsonEncode(5), 9000, 'other', {'other': 1}],
    ];
    laptop.mergeAll([(badSetReg, 'other')]);
    expect(laptopStore.raw.select("SELECT * FROM training_sets WHERE uid = 'ts1'"), isEmpty);

    // 4. Rolled-back batch in mergeAll does not poison _lastTs / _lastSeq.
    final freshStore = Store.memory();
    addTearDown(freshStore.close);
    final fresh = SyncEngine(freshStore, 'pc', clock: () => 20000);
    final failingBatch = [
      // This writes ts=9999999999999 and vv['pc']=999999, then fails foreign-key / null constraint if row triggers error.
      ['todo', 'bad-ts', 'text', jsonEncode('x'), 9999999999999, 'other', {'pc': 999999}],
      // Force an exception on invalid rowkey split for entry (missing '/').
      ['entry', 'no-slash', 'status', jsonEncode(1), 9999999999999, 'other', {'pc': 999999}],
    ];
    final res = fresh.mergeAll([(failingBatch, 'other')]);
    expect(res.failed, {0});
    freshStore.setJournal('2026-11-19', 'After rollback');
    fresh.flush();
    expect(fresh.latest, lessThan(999999));

    // 5. clearForJoining clears holiday/repeat pause state too.
    pcStore.setSetting(StoreTodos.walkedSetting, '{}');
    pcStore.setSetting(StoreTodos.walkedHolidaysSetting, '[]');
    pcStore.setSetting(StoreTodos.pausedTimesSetting, '["r1@2026-11-19"]');
    pc.clearForJoining();
    expect(pcStore.setting(StoreTodos.walkedSetting), isNull);
    expect(pcStore.setting(StoreTodos.walkedHolidaysSetting), isNull);
    expect(pcStore.setting(StoreTodos.pausedTimesSetting), isNull);
  });

  test('sync register validation rejects invalid dates, months, weights, muscles, positions, and task history', () {
    final store = Store.memory();
    addTearDown(store.close);
    final dir = tempDir();
    final folder = SyncFolder(dir, 'pc', 'PC');
    final invalidCases = <List<Object?>>[
      ['entry', '2026-02-31/h1', 'status', jsonEncode(1), 1, 'other', {'other': 1}],
      ['habit_month', '2026-13', 'initialized', jsonEncode(true), 1, 'other', {'other': 1}],
      ['training_set', 's1', 'weight', jsonEncode(-5), 1, 'other', {'other': 1}],
      ['exercise', 'e1', 'muscle', jsonEncode('wings'), 1, 'other', {'other': 1}],
      ['month_habit', '2026-11/h1', 'position', jsonEncode(-1), 1, 'other', {'other': 1}],
      [
        'todo_history',
        '2026-11-19/t1',
        'snapshot',
        jsonEncode(jsonEncode({'scope': 'today', 'text': 'x', 'period': 'bad', 'since': '2026-11-19', 'done': 0, 'carried': 0, 'deleted': false})),
        1,
        'other',
        {'other': 1},
      ],
    ];
    for (final (i, reg) in invalidCases.indexed) {
      final sub = Directory(p.join(dir.path, 'case$i'))..createSync();
      final f = SyncFolder(sub, 'pc', 'PC');
      File(p.join(sub.path, 'other', '2026-11-19.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'version': 1, 'name': 'Other', 'registers': [reg]}));
      f.read(SyncEngine(store, 'pc'));
      expect(f.unread, {'Other'}, reason: 'case $i should be rejected: $reg');
    }
    expect(folder.hasOthers, isFalse);
  });

  test('AppDataFolder uses random boundaries, octet-stream for .db, coalesces bearer refreshes, retries 429/5xx, and keeps oldest journal duplicate', () async {
    final calls = <(String method, Uri uri, String? type, List<int>? body, String? bearer)>[];
    var refreshCount = 0;
    var listAttempt = 0;
    final folder = AppDataFolder(
      'refresh-token',
      send: (method, uri, {body, type, bearer}) async {
        calls.add((method, uri, type, body, bearer));
        if (uri.host == 'oauth2.googleapis.com') {
          refreshCount++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return (200, Uint8List.fromList(utf8.encode(jsonEncode({'access_token': 'tok-$refreshCount', 'expires_in': 3600}))));
        }
        if (method == 'GET' && uri.path == '/drive/v3/files' && (uri.queryParameters['spaces'] == 'appDataFolder')) {
          listAttempt++;
          if (listAttempt == 1) return (429, Uint8List(0));
          if (listAttempt == 2) return (503, Uint8List(0));
          return (200, Uint8List.fromList(utf8.encode(jsonEncode({'files': []}))));
        }
        if (uri.queryParameters['q']?.contains('mimeType =') == true) {
          return (
            200,
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'files': [
                    {'id': 'year-old', 'name': '2026'},
                    {'id': 'year-new', 'name': '2026'},
                  ],
                }),
              ),
            ),
          );
        }
        if (uri.queryParameters['q']?.contains('year-old') == true) {
          return (
            200,
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'files': [
                    {'id': 'file-old', 'name': '2026-11-19.md', 'md5Checksum': 'abc'},
                    {'id': 'file-new', 'name': '2026-11-19.md', 'md5Checksum': 'def'},
                  ],
                }),
              ),
            ),
          );
        }
        return (200, Uint8List.fromList(utf8.encode(jsonEncode({'id': 'u1', 'name': 'backup.db', 'modifiedTime': '2026-11-19T00:00:00Z'}))));
      },
      wait: (_) async {},
    );

    // Concurrent calls share a single token refresh, and 429 + 503 retry cleanly.
    final results = await Future.wait([folder.list(), folder.list()]);
    expect(results, [[], []]);
    expect(refreshCount, 1);

    // .db upload uses application/octet-stream and distinct multipart boundaries.
    await folder.upload('backup_pc_2026-11-19.db', [1, 2, 3]);
    await folder.upload('backup_pc_2026-11-20.db', [4, 5, 6]);
    final dbPosts = calls.where((c) => c.$1 == 'POST' && c.$2.path == '/upload/drive/v3/files').toList();
    expect(dbPosts, hasLength(2));
    final b1 = RegExp(r'boundary=([^\s;]+)').firstMatch(dbPosts[0].$3!)!.group(1)!;
    final b2 = RegExp(r'boundary=([^\s;]+)').firstMatch(dbPosts[1].$3!)!.group(1)!;
    expect(b1, isNot(b2));
    expect(utf8.decode(dbPosts[0].$4!, allowMalformed: true), contains('Content-Type: application/octet-stream'));
    await folder.upload('backup_pc_2026-11-19.db', [7, 8], id: 'existing-id');
    final dbPatch = calls.last;
    expect(dbPatch.$1, 'PATCH');
    expect(dbPatch.$3, 'application/octet-stream');

    // listJournal keeps the oldest duplicate (first in createdTime order).
    final (files, years) = await folder.listJournal('root-folder');
    expect(years['2026'], 'year-old');
    expect(files['2026/2026-11-19.md'], ('file-old', 'abc'));
  });

  test('JournalFolder hourly check detects MD5 changes in Drive and re-uploads reverted edits', () async {
    final drive = _FakeSyncDrive();
    final config = <String, dynamic>{};
    var now = DateTime(2026, 11, 19, 9);
    final folder = JournalFolder(config, () async {}, now: () => now);
    var text = 'My real entry';
    await folder.copy(
      drive,
      machine: 'pc',
      stamp: 's1',
      writers: () => {'2026-11-19': 'pc'},
      texts: () => {'2026-11-19': text},
      stopped: () => false,
    );
    final folderId = folder.id!;
    final yearId = (config['journalYears'] as Map)['2026'] as String;
    final fileId = (config['journalUp'] as Map)['2026-11-19'][0] as String;

    // Simulate Drive holding stale/reverted content while local has current content.
    await drive.writeFile('2026-11-19.md', yearId, utf8.encode('Old reverted entry'), id: fileId);
    now = now.add(const Duration(hours: 2));
    await folder.copy(
      drive,
      machine: 'pc',
      stamp: 's1',
      writers: () => {'2026-11-19': 'pc'},
      texts: () => {'2026-11-19': text},
      stopped: () => false,
    );
    expect(utf8.decode(drive.journalFiles[fileId]!.$3), contains('My real entry'));
    expect(await drive.exists(folderId), isTrue);
  });

  test('SyncService redacts sync.json.damaged with 0600 perms and look() does not wipe disk before turnOn()', () async {
    final dir = tempDir();
    final home = Directory(p.join(dir.path, 'home'))..createSync();
    final syncFile = File(p.join(home.path, 'sync.json'))
      ..writeAsStringSync(jsonEncode({'refresh': '1//super-secret', 'machine': 123}));
    Process.runSync('chmod', ['644', syncFile.path]);

    final store = Store.memory();
    addTearDown(store.close);
    final drive = _FakeSyncDrive();
    await drive.upload('other_2026-11-19.json', utf8.encode(jsonEncode({'version': 1, 'name': 'Other', 'registers': []})));

    final service = SyncService.load(home, store, connect: (_) => drive);
    addTearDown(service.dispose);
    final damagedFile = File('${syncFile.path}.damaged');
    expect(damagedFile.existsSync(), isTrue);
    final damagedText = damagedFile.readAsStringSync();
    expect(damagedText, isNot(contains('1//super-secret')));
    expect(damagedText, contains('<redacted>'));
    final mode = damagedFile.statSync().mode & 0x1FF;
    expect(mode, 0x180); // 0600

    // Seed local folder.disk with a pending cached file; look() must NOT wipe it.
    await service.folder.disk.writeBytes('pc', '2026-11-19.json', utf8.encode('{"cached":true}'));
    final hasOthers = await service.look(const GoogleAccount(email: 'a@example.com', id: 'a', refreshToken: 'R'));
    expect(hasOthers, isTrue);
    expect(service.folder.disk.exists('pc', '2026-11-19.json'), isTrue);
  });

  test('SyncService.stop() mid-_copyToDrive aborts cleanly without invoking afterDriveCopy', () async {
    final dir = tempDir();
    final home = Directory(p.join(dir.path, 'home'))..createSync();
    final store = Store.memory();
    addTearDown(store.close);
    final drive = _FakeSyncDrive();
    final service = SyncService.load(home, store, connect: (_) => drive);
    addTearDown(service.dispose);

    const account = GoogleAccount(email: 'a@example.com', id: 'a', refreshToken: 'R');
    await service.look(account);
    await service.turnOn(account, join: false);
    service.copiesToDrive = true;

    var afterCopyCalled = false;
    service.afterDriveCopy = () => afterCopyCalled = true;
    final gate = Completer<void>();
    drive.backupUploadGate = gate;

    final running = service.run();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    service.stop();
    gate.complete();
    await running;

    expect(afterCopyCalled, isFalse);
    expect(service.hasDriveCopy, isFalse);
    expect(service.error, isNull);
  });

  test('PhoneUpdater validates URL, SHA-256 checksum, +build, offline retries, .part cleanup, and install permission fallback', () async {
    final dir = tempDir();
    final updatesDir = Directory(p.join(dir.path, 'updates'));
    final apkBytes = utf8.encode('fake-apk-payload');
    final apkSha = sha256.convert(apkBytes).toString();
    var now = DateTime(2026, 11, 19, 10);

    // 1. Offline check failure leaves _checked unset so retry succeeds immediately.
    var call = 0;
    var downloadUrl = 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/Eclipse.apk';
    var releaseDigest = 'sha256:$apkSha';
    var releaseBody = '<!-- eclipse-build: 2 -->';
    var tag = 'v26.11.10';
    var installResult = false;
    var downloadCalls = 0;

    final updater = PhoneUpdater(
      installed: '26.11.10+1',
      fetch: (uri) async {
        call++;
        if (call == 1) return (503, const <int>[]);
        if (uri.path.endsWith('/SHA256SUMS')) {
          return (200, utf8.encode('$apkSha  Eclipse.apk\n'));
        }
        return (
          200,
          utf8.encode(
            jsonEncode({
              'tag_name': tag,
              'body': releaseBody,
              'assets': [
                {
                  'name': 'Eclipse.apk',
                  'browser_download_url': downloadUrl,
                  if (releaseDigest.isNotEmpty) 'digest': releaseDigest,
                },
                {
                  'name': 'SHA256SUMS',
                  'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/SHA256SUMS',
                },
              ],
            }),
          ),
        );
      },
      downloadToFile: (uri, part) async {
        downloadCalls++;
        await part.writeAsBytes(apkBytes, flush: true);
      },
      install: (_) async => installResult,
      updatesDir: () async => updatesDir,
      now: () => now,
    );

    await updater.check(); // HTTP 503
    expect(updater.available, isNull);
    // Same timestamp (within 3h) still retries because first check failed!
    await updater.check();
    expect(updater.available, '26.11.10', reason: 'same version with newer +build 2 > 1 is offered');

    // First install returns false -> sets clear guidance error, keeps verified Eclipse.apk.
    await updater.update();
    expect(updater.error, contains('Settings'));
    expect(downloadCalls, 1);
    expect(File(p.join(updatesDir.path, 'Eclipse.apk')).existsSync(), isTrue);

    // Retry after user allows permission -> reuses verified Eclipse.apk without re-downloading.
    installResult = true;
    await updater.update();
    expect(updater.error, isNull);
    expect(downloadCalls, 1);

    // Non-GitHub / HTTP URL is rejected during check.
    now = now.add(const Duration(hours: 4));
    downloadUrl = 'http://evil.example/Eclipse.apk';
    final badUrlUpdater = PhoneUpdater(
      installed: '26.11.9+1',
      fetch: (_) async => (
        200,
        utf8.encode(
          jsonEncode({
            'tag_name': 'v26.11.10',
            'body': '<!-- eclipse-build: 1 -->',
            'assets': [
              {'name': 'Eclipse.apk', 'browser_download_url': downloadUrl, 'digest': releaseDigest},
            ],
          }),
        ),
      ),
      updatesDir: () async => updatesDir,
    );
    await badUrlUpdater.check();
    expect(badUrlUpdater.available, isNull);

    // Checksum mismatch deletes .part and reports error.
    final mismatchDir = Directory(p.join(dir.path, 'updates2'));
    final mismatchUpdater = PhoneUpdater(
      installed: '26.11.9+1',
      fetch: (_) async => (
        200,
        utf8.encode(
          jsonEncode({
            'tag_name': 'v26.11.10',
            'body': '<!-- eclipse-build: 1 -->',
            'assets': [
              {
                'name': 'Eclipse.apk',
                'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/Eclipse.apk',
                'digest': 'sha256:${'0' * 64}',
              },
            ],
          }),
        ),
      ),
      downloadToFile: (uri, part) async => part.writeAsBytes(apkBytes, flush: true),
      install: (_) async => true,
      updatesDir: () async => mismatchDir,
    );
    await mismatchUpdater.check();
    await mismatchUpdater.update();
    expect(mismatchUpdater.error, contains('checksum'));
    expect(File(p.join(mismatchDir.path, 'Eclipse.apk.part')).existsSync(), isFalse);
    expect(File(p.join(mismatchDir.path, 'Eclipse.apk')).existsSync(), isFalse);

    // Missing digest falls back to SHA256SUMS asset.
    final sumsDir = Directory(p.join(dir.path, 'updates3'));
    final sumsUpdater = PhoneUpdater(
      installed: '26.11.9+1',
      fetch: (uri) async {
        if (uri.path.endsWith('/SHA256SUMS')) return (200, utf8.encode('$apkSha  Eclipse.apk\n'));
        return (
          200,
          utf8.encode(
            jsonEncode({
              'tag_name': 'v26.11.10',
              'body': '<!-- eclipse-build: 1 -->',
              'assets': [
                {
                  'name': 'Eclipse.apk',
                  'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/Eclipse.apk',
                },
                {
                  'name': 'SHA256SUMS',
                  'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/SHA256SUMS',
                },
              ],
            }),
          ),
        );
      },
      downloadToFile: (uri, part) async => part.writeAsBytes(apkBytes, flush: true),
      install: (_) async => true,
      updatesDir: () async => sumsDir,
    );
    await sumsUpdater.check();
    await sumsUpdater.update();
    expect(sumsUpdater.error, isNull);
    expect(File(p.join(sumsDir.path, 'Eclipse.apk')).existsSync(), isTrue);
  });
}
