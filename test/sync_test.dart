import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/models.dart';

/// Two computers, each with its own database, exchanging change files the
/// way they would through Drive.
class _Computer {
  _Computer(this.name) : store = Store.memory() {
    engine = SyncEngine(store, name);
  }

  final String name;
  final Store store;
  late SyncEngine engine;

  /// Shared by both, so tests decide which edit came later.
  static int clock = 1000;

  /// Edits since the last call happened at [clock], not the real time.
  void stamp() => store.raw.execute('UPDATE sync_dirty SET at = ? WHERE at > ?', [clock, 1e12]);

  Incoming hearFrom(_Computer other) {
    stamp();
    other.stamp();
    other.engine.flush();
    return engine.mergeAll([(other.engine.changesSince(0).values.expand((day) => day), other.name)]);
  }

  /// Everything that syncs, by ids that mean the same on both.
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
      'settings': rows("SELECT key, value FROM settings WHERE key IN ('dayStartHour', 'restWeekends')"),
    };
  }
}

/// One Google account's hidden Eclipse folder, in memory.
class _FakeDrive implements SyncDrive {
  final files = <String, (String, List<int>, int)>{}; // id: name, bytes, version
  var _next = 0;
  var signedOut = false;

  void _check() {
    if (signedOut) throw const DriveError('Google signed Eclipse out. Sign in again.', signedOut: true);
  }

  @override
  Future<List<DriveFile>> list() async {
    _check();
    return [
      for (final MapEntry(:key, :value) in files.entries) DriveFile(id: key, name: value.$1, modified: '${value.$3}'),
    ];
  }

  @override
  Future<List<int>> download(String id) async => files[id]!.$2;

  @override
  Future<void> upload(String name, List<int> bytes, {String? id}) async {
    _check();
    files[id ?? 'f${_next++}'] = (name, bytes, _next++);
  }
}

