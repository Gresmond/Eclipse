import 'dart:convert';
import 'dart:io';

import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// One computer: its own database and sync engine, with a clock tests set.
class _Pc {
  _Pc(this.name) : store = Store.memory() {
    engine = SyncEngine(store, name, clock: () => clock);
  }
  final String name;
  final Store store;
  late SyncEngine engine;
  static int clock = 1000000;

  List<List<Object?>> sent() {
    engine.flush();
    return engine.changesSince(0).values.expand((d) => d).toList();
  }

  Incoming hear(_Pc other) => engine.mergeAll([(other.sent(), other.name)]);

  List<Holiday> get holidays => decodeHolidays(store.setting('holidays'));
}

void main() {
  late _Pc pc, laptop;

  setUp(() {
    _Pc.clock = 1000000;
    pc = _Pc('pc');
    laptop = _Pc('laptop');
    pc.store.addHabit(2026, 11, 'Read');
    pc.engine.claimAll();
    laptop.engine.clearForJoining();
    laptop.hear(pc);
  });

  tearDown(() {
    pc.store.close();
    laptop.store.close();
  });

  void tick() => _Pc.clock += 1000;

  group('holidays', () {
    final november = (start: DateTime(2026, 11, 10), end: DateTime(2026, 11, 12));
    final december = (start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 27));
    final january = (start: DateTime(2027, 1, 4), end: DateTime(2027, 1, 8));

    test('added on two computers before they sync are both kept', () {
      pc.store.setSetting('holidays', encodeHolidays([november]));
      tick();
      laptop.store.setSetting('holidays', encodeHolidays([december]));
      tick();
      pc.hear(laptop);
      laptop.hear(pc);
      expect(pc.holidays, laptop.holidays, reason: 'they converge');
      expect(pc.holidays, [november, december], reason: 'neither computer\'s holiday is lost');
    });

    test('one taken away on the PC while the laptop adds another: both edits stay', () {
      pc.store.setSetting('holidays', encodeHolidays([november, december]));
      tick();
      laptop.hear(pc);
      tick();
      pc.store.setSetting('holidays', encodeHolidays([december]));
      tick();
      laptop.store.setSetting('holidays', encodeHolidays([november, december, january]));
      tick();
      pc.hear(laptop);
      laptop.hear(pc);
      expect(pc.holidays, [december, january]);
      expect(laptop.holidays, [december, january], reason: 'the removal sticks');
      // And stays taken away after another round.
      tick();
      pc.hear(laptop);
      laptop.hear(pc);
      expect(
        [pc.holidays, laptop.holidays],
        [
          [december, january],
          [december, january],
        ],
      );
    });

    test('a list from an older Eclipse, with no register per holiday, is taken in and merged', () {
      pc.store.setSetting('holidays', encodeHolidays([december]));
      tick();
      // How versions before 34 send them: the whole list, one register. Every
      // computer reads that one's file for itself.
      final older = [
        [
          'setting',
          'holidays',
          'value',
          jsonEncode(encodeHolidays([november])),
          _Pc.clock + 1000,
          'old',
          {'old': 1},
        ],
      ];
      for (final c in [pc, laptop]) {
        expect(c.engine.mergeAll([(older, 'old')]).failed, isEmpty);
      }
      expect(pc.holidays, [november, december], reason: 'its holiday joins the ones here, which stay');
      tick();
      laptop.hear(pc);
      expect(laptop.holidays, [november, december], reason: 'and both computers end up the same');
    });

    test('a holiday from before they were synced one by one can still be taken away', () {
      // Both had it from the list as a whole, as versions before 34 sync it.
      pc.store.setSetting('holidays', encodeHolidays([november]));
      pc.engine.flush();
      pc.store.raw.execute("DELETE FROM sync_reg WHERE kind = 'holiday'");
      laptop.hear(pc);
      laptop.store.raw.execute("DELETE FROM sync_reg WHERE kind = 'holiday'");
      expect(laptop.holidays, [november]);
      tick();
      laptop.store.setSetting('holidays', encodeHolidays(const []));
      tick();
      pc.hear(laptop);
      expect(pc.holidays, isEmpty);
    });
  });

  group('a repeat ended on one computer', () {
    final today = DateTime(2026, 11, 3);

    /// What each computer does when they sync: hear the other, then start
    /// the day over what came in.
    void meet() {
      tick();
      pc.hear(laptop);
      pc.store.makeRepeats(today);
      tick();
      laptop.hear(pc);
      laptop.store.makeRepeats(today);
      tick();
      pc.hear(laptop);
    }

    List<String> openAfter(_Pc c, String uid, String end) => [
      for (final r in c.store.raw.select("SELECT uid FROM todos WHERE uid LIKE '$uid@%' AND done = 0"))
        if ((r['uid'] as String).substring(uid.length + 1).compareTo(end) > 0) r['uid'] as String,
    ];

    late Repeat repeat;

    setUp(() {
      repeat = pc.store.addRepeat('Water plants', const RepeatRule.every(1), DateTime(2026, 11, 1));
      pc.store.makeRepeats(today); // Up to 10 Nov.
      tick();
      laptop.hear(pc);
      tick();
      // The laptop's day is already the 4th, so it makes the 11th too.
      laptop.store.makeRepeats(DateTime(2026, 11, 4));
      tick();
    });

    test('leaves no open time after its end on either computer', () {
      pc.store.endRepeat(repeat.uid, DateTime(2026, 11, 8), today);
      meet();
      for (final c in [pc, laptop]) {
        expect(c.store.repeats().single.until, DateTime(2026, 11, 7));
        expect(openAfter(c, repeat.uid, '2026-11-07'), isEmpty, reason: 'on ${c.name}');
      }
    });

    test('a time ticked after the end stays', () {
      final later = laptop.store.makeOccurrence(repeat, DateTime(2026, 11, 12));
      laptop.store.setTodoDone(later.id, true, day: today);
      tick();
      pc.store.endRepeat(repeat.uid, DateTime(2026, 11, 8), today);
      meet();
      for (final c in [pc, laptop]) {
        final ticked = c.store.raw.select('SELECT done FROM todos WHERE uid = ?', [later.uid]);
        expect(ticked.single['done'], 1, reason: 'on ${c.name}: it was done, whenever the repeat ended');
        expect(openAfter(c, repeat.uid, '2026-11-07'), isEmpty, reason: 'on ${c.name}');
      }
    });
  });

  test('edits made after the clock was put right are adopted when sync settings are lost', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse_adopt');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.memory();
    addTearDown(store.close);
    var clock = 5000000; // this computer's clock is an hour fast
    final old = SyncEngine(store, 'old', clock: () => clock);
    store.setJournal('2026-11-01', 'Sent before');
    old.claimAll();
    final folder = SyncFolder(dir, 'old', 'PC');
    await folder.write(old, 0);
    // Drive put the clock right: an hour back.
    old.offset = -3600000;
    clock += 1000;
    store.setJournal('2026-11-02', 'Written after the clock was put right');
    old.flush();
    // sync.json is lost (damaged, say); the database is kept. Signing in
    // again gives this computer a new id, and adopts its unsent edits.
    final again = SyncEngine(store, 'new', clock: () => clock);
    again.adoptUnsent(folder.latestSent());
    final going = again.changesSince(0).values.expand((d) => d).map((r) => r[1]).toSet();
    expect(going, contains('2026-11-02'), reason: 'the unsent journal edit still goes up');
    expect(going, isNot(contains('2026-11-01')), reason: 'what went already isn\'t sent again');
  });

  group('a task value this version can\'t read', () {
    List<Object?> reg(String field, Object? v) => [
      'todo',
      'bad1',
      field,
      jsonEncode(v),
      2000000,
      'pc',
      {'pc': 5},
    ];
    final bad = {
      'period': '1',
      'position': 1.5,
      'reminders': 'often',
      'due_date': 'soon',
      'done_at': 'later',
      'text': 3,
    };

    for (final MapEntry(key: field, value: value) in bad.entries) {
      test('in $field is left in its file, as one that couldn\'t be read', () {
        final dir = Directory.systemTemp.createTempSync('eclipse_bad_task');
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/pc/2026-11-03.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'version': 1,
              'name': 'PC',
              'registers': [
                reg('_', true),
                reg('scope', 'tomorrow'),
                reg('since', '2026-11-01'),
                if (field != 'period') reg('period', '2026-11-02'),
                if (field != 'text') reg('text', 'X'),
                reg(field, value),
              ],
            }),
          );
        final folder = SyncFolder(dir, 'laptop', 'Laptop');
        final incoming = folder.read(laptop.engine);
        expect(folder.unread, {'PC'});
        expect(incoming.rows, isEmpty);
      });
    }

    test('taken in all the same, still lets the day start', () {
      final incoming = laptop.engine.mergeAll([
        (
          [reg('_', true), reg('scope', 'tomorrow'), reg('period', '1'), reg('text', 'X'), reg('since', '2026-11-01')],
          'pc',
        ),
        ([reg('position', 1.5)], 'pc'),
      ]);
      expect(incoming.failed, isEmpty);
      expect(() => laptop.store.startDay(DateTime(2026, 11, 3)), returnsNormally);
      expect(laptop.store.todos(TodoScope.today, '2026-11-03').map((t) => t.text), contains('X'));
      expect(() => laptop.store.searchableTodos().toList(), returnsNormally);
    });
  });
}
