import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/year_heatmap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final mwf = weekdayBit(DateTime.monday) | weekdayBit(DateTime.wednesday) | weekdayBit(DateTime.friday);

  test('a change of days partway through a month leaves earlier days alone', () {
    final from = DateTime(2026, 10, 27);
    var days = changeDays([], from, mwf);
    expect(isOnDay(days, DateTime(2026, 10, 20)), isTrue, reason: 'a Tuesday before the change');
    expect(isOnDay(days, DateTime(2026, 10, 27)), isFalse, reason: 'a Tuesday from the change on');
    expect(isOnDay(days, DateTime(2026, 10, 28, 9)), isTrue);

    // Changed again the same day: replaces that day's change.
    days = changeDays(days, from, mwf | weekdayBit(DateTime.tuesday));
    expect(days, hasLength(1));
    expect(changeDays(days, from, everyDay), isEmpty, reason: 'back to every day');

    // A whole-month change replaces everything.
    expect(changeDays(days, null, mwf), [(null, mwf)]);
    expect(decodeDays(encodeDays(days)), days);
  });

  test('off days count for nothing: not in the score and not breaking a streak', () {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 10, 'Gym');
    store.setHabitDays(2026, 10, habit.id, [(null, mwf)]);
    expect(store.monthHabits(2026, 10).single.weekdays, mwf);

    // Mon 19, Wed 21, Fri 23, Mon 26 done; Tue 20 logged missed before the
    // schedule was set.
    for (final day in ['2026-10-19', '2026-10-21', '2026-10-23', '2026-10-26']) {
      store.setEntry(day, habit.id, HabitStatus.done);
    }
    store.setEntry('2026-10-20', habit.id, HabitStatus.missed);
    expect(store.monthScores(2026, 10)[habit.id], (4, 4));
    expect(store.streaks(habit.id, DateTime(2026, 10, 27)), (4, 4));
    // Wednesday left blank breaks it once Thursday comes.
    expect(store.streaks(habit.id, DateTime(2026, 10, 29)), (0, 4));
  });

  test("the week trail is a ritual's last 7 days, back across months, and no further than it goes", () {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 9, 'Gym', addedOn: DateTime(2026, 9, 14));
    store.setHabitDays(2026, 9, habit.id, [(null, weekdayBit(DateTime.monday))]);
    // October isn't saved yet, so it's on September's days.
    expect(store.pastDays(habit.id, DateTime(2026, 10, 27), 7), [
      DateTime(2026, 10, 26),
      DateTime(2026, 10, 19),
      DateTime(2026, 10, 12),
      DateTime(2026, 10, 5),
      DateTime(2026, 9, 28),
      DateTime(2026, 9, 21),
      DateTime(2026, 9, 14),
    ]);
    // Saved, and on Mondays and Fridays from the 20th: only the day it was added stops it.
    store.copyMonth((2026, 9), (2026, 10));
    store.setHabitDays(
      2026,
      10,
      habit.id,
      changeDays(
        [(null, weekdayBit(DateTime.monday))],
        DateTime(2026, 10, 20),
        weekdayBit(DateTime.monday) | weekdayBit(DateTime.friday),
      ),
    );
    expect(store.pastDays(habit.id, DateTime(2026, 10, 27), 7).take(3), [
      DateTime(2026, 10, 26),
      DateTime(2026, 10, 23),
      DateTime(2026, 10, 19),
    ]);
    expect(store.pastDays(habit.id, DateTime(2026, 9, 22), 7), [DateTime(2026, 9, 21), DateTime(2026, 9, 14)]);
  });

  test('a new month starts on the latest days, and days sync', () {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 10, 'Gym');
    store.setHabitDays(2026, 10, habit.id, changeDays([], DateTime(2026, 10, 27), mwf));
    store.copyMonth((2026, 10), (2026, 11));
    expect(store.monthHabits(2026, 11).single.days, [(null, mwf)]);

    final other = Store.memory();
    addTearDown(other.close);
    final sender = SyncEngine(store, 'a')..claimAll();
    final receiver = SyncEngine(other, 'b')..clearForJoining();
    receiver.mergeAll([(sender.changesSince(0).values.expand((v) => v).toList(), 'a')]);
    expect(other.monthHabits(2026, 10).single.days, store.monthHabits(2026, 10).single.days);
  });

  test('a ritual added partway through a month stays out of the months before it', () {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 10, 'Read');
    store.addHabit(2026, 10, 'Sunlight', addedOn: DateTime(2026, 10, 27));
    store.copyMonth((2026, 10), (2026, 9));
    expect([for (final h in store.monthHabits(2026, 9)) h.name], ['Read']);
    store.copyMonth((2026, 10), (2026, 11));
    expect([for (final h in store.monthHabits(2026, 11)) h.name], ['Read', 'Sunlight']);
  });

  test('ritual addedOn dates sync across devices without carrying to copied months', () {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 10, 'Read', addedOn: DateTime(2026, 10, 26));
    final sender = SyncEngine(store, 'a')..claimAll();
    final other = Store.memory();
    addTearDown(other.close);
    final receiver = SyncEngine(other, 'b')..clearForJoining();
    receiver.mergeAll([(sender.changesSince(0).values.expand((v) => v).toList(), 'a')]);
    expect(other.monthHabits(2026, 10).single.addedOn, DateTime(2026, 10, 26));
    other.copyMonth((2026, 10), (2026, 11));
    expect(other.monthHabits(2026, 11).single.addedOn, isNull);
  });

  test('days before a ritual was added are greyed out and left out of its score', () {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 10, 'Read', addedOn: DateTime(2026, 10, 20));
    expect(habit.startedBy(DateTime(2026, 10, 19)), isFalse);
    expect(habit.startedBy(DateTime(2026, 10, 20, 9)), isTrue);
    store.setEntry('2026-10-12', habit.id, HabitStatus.missed);
    store.setEntry('2026-10-21', habit.id, HabitStatus.done);
    expect(store.monthScores(2026, 10)[habit.id], (1, 1));
    expect(store.habitBeforeYear(habit.id, 2026), isFalse);
    expect(store.habitBeforeYear(habit.id, 2027), isTrue);
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
    expect(scores[weekly.id], (1, 2));
  });

  test('weekly goals count each eligible day once across month boundaries', () {
    final store = Store.memory();
    addTearDown(store.close);
    final ritual = store.addHabit(2026, 11, 'Walk', addedOn: DateTime(2026, 10, 26));
    store.raw.execute('UPDATE month_habits SET weekly=7 WHERE habit_id=?', [ritual.id]);
    store.setEntry('2026-10-26', ritual.id, HabitStatus.done);
    store.setEntry('2026-10-27', ritual.id, HabitStatus.other);
    store.setEntry('2026-10-28', ritual.id, HabitStatus.done);
    final scores = store.monthScores(
      2026,
      11,
      asOf: DateTime(2026, 11, 1),
      holidays: [(start: DateTime(2026, 10, 27), end: DateTime(2026, 10, 28))],
    );
    expect(scores[ritual.id], (1, 5));
  });

  test('numeric progress survives reload and only reaching the goal counts for the week', () {
    final day = DateTime(2026, 11, 19);
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 19, 12));
    addTearDown(state.dispose);
    final habit = state.habits.single;
    state.setRitualGoal(2026, 11, habit, weekly: 3, target: 10, unit: 'pages');
    state.recordAmount(day, habit, 6);
    expect(state.amountOn(day, habit), 6);
    expect(state.weeklyDone(day, habit), 0);
    state.recordAmount(day, habit, 12);
    expect(state.statusOf(day, habit), HabitStatus.done);
    expect(state.weeklyDone(day, habit), 1);
    expect(store.raw.select('SELECT target,unit FROM month_habits').single['unit'], 'pages');
  });

  testWidgets('YearHeatmap ignores entries before addedOn and on unscheduled weekdays', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = Store.memory();
    addTearDown(store.close);
    final mondayHabit = store.addHabit(2026, 11, 'Monday review', addedOn: DateTime(2026, 11, 9));
    store.setHabitDays(2026, 11, mondayHabit.id, [(null, weekdayBit(DateTime.monday))]);
    store.setEntry('2026-11-02', mondayHabit.id, HabitStatus.missed);
    store.setEntry('2026-11-10', mondayHabit.id, HabitStatus.missed);
    store.setEntry('2026-11-09', mondayHabit.id, HabitStatus.done);
    final state = AppState(store, clock: () => DateTime(2026, 11, 10, 10));
    addTearDown(state.dispose);
    state.showYear();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    expect(find.text('THE YEAR  ·  100% OF RITUALS DONE'), findsOneWidget);
  });

  testWidgets('YearHeatmap slips always exclude weekends and weekend baseline', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = Store.memory();
    addTearDown(store.close);
    final stretch = store.addHabit(2026, 10, 'Stretch', addedOn: DateTime(2026, 10, 1));
    final read = store.addHabit(2026, 10, 'Read', addedOn: DateTime(2026, 10, 1));
    // 28 days (4 full Mon-Sun weeks): 4 occurrences of every weekday.
    for (var d = 1; d <= 28; d++) {
      final day = DateTime(2026, 10, d);
      final key = dateKey(day);
      final isWeekend = day.weekday >= DateTime.saturday;
      store.setEntry(key, stretch.id, isWeekend ? HabitStatus.missed : HabitStatus.done);
      store.setEntry(
        key,
        read.id,
        isWeekend || day.weekday == DateTime.friday ? HabitStatus.missed : HabitStatus.done,
      );
    }

    final state = AppState(store, clock: () => DateTime(2026, 11, 2, 10));
    addTearDown(state.dispose);
    state.showYear();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(YearHeatmap),
        matching: find.textContaining('Stretch', findRichText: true),
      ),
      findsNothing,
    );
    expect(find.textContaining('Saturdays', findRichText: true), findsNothing);
    expect(find.textContaining('Read slips on Fridays  0%, usually 80%', findRichText: true), findsOneWidget);
  });

  group('Habits & Sleep Schedule', () {
    test('monthScores excludes HabitStatus.other from denominator', () {
      final store = Store.memory();
      addTearDown(store.close);
      final habit = store.addHabit(2026, 11, 'Read');
      store.setEntry('2026-11-01', habit.id, HabitStatus.done);
      store.setEntry('2026-11-02', habit.id, HabitStatus.missed);
      store.setEntry('2026-11-03', habit.id, HabitStatus.other);
      store.setEntry('2026-11-04', habit.id, HabitStatus.other);

      expect(store.monthScores(2026, 11)[habit.id], (1, 2));
    });

    test('pastDays returns 7 days of history for sleep habits', () {
      final store = Store.memory();
      addTearDown(store.close);
      final sleep = store.sleepHabits(2026, 11).first;
      final days = store.pastDays(sleep.id, DateTime(2026, 11, 10), 7);
      expect(days, [
        DateTime(2026, 11, 9),
        DateTime(2026, 11, 8),
        DateTime(2026, 11, 7),
        DateTime(2026, 11, 6),
        DateTime(2026, 11, 5),
        DateTime(2026, 11, 4),
        DateTime(2026, 11, 3),
      ]);
    });

    test('removeHabit on preview month captures undo snapshot and clears scores/streaks', () {
      final store = Store.memory();
      addTearDown(store.close);
      store.addHabit(2026, 10, 'Read');
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 9));
      addTearDown(state.dispose);
      final preview = state.habitsFor(2026, 12);
      expect(state.isPreviewMonth(2026, 12), isTrue);

      state.removeHabit(2026, 12, preview.single);
      expect(state.habitsFor(2026, 12), isEmpty);
      state.undo();
      expect(state.habitsFor(2026, 12), hasLength(1));
    });

    test('renameHabit, setHabitNote, setHabitDays, setSleepTime guard missing habits and future days', () {
      final store = Store.memory();
      addTearDown(store.close);
      final habit = store.addHabit(2026, 11, 'Read');
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 9));
      addTearDown(state.dispose);

      state.removeHabit(2026, 11, habit);
      state.renameHabit(2026, 11, habit, 'Should ignore');
      state.setHabitNote(2026, 11, habit, 'Ignored note');
      state.setHabitDays(2026, 11, habit, 1);
      state.setSleepTime(2026, 11, Habit(-999, 'Missing'), 600);
      expect(state.habitsFor(2026, 11), isEmpty);

      final future = DateTime(2026, 11, 6);
      final h2 = store.addHabit(2026, 11, 'Walk');
      expect(state.selectStatus(future, h2, HabitStatus.done), HabitStatus.none);
      state.setNote(future, h2, 'Nope');
      expect(state.statusOf(future, h2), HabitStatus.none);
      expect(state.noteOf(future, h2), isNull);
    });
  });
}
