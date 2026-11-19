import 'dart:async';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/search.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/training_view.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/training_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingNotifier implements ReminderNotifier {
  final shown = <(String, String)>[];

  @override
  void show(ReminderAlert alert, String body) => shown.add((alert.text, body));

  @override
  set onOpen(void Function(String uid)? open) {}
}

void main() {
  Store memory({bool empty = false}) {
    final store = Store.memory();
    addTearDown(store.close);
    if (!empty) store.addHabit(2026, 11, 'Read');
    return store;
  }

  group('Habits & Sleep Schedule', () {
    test('monthScores excludes HabitStatus.other from denominator', () {
      final store = memory(empty: true);
      final habit = store.addHabit(2026, 11, 'Read');
      store.setEntry('2026-11-01', habit.id, HabitStatus.done);
      store.setEntry('2026-11-02', habit.id, HabitStatus.missed);
      store.setEntry('2026-11-03', habit.id, HabitStatus.other);
      store.setEntry('2026-11-04', habit.id, HabitStatus.other);

      expect(store.monthScores(2026, 11)[habit.id], (1, 2));
    });

    test('pastDays returns 7 days of history for sleep habits', () {
      final store = memory();
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
      final store = memory(empty: true);
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
      final store = memory(empty: true);
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

  group('Task Ordering & Reminders', () {
    test('sortTodos satisfies strict weak ordering with mixed dated and undated subtasks', () {
      final today = DateTime(2026, 11, 5);
      TodoItem project(int id, {DateTime? due, int? position, bool done = false}) => TodoItem(
        id,
        'P$id',
        since: today,
        dueDate: due,
        position: position,
        done: done,
        subtasks: const [TodoSubtask('Step')],
      );

      final items = [
        project(1, position: 0),
        project(2, due: DateTime(2026, 11, 8), position: 1),
        project(3, due: DateTime(2026, 11, 6), position: 2),
        project(4),
        project(5, done: true),
        project(6, due: DateTime(2026, 11, 7), done: true),
      ];

      final sorted = sortTodos(items);
      expect(sorted.map((t) => t.id), [3, 2, 1, 4, 6, 5]);
      // Re-sorting any permutation must yield the same relative order for distinct dates/undated.
      final reversed = sortTodos(items.reversed);
      expect(reversed.map((t) => t.dueDate != null), [true, true, false, false, true, false]);
    });

    test('carried-over undated Today task fires reminder when time/reminder is added today', () {
      final store = memory();
      var now = DateTime(2026, 11, 4, 10);
      final notifier = _RecordingNotifier();
      final state = AppState(store, notifier: notifier, clock: () => now);
      addTearDown(state.dispose);

      state.addTodo(TodoScope.today, 'Call bank');
      now = DateTime(2026, 11, 5, 10);
      state.checkDate();

      final carried = state.todos[TodoScope.today]!.single;
      state.editTodo(
        TodoScope.today,
        carried,
        carried.text,
        carried.dueDate,
        time: 15 * 60,
        reminders: Reminder.quarterBefore.bit,
      );

      now = DateTime(2026, 11, 5, 14, 46);
      state.checkReminders();
      expect(notifier.shown, [('Call bank', 'In 14 min, at 3:00 pm')]);
    });

    test('carried-over past-due task anchors dueDate to today when time/reminders change', () {
      final store = memory();
      var now = DateTime(2026, 11, 4, 10);
      final notifier = _RecordingNotifier();
      final state = AppState(store, notifier: notifier, clock: () => now);
      addTearDown(state.dispose);

      state.addTodo(TodoScope.today, 'Submit report', dueDate: DateTime(2026, 11, 4));
      now = DateTime(2026, 11, 5, 10);
      state.checkDate();

      final carried = state.todos[TodoScope.today]!.single;
      state.editTodo(
        TodoScope.today,
        carried,
        carried.text,
        carried.dueDate,
        time: 16 * 60,
        reminders: Reminder.quarterBefore.bit,
      );

      expect(state.todos[TodoScope.today]!.single.dueDate, isNull);
      now = DateTime(2026, 11, 5, 15, 46);
      state.checkReminders();
      expect(notifier.shown, [('Submit report', 'In 14 min, at 4:00 pm')]);
    });

    test('reminderCards prune on edit/complete/delete, openReminder removes all matching cards, and holdReminders guards dispose', () async {
      final store = memory();
      var now = DateTime(2026, 11, 5, 14);
      final state = AppState(store, clock: () => now);

      state.addTodo(TodoScope.today, 'Dentist', time: 15 * 60, reminders: Reminder.quarterBefore.bit);
      state.addTodo(TodoScope.today, 'Call', time: 16 * 60, reminders: Reminder.quarterBefore.bit);
      now = DateTime(2026, 11, 5, 14, 46);
      state.checkReminders();
      expect(state.reminderCards, hasLength(1));

      // Renaming updates the shown reminder card text.
      var dentist = state.todos[TodoScope.today]!.firstWhere((t) => t.text == 'Dentist');
      state.editTodo(
        TodoScope.today,
        dentist,
        'Orthodontist',
        dentist.dueDate,
        time: dentist.dueTime,
        reminders: dentist.reminders,
      );
      expect(state.reminderCards.single.text, 'Orthodontist');

      // Moving to tomorrow removes the stale card.
      dentist = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Orthodontist');
      state.moveTodoTo(TodoScope.today, dentist, DateTime(2026, 11, 6));
      expect(state.reminderCards, isEmpty);

      // Completing a task removes its card; openReminder removes all cards for that uid.
      now = DateTime(2026, 11, 5, 15, 46);
      state.checkReminders();
      expect(state.reminderCards.single.text, 'Call');
      final call = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Call');
      state.reminderCards.add(state.reminderCards.single);
      state.openReminder(call.uid!);
      expect(state.reminderCards, isEmpty);

      // Malformed remindersShown setting does not crash.
      store.setSetting('remindersShown', '{"not":"a list"}');
      state.checkReminders();
      store.setSetting('remindersShown', '["badkey"]');
      state.checkReminders();

      // Disposing during holdReminders does not throw or notify.
      final sync = Completer<void>();
      state.holdReminders(sync.future);
      state.dispose();
      sync.complete();
      await Future<void>.delayed(Duration.zero);
    });

    test('ReminderAlert.body and dueReminders respect dayStartHour', () {
      const startHour = 4;
      final item = TodoItem(
        1,
        'Late call',
        since: DateTime(2026, 11, 3),
        uid: 'late',
        dueTime: 60, // 1:00 am
        reminders: Reminder.dayBefore.bit,
      );
      // 1:00 am on logical day Nov 3 is calendar Nov 4 01:00.
      final calendarDay = DateTime(2026, 11, 4);
      final [(alert, _)] = dueReminders(
        [(item, calendarDay)],
        DateTime(2026, 11, 3, 22),
        const {},
        startHour: startHour,
      );
      expect(alert.body(DateTime(2026, 11, 3, 22), startHour: startHour), 'In 3 hours, at 1:00 am');

      final mum = TodoItem(
        2,
        'Mum',
        since: DateTime(2026, 11, 3),
        uid: 'mum',
        birthday: true,
        reminders: Reminder.dayBefore.bit | Reminder.onTheDay.bit,
      );
      // At 1:00 am on Nov 4 with 4am day start, it's still Nov 3 ("Birthday tomorrow").
      final [(bdayAlert, _)] = dueReminders(
        [(mum, DateTime(2026, 11, 4))],
        DateTime(2026, 11, 4, 1),
        const {},
        startHour: startHour,
      );
      expect(bdayAlert.reminder, Reminder.dayBefore);
      expect(bdayAlert.body(DateTime(2026, 11, 4, 1), startHour: startHour), 'Birthday tomorrow');
    });
  });

  group('Repeats, Subtasks, Holidays & Yesterday', () {
    test('changeRepeat preserves note, subtask progress/notes, and carried-over occurrences', () {
      final store = memory();
      var now = DateTime(2026, 11, 1, 9);
      final state = AppState(store, clock: () => now);
      addTearDown(state.dispose);

      state.addRepeat('Pack', const RepeatRule.every(1), DateTime(2026, 11, 1));
      now = DateTime(2026, 11, 3, 9);
      state.checkDate();

      // Carried-over Nov 1 occurrence stays untouched when Nov 3 occurrence changes rule.
      final nov3 = state.todos[TodoScope.today]!.firstWhere((t) => t.repeatDay == DateTime(2026, 11, 3));
      state.setTodoNote(TodoScope.today, nov3, 'Keep this note');
      state.setTodoSubtasks(TodoScope.today, nov3, const [
        TodoSubtask('Passport', done: true, note: 'Top drawer'),
        TodoSubtask('Tickets'),
      ]);
      final repeat = state.repeatOf(nov3)!;
      state.changeRepeat(repeat, DateTime(2026, 11, 3), 'Pack', const RepeatRule.every(2));

      final carried = state.todos[TodoScope.today]!.where((t) => t.repeatDay == DateTime(2026, 11, 1)).toList();
      expect(carried, hasLength(1));

      final updated = state.todos[TodoScope.today]!.firstWhere((t) => t.repeatDay == DateTime(2026, 11, 3));
      expect(updated.note, 'Keep this note');
      expect(updated.subtasks.first.done, isTrue);
      expect(updated.subtasks.first.note, 'Top drawer');
    });

    test('makeRepeating handles TodoScope.tomorrow, completed tasks, and holiday starts', () {
      final store = memory();
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 9));
      addTearDown(state.dispose);

      state.addHoliday(DateTime(2026, 11, 6), DateTime(2026, 11, 6));
      state.addTodo(TodoScope.tomorrow, 'Stretch');
      final tomorrowItem = state.todos[TodoScope.tomorrow]!.single;
      state.makeRepeating(TodoScope.tomorrow, tomorrowItem, 'Stretch', const RepeatRule.every(1));
      // Nov 6 is a holiday, so the first active occurrence made is Nov 7 (from tomorrow start Nov 6).
      expect(state.repeats.single.start, DateTime(2026, 11, 6));
      expect(state.todos[TodoScope.tomorrow], isEmpty);
      expect(
        state.todos.values.expand((l) => l).any((t) => t.repeatDay == DateTime(2026, 11, 7) && t.text == 'Stretch'),
        isTrue,
      );

      // Completed task made repeating stays done today when starting today.
      state.addTodo(TodoScope.today, 'Vitamins');
      final doneItem = state.todos[TodoScope.today]!.single;
      state.toggleTodo(doneItem);
      state.makeRepeating(
        TodoScope.today,
        state.todos[TodoScope.today]!.single,
        'Vitamins',
        const RepeatRule.every(1),
      );
      final todayOcc = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Vitamins');
      expect(todayOcc.done, isTrue);
      expect(todayOcc.repeatDay, DateTime(2026, 11, 5));
    });

    test('nestTodo rejects completed targets and preserves from.note on future open occurrences', () {
      final store = memory();
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 9));
      addTearDown(state.dispose);

      state.addTodo(TodoScope.today, 'Done target');
      state.toggleTodo(state.todos[TodoScope.today]!.single);
      state.addTodo(TodoScope.today, 'Open source');
      expect(
        state.nestTodo(
          TodoScope.today,
          state.todos[TodoScope.today]!.firstWhere((t) => t.text == 'Open source'),
          TodoScope.today,
          state.todos[TodoScope.today]!.firstWhere((t) => t.text == 'Done target'),
        ),
        isFalse,
      );

      state.addRepeat('Trip prep', const RepeatRule.every(1), DateTime(2026, 11, 5));
      final source = state.todos[TodoScope.today]!.firstWhere((t) => t.text == 'Open source');
      state.setTodoNote(TodoScope.today, source, 'Bring receipt');
      final target = state.todos[TodoScope.today]!.firstWhere((t) => t.text == 'Trip prep');
      final reloadedSource = state.todos[TodoScope.today]!.firstWhere((t) => t.text == 'Open source');

      expect(state.nestTodo(TodoScope.today, reloadedSource, TodoScope.today, target, future: true), isTrue);
      final tomorrowOcc = state.todos.values
          .expand((l) => l)
          .singleWhere((t) => t.text == 'Trip prep' && t.repeatDay == DateTime(2026, 11, 6));
      expect(tomorrowOcc.subtasks.single.note, 'Bring receipt');
      // Template itself remains note-free.
      expect(state.repeats.single.subtasks.single.note, isNull);
    });

    test('holiday-paused repeats recover when holiday is removed on another synced device', () {
      final aStore = memory(), bStore = memory();
      final now = DateTime(2026, 11, 2, 9);
      final aState = AppState(aStore, clock: () => now);
      final bState = AppState(bStore, clock: () => now);
      addTearDown(aState.dispose);
      addTearDown(bState.dispose);

      aState.addRepeat('Water plants', const RepeatRule.every(1), DateTime(2026, 11, 2));
      final ea = SyncEngine(aStore, 'a'), eb = SyncEngine(bStore, 'b');

      // Sync initial repeat to B.
      ea.flush();
      eb.mergeAll([(ea.changesSince(0).values.expand((c) => c), 'a')]);
      bStore.startDay(now);

      // A adds holiday Nov 3-4, pausing those occurrences.
      aState.addHoliday(DateTime(2026, 11, 3), DateTime(2026, 11, 4));
      ea.flush();
      final incoming = eb.mergeAll([(ea.changesSince(0).values.expand((c) => c), 'a')]);
      expect(incoming.rows, isNotEmpty);
      bState.holidays = decodeHolidays(bStore.setting('holidays'));

      // B removes the holiday and must restore Nov 3 and Nov 4.
      bState.removeHoliday(bState.holidays.single);
      final bUids = bState.todos.values.expand((l) => l).map((t) => t.uid).toSet();
      expect(bUids, contains(endsWith('@2026-11-03')));
      expect(bUids, contains(endsWith('@2026-11-04')));
    });

    test('setPastTodoDone preserves today subtasks and wraps promotions in local()', () {
      final store = memory();
      var now = DateTime(2026, 11, 4, 9);
      final state = AppState(store, clock: () => now);
      addTearDown(state.dispose);

      state.addTodo(TodoScope.today, 'Project');
      final yTask = state.todos[TodoScope.today]!.single;
      state.setTodoSubtasks(TodoScope.today, yTask, const [TodoSubtask('One')]);

      now = DateTime(2026, 11, 5, 9);
      state.checkDate();
      final todayTask = state.todos[TodoScope.today]!.single;
      state.setTodoSubtasks(TodoScope.today, todayTask, const [TodoSubtask('One'), TodoSubtask('Two')]);

      final yesterday = DateTime(2026, 11, 4);
      final pastItem = state.todosOn(TodoScope.today, yesterday).single;
      state.toggleTodo(pastItem, day: yesterday);
      final liveAfter = store.todos(TodoScope.today, dateKey(yesterday)).single;
      expect(liveAfter.done, isTrue);
      expect(liveAfter.subtasks.map((s) => (s.text, s.done)), [('One', true), ('Two', true)]);
    });

    test('adding a task under Today while viewing Yesterday persists to Today', () {
      final store = memory();
      var now = DateTime(2026, 11, 5, 9);
      final state = AppState(store, clock: () => now);
      addTearDown(state.dispose);

      final yesterday = DateTime(2026, 11, 4);
      state.showDay(yesterday);
      state.addTodo(TodoScope.tomorrow, 'Added while looking back', day: yesterday);

      expect(state.todosOn(TodoScope.tomorrow, yesterday).map((t) => t.text), ['Added while looking back']);
      expect(state.todos[TodoScope.today]!.map((t) => t.text), ['Added while looking back']);
      state.showToday();
      expect(state.todos[TodoScope.today]!.map((t) => t.text), ['Added while looking back']);
    });
  });

  group('Dates, Timezone & Settings Validation', () {
    test('Repeat.on/next normalize non-midnight dates and RepeatRule.decode bounds every', () {
      final r = Repeat(
        uid: 'r1',
        text: 'Daily',
        rule: const RepeatRule.every(2),
        start: DateTime(2026, 11, 1, 15, 30),
        until: DateTime(2026, 11, 5, 8, 0),
      );
      expect(r.on(DateTime(2026, 11, 5, 23, 59)), isTrue);
      expect(r.next(DateTime(2026, 11, 1, 20, 0)), DateTime(2026, 11, 1));
      expect(RepeatRule.decode('days:1001'), isNull);
      expect(RepeatRule.decode('days:1000'), const RepeatRule.every(1000));
    });

    test('parseClock and dayStartHour validate ranges and setDayStartHour bumps todosRevision', () {
      expect(parseClock('25:00'), isNull);
      expect(parseClock('12:60'), isNull);
      expect(parseClock('13:00 pm'), isNull);
      expect(parseClock('08:30'), 510);
      expect(parseDayStartHour('24'), 0);
      expect(parseDayStartHour('-1'), 0);
      expect(parseDayStartHour('4'), 4);

      final store = memory();
      store.setSetting('dayStartHour', '99');
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 2));
      addTearDown(state.dispose);
      expect(state.dayStartHour, 0);

      final rev = state.todosRevision;
      state.setDayStartHour(99);
      expect(state.dayStartHour, 0);
      state.setDayStartHour(4);
      expect(state.dayStartHour, 4);
      expect(state.todosRevision, greaterThan(rev));
      expect(state.today, DateTime(2026, 11, 4));
    });
  });

  group('Training Math & Validation', () {
    test('trainingPoints indexes by counted working set and stays positive without drift', () {
      TrainingSet s(String uid, double? w, int r, int pos) =>
          TrainingSet(uid: uid, day: '2026-11-01', exercise: 'e', position: pos, weight: w, reps: r);

      // Uncounted 25-rep warmup at index 0 should not shift working set index comparison.
      final points = trainingPoints([
        (
          DateTime(2026, 11, 1),
          [s('1', 20, 25, 0), s('2', 100, 5, 1)],
        ),
        (
          DateTime(2026, 11, 3),
          [s('3', 100, 5, 0)],
        ),
      ], bodyweight: false);
      expect(points, hasLength(2));
      expect(points[1].value, closeTo(points[0].value, 1e-9));

      // Extreme drop across sessions stays clamped positive and never drops <= 0.
      final extreme = trainingPoints([
        (
          DateTime(2026, 11, 1),
          [s('a1', null, 20, 0), s('a2', null, 2, 1)],
        ),
        (
          DateTime(2026, 11, 2),
          [s('b1', null, 2, 0)],
        ),
      ], bodyweight: true);
      expect(extreme.last.value, greaterThan(0));
      expect(extreme.last.value, greaterThanOrEqualTo(1.0));
    });

    test('personalBests ignores empty placeholder prior sets and lighter sets after high-rep sets', () {
      final store = memory();
      final log = TrainingLog(store, () {});
      final bench = log.createExercise('Bench', MuscleGroup.chest, bodyweight: false);

      // Day 1 has only an empty placeholder set (0 reps).
      final d1 = DateTime(2026, 11, 1);
      log.addToDay(d1, bench);
      log.updateSet(log.session(d1).single.$2.single, weight: 60, reps: 0);

      // Day 2 is the first real session: no PB yet.
      final d2 = DateTime(2026, 11, 3);
      log.addToDay(d2, bench);
      log.updateSet(log.session(d2).single.$2.single, weight: 40, reps: 25);
      expect(log.personalBests(d2, bench), isEmpty);

      // Day 3 with a much lighter set than Day 2's 40kg x 25 is not a PB.
      final d3 = DateTime(2026, 11, 5);
      log.addToDay(d3, bench);
      log.updateSet(log.session(d3).single.$2.single, weight: 20, reps: 5);
      expect(log.personalBests(d3, bench), isEmpty);
    });

    test('loggedDays and loggedOrder filter orphaned sets, validation rejects invalid inputs, and _lastSet respects date', () {
      final store = memory();
      store.addTrainingSet('2026-11-01', 'deleted-exercise', position: 0, weight: 50, reps: 5);
      final log = TrainingLog(store, () {});
      expect(log.loggedDays, isEmpty);
      expect(log.loggedOrder, isEmpty);

      expect(() => log.createExercise('   ', MuscleGroup.chest, bodyweight: false), throwsArgumentError);

      final squat = log.createExercise('Squat', MuscleGroup.quads, bodyweight: false);
      final later = DateTime(2026, 11, 10);
      final earlier = DateTime(2026, 11, 5);
      log.addToDay(later, squat);
      log.updateSet(log.session(later).single.$2.single, weight: 100, reps: 5);

      // Negative weight/reps or NaN are ignored.
      log.updateSet(log.session(later).single.$2.single, weight: -10);
      log.updateSet(log.session(later).single.$2.single, reps: -3);
      expect(log.session(later).single.$2.single.weight, 100);
      expect(log.session(later).single.$2.single.reps, 5);

      // Adding on an earlier day before any prior set uses fallback or earlier weighted set, not crashing.
      final mid = DateTime(2026, 11, 7);
      log.addToDay(earlier, squat);
      log.updateSet(log.session(earlier).single.$2.single, weight: 62.25, reps: 5);
      log.addToDay(mid, squat);
      expect(log.session(mid).single.$2.single.weight, 62.25);

      // addSet into an exercise that has 0 sets on a day already containing another exercise assigns next position.
      final press = log.createExercise('Press', MuscleGroup.chest, bodyweight: false);
      log.addSet(mid, press);
      expect(log.session(mid).map((g) => g.$1.name), ['Squat', 'Press']);
    });

    testWidgets('TrainingView displays quarter-kilo microplates like 62.25 accurately', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final store = memory();
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 10));
      addTearDown(state.dispose);
      final press = state.training.createExercise('Press', MuscleGroup.chest, bodyweight: false);
      state.training.addToDay(state.today, press);
      state.training.updateSet(state.training.session(state.today).single.$2.single, weight: 62.25, reps: 5);

      await tester.pumpWidget(
        MaterialApp(
          theme: themeNamed(null),
          home: ThemeMorph(
            target: paletteNamed(null),
            child: AppScope(state: state, child: const Scaffold(body: TrainingView())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('62.25'), findsOneWidget);
    });
  });

  group('Search Unicode Safety', () {
    test('handles expanding lowercase like Turkish dotted I, surrogate pairs, and empty words', () {
      final store = memory();
      final longTail = '${'a ' * 119}\u{1F600} İstanbul trip';
      store.setJournal('2026-11-05', longTail);

      final index = SearchIndex(store);
      final hits = index.search('istanbul');
      expect(hits, hasLength(1));
      // Valid UTF-16 output without lone surrogates.
      expect(hits.single.text.runes.toList(), isNotEmpty);

      final ranges = matchRanges('Visit İstanbul today', ['istanbul', '', '   ']);
      expect(ranges, [(6, 14)]);
    });
  });
}