void main() {
  late _Computer pc, laptop;
  final day = DateTime(2026, 10, 24);

  setUp(() {
    _Computer.clock = 1000;
    pc = _Computer('pc');
    laptop = _Computer('laptop');
    // The PC has history; the laptop has only a new install's examples.
    final read = pc.store.addHabit(2026, 10, 'Read');
    pc.store.addHabit(2026, 10, 'Run');
    pc.store.setEntry('2025-06-01', read.id, HabitStatus.done);
    pc.store.setEntry('2026-10-23', read.id, HabitStatus.missed);
    pc.store.setNote('2026-10-23', read.id, 'Too tired');
    pc.store.addTodo(TodoScope.today, day, 'Post the letter');
    pc.store.setJournal('2025-06-01', 'A long time ago');
    pc.store.setSetting('restWeekends', '1');
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

  test('a computer that joins takes the whole history, and nothing of its own', () {
    join();
    expect(laptop.dump(), pc.dump());
    expect(laptop.store.setting('theme'), isNull, reason: 'each computer keeps its own theme');
  });

  test('a tick on one shows on the other', () {
    join();
    final read = laptop.store.monthHabits(2026, 10).first;
    _Computer.clock = 2000;
    laptop.store.setEntry('2026-10-24', read.id, HabitStatus.done);
    final incoming = pc.hearFrom(laptop);
    expect(incoming.changes, 1);
    expect(incoming.from, {'laptop'});
    expect(pc.dump(), laptop.dump());
  });

  test('ticked differently on both before syncing: the later one wins on both', () {
    join();
    final onPc = pc.store.monthHabits(2026, 10).first, onLaptop = laptop.store.monthHabits(2026, 10).first;
    _Computer.clock = 2000;
    pc.store.setEntry('2026-10-24', onPc.id, HabitStatus.missed);
    pc.stamp();
    _Computer.clock = 3000;
    laptop.store.setEntry('2026-10-24', onLaptop.id, HabitStatus.done);
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    expect(pc.dump(), laptop.dump());
    expect(pc.dump()['entries'], contains(endsWith('|${HabitStatus.done.index}|null')));
    expect(pc.dump()['entries'], isNot(contains(endsWith('|${HabitStatus.missed.index}|null'))));
  });

  test('the journal written on both before syncing keeps both texts, the same on both', () {
    join();
    _Computer.clock = 2000;
    pc.store.setJournal('2026-10-24', 'Morning on the PC');
    pc.stamp();
    _Computer.clock = 3000;
    laptop.store.setJournal('2026-10-24', 'Evening on the laptop');
    final onPc = pc.hearFrom(laptop);
    final onLaptop = laptop.hearFrom(pc);
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    expect(onPc.keptBoth, {'2026-10-24'});
    expect(onLaptop.keptBoth, isEmpty, reason: 'the PC already kept both; the laptop takes that');
    expect(pc.store.journal('2026-10-24'), 'Morning on the PC\n\n---\n\nEvening on the laptop');
    expect(pc.dump(), laptop.dump());
  });

  test('both keeping both at once agree, and writing on afterwards replaces it, not doubled', () {
    join();
    _Computer.clock = 2000;
    pc.store.setJournal('2026-10-24', 'A');
    _Computer.clock = 3000;
    laptop.store.setJournal('2026-10-24', 'B');
    List<List<Object?>> sent(_Computer c) {
      c.stamp();
      c.engine.flush();
      return c.engine.changesSince(0).values.expand((day) => day).toList();
    }

    // Each hears the other's first text before either hears the other's merge.
    final (fromPc, fromLaptop) = (sent(pc), sent(laptop));
    expect(pc.engine.mergeAll([(fromLaptop, 'laptop')]).keptBoth, {'2026-10-24'});
    expect(laptop.engine.mergeAll([(fromPc, 'pc')]).keptBoth, {'2026-10-24'});
    expect(pc.store.journal('2026-10-24'), laptop.store.journal('2026-10-24'));

    _Computer.clock = 4000;
    pc.store.setJournal('2026-10-24', 'A\n\n---\n\nB, and more');
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    expect(pc.store.journal('2026-10-24'), 'A\n\n---\n\nB, and more');
    expect(pc.dump(), laptop.dump());
  });

  test('a journal edited after seeing the other replaces it, without keeping both', () {
    join();
    _Computer.clock = 2000;
    pc.store.setJournal('2026-10-24', 'First draft');
    laptop.hearFrom(pc);
    _Computer.clock = 3000;
    laptop.store.setJournal('2026-10-24', 'First draft, finished on the laptop');
    final incoming = pc.hearFrom(laptop);
    expect(incoming.keptBoth, isEmpty);
    expect(pc.store.journal('2026-10-24'), 'First draft, finished on the laptop');
  });

  test('to-dos added, ticked and deleted follow across', () {
    join();
    _Computer.clock = 2000;
    final added = laptop.store.addTodo(TodoScope.week, day, 'Call the bank');
    pc.hearFrom(laptop);
    expect(pc.store.todos(TodoScope.week, TodoScope.week.period(day)).map((t) => t.text), contains('Call the bank'));
    _Computer.clock = 3000;
    final onPc = pc.store.todos(TodoScope.today, TodoScope.today.period(day)).single;
    pc.store.setTodoDone(onPc.id, true);
    laptop.hearFrom(pc);
    expect(laptop.store.todos(TodoScope.today, TodoScope.today.period(day)).single.done, isTrue);
    _Computer.clock = 4000;
    laptop.store.deleteTodo(added.id);
    pc.hearFrom(laptop);
    expect(pc.dump(), laptop.dump());
    expect(pc.dump()['todos'], hasLength(1));
  });

  test('a to-do ticked on one while the other carries it to the next day keeps the tick', () {
    join();
    final next = DateTime(2026, 10, 25);
    _Computer.clock = 2000;
    final onPc = pc.store.todos(TodoScope.today, TodoScope.today.period(day)).single;
    pc.store.setTodoDone(onPc.id, true);
    pc.stamp();
    _Computer.clock = 3000;
    laptop.store.carryForward(TodoScope.today, TodoScope.today.period(next));
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    expect(pc.dump(), laptop.dump());
    expect(pc.dump()['todos'].toString(), contains('|1|'), reason: 'still done');
  });

  test('rituals renamed and removed follow across', () {
    join();
    final run = laptop.store.monthHabits(2026, 10).last;
    _Computer.clock = 2000;
    laptop.store.renameHabit(2026, 10, run.id, 'Run 5k');
    pc.hearFrom(laptop);
    expect(pc.store.monthHabits(2026, 10).map((h) => h.name), ['Read', 'Run 5k']);
    _Computer.clock = 3000;
    laptop.store.removeHabit(2026, 10, run.id);
    pc.hearFrom(laptop);
    expect(pc.store.monthHabits(2026, 10).map((h) => h.name), ['Read']);
    expect(pc.dump(), laptop.dump());
  });

  test('hearing the same changes twice changes nothing', () {
    join();
    expect(laptop.hearFrom(pc).isEmpty, isTrue);
    expect(pc.hearFrom(laptop).isEmpty, isTrue);
  });

  test('restoring a backup sends the restored data to the other computer', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse-sync');
    addTearDown(() => dir.deleteSync(recursive: true));
    join();
    final backup = '${dir.path}/backup.db';
    pc.store.saveCopy(backup);
    final read = laptop.store.monthHabits(2026, 10).first;
    _Computer.clock = 2000;
    laptop.store.setEntry('2026-10-24', read.id, HabitStatus.done);
    laptop.store.setJournal('2026-10-24', 'Written after the backup');
    pc.hearFrom(laptop);
    _Computer.clock = 3000;
    await pc.store.restoreFrom(backup);
    pc.engine = SyncEngine(pc.store, 'pc');
    laptop.hearFrom(pc);
    expect(laptop.dump(), pc.dump());
    expect(laptop.store.journal('2026-10-24'), '');
  });

  test('change files on disk carry the same changes', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse-sync');
    addTearDown(() => dir.deleteSync(recursive: true));
    pc.engine.claimAll();
    expect(await SyncFolder(dir, 'pc', 'PC').write(pc.engine, 0), isTrue);
    final folder = SyncFolder(dir, 'laptop', 'Laptop');
    expect(folder.hasOthers, isTrue);
    laptop.engine.clearForJoining();
    final incoming = folder.read(laptop.engine);
    expect(incoming.from, {'PC'});
    expect(laptop.dump(), pc.dump());
    expect(folder.read(laptop.engine).isEmpty, isTrue, reason: 'files already read are skipped');
  });

  test('the sleep schedule has the same ids on every computer', () {
    final sleep = pc.store.raw.select("SELECT uid FROM habits WHERE uid LIKE 'sleep-%'");
    expect(sleep, hasLength(SleepItem.values.length));
  });

  group('through Google Drive', () {
    late Directory dir;
    late _FakeDrive drive;
    const account = GoogleAccount(email: 'me@example.com', refreshToken: 'lasting');

    setUp(() {
      dir = Directory.systemTemp.createTempSync('eclipse-drive');
      drive = _FakeDrive();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    SyncService service(_Computer c) {
      final home = Directory('${dir.path}/${c.name}')..createSync();
      return SyncService.load(home, c.store, connect: (_) => drive, signIn: ({cancel}) async => account);
    }

    test('the first computer starts it, the next joins, and edits go both ways', () async {
      final onPc = service(pc), onLaptop = service(laptop);
      expect(await onPc.look(await onPc.signIn()), isFalse, reason: 'nothing there yet');
      await onPc.turnOn(account, join: false);
      expect(onPc.email, 'me@example.com');
      expect(drive.files, isNotEmpty);

      expect(await onLaptop.look(account), isTrue);
      await onLaptop.turnOn(account, join: true);
      expect(laptop.dump(), pc.dump());

      laptop.store.setJournal('2026-10-24', 'Written on the laptop');
      await onLaptop.run();
      await onPc.run();
      expect(pc.store.journal('2026-10-24'), 'Written on the laptop');
      expect(onPc.lastIncoming?.changes, greaterThan(0));
      expect(pc.dump(), laptop.dump());

      // Files already copied aren't copied again.
      final versions = {for (final f in drive.files.values) f.$1: f.$3};
      await onPc.run();
      await onLaptop.run();
      expect({for (final f in drive.files.values) f.$1: f.$3}, versions);
      onPc.dispose();
      onLaptop.dispose();
    });

    test('joining saves a copy of what was here first, listed with the backups', () async {
      final onPc = service(pc), onLaptop = service(laptop);
      await onPc.look(account);
      await onPc.turnOn(account, join: false);

      laptop.store.addTodo(TodoScope.today, DateTime(2026, 10, 24), 'Only on the laptop');
      final backups = Backups(Directory('${dir.path}/backups'));
      AppState(laptop.store, backups: backups, sync: onLaptop, clock: () => DateTime(2026, 10, 24));
      await onLaptop.look(account);
      await onLaptop.turnOn(account, join: true);
      expect(laptop.dump(), pc.dump());

      final copy = backups.list().singleWhere((b) => b.isBeforeJoin);
      expect(copy.isBeforeRestore, isFalse);
      final saved = Store.open(copy.file.path);
      expect(saved.raw.select('SELECT text FROM todos').map((r) => r['text']), contains('Only on the laptop'));
      saved.close();
      onPc.dispose();
      onLaptop.dispose();
    });

    test('a sign-in Google takes back turns sync off, saying so', () async {
      final onPc = service(pc);
      await onPc.look(account);
      await onPc.turnOn(account, join: false);
      drive.signedOut = true;
      await onPc.run();
      expect(onPc.isOn, isFalse);
      expect(onPc.error, contains('Sign in again'));
      expect(service(pc).isOn, isFalse, reason: 'remembered after a restart');
      onPc.dispose();
    });
  });
}
