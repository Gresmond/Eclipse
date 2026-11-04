import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/search.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards for the data work a task change, a day start and Settings do on
/// the UI thread, which grows with history if it's allowed to.
void main() {
  final today = DateTime(2026, 11, 3);

  /// A store a few years into use: [repeats] repeats begun over the years,
  /// and a history of tasks ticked day after day.
  Store used({int repeats = 200, int days = 900}) {
    final store = Store.memory();
    store.addHabit(today.year, today.month, 'Read');
    for (var i = 0; i < repeats; i++) {
      store.addRepeat(
        'Repeat $i',
        switch (i % 4) {
          0 => const RepeatRule.every(1),
          1 => RepeatRule.weekly({1 + i % 7}),
          2 => RepeatRule.monthly(1 + i % 28),
          _ => const RepeatRule.yearly(1),
        },
        DateTime(today.year - 3, 1 + i % 12, 1 + i % 28),
        birthday: i % 4 == 3,
      );
    }
    store.raw.execute('BEGIN');
    for (var d = 0; d < days; d++) {
      final day = dateKey(DateTime(today.year, today.month, today.day - days + d));
      for (var t = 0; t < 6; t++) {
        store.raw.execute("INSERT INTO todos (uid, scope, period, text, done, since) VALUES (?, 'today', ?, ?, 1, ?)", [
          'old$d-$t',
          day,
          'Task $d $t',
          day,
        ]);
        store.raw.execute('INSERT INTO todo_history VALUES (?, ?, ?)', [
          'old$d-$t',
          day,
          '{"scope":"today","period":"$day","text":"Task","done":1,"carried":0,"since":"$day","deleted":false}',
        ]);
      }
    }
    store.raw.execute('COMMIT');
    return store;
  }

  test('a time skipped while walking is still made the next day: one opened further ahead', () {
    final store = Store.memory();
    addTearDown(store.close);
    final repeat = store.addRepeat('Bins', RepeatRule.weekly({DateTime.tuesday}), today);
    store.makeRepeats(today);
    // A time a month ahead, opened from Further ahead, is made first.
    store.makeOccurrence(repeat, DateTime(2026, 12, 1));
    // Closed for three weeks: the Tuesdays between are made all the same.
    store.makeRepeats(DateTime(2026, 11, 24));
    expect(store.madeOccurrences(repeat.uid), {
      for (final d in [3, 10, 17, 24]) '${repeat.uid}@2026-11-${d.toString().padLeft(2, '0')}',
      '${repeat.uid}@2026-12-01',
    });
  });

  test('Settings reads the search index once until something changes, and only to search', () {
    final store = used(repeats: 0, days: 50);
    addTearDown(store.close);
    final state = AppState(store, clock: () => today.add(const Duration(hours: 10)));
    addTearDown(state.dispose);
    final builds = SearchIndex.debugBuilds;
    final index = state.searchIndex;
    expect(identical(state.searchIndex, index), isTrue, reason: 'opened again, or back to General');
    expect(SearchIndex.debugBuilds, builds, reason: 'not read until something is typed');
    expect(index.search('task 3'), isNotEmpty);
    index.search('task 4');
    expect(SearchIndex.debugBuilds, builds + 1);
    state.addTodo(TodoScope.today, 'Dentist');
    expect(state.searchIndex.search('dentist'), hasLength(1), reason: 'a change reads it afresh');
  });

  test('turning sync on with a long history flushes it a frame at a time', () async {
    final store = used(repeats: 20, days: 400);
    addTearDown(store.close);
    final engine = SyncEngine(store, 'pc');
    final slices = <int>[];
    final claiming = engine.claimAllGradually();
    // Edits made meanwhile wait their turn, a frame's worth at a time.
    var edits = 0;
    while (store.raw.select('SELECT 1 FROM sync_dirty LIMIT 1').isNotEmpty) {
      await Future<void>.delayed(Duration.zero);
      slices.add(engine.debugLastFlushed);
      store.setJournal('2026-11-03', 'Typed while it went ${edits++}');
      engine.flush();
    }
    await claiming;
    expect(slices.length, greaterThan(3), reason: 'more than one frame');
    final twin = used(repeats: 20, days: 400);
    addTearDown(twin.close);
    twin.setJournal('2026-11-03', 'Typed while it went ${edits - 1}');
    SyncEngine(twin, 'pc').claimAll();
    int count(Store s, String sql) => s.raw.select(sql).single.columnAt(0) as int;
    const registers = "SELECT COUNT(*) FROM sync_reg WHERE kind != 'todo_repeat'";
    expect(count(store, registers), count(twin, registers), reason: 'everything went, as at once');
    expect(store.journal('2026-11-03'), twin.journal('2026-11-03'));
  });
}
