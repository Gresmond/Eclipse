import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/smart_add.dart';
import 'package:eclipse/training.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 11, 20); // Friday

  test('smart add parses tricky places and times while leaving ratios, bible verses, and plain words literal', () {
    final oval = parseQuickTask('Training at North Adelaide Oval at 19:35', today);
    expect(oval.name, 'Training');
    expect(oval.location, 'North Adelaide Oval');
    expect(oval.minutes, 19 * 60 + 35);

    final fraction = parseQuickTask('Use 1/2 cup oats', today);
    expect(fraction.day, isNull);
    expect(fraction.name, 'Use 1/2 cup oats');

    final sunblock = parseQuickTask('Buy sunblock', today);
    expect(sunblock.day, isNull);
    expect(sunblock.name, 'Buy sunblock');

    final satchel = parseQuickTask('Fix sat nav', today);
    expect(satchel.day, isNull);
    expect(satchel.name, 'Fix sat nav');

    final nextMon = parseQuickTask('Dentist next Monday', DateTime(2026, 11, 16));
    expect(nextMon.day, DateTime(2026, 11, 23));

    final range = parseQuickTask('Deep work between 3pm and 5pm', today);
    expect(range.name, 'Deep work');
    expect(range.minutes, 15 * 60);

    expect(parseQuickTask('Meeting from 3pm to 4pm', today).minutes, 900);
    expect(parseQuickTask('Dentist next Monday', today).day, DateTime(2026, 11, 23));
    expect(parseQuickTask('Buy milk 1/2', today).day, isNull);
    expect(parseQuickTask('Buy milk on 1/2', today).day, DateTime(2027, 2, 1));

    final verse = parseQuickTask('Read John 3:16', today);
    expect(verse.minutes, isNull);
    expect(verse.name, 'Read John 3:16');

    final ratio = parseQuickTask('Mix 2:1 epoxy', today);
    expect(ratio.minutes, isNull);
    expect(ratio.name, 'Mix 2:1 epoxy');
  });

  test('monthScores excludes other marks, honors holidays, and scores weekly targets separately', () {
    final store = Store.memory();
    addTearDown(store.close);
    final daily = store.addHabit(2026, 11, 'Meditate');
    final weekly = store.addHabit(2026, 11, 'Run', addedOn: DateTime(2026, 11, 2));
    store.raw.execute('UPDATE month_habits SET weekly=2 WHERE year=2026 AND month=11 AND habit_id=?', [weekly.id]);
    store.setEntry(dateKey(DateTime(2026, 11, 2)), daily.id, HabitStatus.done);
    store.setEntry(dateKey(DateTime(2026, 11, 3)), daily.id, HabitStatus.other);
    store.setEntry(dateKey(DateTime(2026, 11, 4)), daily.id, HabitStatus.missed);
    store.setEntry(dateKey(DateTime(2026, 11, 5)), daily.id, HabitStatus.missed);
    store.setEntry(dateKey(DateTime(2026, 11, 2)), weekly.id, HabitStatus.done);

    final scores = store.monthScores(
      2026,
      11,
      asOf: DateTime(2026, 11, 5),
      holidays: [(start: DateTime(2026, 11, 5), end: DateTime(2026, 11, 5))],
    );
    expect(scores[daily.id], (1, 2));
    expect(scores[weekly.id], (1, 1));
  });

  test('weighted bodyweight uses total load for 1RM, clears added weight, and manages routines', () {
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 11, 20, 12));
    addTearDown(state.dispose);
    final log = state.training;

    log.weighIn(DateTime(2026, 11, 1), 80);
    final dips = log.createExercise('Dips', MuscleGroup.chest, bodyweight: true);
    log.addSet(today, dips, reps: 5, loggedWeight: 20);
    expect(log.usesTotalLoad(dips), isTrue);

    final sets = log.session(today).single.$2;
    expect(sets.single.weight, 20);
    log.setDetails(sets.single, 'Felt heavy', 8.5, clearWeight: true);
    expect(log.session(today).single.$2.single.weight, isNull);
    expect(log.session(today).single.$2.single.rpe, 8.5);
    expect(log.usesTotalLoad(dips), isFalse);

    log.addSet(today, dips, reps: 8, loggedWeight: 10);
    log.saveRoutine('Upper A', today);
    final routine = log.routines.single;
    log.renameRoutine(routine.$1, 'Upper Power');
    expect(log.routines.single.$2, 'Upper Power');
    log.deleteRoutine(routine.$1);
    expect(log.routines, isEmpty);
  });

  test('holidays record undo/redo snapshots, makeRepeating keeps notes, and shutdown is single-flight', () async {
    final home = Directory.systemTemp.createTempSync('eclipse-audit-test');
    final store = Store.memory();
    final sync = SyncService.load(home, store);
    final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 20, 12));
    addTearDown(() {
      state.dispose();
      sync.dispose();
      store.close();
      home.deleteSync(recursive: true);
    });

    state.addHoliday(DateTime(2026, 12, 25), DateTime(2026, 12, 26));
    expect(state.holidays, hasLength(1));
    state.undo();
    expect(state.holidays, isEmpty);
    state.redo();
    expect(state.holidays, hasLength(1));

    state.addTodo(TodoScope.today, 'Pay rent');
    TodoItem rent() => state.todos[TodoScope.today]!.singleWhere((item) => item.text == 'Pay rent');
    final item = rent();
    state.setTodoNote(TodoScope.today, item, 'BSB 123-456');
    state.makeRepeating(
      TodoScope.today,
      rent(),
      'Pay rent',
      const RepeatRule.monthly(20),
      note: (value: 'Updated note'),
    );
    expect(rent().note, 'Updated note');

    sync.onIncoming!(Incoming({('todo', 'fake')}, {'Other'}));
    expect(state.canUndo, isFalse);
    expect(state.canRedo, isFalse);

    await Future.wait([state.shutdown(sync: false), state.shutdown(sync: false)]);
    expect(state.closing, isTrue);
  });
}
