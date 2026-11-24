import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/sqlite.dart' show sqlite3;
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_disk.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Computer {
  _Computer(this.name) : store = Store.memory() {
    engine = SyncEngine(store, name);
  }

  final String name;
  final Store store;
  late SyncEngine engine;
  static int clock = 1000;

  void stamp() => store.raw.execute('UPDATE sync_dirty SET at = ? WHERE at > ?', [clock, 1e12]);

  Incoming hearFrom(_Computer other) {
    stamp();
    other.stamp();
    other.engine.flush();
    return engine.mergeAll([(other.engine.changesSince(0).values.expand((day) => day), other.name)]);
  }

  Map<String, Object?> dump() {
    final db = store.raw;
    List<String> rows(String sql) => [for (final r in db.select(sql)) r.values.join('|')]..sort();
    return {
      'months': rows(
        'SELECT year, month, h.uid, name, position, note FROM month_habits JOIN habits h ON h.id = habit_id',
      ),
      'entries': rows('SELECT day, h.uid, status, note FROM entries JOIN habits h ON h.id = habit_id'),
      'todos': rows('SELECT uid, scope, period, text, done, carried, since FROM todos'),
      'journal': rows('SELECT day, text FROM journal'),
      'sleep': rows('SELECT year, month, item, note FROM sleep_notes'),
      'settings': rows("SELECT key, value FROM settings WHERE key IN ('dayStartHour')"),
    };
  }
}

class _FakeDrive implements SyncDrive, JournalDrive, CopiesDrive {
  final files = <String, (String name, List<int> bytes, int ver)>{};
  final folders = <String, (String name, String? parent)>{};
  final journalFiles = <String, (String name, String parent, List<int> bytes, String md5)>{};
  var _next = 0;

  @override
  Future<List<DriveFile>> list() async => [
    for (final e in files.entries) DriveFile(id: e.key, name: e.value.$1, modified: '${e.value.$3}'),
  ];

  @override
  Future<List<int>> download(String id) async => files[id]!.$2;

  @override
  Future<DriveFile> upload(String name, List<int> bytes, {String? id}) async {
    final key = id ?? 'f${_next++}';
    files[key] = (name, bytes, _next++);
    return DriveFile(id: key, name: name, modified: '${files[key]!.$3}');
  }

  @override
  Future<void> delete(String id) async => files.remove(id);

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
    final id = 'd${_next++}';
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
        if (e.value.$2 == folder && e.value.$1 != '') e.value.$1: e.key,
    };
    return (
      {
        for (final y in years.entries)
          for (final f in journalFiles.entries)
            if (f.value.$2 == y.value) '${y.key}/${f.value.$1}': (f.key, f.value.$4),
      },
      years,
    );
  }

  @override
  Future<(String, String)> writeFile(String name, String folder, List<int> bytes, {String? id}) async {
    final key = id ?? 'j${_next++}';
    journalFiles[key] = (name, folder, bytes, md5.convert(bytes).toString());
    return (key, journalFiles[key]!.$4);
  }

  @override
  Future<void> bin(String id) async {
    folders.remove(id);
    journalFiles.remove(id);
  }
}

