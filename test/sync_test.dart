import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show AllowedArgumentCount;
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/training.dart';

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

/// One Google account's hidden Eclipse folder, and the folders and files
/// Eclipse made in the rest of Drive, in memory.
class _FakeDrive implements SyncDrive, JournalDrive {
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
      for (final MapEntry(:key, :value) in files.entries)
        if (!hidden.contains(key)) DriveFile(id: key, name: value.$1, modified: '${value.$3}'),
    ];
  }

  /// Files whose next download comes back cut short, as a dropped
  /// connection can leave it.
  final cutShort = <String>{};

  @override
  Future<List<int>> download(String id) async {
    final bytes = files[id]!.$2;
    return cutShort.remove(id) ? bytes.sublist(0, bytes.length ~/ 2) : bytes;
  }

  @override
  Future<DriveFile> upload(String name, List<int> bytes, {String? id}) async {
    _check();
    if (id != null && !files.containsKey(id)) throw const DriveError('Not found', notFound: true);
    final key = id ?? 'f${_next++}';
    files[key] = (name, bytes, _next++);
    return DriveFile(id: key, name: name, modified: clock?.call() ?? '${files[key]!.$3}');
  }

  /// Drive's own time for a file just written; its version number if null.
  String Function()? clock;

  /// What [list] leaves out, as Drive's list can for a moment after a file
  /// is made.
  final hidden = <String>{};

  /// id: name, parent ('root' at the top), contents (null for a folder),
  /// whether it's in the bin.
  final visible = <String, ({String name, String parent, List<int>? bytes, bool binned})>{};
  var writes = 0;

  /// Each day's file, by 'folder/year/name', that isn't in the bin.
  Map<String, String> get journal {
    String path(String id) => id == 'root' ? '' : '${path(visible[id]!.parent)}/${visible[id]!.name}';
    bool live(String id) => id == 'root' || (!visible[id]!.binned && live(visible[id]!.parent));
    return {
      for (final MapEntry(:key, :value) in visible.entries)
        if (value.bytes != null && live(key)) path(key).substring(1): utf8.decode(value.bytes!),
    };
  }

  static String _sum(List<int> bytes) => md5.convert(bytes).toString();

  Iterable<String> _find(String name, String parent, {required bool folder}) => visible.entries
      .where((e) => e.value.name == name && e.value.parent == parent && !e.value.binned)
      .where((e) => (e.value.bytes == null) == folder)
      .map((e) => e.key);

  @override
  Future<bool> exists(String id) async => visible[id] != null && !visible[id]!.binned;

  @override
  Future<String?> findFolder(String name, {String? parent}) async =>
      _find(name, parent ?? 'root', folder: true).firstOrNull;

  @override
  Future<String> makeFolder(String name, {String? parent}) async {
    final id = 'd${_next++}';
    visible[id] = (name: name, parent: parent ?? 'root', bytes: null, binned: false);
    return id;
  }

  @override
  Future<(String, String)?> findFile(String name, String folder) async {
    final id = _find(name, folder, folder: false).firstOrNull;
    return id == null ? null : (id, _sum(visible[id]!.bytes!));
  }

  @override
  Future<(Map<String, (String, String)>, Map<String, String>)> listJournal(String folder) async {
    final years = {
      for (final e in visible.entries.where(
        (e) => e.value.parent == folder && e.value.bytes == null && !e.value.binned,
      ))
        e.value.name: e.key,
    };
    return (
      {
        for (final MapEntry(key: year, value: yearId) in years.entries)
          for (final e in visible.entries.where(
            (e) => e.value.parent == yearId && e.value.bytes != null && !e.value.binned,
          ))
            '$year/${e.value.name}': (e.key, _sum(e.value.bytes!)),
      },
      years,
    );
  }

  @override
  Future<(String, String)> writeFile(String name, String folder, List<int> bytes, {String? id}) async {
    writes++;
    if (id != null && visible[id] == null) throw const DriveError('Not found', notFound: true);
    id ??= 'j${_next++}';
    visible[id] = (name: name, parent: folder, bytes: bytes, binned: false);
    return (id, _sum(bytes));
  }

  @override
  Future<void> bin(String id) async {
    final f = visible[id]!;
    visible[id] = (name: f.name, parent: f.parent, bytes: f.bytes, binned: true);
  }

  void binFolder(String name) {
    final id = _find(name, 'root', folder: true).single;
    final f = visible[id]!;
    visible[id] = (name: f.name, parent: f.parent, bytes: f.bytes, binned: true);
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

  test('a to-do ticked on one and moved on the other before syncing: the later wins, whole', () {
    join();
    _Computer.clock = 2000;
    final onPc = pc.store.todos(TodoScope.today, TodoScope.today.period(day)).single;
    pc.store.setTodoDone(onPc.id, true, day: day);
    pc.stamp();
    _Computer.clock = 3000;
    final onLaptop = laptop.store.todos(TodoScope.today, TodoScope.today.period(day)).single;
    laptop.store.moveTodo(onLaptop.id, TodoScope.week, day);
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    expect(pc.dump(), laptop.dump());
    // Not a ticked task sitting in this week's list.
    final task = pc.store.raw.select('SELECT scope, done FROM todos').single;
    expect((task['scope'], task['done']), ('week', 0));

    // The other way round, the tick is later and wins.
    _Computer.clock = 4000;
    laptop.store.moveTodo(onLaptop.id, TodoScope.month, day);
    laptop.stamp();
    _Computer.clock = 5000;
    pc.store.setTodoDone(onPc.id, true, day: day);
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    expect(pc.dump(), laptop.dump());
    final ticked = pc.store.raw.select('SELECT scope, period, done FROM todos').single;
    expect((ticked['scope'], ticked['period'], ticked['done']), ('today', dateKey(day), 1));
  });

  test('a computer starting the next day before hearing of a tick never unticks it', () {
    join();
    final next = DateTime(2026, 10, 25);
    _Computer.clock = 2000;
    final onPc = pc.store.todos(TodoScope.today, TodoScope.today.period(day)).single;
    pc.store.setTodoDone(onPc.id, true, day: day);
    pc.stamp();
    // The laptop wakes the next day without the tick, and moves the task on.
    _Computer.clock = 3000;
    final stale = laptop.store.startDay(next);
    expect(stale[TodoScope.today]!.single.done, isFalse);
    for (final (a, b) in [(pc, laptop), (laptop, pc), (pc, laptop)]) {
      a.hearFrom(b);
      a.store.startDay(next);
    }
    for (final c in [pc, laptop]) {
      expect(c.store.todoListsOn(day)[TodoScope.today]!.single.done, isTrue, reason: '${c.name}: done that day');
      expect(c.store.todoListsOn(next)[TodoScope.today], isEmpty, reason: '${c.name}: not carried to the next day');
      expect(c.store.todos(TodoScope.today, TodoScope.today.period(day)).single.done, isTrue);
    }
    expect(pc.dump(), laptop.dump());
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

  test('restoring a backup sends the restored data to the other computer, but never removes writing', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse-sync');
    addTearDown(() => dir.deleteSync(recursive: true));
    pc.store.setJournal('2026-10-23', 'Before the backup');
    join();
    final backup = '${dir.path}/backup.db';
    pc.store.saveCopy(backup);
    final read = laptop.store.monthHabits(2026, 10).first;
    _Computer.clock = 2000;
    laptop.store.setEntry('2026-10-24', read.id, HabitStatus.done);
    laptop.store.setJournal('2026-10-24', 'Written after the backup');
    laptop.store.setJournal('2026-10-23', 'Rewritten after the backup');
    pc.hearFrom(laptop);
    _Computer.clock = 3000;
    await pc.store.restoreFrom(backup);
    pc.engine = SyncEngine(pc.store, 'pc');
    laptop.hearFrom(pc);
    expect(laptop.dump(), pc.dump());
    expect(laptop.store.entriesInMonth(2026, 10).where((e) => e.day == '2026-10-24'), isEmpty, reason: 'as the backup');
    expect(laptop.store.journal('2026-10-24'), 'Written after the backup');
    expect(laptop.store.journal('2026-10-23'), 'Before the backup${Store.journalBreak}Rewritten after the backup');
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

  test('typing saved just as another computer\'s journal text came in keeps both', () {
    final state = AppState(pc.store, clock: () => day);
    addTearDown(state.dispose);
    state.setJournal(day, 'Morning');
    state.journalShown(day, 'Morning');
    state.draftJournal(day, 'Morning, and lunch');
    // Synced in the moment before the editor shows it.
    pc.store.setJournal(dateKey(day), 'Morning${Store.journalBreak}From the laptop');
    state.saveJournalDraft();
    expect(pc.store.journal(dateKey(day)), normaliseNote('Morning, and lunch${Store.journalBreak}From the laptop'));
    // Typing on with nothing new in between just saves.
    final shown = pc.store.journal(dateKey(day));
    state.draftJournal(day, '$shown, and tea');
    state.saveJournalDraft();
    expect(pc.store.journal(dateKey(day)), '$shown, and tea');
  });

  test('a month copied on a computer that hasn\'t heard of edits to it never undoes them', () {
    join();
    _Computer.clock = 2000;
    pc.store.ensureMonth(2026, 11);
    final november = pc.store.monthHabits(2026, 11);
    pc.store.renameHabit(2026, 11, november.first.id, 'Read 20 pages');
    pc.store.removeHabit(2026, 11, november.last.id);
    pc.stamp();
    // The laptop opens November later, before hearing of it.
    _Computer.clock = 3000;
    laptop.store.ensureMonth(2026, 11);
    for (final (a, b) in [(pc, laptop), (laptop, pc)]) {
      a.hearFrom(b);
    }
    for (final c in [pc, laptop]) {
      expect(c.store.monthHabits(2026, 11).map((h) => h.name), ['Read 20 pages'], reason: c.name);
    }
    expect(pc.dump(), laptop.dump());
  });

  test('what a day start moved is never sent, even when every row is compared', () {
    join();
    _Computer.clock = 2000;
    final onPc = pc.store.todos(TodoScope.today, dateKey(day)).single;
    pc.store.setTodoDone(onPc.id, true, day: day);
    pc.stamp();
    _Computer.clock = 3000;
    final next = DateTime(2026, 10, 25);
    laptop.store.startDay(next);
    final sent = laptop.engine.latest;
    // As a restore or an upgrade compares every row with what was sent.
    laptop.store.markAllChanged();
    laptop.engine.flush();
    expect(laptop.engine.latest, sent, reason: 'nothing to send');
    // An edit of something else of the task sends only that.
    final onLaptop = laptop.store.todos(TodoScope.today, dateKey(next)).single;
    laptop.store.editTodo(onLaptop.id, 'Post the letter today', null, next);
    for (final (a, b) in [(pc, laptop), (laptop, pc)]) {
      a.hearFrom(b);
      a.store.startDay(next);
    }
    for (final c in [pc, laptop]) {
      final task = c.store.raw.select('SELECT text, period, done FROM todos').single;
      expect((task['text'], task['period'], task['done']), ('Post the letter today', dateKey(day), 1), reason: c.name);
    }
  });

  test('an edit not sent yet when the day starts goes as made, at its own time, without the moves', () {
    join();
    final next = DateTime(2026, 10, 25);
    _Computer.clock = 2000;
    final onLaptop = laptop.store.todos(TodoScope.today, dateKey(day)).single;
    laptop.store.editTodo(onLaptop.id, 'Laptop text, earlier', null, day);
    laptop.stamp();
    _Computer.clock = 2500;
    final onPc = pc.store.todos(TodoScope.today, dateKey(day)).single;
    pc.store.setTodoDone(onPc.id, true, day: day);
    pc.store.editTodo(onPc.id, 'PC text, later', null, day);
    pc.stamp();
    // Offline, the laptop opens the next day before sending its edit.
    _Computer.clock = 5000;
    laptop.store.startDay(next);
    for (final (a, b) in [(pc, laptop), (laptop, pc)]) {
      a.hearFrom(b);
      a.store.startDay(next);
    }
    for (final c in [pc, laptop]) {
      final task = c.store.raw.select('SELECT text, period, done FROM todos').single;
      expect((task['text'], task['period'], task['done']), ('PC text, later', dateKey(day), 1), reason: c.name);
      expect(c.store.todoListsOn(next)[TodoScope.today], isEmpty, reason: c.name);
    }
  });

  test('deleted on one and edited later on the other comes back; deleted later, it stays deleted', () {
    join();
    final onPc = pc.store.todos(TodoScope.today, dateKey(day)).single;
    final onLaptop = laptop.store.todos(TodoScope.today, dateKey(day)).single;
    _Computer.clock = 2000;
    pc.store.deleteTodo(onPc.id, day: day);
    pc.stamp();
    _Computer.clock = 3000;
    laptop.store.setTodoDone(onLaptop.id, true, day: day);
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    expect(pc.dump(), laptop.dump());
    expect(pc.store.todos(TodoScope.today, dateKey(day)).single.done, isTrue, reason: 'back, ticked');

    _Computer.clock = 4000;
    laptop.store.setTodoDone(onLaptop.id, false, day: day);
    laptop.stamp();
    _Computer.clock = 5000;
    pc.store.deleteTodo(pc.store.todos(TodoScope.today, dateKey(day)).single.id, day: day);
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    expect(pc.dump(), laptop.dump());
    expect(pc.dump()['todos'], isEmpty);

    // Rituals too: removed from a month on one, renamed later on the other.
    final run = pc.store.monthHabits(2026, 10).last;
    _Computer.clock = 6000;
    pc.store.removeHabit(2026, 10, run.id);
    pc.stamp();
    _Computer.clock = 7000;
    laptop.store.renameHabit(2026, 10, laptop.store.monthHabits(2026, 10).last.id, 'Run 5k');
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    expect(pc.store.monthHabits(2026, 10).map((h) => h.name), ['Read', 'Run 5k']);
    expect(pc.dump(), laptop.dump());
  });

  test('rituals reordered on both at once come out in the same order on both', () {
    pc.store.addHabit(2026, 10, 'Stretch');
    join();
    final onPc = [for (final h in pc.store.monthHabits(2026, 10)) h.id];
    final onLaptop = [for (final h in laptop.store.monthHabits(2026, 10)) h.id];
    // Run before Read on the PC; Stretch before Run on the laptop. Read and
    // Stretch end up sharing a place.
    _Computer.clock = 2000;
    pc.store.reorderHabits(2026, 10, [onPc[1], onPc[0], onPc[2]]);
    pc.stamp();
    _Computer.clock = 3000;
    laptop.store.reorderHabits(2026, 10, [onLaptop[0], onLaptop[2], onLaptop[1]]);
    pc.hearFrom(laptop);
    laptop.hearFrom(pc);
    final places = pc.store.raw.select('SELECT position FROM month_habits WHERE year = 2026 AND month = 10');
    expect(places.map((r) => r['position']).toSet(), hasLength(2), reason: 'a shared place');
    String names(_Computer c) => c.store.monthHabits(2026, 10).map((h) => h.name).join(', ');
    expect(names(pc), names(laptop));
  });

  test('a computer with a far-future clock can\'t push the others\' edits out with it', () {
    join();
    final future = DateTime(2040).millisecondsSinceEpoch;
    laptop.engine = SyncEngine(laptop.store, 'laptop', clock: () => future);
    final read = laptop.store.monthHabits(2026, 10).first;
    laptop.store.setEntry('2026-10-24', read.id, HabitStatus.done);
    laptop.store.raw.execute('UPDATE sync_dirty SET at = ?', [future]);
    laptop.engine.flush();
    pc.engine.mergeAll([(laptop.engine.changesSince(0).values.expand((d) => d), 'laptop')]);
    // The PC changes it after hearing: later, though its time is earlier.
    pc.store.setEntry('2026-10-24', pc.store.monthHabits(2026, 10).first.id, HabitStatus.missed);
    pc.engine.flush();
    expect(pc.engine.latest, lessThan(DateTime.now().add(const Duration(days: 2)).millisecondsSinceEpoch));
    laptop.engine.mergeAll([(pc.engine.changesSince(0).values.expand((d) => d), 'pc')]);
    expect(laptop.store.entriesInMonth(2026, 10).singleWhere((e) => e.day == '2026-10-24').status, HabitStatus.missed);
  });

  test('edits the database loses come back from this computer\'s own change files', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse-sync');
    addTearDown(() => dir.deleteSync(recursive: true));
    join();
    final folder = SyncFolder(dir, 'pc', 'PC');
    pc.store.setJournal('2026-10-24', 'Written just before the power cut');
    pc.engine.flush();
    await folder.write(pc.engine, 0);
    folder.read(pc.engine); // as each round reads its own back
    // A power cut takes the database's last moments: the entry, what sync
    // made of it, and that its file was read.
    pc.store.raw.execute("DELETE FROM sync_reg WHERE kind = 'journal' AND rowkey = '2026-10-24'");
    pc.store.raw.execute("DELETE FROM journal WHERE day = '2026-10-24'");
    pc.store.raw.execute('DELETE FROM sync_dirty');
    pc.store.raw.execute('DELETE FROM sync_seen');
    final incoming = folder.read(pc.engine);
    expect(pc.store.journal('2026-10-24'), 'Written just before the power cut');
    expect(incoming.from, isEmpty, reason: 'no banner for its own');
  });

  test('an upgrade takes in what the older version couldn\'t keep, rather than sending its blanks', () {
    final dir = Directory.systemTemp.createTempSync('eclipse-sync');
    addTearDown(() => dir.deleteSync(recursive: true));
    join();
    pc.store.addExercise('Squat', MuscleGroup.quads, bodyweight: false);
    final path = '${dir.path}/laptop.db';
    var old = Store.open(path);
    SyncEngine(old, 'laptop')
      ..clearForJoining()
      ..mergeAll([(pc.engine.changesSince(0).values.expand((d) => d).toList(), 'pc')]);
    pc.engine.flush();
    SyncEngine(old, 'laptop').mergeAll([(pc.engine.changesSince(0).values.expand((d) => d).toList(), 'pc')]);
    // As a version from before training: the change kept, but not the row.
    old.raw.execute('DELETE FROM exercises');
    old.raw.execute('DELETE FROM sync_dirty');
    old.raw.execute('PRAGMA user_version = 21');
    old.close();

    final upgraded = Store.open(path);
    addTearDown(upgraded.close);
    final engine = SyncEngine(upgraded, 'laptop');
    expect(upgraded.exercises().map((e) => e.name), ['Squat']);
    pc.engine.mergeAll([(engine.changesSince(0).values.expand((d) => d).toList(), 'laptop')]);
    expect(pc.store.exercises().map((e) => e.name), ['Squat'], reason: 'not deleted everywhere');
  });

  test('a change of a kind a newer version makes is kept, and never stops sync', () {
    join();
    laptop.engine.mergeAll([
      (
        [
          [
            'mood',
            '2026-10-24',
            'value',
            jsonEncode(4),
            5000,
            'mac',
            {'mac': 5000},
          ],
        ],
        'Mac',
      ),
    ]);
    expect(laptop.engine.newerOrigins, {'mac'});
    laptop.store.raw.execute('INSERT OR IGNORE INTO sync_dirty SELECT DISTINCT kind, rowkey, 0 FROM sync_reg');
    laptop.engine.flush();
    expect(laptop.store.raw.select("SELECT value FROM sync_reg WHERE kind = 'mood'").single['value'], '4');
  });

  test('every field each kind of row keeps is listed with the version that added it', () {
    final store = pc.store;
    final read = store.monthHabits(2026, 10).first;
    store.setHabitNote(2026, 10, read.id, 'Ten pages');
    store.setHabitDays(2026, 10, read.id, [(null, weekdayBit(DateTime.monday))]);
    store.raw.execute("UPDATE month_habits SET added_on = '2026-10-01'");
    store.raw.execute(
      "UPDATE todos SET done = 1, done_at = 'x', carried = 1, due_date = '2026-10-30', return_to_tomorrow = 1, "
      "return_scope = 'tomorrow', defer_promotion_day = '2026-10-24', subtasks = '[]'",
    );
    final squat = store.addExercise('Squat', MuscleGroup.quads, bodyweight: true);
    store.addTrainingSet('2026-10-24', squat.uid, position: 1, weight: 20, reps: 5);
    pc.engine.claimAll();
    final sent = {
      for (final r in store.raw.select('SELECT DISTINCT kind, field FROM sync_reg'))
        (r['kind'] as String, r['field'] as String),
    };
    final listed = {
      for (final MapEntry(key: kind, value: fields) in SyncEngine.fields.entries)
        for (final field in fields.keys) (kind, field),
    };
    expect(sent, listed);
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

    Future<(SyncService, SyncService)> syncBoth() async {
      final onPc = service(pc), onLaptop = service(laptop);
      addTearDown(onPc.dispose);
      addTearDown(onLaptop.dispose);
      await onPc.look(account);
      await onPc.turnOn(account, join: false);
      await onLaptop.look(account);
      await onLaptop.turnOn(account, join: true);
      return (onPc, onLaptop);
    }

    test('signing in again sends only edits, never the day starts made meanwhile', () async {
      final (onPc, onLaptop) = await syncBoth();
      await onLaptop.turnOff();
      final task = pc.store.todos(TodoScope.today, dateKey(day)).single;
      pc.store.setTodoDone(task.id, true, day: day);
      onPc.recordEdits();
      await onPc.run();
      // Signed out, the laptop opens the next day and moves the task on.
      final next = DateTime(2026, 10, 25);
      laptop.store.startDay(next);
      expect(await onLaptop.look(account), isTrue);
      expect(onLaptop.isReturning(account), isTrue);
      await onLaptop.turnOn(account, join: false);
      laptop.store.startDay(next);
      await onPc.run();
      pc.store.startDay(next);
      for (final c in [pc, laptop]) {
        expect(c.store.todoListsOn(day)[TodoScope.today]!.single.done, isTrue, reason: '${c.name}: done that day');
        expect(c.store.todoListsOn(next)[TodoScope.today], isEmpty, reason: '${c.name}: not open the next day');
      }
    });

    test('each computer\'s clock is put right by Google\'s', () async {
      const ahead = Duration(minutes: 5);
      drive.clock = () => DateTime.now().add(ahead).toUtc().toIso8601String();
      final onPc = service(pc);
      addTearDown(onPc.dispose);
      await onPc.look(account);
      await onPc.turnOn(account, join: false);
      expect(onPc.engine.offset, closeTo(ahead.inMilliseconds, 2000));
      pc.store.setJournal('2026-10-24', 'Written');
      onPc.recordEdits();
      final ts = pc.store.raw.select("SELECT ts FROM sync_reg WHERE kind = 'journal' AND rowkey = '2026-10-24'");
      expect((ts.single['ts'] as int) - DateTime.now().millisecondsSinceEpoch, closeTo(ahead.inMilliseconds, 2000));
      expect(service(pc).engine.offset, onPc.engine.offset, reason: 'remembered');
    });

    test('a change file cut short is fetched again; a newer version\'s waits, and says so', () async {
      final (onPc, onLaptop) = await syncBoth();
      pc.store.setJournal('2026-10-24', 'Cut short once');
      onPc.recordEdits();
      await onPc.run();
      drive.cutShort.addAll(drive.files.keys);
      await onLaptop.run();
      expect(laptop.store.journal('2026-10-24'), '');
      await onLaptop.run();
      expect(laptop.store.journal('2026-10-24'), 'Cut short once');

      await drive.upload(
        'ffffffffffffffff_2026-10-25.json',
        utf8.encode(jsonEncode({'version': 2, 'name': 'Mac', 'registers': 'in a new way'})),
      );
      await onLaptop.run();
      expect(onLaptop.error, isNull, reason: 'the round carried on');
      expect(onLaptop.newerFrom, {'Mac'});
    });

    test('a file Drive doesn\'t list yet isn\'t made twice, and two of one name are both read', () async {
      final onPc = service(pc);
      addTearDown(onPc.dispose);
      await onPc.look(account);
      await onPc.turnOn(account, join: false);
      final names = [for (final f in drive.files.values) f.$1];
      drive.hidden.addAll(drive.files.keys);
      pc.store.setJournal('2026-10-24', 'Written while the list lagged');
      onPc.recordEdits();
      await onPc.run();
      drive.hidden.clear();
      expect([for (final f in drive.files.values) f.$1]..sort(), names..sort());

      // Two files of one name, from before.
      final remote = _Computer('remote');
      remote.store.setJournal('2026-10-01', 'In one');
      remote.engine.claimAll();
      final one = remote.engine.changesSince(0).values.expand((d) => d).toList();
      remote.store.setJournal('2026-10-02', 'In the other');
      remote.engine.flush();
      final other = [
        for (final r in remote.engine.changesSince(0).values.expand((d) => d))
          if (r[1] == '2026-10-02') r,
      ];
      for (final registers in [one, other]) {
        await drive.upload(
          'remote_2026-10-24.json',
          utf8.encode(jsonEncode({'version': 1, 'name': 'Remote', 'registers': registers})),
        );
      }
      await onPc.run();
      expect(pc.store.journal('2026-10-01'), 'In one');
      expect(pc.store.journal('2026-10-02'), 'In the other');
    });

    test('a computer that lost sync\'s settings but shares the history merges, nothing replaced', () async {
      final (onPc, onLaptop) = await syncBoth();
      laptop.store.setJournal('2026-10-24', 'Only on the laptop');
      onLaptop.recordEdits();
      // Reinstalled, the data folder kept: sync's settings are new.
      onLaptop.stop();
      final fresh = SyncService.load(
        Directory('${dir.path}/laptop-again')..createSync(),
        laptop.store,
        connect: (_) => drive,
        signIn: ({cancel}) async => account,
      );
      addTearDown(fresh.dispose);
      expect(await fresh.look(account), isTrue);
      expect(fresh.isReturning(account), isTrue);
      expect(fresh.needsAccountChoice(account), isFalse);
      await fresh.turnOn(account, join: false);
      await onPc.run();
      expect(pc.store.journal('2026-10-24'), 'Only on the laptop');
      expect(laptop.dump(), pc.dump());

      // One that has never synced is asked, as a new computer is.
      final unsynced = _Computer('new');
      final asks = SyncService.load(
        Directory('${dir.path}/new')..createSync(),
        unsynced.store,
        connect: (_) => drive,
        signIn: ({cancel}) async => account,
      );
      addTearDown(asks.dispose);
      expect(await asks.look(account), isTrue);
      expect(asks.isReturning(account), isFalse);
    });

    test('an empty database while signed in fills from sync, with no examples added', () async {
      final (onPc, _) = await syncBoth();
      final empty = Store.memory();
      addTearDown(empty.close);
      final home = Directory('${dir.path}/laptop');
      final signedIn = SyncService.load(home, empty, connect: (_) => drive, signIn: ({cancel}) async => account);
      addTearDown(signedIn.dispose);
      final state = AppState(empty, sync: signedIn, clock: () => day);
      addTearDown(state.dispose);
      expect(state.firstRun, isFalse);
      expect(empty.isEmpty, isTrue, reason: 'nothing seeded');
      await signedIn.run();
      await onPc.run();
      expect(pc.store.monthHabits(2026, 10).map((h) => h.name), ['Read', 'Run']);
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

    group('the journal\'s folder', () {
      const withJournal = GoogleAccount(email: 'me@example.com', refreshToken: 'lasting', journalAccess: true);

      SyncService signedIn(_Computer c) {
        final home = Directory('${dir.path}/${c.name}')..createSync();
        return SyncService.load(home, c.store, connect: (_) => drive, signIn: ({cancel}) async => withJournal);
      }

      test('is filled by the computer that makes it, then each uploads the days it wrote', () async {
        pc.store.setJournal('2026-10-20', 'Before sync');
        final onPc = signedIn(pc), onLaptop = signedIn(laptop);
        await onPc.look(withJournal);
        await onPc.turnOn(withJournal, join: false);
        expect(drive.journal, {
          'Eclipse Journals/2025/2025-06-01.md': '# Sunday 1 June 2025\n\nA long time ago\n',
          'Eclipse Journals/2026/2026-10-20.md': '# Tuesday 20 October 2026\n\nBefore sync\n',
        });
        expect(onPc.journalFolderLink, startsWith('https://drive.google.com/drive/folders/'));

        await onLaptop.look(withJournal);
        await onLaptop.turnOn(withJournal, join: true);
        expect(drive.writes, 2, reason: 'the laptop found them there already');
        expect(onLaptop.journalFolderLink, onPc.journalFolderLink);

        laptop.store.setJournal('2026-10-24', 'Written on the laptop');
        await onLaptop.run();
        await onPc.run();
        expect(drive.journal['Eclipse Journals/2026/2026-10-24.md'], contains('Written on the laptop'));
        expect(drive.writes, 3, reason: 'only the laptop wrote it, so only it uploads it');

        // Written on both at once: the later one uploads the joined entry.
        pc.store.setJournal('2026-10-25', 'From the PC');
        await onPc.run();
        await onLaptop.run();
        pc.store.setJournal('2026-10-26', 'PC first');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        laptop.store.setJournal('2026-10-26', 'Laptop later');
        await onPc.run();
        await onLaptop.run();
        await onPc.run();
        await onLaptop.run();
        expect(pc.store.journal('2026-10-26'), laptop.store.journal('2026-10-26'));
        final joined = drive.journal['Eclipse Journals/2026/2026-10-26.md']!;
        expect(joined, allOf(contains('PC first'), contains('Laptop later')));
        expect(drive.journal.keys.where((k) => k.endsWith('2026-10-26.md')), hasLength(1));

        // Emptied on the laptop, though the PC uploaded it: to the bin.
        laptop.store.setJournal('2026-10-25', '');
        await onLaptop.run();
        await onPc.run();
        expect(drive.journal.keys, isNot(contains('Eclipse Journals/2026/2026-10-25.md')));

        // Deleted in Drive: made again, with everything, by whoever's next.
        drive.binFolder('Eclipse Journals');
        await onPc.run();
        expect(drive.journal.keys.toSet(), {
          'Eclipse Journals/2025/2025-06-01.md',
          'Eclipse Journals/2026/2026-10-20.md',
          'Eclipse Journals/2026/2026-10-24.md',
          'Eclipse Journals/2026/2026-10-26.md',
        });
        final writes = drive.writes;
        await onLaptop.run();
        expect(drive.writes, writes);
        onPc.dispose();
        onLaptop.dispose();
      });

      test('can stop saving files on this computer, and they come back up to date with Drive gone', () async {
        final files = JournalFiles(Directory('${dir.path}/files'));
        final onPc = signedIn(pc);
        final state = AppState(pc.store, journalFiles: files, sync: onPc, clock: () => DateTime(2026, 10, 28));
        await state.setJournal(DateTime(2026, 10, 20), 'Kept');
        await state.setJournal(DateTime(2026, 10, 21), 'Emptied later');
        await state.flushFiles();
        expect(state.journalInDrive, isFalse);
        state.setKeepsJournalFiles(false);
        expect(state.savesJournalFiles, isTrue, reason: 'no journal in Drive yet');

        await onPc.look(withJournal);
        await onPc.turnOn(withJournal, join: false);
        expect(state.journalInDrive, isTrue);
        expect(state.savesJournalFiles, isFalse);
        await state.setJournal(DateTime(2026, 10, 20), 'Changed while off');
        await state.setJournal(DateTime(2026, 10, 21), '');
        await state.setJournal(DateTime(2026, 10, 22), 'New while off');
        await state.flushFiles();
        expect(files.fileFor(DateTime(2026, 10, 20)).readAsStringSync(), contains('Kept'));
        expect(files.fileFor(DateTime(2026, 10, 21)).existsSync(), isTrue, reason: 'left as they were');
        expect(files.fileFor(DateTime(2026, 10, 22)).existsSync(), isFalse);

        await onPc.turnOff();
        expect(state.savesJournalFiles, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await state.flushFiles();
        expect(files.fileFor(DateTime(2026, 10, 20)).readAsStringSync(), contains('Changed while off'));
        expect(files.fileFor(DateTime(2026, 10, 21)).existsSync(), isFalse);
        expect(files.fileFor(DateTime(2026, 10, 22)).readAsStringSync(), contains('New while off'));
        state.dispose();
        onPc.dispose();
      });

      test('a sign-in from before asks to sign in again, and sync carries on', () async {
        final onPc = service(pc);
        await onPc.look(account);
        await onPc.turnOn(account, join: false);
        expect(onPc.needsJournalSignIn, isTrue);
        expect(drive.journal, isEmpty);
        expect(onPc.journalFolderLink, isNull);

        final again = SyncService.load(
          Directory('${dir.path}/pc'),
          pc.store,
          connect: (_) => drive,
          signIn: ({cancel}) async => withJournal,
        );
        await again.signInForJournal();
        expect(again.needsJournalSignIn, isFalse);
        expect(drive.journal, contains('Eclipse Journals/2025/2025-06-01.md'));
        onPc.dispose();
        again.dispose();
      });

      test('uploads a few at a time, so a round stays short', () async {
        for (var d = 1; d <= SyncService.journalBatch + 5; d++) {
          pc.store.setJournal('2026-09-${'$d'.padLeft(2, '0')}', 'Day $d');
        }
        final onPc = signedIn(pc);
        await onPc.look(withJournal);
        await onPc.turnOn(withJournal, join: false);
        expect(drive.journal, hasLength(SyncService.journalBatch));
        await onPc.run();
        expect(drive.journal, hasLength(SyncService.journalBatch + 6));
        onPc.dispose();
      });
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

  group('randomized', () {
    // SYNC_SOAK=<seeds> runs that many, each four times as long.
    final soak = int.tryParse(Platform.environment['SYNC_SOAK'] ?? '');
    final seeds = soak ?? 6, steps = soak == null ? 150 : 600;
    for (var seed = 1; seed <= seeds; seed++) {
      test('three computers editing, starting days, offline and hearing late lose nothing (seed $seed)', () {
        final world = _World(seed)..begin();
        for (var step = 0; step < steps; step++) {
          world.step();
        }
        world.settle();
        world.check();
      });
    }
  });
}

/// A computer in the randomized simulation, used the way the app uses it.
class _Sim {
  _Sim(this.world, this.id) : store = Store.memory() {
    // Ids from the seed too, so a seed runs the same each time.
    final random = Random(world.seed * 31 + id.hashCode);
    store.raw.createFunction(
      functionName: 'randomblob',
      argumentCount: const AllowedArgumentCount(1),
      function: (args) => Uint8List.fromList([for (var i = 0; i < (args[0] as int); i++) random.nextInt(256)]),
    );
    engine = SyncEngine(store, id, clock: () => world.now);
  }

  final _World world;
  final String id;
  final Store store;
  late final SyncEngine engine;

  /// The app's today, from its last day start.
  late DateTime day;
  bool open = true, online = true, joined = false;

  /// The version of each other computer's file merged here, by name.
  final heard = <String, int>{};
  int pushed = 0;

  /// What the app does on opening, when the day turns, and after a merge.
  void startDay() {
    store.startDay(day);
    store.ensureMonth(day.year, day.month);
  }
}

/// Computers editing as you would, starting days, closing for days, going
/// offline, and hearing from each other late, out of order and twice.
/// Every real edit is noted with when it was made: once they've all heard
/// everything, each thing must be as the latest edit of it left it, the
/// same on every computer.
class _World {
  _World(this.seed) : random = Random(seed);

  final int seed;
  final Random random;

  /// Earlier than the real time, so the times the triggers note never win.
  int now = DateTime(2025, 10, 27, 7).millisecondsSinceEpoch;
  DateTime get date => dateOnly(DateTime.fromMillisecondsSinceEpoch(now));
  late final DateTime first = date;

  late final sims = [
    for (final id in ['pc', 'laptop', 'mac']) _Sim(this, id),
  ];

  /// Each computer's change files as they went up, every version, by
  /// computer and day.
  final drive = <String, List<List<List<Object?>>>>{};

  /// The latest real edit of each thing: when, and what it left.
  final facts = <String, (int, Object?)>{};

  /// Words written to each day's journal, each of which must stay.
  final words = <String, Set<String>>{};
  var _count = 0;
  String word(String prefix) => '$prefix${_count++}';

  /// What happened, for a failure to show.
  final events = <String>[];
  void note(_Sim c, String what) => events.add(
    '${DateTime.fromMillisecondsSinceEpoch(now).toString().substring(0, 16)} ${c.id} (day ${dateKey(c.day)}): $what',
  );

  /// The events that mention [uid], and the syncs between them, and each
  /// computer's registers of it.
  String trace(String uid) => [
    for (final c in sims)
      for (final r in c.store.raw.select(
        "SELECT field, value, ts, origin, vv FROM sync_reg WHERE kind = 'todo' AND rowkey = ? ORDER BY field",
        [uid],
      ))
        '${c.id} has ${r['field']} = ${r['value']} at ${DateTime.fromMillisecondsSinceEpoch(r['ts'] as int).toString().substring(0, 16)} from ${r['origin']} ${r['vv']}',

    for (final e in events)
      if (e.contains(uid) ||
          e.contains('sent') ||
          e.contains('opened') ||
          e.contains('closed') ||
          e.endsWith('day start'))
        e,
  ].join('\n');

  T pick<T>(List<T> list) => list[random.nextInt(list.length)];
  bool chance(double p) => random.nextDouble() < p;

  void begin() {
    final pc = sims.first..day = date;
    edit(pc, (s) {
      for (final name in ['Read', 'Run', 'Stretch']) {
        s.addHabit(date.year, date.month, name);
      }
      for (final (scope, text) in [
        (TodoScope.today, 'Post the letter'),
        (TodoScope.tomorrow, 'Water the plants'),
        (TodoScope.week, 'Call the bank'),
        (TodoScope.month, 'Book the dentist'),
      ]) {
        s.addTodo(scope, date, text);
      }
    });
    pc
      ..joined = true
      ..engine.claimAll()
      ..startDay();
    publish(pc);
    join(sims[1]);
    sims[2].open = false; // joins later
  }

  void step() {
    now += (1 + random.nextInt(240)) * 60000;
    for (final c in sims) {
      if (c.open && c.joined && c.day != date) {
        c
          ..day = date
          ..startDay();
      }
    }
    final c = pick(sims);
    final r = random.nextDouble();
    if (!c.joined) {
      if (r < 0.1) join(c);
    } else if (r < 0.05) {
      // Quitting sends what's waiting; opening hears the others.
      if (c.open && c.online) publish(c);
      c.open = !c.open;
      note(c, c.open ? 'opened' : 'closed');
      if (c.open) {
        c
          ..day = date
          ..startDay();
        if (c.online) deliver(c);
      }
    } else if (r < 0.09) {
      c.online = !c.online;
    } else if (r < 0.30) {
      if (c.open && c.online) {
        publish(c);
        deliver(c);
      }
    } else if (c.open) {
      act(c);
    }
  }

  /// All open, online and in, until nothing new comes in anywhere.
  void settle() {
    for (final c in sims) {
      if (!c.joined) join(c);
      c
        ..open = true
        ..online = true
        ..day = date
        ..startDay();
    }
    for (var round = 0; round < 6; round++) {
      for (final c in sims) {
        publish(c);
      }
      var quiet = true;
      for (final c in sims) {
        if (!deliver(c, everything: true).isEmpty) quiet = false;
      }
      if (quiet) return;
    }
    fail('still changing after six rounds (seed $seed)');
  }

  void publish(_Sim c) {
    final latest = c.engine.latest;
    for (final MapEntry(key: day, value: registers) in c.engine.changesSince(c.pushed).entries) {
      (drive['${c.id}/$day'] ??= []).add(registers);
    }
    c.pushed = latest;
    note(c, 'sent');
  }

  /// What [c] finds of the others' files and merges, as the app does: most
  /// at their latest; some not listed yet, some an old copy again.
  Incoming deliver(_Sim c, {bool everything = false}) {
    final batches = <(List<List<Object?>>, String)>[];
    for (final MapEntry(key: name, value: versions) in drive.entries) {
      final from = name.split('/').first;
      if (from == c.id) continue;
      if (!everything && chance(0.15)) continue;
      if (!everything && chance(0.15)) batches.add((pick(versions), from));
      if ((c.heard[name] ?? -1) < versions.length - 1) {
        batches.add((versions.last, from));
        c.heard[name] = versions.length - 1;
      }
    }
    batches.shuffle(random);
    final incoming = c.engine.mergeAll(batches);
    note(
      c,
      'heard ${[for (final (kind, key) in incoming.rows)
        if (kind.startsWith('todo')) key].join(' ')}',
    );
    c.startDay();
    return incoming;
  }

  void join(_Sim c) {
    c
      ..engine.clearForJoining()
      ..heard.clear()
      ..pushed = 0
      ..joined = true
      ..open = true
      ..online = true
      ..day = date;
    deliver(c, everything: true);
  }

  /// One thing you might do on [c].
  void act(_Sim c) {
    final s = c.store, today = c.day, yesterday = DateTime(today.year, today.month, today.day - 1);
    final r = random.nextDouble();
    if (r < 0.20) {
      final d = chance(0.7) ? today : yesterday;
      s.ensureMonth(d.year, d.month);
      final habits = s.monthHabits(d.year, d.month);
      if (habits.isEmpty) return;
      final h = pick(habits), status = pick(HabitStatus.values);
      edit(c, (s) => s.setEntry(dateKey(d), h.id, status, clearNote: true));
    } else if (r < 0.25) {
      final marked = s.entriesInMonth(today.year, today.month).toList();
      if (marked.isEmpty) return;
      final e = pick(marked);
      edit(c, (s) => s.setNote(e.day, e.habitId, chance(0.8) ? word('note') : null));
    } else if (r < 0.37) {
      s.ensureMonth(today.year, today.month);
      final habits = s.monthHabits(today.year, today.month);
      final (y, m) = (today.year, today.month);
      final which = random.nextInt(6);
      if (habits.isEmpty || which == 0) {
        edit(c, (s) => s.addHabit(y, m, word('Ritual '), addedOn: today));
        return;
      }
      final h = pick(habits);
      edit(c, (s) {
        switch (which) {
          case 1:
            s.renameHabit(y, m, h.id, word('Renamed '));
          case 2:
            s.setHabitNote(y, m, h.id, chance(0.7) ? word('Why ') : null);
          case 3:
            s.setHabitDays(y, m, h.id, [(null, 1 + random.nextInt(everyDay))]);
          case 4:
            s.removeHabit(y, m, h.id);
          default:
            s.reorderHabits(y, m, [for (final x in habits..shuffle(random)) x.id]);
        }
      });
    } else if (r < 0.47) {
      final scope = pick(TodoScope.values), text = word('Task ');
      final due = chance(0.25) ? DateTime(today.year, today.month, today.day + random.nextInt(6)) : null;
      edit(c, (s) {
        final item = s.addTodo(scope, today, text);
        if (due != null) {
          s.editTodo(item.id, text, due, today);
          s.promoteDueTodos(today, earliest: today);
          s.rollTomorrowToToday(dateKey(today));
        }
      });
    } else if (r < 0.75) {
      final scope = pick(TodoScope.values);
      final items = s.todos(scope, scope.period(today));
      if (items.isEmpty) return;
      final item = pick(items), which = random.nextInt(10);
      edit(c, (s) {
        if (which < 5) {
          s.setTodoDone(item.id, !item.done, day: today);
        } else if (which < 7) {
          s.editTodo(item.id, word('Edited '), chance(0.2) ? today : item.dueDate, today);
          s.promoteDueTodos(today, earliest: today);
          s.rollTomorrowToToday(dateKey(today));
        } else if (which < 8) {
          s.deleteTodo(item.id, day: today);
        } else {
          s.moveTodo(
            item.id,
            pick([
              for (final to in TodoScope.values)
                if (to != scope) to,
            ]),
            today,
          );
        }
      });
    } else if (r < 0.82) {
      final scope = pick(TodoScope.values);
      final items = [
        for (final t in s.todoListsOn(yesterday)[scope]!)
          if (t.id > 0) t,
      ];
      if (items.isEmpty) return;
      final item = pick(items);
      edit(c, (s) {
        if (chance(0.8)) {
          s.setPastTodoDone(scope, yesterday, item, !item.done, today);
        } else {
          s.editPastTodo(scope, yesterday, item: item, text: word('Then '));
        }
      });
    } else if (r < 0.92) {
      final day = dateKey(chance(0.8) ? today : yesterday), text = s.journal(day), w = word('w');
      (words[day] ??= {}).add(w);
      edit(c, (s) => s.setJournal(day, text.isEmpty ? w : '$text $w'));
    } else if (r < 0.95) {
      final item = pick(SleepItem.values), time = '2${random.nextInt(4)}:${pick(['00', '30'])}';
      edit(c, (s) => s.setSleepNote(today.year, today.month, item, time));
    } else if (r < 0.96) {
      final value = chance(0.5) ? '1' : '0';
      edit(c, (s) => s.setSetting('restWeekends', value));
    } else {
      final sets = s.trainingSets();
      edit(c, (s) {
        if (sets.isEmpty || chance(0.4)) {
          final exercises = s.exercises();
          final e = exercises.isEmpty ? s.addExercise('Squat', MuscleGroup.quads, bodyweight: false) : pick(exercises);
          s.addTrainingSet(
            dateKey(today),
            e.uid,
            position: random.nextInt(4),
            weight: 20.0 + random.nextInt(60),
            reps: 5,
          );
        } else if (chance(0.7)) {
          s.saveTrainingSet(pick(sets).copyWith(weight: 20.0 + random.nextInt(60), reps: 1 + random.nextInt(12)));
        } else {
          s.deleteTrainingSet(pick(sets).uid);
        }
      });
    }
  }

  /// Runs a real edit on [c], as the app does, and notes what it changed.
  void edit(_Sim c, void Function(Store) body) {
    final s = c.store;
    final before = (_entries(s), _months(s), _todos(s), _sets(s), _sleep(s), _settings(s));
    body(s);
    c.engine.flush(); // the app records an edit as it shows it
    final after = (_entries(s), _months(s), _todos(s), _sets(s), _sleep(s), _settings(s));
    _changed('entry', before.$1, after.$1, gone: (key, b) => {'status': 0, if (b['note'] != null) 'note': null});
    _changed('month', before.$2, after.$2, removable: true);
    _changed('set', before.$4, after.$4, removable: true);
    _changed('sleep', before.$5, after.$5);
    _changed('setting', before.$6, after.$6);
    for (final uid in {...before.$3.keys, ...after.$3.keys}) {
      final b = before.$3[uid], a = after.$3[uid];
      if (a == null) {
        _fact('todo/$uid/present', false);
        continue;
      }
      var changed = b == null;
      for (final f in ['text', 'due_date']) {
        if (b == null ? _blank(a[f]) : b[f] == a[f]) continue;
        _fact('todo/$uid/$f', a[f]);
        changed = true;
      }
      if (b == null || ['done', 'scope', 'period'].any((f) => b[f] != a[f])) {
        _fact('todo/$uid/place', (a['done'], a['scope'], a['period']));
        changed = true;
      }
      if (changed) {
        _fact('todo/$uid/present', true);
        note(c, '$uid ${b == null ? 'added' : 'now'} ${a['scope']} ${a['period']} done ${a['done']} "${a['text']}"');
      }
    }
  }

  void _fact(String key, Object? value) => facts[key] = (now, value);

  static bool _blank(Object? v) => v == null || v == 0 || v == '';

  void _changed(
    String kind,
    Map<String, Map<String, Object?>> before,
    Map<String, Map<String, Object?>> after, {
    bool removable = false,
    Map<String, Object?> Function(String key, Map<String, Object?> before)? gone,
  }) {
    for (final key in {...before.keys, ...after.keys}) {
      final b = before[key], a = after[key];
      if (a == null) {
        if (removable) _fact('$kind/$key/present', false);
        for (final MapEntry(key: f, value: v) in (gone?.call(key, b!) ?? const {}).entries) {
          _fact('$kind/$key/$f', v);
        }
        continue;
      }
      var changed = b == null;
      for (final MapEntry(key: f, value: v) in a.entries) {
        if (b == null ? _blank(v) : b[f] == v) continue;
        _fact('$kind/$key/$f', v);
        changed = true;
      }
      if (removable && changed) _fact('$kind/$key/present', true);
    }
  }

  static Map<String, Map<String, Object?>> _rows(
    Store s,
    String sql,
    String Function(Map<String, Object?>) key,
    List<String> fields,
  ) => {
    for (final r in s.raw.select(sql)) key(r): {for (final f in fields) f: r[f]},
  };

  static Map<String, Map<String, Object?>> _entries(Store s) => _rows(
    s,
    'SELECT day, h.uid, status, note FROM entries JOIN habits h ON h.id = habit_id',
    (r) => '${r['day']}/${r['uid']}',
    ['status', 'note'],
  );

  static Map<String, Map<String, Object?>> _months(Store s) => _rows(
    s,
    'SELECT year, month, h.uid, name, note, position, days, added_on FROM month_habits JOIN habits h ON h.id = habit_id',
    (r) => '${r['year']}-${r['month']}/${r['uid']}',
    ['name', 'note', 'position', 'days', 'added_on'],
  );

  static Map<String, Map<String, Object?>> _todos(Store s) =>
      _rows(s, 'SELECT * FROM todos', (r) => r['uid'] as String, [
        'scope',
        'period',
        'text',
        'done',
        'since',
        'due_date',
        'return_to_tomorrow',
        'return_scope',
        'defer_promotion_day',
        'subtasks',
        'done_at',
      ]);

  static Map<String, Map<String, Object?>> _sets(Store s) => _rows(
    s,
    'SELECT * FROM training_sets',
    (r) => r['uid'] as String,
    ['day', 'exercise', 'position', 'weight', 'reps'],
  );

  static Map<String, Map<String, Object?>> _sleep(Store s) =>
      _rows(s, 'SELECT * FROM sleep_notes', (r) => '${r['year']}-${r['month']}/${r['item']}', ['note']);

  static Map<String, Map<String, Object?>> _settings(Store s) => _rows(
    s,
    "SELECT * FROM settings WHERE key IN (${Store.syncedSettings.map((k) => "'$k'").join(', ')})",
    (r) => r['key'] as String,
    ['value'],
  );

  /// Everything you can see, by ids that mean the same everywhere. A to-do's
  /// carried count isn't shown anywhere, and each computer counts its own.
  Map<String, Object?> _view(_Sim c) {
    final s = c.store;
    return {
      'entries': _entries(s),
      'months': {
        for (final r in s.raw.select('SELECT year, month FROM habit_months ORDER BY year, month'))
          '${r['year']}-${r['month']}': [
            for (final h in s.monthHabits(r['year'] as int, r['month'] as int))
              '${s.raw.select('SELECT uid FROM habits WHERE id = ?', [h.id]).single['uid']}|${h.name}|${h.description}|${h.weekdays}',
          ],
      },
      'todos': _todos(s),
      'lists': {
        for (var d = first; !d.isAfter(c.day); d = DateTime(d.year, d.month, d.day + 1))
          dateKey(d): {
            for (final MapEntry(key: scope, value: items) in s.todoListsOn(d).entries)
              scope.name: [for (final t in items) '${t.uid}|${t.text}|${t.done}']..sort(),
          },
      },
      'journal': {for (final e in s.journalEntries()) e.day: e.text},
      'sleep': _sleep(s),
      'settings': _settings(s),
      'sets': _sets(s),
      'exercises': [for (final e in s.exercises()) '${e.uid}|${e.name}'],
    };
  }

  void check() {
    final views = [for (final c in sims) _view(c)];
    for (final (i, view) in views.indexed.skip(1)) {
      for (final part in view.keys) {
        final differing = part == 'todos'
            ? [
                for (final uid in (view[part] as Map).keys)
                  if ('${(view[part] as Map)[uid]}' != '${(views.first[part] as Map)[uid]}') trace(uid as String),
              ].join('\n')
            : '';
        expect(view[part], views.first[part], reason: '${sims[i].id} and pc differ in $part (seed $seed)\n$differing');
      }
    }
    final s = sims.first.store;
    final rows = {
      'entry': _entries(s),
      'month': _months(s),
      'todo': _todos(s),
      'set': _sets(s),
      'sleep': _sleep(s),
      'setting': _settings(s),
    };
    for (final MapEntry(key: key, value: (_, value)) in facts.entries) {
      final parts = key.split('/');
      final kind = parts.first, field = parts.last, id = parts.sublist(1, parts.length - 1).join('/');
      final row = rows[kind]![id],
          why = '$key, last set to $value (seed $seed)${kind == 'todo' ? '\n${trace(id)}' : ''}';
      if (field == 'present') {
        expect(row != null, value, reason: why);
      } else if (kind == 'entry') {
        final status = row?['status'] ?? 0;
        if (field == 'status') expect(status, value, reason: why);
        if (field == 'note' && status != 0) expect(row!['note'], value, reason: why);
      } else if (row == null) {
        expect(kind == 'month' || kind == 'todo' || kind == 'set', isTrue, reason: '$why: missing');
      } else if (field == 'place') {
        final (done, scope, period) = value as (Object?, Object?, Object?);
        expect(row['done'], done, reason: why);
        if (done == 1) expect((row['scope'], row['period']), (scope, period), reason: why);
      } else {
        expect(row[field], value, reason: why);
      }
    }
    // A tick, the last thing done to a task, shows on its day and leaves it
    // open on no day after.
    final touched = <String, int>{};
    for (final MapEntry(key: key, value: (at, _)) in facts.entries) {
      if (key.startsWith('todo/')) touched.update(key.split('/')[1], (t) => max(t, at), ifAbsent: () => at);
    }
    for (final MapEntry(key: key, value: (at, value)) in facts.entries) {
      if (!key.startsWith('todo/') || !key.endsWith('/place')) continue;
      final uid = key.split('/')[1];
      final (done, _, period) = value as (Object?, Object?, Object?);
      if (done != 1 || touched[uid] != at) continue;
      final ticked = DateTime.parse(period as String);
      for (final c in sims) {
        final on = c.store.todoListsOn(ticked).values.expand((l) => l).where((t) => t.uid == uid);
        expect(on.map((t) => t.done), [
          true,
        ], reason: '$uid on ${dateKey(ticked)} on ${c.id} (seed $seed)\n${trace(uid)}');
        for (
          var d = DateTime(ticked.year, ticked.month, ticked.day + 1);
          !d.isAfter(c.day);
          d = DateTime(d.year, d.month, d.day + 1)
        ) {
          final open = c.store.todoListsOn(d).values.expand((l) => l).where((t) => t.uid == uid && !t.done);
          expect(
            open,
            isEmpty,
            reason: '$uid open on ${dateKey(d)} on ${c.id}, ticked ${dateKey(ticked)} (seed $seed)\n${trace(uid)}',
          );
        }
      }
    }
    for (final MapEntry(key: day, value: written) in words.entries) {
      final text = s.journal(day);
      for (final w in written) {
        expect(text, contains(w), reason: 'the journal of $day lost "$w" (seed $seed)');
      }
    }
  }
}