void main() {
  Directory tempDir([String prefix = 'eclipse_sync']) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  late _Computer pc, laptop;
  final day = DateTime(2026, 10, 24);

  setUp(() {
    _Computer.clock = 1000;
    pc = _Computer('pc');
    laptop = _Computer('laptop');
    addTearDown(pc.store.close);
    addTearDown(laptop.store.close);
    final read = pc.store.addHabit(2026, 10, 'Read');
    pc.store.addHabit(2026, 10, 'Run');
    pc.store.setEntry('2026-10-23', read.id, HabitStatus.missed);
    pc.store.setNote('2026-10-23', read.id, 'Too tired');
    pc.store.addTodo(TodoScope.today, day, 'Post the letter');
    pc.store.setJournal('2026-10-22', 'Earlier entry');
    pc.store.setSetting('dayStartHour', '0');
    pc.store.setSetting('theme', 'Lunar Eclipse');
    pc.store.setSleepNote(2026, 10, SleepItem.sleepEarly, '22:30');
    laptop.store.addHabit(2026, 10, 'Make the bed');
    laptop.store.addTodo(TodoScope.today, day, 'Tick this off to try it');
  });

  void join() {
    pc.stamp();
    pc.engine.claimAll();
    laptop.engine.clearForJoining();
    laptop.hearFrom(pc);
  }

  group('sync engine & conflicts', () {
    test('joining copies full history, keeps theme local, and re-merge is idempotent', () {
      join();
      expect(laptop.dump(), pc.dump());
      expect(laptop.store.setting('theme'), isNull);
      expect(laptop.hearFrom(pc).isEmpty, isTrue);
      expect(pc.hearFrom(laptop).isEmpty, isTrue);
      expect(pc.store.raw.select("SELECT uid FROM habits WHERE uid LIKE 'sleep-%'"), hasLength(SleepItem.values.length));
    });

    test('habit ticks, rituals and tasks follow across and resolve later-wins conflicts', () {
      join();
      final pcRead = pc.store.monthHabits(2026, 10).first;
      final laptopRead = laptop.store.monthHabits(2026, 10).first;
      _Computer.clock = 2000;
      pc.store.setEntry('2026-10-24', pcRead.id, HabitStatus.missed);
      pc.stamp();
      _Computer.clock = 3000;
      laptop.store.setEntry('2026-10-24', laptopRead.id, HabitStatus.done);
      pc.hearFrom(laptop);
      laptop.hearFrom(pc);
      expect(pc.dump(), laptop.dump());
      expect(pc.dump()['entries'], contains(endsWith('|${HabitStatus.done.index}|null')));

      final added = laptop.store.addTodo(TodoScope.week, day, 'Call the bank');
      pc.hearFrom(laptop);
      expect(pc.store.todos(TodoScope.week, TodoScope.week.period(day)).map((t) => t.text), contains('Call the bank'));
      _Computer.clock = 4000;
      laptop.store.deleteTodo(added.id);
      pc.hearFrom(laptop);
      expect(pc.dump()['todos'], hasLength(1));

      final run = laptop.store.monthHabits(2026, 10).last;
      _Computer.clock = 5000;
      laptop.store.renameHabit(2026, 10, run.id, 'Run 5k');
      pc.hearFrom(laptop);
      expect(pc.store.monthHabits(2026, 10).map((h) => h.name), ['Read', 'Run 5k']);
      _Computer.clock = 6000;
      laptop.store.removeHabit(2026, 10, run.id);
      pc.hearFrom(laptop);
      expect(pc.store.monthHabits(2026, 10).map((h) => h.name), ['Read']);
    });

    test('todo_history_delete trigger syncs undone task deletions', () async {
      join();
      final pcState = AppState(pc.store, clock: () => day);
      final laptopState = AppState(laptop.store, clock: () => day);
      addTearDown(pcState.dispose);
      addTearDown(laptopState.dispose);

      _Computer.clock = 2000;
      pcState.addTodo(TodoScope.today, 'Buy milk');
      final item = pcState.todos[TodoScope.today]!.firstWhere((t) => t.text == 'Buy milk');
      laptop.hearFrom(pc);
      expect(laptop.store.todos(TodoScope.today, dateKey(day)).map((t) => t.text), contains('Buy milk'));

      _Computer.clock = 3000;
      pcState.removeTodo(TodoScope.today, item);
      laptop.hearFrom(pc);
      expect(laptop.store.todos(TodoScope.today, dateKey(day)).map((t) => t.text), isNot(contains('Buy milk')));

      _Computer.clock = 4000;
      pcState.undo();
      laptop.hearFrom(pc);
      expect(laptop.store.todos(TodoScope.today, dateKey(day)).map((t) => t.text), contains('Buy milk'));
    });

    test('concurrent journal edits keep both deterministically; later edit replaces', () {
      join();
      _Computer.clock = 2000;
      pc.store.setJournal('2026-10-24', 'Morning on PC');
      pc.stamp();
      _Computer.clock = 3000;
      laptop.store.setJournal('2026-10-24', 'Evening on laptop');
      final onPc = pc.hearFrom(laptop);
      final onLaptop = laptop.hearFrom(pc);
      pc.hearFrom(laptop);
      laptop.hearFrom(pc);
      expect(onPc.keptBoth, {'2026-10-24'});
      expect(onLaptop.keptBoth, isEmpty);
      expect(pc.store.journal('2026-10-24'), 'Morning on PC${Store.journalBreak}Evening on laptop');
      expect(pc.dump(), laptop.dump());

      _Computer.clock = 4000;
      laptop.store.setJournal('2026-10-24', 'Edited after seeing both');
      expect(pc.hearFrom(laptop).keptBoth, isEmpty);
      expect(pc.store.journal('2026-10-24'), 'Edited after seeing both');
    });

    test('day start on another device never unticks a completed task', () {
      join();
      final next = DateTime(2026, 10, 25);
      _Computer.clock = 2000;
      final onPc = pc.store.todos(TodoScope.today, dateKey(day)).single;
      pc.store.setTodoDone(onPc.id, true, day: day);
      pc.stamp();
      _Computer.clock = 3000;
      laptop.store.startDay(next);
      for (final (a, b) in [(pc, laptop), (laptop, pc), (pc, laptop)]) {
        a.hearFrom(b);
        a.store.startDay(next);
      }
      expect(laptop.store.todoListsOn(day)[TodoScope.today]!.single.done, isTrue);
      expect(laptop.store.todoListsOn(next)[TodoScope.today], isEmpty);
    });

    test('concurrent holiday additions and removals converge across devices', () {
      join();
      final nov = (start: DateTime(2026, 11, 10), end: DateTime(2026, 11, 12));
      final dec = (start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 27));
      final jan = (start: DateTime(2027, 1, 4), end: DateTime(2027, 1, 8));
      _Computer.clock = 2000;
      pc.store.setSetting('holidays', encodeHolidays([nov, dec]));
      _Computer.clock = 3000;
      laptop.hearFrom(pc);
      _Computer.clock = 4000;
      pc.store.setSetting('holidays', encodeHolidays([dec]));
      _Computer.clock = 5000;
      laptop.store.setSetting('holidays', encodeHolidays([nov, dec, jan]));
      pc.hearFrom(laptop);
      laptop.hearFrom(pc);
      expect(decodeHolidays(pc.store.setting('holidays')), [dec, jan]);
      expect(decodeHolidays(laptop.store.setting('holidays')), [dec, jan]);
    });

    test('ended repeat does not resurrect open future occurrences across devices', () {
      join();
      final today = DateTime(2026, 11, 3);
      final repeat = pc.store.addRepeat('Water plants', const RepeatRule.every(1), DateTime(2026, 11, 1));
      _Computer.clock = 2000;
      pc.store.makeRepeats(today);
      laptop.hearFrom(pc);
      laptop.store.makeRepeats(DateTime(2026, 11, 4));
      _Computer.clock = 3000;
      pc.store.endRepeat(repeat.uid, DateTime(2026, 11, 8), today);
      laptop.hearFrom(pc);
      laptop.store.makeRepeats(today);
      pc.hearFrom(laptop);
      pc.store.makeRepeats(today);
      for (final c in [pc, laptop]) {
        expect(c.store.repeats().single.until, DateTime(2026, 11, 7));
        final openAfter = c.store.raw.select(
          "SELECT uid FROM todos WHERE uid LIKE '${repeat.uid}@%' AND done = 0 AND substr(uid, ${repeat.uid.length + 2}) > '2026-11-07'",
        );
        expect(openAfter, isEmpty);
      }
    });

    test('far-future clock cannot poison edits, unknown kinds are kept, and invalid registers are rejected', () {
      join();
      final future = DateTime(2040).millisecondsSinceEpoch;
      laptop.engine = SyncEngine(laptop.store, 'laptop', clock: () => future);
      final read = laptop.store.monthHabits(2026, 10).first;
      laptop.store.setEntry('2026-10-24', read.id, HabitStatus.done);
      laptop.store.raw.execute('UPDATE sync_dirty SET at = ?', [future]);
      laptop.engine.flush();
      pc.engine.mergeAll([(laptop.engine.changesSince(0).values.expand((d) => d), 'laptop')]);
      pc.store.setEntry('2026-10-24', pc.store.monthHabits(2026, 10).first.id, HabitStatus.missed);
      pc.engine.flush();
      laptop.engine.mergeAll([(pc.engine.changesSince(0).values.expand((d) => d), 'pc')]);
      expect(laptop.store.entriesInMonth(2026, 10).singleWhere((e) => e.day == '2026-10-24').status, HabitStatus.missed);

      laptop.engine.mergeAll([
        (
          [
            ['mood', '2026-10-24', 'value', jsonEncode(4), 5000, 'mac', {'mac': 5000}],
          ],
          'Tablet',
        ),
      ]);
      expect(laptop.engine.newerOrigins, {'mac'});

      final dir = tempDir('eclipse_bad_reg');
      final folder = SyncFolder(dir, 'pc', 'PC');
      File(p.join(dir.path, 'other', '2026-11-19.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'version': 1,
            'name': 'Other',
            'registers': [
              ['entry', '2026-02-31/h1', 'status', jsonEncode(1), 1, 'other', {'other': 1}],
            ],
          }),
        );
      folder.read(SyncEngine(pc.store, 'pc'));
      expect(folder.unread, {'Other'});
    });

    test('restoring a backup syncs restored state without erasing newer writing', () async {
      final dir = tempDir('eclipse_restore_sync');
      pc.store.setJournal('2026-10-23', 'Before backup');
      join();
      final backup = p.join(dir.path, 'backup.db');
      pc.store.saveCopy(backup);
      final read = laptop.store.monthHabits(2026, 10).first;
      _Computer.clock = 2000;
      laptop.store.setEntry('2026-10-24', read.id, HabitStatus.done);
      laptop.store.setJournal('2026-10-24', 'Written after backup');
      pc.hearFrom(laptop);
      _Computer.clock = 3000;
      await pc.store.restoreFrom(backup);
      pc.engine = SyncEngine(pc.store, 'pc');
      laptop.hearFrom(pc);
      expect(laptop.dump(), pc.dump());
      expect(laptop.store.journal('2026-10-24'), 'Written after backup');
    });
  });

  group('Drive & browser SyncService', () {
    const account = GoogleAccount(email: 'me@example.com', id: 'id-1', refreshToken: 'lasting');

    test('first device starts, second joins via beforeJoin, edits flow both ways and unchanged files stay put', () async {
      final dir = tempDir('eclipse_drive_flow');
      final drive = _FakeDrive();
      final onPc = SyncService.load(Directory(p.join(dir.path, 'pc'))..createSync(), pc.store, connect: (_) => drive);
      final onLaptop = SyncService.load(
        Directory(p.join(dir.path, 'laptop'))..createSync(),
        laptop.store,
        connect: (_) => drive,
      );
      addTearDown(onPc.dispose);
      addTearDown(onLaptop.dispose);

      expect(await onPc.look(account), isFalse);
      await onPc.turnOn(account, join: false);
      var backedUpBeforeJoin = false;
      onLaptop.beforeJoin = () => backedUpBeforeJoin = true;
      expect(await onLaptop.look(account), isTrue);
      await onLaptop.turnOn(account, join: true);
      expect(backedUpBeforeJoin, isTrue);
      expect(laptop.dump(), pc.dump());

      laptop.store.setJournal('2026-10-24', 'Written on laptop');
      await onLaptop.run();
      await onPc.run();
      expect(pc.store.journal('2026-10-24'), 'Written on laptop');

      final versions = {for (final f in drive.files.values) f.$1: f.$3};
      await onPc.run();
      await onLaptop.run();
      expect({for (final f in drive.files.values) f.$1: f.$3}, versions);
    });

    test('path traversal files ignored and damaged sync.json leaves app starting safely', () async {
      final dir = tempDir('eclipse_drive_guard');
      final drive = _FakeDrive();
      await drive.upload('pc_../../escaped.json', utf8.encode('{}'));
      final home = Directory(p.join(dir.path, 'home'))..createSync();
      final damagedFile = File(p.join(home.path, 'sync.json'))
        ..writeAsStringSync(jsonEncode({'refresh': '1//secret', 'machine': 123}));
      final service = SyncService.load(home, laptop.store, connect: (_) => drive);
      addTearDown(service.dispose);
      expect(File('${damagedFile.path}.damaged').readAsStringSync(), isNot(contains('1//secret')));
      await service.look(account);
      expect(File(p.join(dir.path, 'escaped.json')).existsSync(), isFalse);

      final broken = Directory(p.join(dir.path, 'broken'))..createSync();
      File(p.join(broken.path, 'sync.json')).writeAsStringSync('[]');
      final safe = SyncService.load(broken, laptop.store, connect: (_) => drive);
      addTearDown(safe.dispose);
      expect(safe.isOn, isFalse);
      expect(safe.error, isNotNull);
    });

    test('account switch requires explicit transfer or join', () async {
      final dir = tempDir('eclipse_acct_switch');
      final driveA = _FakeDrive(), driveB = _FakeDrive();
      const accountA = GoogleAccount(email: 'a@example.com', id: 'a', refreshToken: 'A');
      const accountB = GoogleAccount(email: 'b@example.com', id: 'b', refreshToken: 'B');
      final store = Store.memory();
      addTearDown(store.close);
      store.setJournal('2026-10-25', 'Private to A');

      var service = SyncService.load(dir, store, connect: (t) => t == 'A' ? driveA : driveB);
      await service.look(accountA);
      await service.turnOn(accountA, join: false);
      await service.turnOff();
      service.dispose();

      service = SyncService.load(dir, store, connect: (t) => t == 'A' ? driveA : driveB);
      addTearDown(service.dispose);
      expect(service.needsAccountChoice(accountB), isTrue);
      await service.look(accountB);
      await expectLater(service.turnOn(accountB, join: false), throwsA(isA<DriveError>()));
      await service.turnOn(accountB, join: false, transfer: true);
      expect(driveB.files.values.any((f) => utf8.decode(f.$2).contains('Private to A')), isTrue);
    });

    test('DatabaseDisk & DatabaseSettings sync both ways in browser storage', () async {
      final drive = _FakeDrive();
      final pcDb = sqlite3.openInMemory(), webDb = sqlite3.openInMemory();
      addTearDown(pcDb.close);
      addTearDown(webDb.close);
      final first = SyncService.loadFrom(DatabaseSettings(pcDb), DatabaseDisk(pcDb), pc.store, connect: (_) => drive);
      final second = SyncService.loadFrom(
        DatabaseSettings(webDb),
        DatabaseDisk(webDb),
        laptop.store,
        connect: (_) => drive,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await first.look(account);
      await first.turnOn(account, join: false);
      expect(await second.look(account), isTrue);
      await second.turnOn(account, join: true);
      expect(laptop.dump(), pc.dump());

      laptop.store.setJournal('2026-10-25', 'Written in browser');
      await second.run();
      await first.run();
      expect(pc.store.journal('2026-10-25'), 'Written in browser');
    });
  });
}
