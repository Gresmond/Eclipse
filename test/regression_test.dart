import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/data_folder.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/http_request.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/data/updates.dart';
import 'package:eclipse/models.dart';

class _Drive implements SyncDrive {
  final files = <String, (String, List<int>, int)>{};
  int serial = 0;
  Future<void>? waitingForList;
  @override
  Future<List<DriveFile>> list() async {
    await waitingForList;
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
}

// Widget tests install an HTTP mock globally; this test only connects to its
// own loopback server and needs the real transport.
class _LoopbackHttpOverrides extends HttpOverrides {}

List<List<Object?>> _sent(SyncEngine e) => e.changesSince(0).values.expand((v) => v).toList();

void main() {
  Store memory() {
    final store = Store.memory();
    addTearDown(store.close);
    return store;
  }

  Directory temporary() {
    final temp = Directory.systemTemp.createTempSync('eclipse-regression');
    addTearDown(() => temp.deleteSync(recursive: true));
    return temp;
  }

  test('adding a dated task schedules it immediately and preserves past-day edits', () {
    final store = memory();
    final today = DateTime(2026, 10, 25);
    final state = AppState(store, clock: () => today);
    addTearDown(state.dispose);
    state.addTodo(TodoScope.week, 'Due now', dueDate: today);
    state.addTodo(TodoScope.month, 'Due tomorrow', dueDate: DateTime(2026, 10, 26));
    state.addTodo(TodoScope.week, 'Later', dueDate: DateTime(2026, 10, 28));
    expect(state.todos[TodoScope.today]!.map((t) => t.text), contains('Due now'));
    expect(state.todos[TodoScope.tomorrow]!.map((t) => t.text), contains('Due tomorrow'));
    expect(state.todos[TodoScope.week]!.firstWhere((t) => t.text == 'Later').dueDate, DateTime(2026, 10, 28));
    final yesterday = DateTime(2026, 10, 24);
    state.addTodo(TodoScope.month, 'Past entry', day: yesterday, dueDate: DateTime(2026, 10, 30));
    expect(
      state.todosOn(TodoScope.month, yesterday).firstWhere((t) => t.text == 'Past entry').dueDate,
      DateTime(2026, 10, 30),
    );
    expect(state.todos[TodoScope.month]!.any((t) => t.text == 'Past entry'), isFalse);
  });

  test('scheduled tasks promote through Tomorrow and Today, retaining history and sync', () {
    final store = memory();
    store.addHabit(2026, 10, 'Read');
    var now = DateTime(2026, 10, 25);
    final state = AppState(store, clock: () => now);
    for (final scope in [TodoScope.week, TodoScope.month]) {
      state.addTodo(scope, scope.name);
      final task = state.todos[scope]!.single;
      state.editTodo(scope, task, 'Scheduled ${scope.name}', DateTime(2026, 10, 28));
    }
    // Due within a week, the monthly task joins the weekly one at once.
    expect(state.todos[TodoScope.month], isEmpty);
    expect(state.todos[TodoScope.week]!.map((t) => t.dueDate), [DateTime(2026, 10, 28), DateTime(2026, 10, 28)]);
    final sender = SyncEngine(store, 'a')..claimAll();
    final other = memory();
    final receiver = SyncEngine(other, 'b')..clearForJoining();
    receiver.mergeAll([(_sent(sender), 'a')]);
    expect(other.todos(TodoScope.week, '2026-10-19').map((t) => t.dueDate), [DateTime(2026, 10, 28), DateTime(2026, 10, 28)]);
    now = DateTime(2026, 10, 27);
    state.checkDate();
    expect(state.todos[TodoScope.tomorrow], hasLength(2));
    expect(state.todos[TodoScope.week], isEmpty);
    expect(state.todos[TodoScope.month], isEmpty);
    now = DateTime(2026, 10, 28);
    state.checkDate();
    expect(state.todos[TodoScope.today], hasLength(2));
    expect(state.todos[TodoScope.tomorrow], isEmpty);
    expect(state.todosOn(TodoScope.tomorrow, DateTime(2026, 10, 27)), hasLength(2));
    // A second computer closed across the deadline reconstructs the same transitions.
    final reopened = AppState(other, clock: () => DateTime(2026, 11, 2));
    expect(reopened.todos[TodoScope.today], hasLength(2));
    expect(reopened.todosOn(TodoScope.tomorrow, DateTime(2026, 10, 27)), hasLength(2));
    expect(reopened.todosOn(TodoScope.today, DateTime(2026, 10, 28)), hasLength(2));
    state.dispose();
    reopened.dispose();
  });

  test('a monthly task moves to This week 7 days before it is due, then back there after an untick', () {
    final store = memory();
    store.addHabit(2026, 10, 'Read');
    var now = DateTime(2026, 10, 20);
    final state = AppState(store, clock: () => now);
    addTearDown(state.dispose);
    state.addTodo(TodoScope.month, 'Book flights', dueDate: DateTime(2026, 11, 4));
    now = DateTime(2026, 10, 27);
    state.checkDate();
    expect(state.todos[TodoScope.month]!.single.text, 'Book flights');
    // Closed across the day it was ready, it still shows in that day's record.
    now = DateTime(2026, 10, 29);
    state.checkDate();
    expect(state.todos[TodoScope.month], isEmpty);
    expect(state.todos[TodoScope.week]!.single.text, 'Book flights');
    expect(state.todosOn(TodoScope.week, DateTime(2026, 10, 28)).single.text, 'Book flights');
    state.toggleTodo(state.todos[TodoScope.week]!.single, scope: TodoScope.week);
    state.toggleTodo(state.todos[TodoScope.today]!.single);
    expect(state.todos[TodoScope.week]!.single.done, isFalse);
    expect(state.todos[TodoScope.month], isEmpty);
  });

  test('due today or overdue moves immediately; completed tasks remain on their completion day', () {
    final store = memory();
    store.addHabit(2026, 10, 'Read');
    var now = DateTime(2026, 10, 31);
    final state = AppState(store, clock: () => now);
    state.addTodo(TodoScope.month, 'Due now');
    state.editTodo(TodoScope.month, state.todos[TodoScope.month]!.single, 'Updated', now);
    expect(state.todos[TodoScope.today]!.single.text, 'Updated');
    expect(state.todosOn(TodoScope.today, DateTime(2026, 10, 30)), isEmpty);
    state.addTodo(TodoScope.month, 'Completed');
    state.toggleTodo(state.todos[TodoScope.month]!.single);
    state.editTodo(TodoScope.today, state.todos[TodoScope.today]!.last, 'Completed', DateTime(2026, 11, 2));
    now = DateTime(2026, 11, 2);
    state.checkDate();
    expect(state.todos[TodoScope.tomorrow], isEmpty);
    expect(state.todos[TodoScope.today]!.single.text, 'Updated');
    expect(store.todos(TodoScope.today, '2026-10-31').single.done, isTrue);
    state.addTodo(TodoScope.week, 'Overdue');
    state.editTodo(TodoScope.week, state.todos[TodoScope.week]!.last, 'Overdue', DateTime(2026, 10, 29));
    expect(state.todos[TodoScope.today]!.last.text, 'Overdue');
    state.dispose();
  });

  test('early Tomorrow completion and undo survive reopen, edits, sync and rollover', () {
    final store = memory();
    store.addHabit(2026, 10, 'Read');
    var now = DateTime(2026, 10, 25);
    var state = AppState(store, clock: () => now);
    state.addTodo(TodoScope.tomorrow, 'Prepare breakfast', dueDate: DateTime(2026, 10, 26));
    final task = state.todos[TodoScope.tomorrow]!.single;
    state.toggleTodo(task, scope: TodoScope.tomorrow);
    expect(state.todos[TodoScope.tomorrow], isEmpty);
    expect(state.todos[TodoScope.today]!.single.done, isTrue);
    state.editTodo(TodoScope.today, state.todos[TodoScope.today]!.single, 'Prepare breakfast early', task.dueDate);
    state.dispose();
    state = AppState(store, clock: () => now);
    final sender = SyncEngine(store, 'a')..claimAll();
    final other = memory();
    final receiver = SyncEngine(other, 'b')..clearForJoining();
    receiver.mergeAll([(_sent(sender), 'a')]);
    final synced = AppState(other, clock: () => now);
    expect(synced.todos[TodoScope.today]!.single.done, isTrue);
    synced.toggleTodo(synced.todos[TodoScope.today]!.single);
    expect(synced.todos[TodoScope.today], isEmpty);
    expect(synced.todos[TodoScope.tomorrow]!.single.done, isFalse);
    expect(synced.todos[TodoScope.tomorrow]!.single.uid, task.uid);
    expect(synced.todos[TodoScope.tomorrow]!.single.dueDate, task.dueDate);
    synced.dispose();
    now = DateTime(2026, 10, 26);
    state.checkDate();
    expect(state.todos[TodoScope.today], isEmpty);
    final yesterday = DateTime(2026, 10, 25);
    state.toggleTodo(state.todosOn(TodoScope.today, yesterday).single, day: yesterday);
    expect(state.todosOn(TodoScope.today, yesterday), isEmpty);
    expect(state.todosOn(TodoScope.tomorrow, yesterday).single.done, isFalse);
    expect(state.todos[TodoScope.today]!.single.done, isFalse);
    state.dispose();
  });

  test('weekly and monthly completion returns to its source after reopen and sync', () {
    for (final scope in [TodoScope.week, TodoScope.month]) {
      final store = memory();
      final now = DateTime(2026, 10, 25);
      store.addHabit(2026, 10, 'Read');
      var state = AppState(store, clock: () => now);
      state.addTodo(scope, 'Plan trip', dueDate: DateTime(2026, 11, 12));
      final task = state.todos[scope]!.single;
      state.toggleTodo(task, scope: scope);
      expect(state.todos[scope], isEmpty);
      expect(state.todos[TodoScope.today]!.single.done, isTrue);
      state.dispose();
      state = AppState(store, clock: () => now);
      final sender = SyncEngine(store, 'a')..claimAll();
      final other = memory();
      final receiver = SyncEngine(other, 'b')..clearForJoining();
      receiver.mergeAll([(_sent(sender), 'a')]);
      final synced = AppState(other, clock: () => now);
      synced.toggleTodo(synced.todos[TodoScope.today]!.single);
      expect(synced.todos[TodoScope.today], isEmpty);
      expect(synced.todos[scope]!.single.done, isFalse);
      expect(synced.todos[scope]!.single.uid, task.uid);
      expect(synced.todos[scope]!.single.dueDate, task.dueDate);
      synced.dispose();
      state.dispose();
    }
  });

  test('undo restores dated plans until rollover, including after reopen and sync', () {
    for (final scope in [TodoScope.week, TodoScope.month]) {
      final store = memory();
      store.addHabit(2026, 10, 'Read');
      var now = DateTime(2026, 10, 24);
      var state = AppState(store, clock: () => now);
      state.addTodo(scope, 'Dated plan');
      state.toggleTodo(state.todos[scope]!.single, scope: scope);
      state.editTodo(TodoScope.today, state.todos[TodoScope.today]!.single, 'Dated plan', DateTime(2026, 10, 25));
      now = DateTime(2026, 10, 25);
      state.checkDate();
      final yesterday = DateTime(2026, 10, 24);
      state.toggleTodo(state.todosOn(TodoScope.today, yesterday).single, day: yesterday);
      expect(state.todos[scope]!.single.done, isFalse);
      expect(state.todos[TodoScope.today], isEmpty);
      state.dispose();
      state = AppState(store, clock: () => now);
      expect(state.todos[scope]!.single.done, isFalse);
      final sender = SyncEngine(store, 'a')..claimAll();
      final other = memory();
      SyncEngine(other, 'b').mergeAll([(_sent(sender), 'a')]);
      final synced = AppState(other, clock: () => now);
      expect(synced.todos[scope]!.single.done, isFalse);
      synced.dispose();
      now = DateTime(2026, 10, 26);
      state.checkDate();
      expect(state.todos[scope], isEmpty);
      expect(state.todos[TodoScope.today]!.single.done, isFalse);
      expect(state.todosOn(scope, yesterday).single.done, isFalse);
      expect(state.todosOn(scope, DateTime(2026, 10, 25)).single.done, isFalse);
      state.dispose();
    }
  });

  test('yesterday completion removes carryover and undo restores it across reopen and sync', () {
    for (final scope in TodoScope.values) {
      final store = memory();
      store.addHabit(2026, 10, 'Read');
      var now = DateTime(2026, 10, 24);
      var state = AppState(store, clock: () => now);
      // Planned tasks always have a day; one far off stays planned.
      final due = scope == TodoScope.week || scope == TodoScope.month ? DateTime(2026, 12, 20) : null;
      state.addTodo(scope, 'Collect prescription', dueDate: due);
      // A separate task with identical wording must not be affected.
      state.addTodo(scope, 'Collect prescription', dueDate: due);
      now = DateTime(2026, 10, 25);
      state.checkDate();
      final yesterday = DateTime(2026, 10, 24);
      final task = state.todosOn(scope, yesterday).first;
      state.toggleTodo(task, scope: scope, day: yesterday);
      const completedScope = TodoScope.today;
      expect(state.todosOn(completedScope, yesterday).first.done, isTrue);
      if (scope == TodoScope.tomorrow) {
        expect(state.todosOn(scope, yesterday).any((t) => t.uid == task.uid), isFalse);
      }
      final liveScope = scope == TodoScope.tomorrow ? TodoScope.today : scope;
      expect(state.todos[liveScope], hasLength(1));
      expect(state.todosOn(liveScope, now), hasLength(1));
      state.dispose();
      state = AppState(store, clock: () => now);
      expect(state.todos[liveScope], hasLength(1));
      final sender = SyncEngine(store, 'a')..claimAll();
      final other = memory();
      final receiver = SyncEngine(other, 'b')..clearForJoining();
      receiver.mergeAll([(_sent(sender), 'a')]);
      final synced = AppState(other, clock: () => now);
      expect(synced.todos[liveScope], hasLength(1));
      expect(synced.todosOn(completedScope, yesterday).singleWhere((t) => t.uid == task.uid).done, isTrue);
      synced.dispose();

      state.toggleTodo(state.todosOn(completedScope, yesterday).first, scope: completedScope, day: yesterday);
      expect(state.todosOn(scope, yesterday).singleWhere((t) => t.uid == task.uid).done, isFalse);
      expect(state.todos[liveScope], hasLength(2));
      expect(state.todos[liveScope]!.every((t) => !t.done), isTrue);
      expect(state.todosOn(liveScope, now), hasLength(2));
      sender.flush();
      receiver.mergeAll([(_sent(sender), 'a')]);
      final syncedUndo = AppState(other, clock: () => now);
      expect(syncedUndo.todos[liveScope], hasLength(2));
      expect(syncedUndo.todos[liveScope]!.every((t) => !t.done), isTrue);
      syncedUndo.dispose();
      state.dispose();
      final reopened = AppState(store, clock: () => now);
      expect(reopened.todos[liveScope], hasLength(2));
      reopened.dispose();
    }
  });

  test('yesterday text corrections stay isolated, completion updates live tasks, and edits lock after midnight', () {
    final store = memory();
    store.addHabit(2026, 10, 'Read');
    var now = DateTime(2026, 10, 31);
    final state = AppState(store, clock: () => now);
    state.addTodo(TodoScope.today, 'Live');
    state.addTodo(TodoScope.today, 'Deleted later');
    now = DateTime(2026, 11, 1);
    state.checkDate();
    state.removeTodo(TodoScope.today, state.todos[TodoScope.today]!.last);
    final yesterday = DateTime(2026, 10, 31);
    expect(state.canEditDay(yesterday), isTrue);
    expect(state.canEditDay(DateTime(2026, 10, 30)), isFalse);
    final task = state.todosOn(TodoScope.today, yesterday).first;
    state.editTodo(TodoScope.today, task, 'Corrected', null, day: yesterday);
    expect(state.todos[TodoScope.today]!.single.text, 'Live');
    state.toggleTodo(task, day: yesterday);
    final deleted = state.todosOn(TodoScope.today, yesterday).last;
    state.editTodo(TodoScope.today, deleted, 'Recovered record', null, day: yesterday);
    state.toggleTodo(deleted, day: yesterday);
    state.toggleTodo(deleted, day: yesterday);
    expect(state.todos[TodoScope.today], isEmpty);
    state.addTodo(TodoScope.today, 'Forgot to record', day: yesterday);
    expect(state.todosOn(TodoScope.today, yesterday).map((t) => t.text), [
      'Corrected',
      'Recovered record',
      'Forgot to record',
    ]);
    expect(state.todosOn(TodoScope.today, yesterday).first.done, isTrue);
    expect(state.todos[TodoScope.today], isEmpty);
    final sender = SyncEngine(store, 'a')..claimAll();
    final other = memory();
    final receiver = SyncEngine(other, 'b')..clearForJoining();
    receiver.mergeAll([(_sent(sender), 'a')]);
    expect(other.todoListsOn(yesterday)[TodoScope.today]!, hasLength(3));
    expect(other.todoListsOn(now)[TodoScope.today]!, isEmpty);
    state.removeTodo(TodoScope.today, task, day: yesterday);
    expect(state.todosOn(TodoScope.today, yesterday), hasLength(2));
    now = DateTime(2026, 11, 2);
    state.checkDate();
    state.addTodo(TodoScope.today, 'Too late', day: yesterday);
    state.editTodo(TodoScope.today, deleted, 'Too late', null, day: yesterday);
    expect(state.canEditDay(yesterday), isFalse);
    expect(state.todosOn(TodoScope.today, yesterday), hasLength(2));
    expect(state.todosOn(TodoScope.today, yesterday).first.text, 'Recovered record');
    state.dispose();
  });

  test('empty monthly lists survive reopening, copying, and sync', () {
    final store = memory();
    store.addHabit(2026, 9, 'Read');
    var state = AppState(store, clock: () => DateTime(2026, 10, 25));
    state.removeHabit(2026, 10, state.habits.single);
    state = AppState(store, clock: () => DateTime(2026, 10, 25));
    expect(state.habits, isEmpty);
    expect(state.habitsFor(2026, 11), isEmpty, reason: 'empty lists are inherited too');
    final sender = SyncEngine(store, 'a')..claimAll();
    final other = memory();
    final receiver = SyncEngine(other, 'b')..clearForJoining();
    receiver.mergeAll([(_sent(sender), 'a')]);
    expect(other.hasMonth(2026, 10), isTrue);
    expect(other.monthHabits(2026, 10), isEmpty);
    expect(AppState(other, clock: () => DateTime(2026, 10, 25)).habits, isEmpty);
  });

  test('empty-month tombstones from older sync also initialize the month', () {
    final store = memory();
    final engine = SyncEngine(store, 'b');
    engine.mergeAll([
      (
        [
          [
            'month_habit',
            '2026-10/old-id',
            '_',
            'false',
            1,
            'a',
            {'a': 1},
          ],
        ],
        'a',
      ),
    ]);
    expect(store.hasMonth(2026, 10), isTrue);
    expect(store.monthHabits(2026, 10), isEmpty);
  });

  test('an empty initialized month does not seed onboarding rituals on restart', () {
    final store = memory();
    store.initializeMonth(2026, 10);
    final state = AppState(store, clock: () => DateTime(2026, 10, 25));
    expect(state.firstRun, isFalse);
    expect(state.habits, isEmpty);
  });

  testWidgets('ritual typing is debounced and navigation flushes pending edits', (tester) async {
    final store = memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 25));
    final habit = state.habits.first;
    final original = habit.name;
    state.draftHabitName(2026, 10, habit, 'Read');
    state.draftHabitName(2026, 10, habit, 'Read daily');
    state.draftHabitNote(2026, 10, habit, 'Before breakfast');
    expect(store.monthHabits(2026, 10).first.name, original);
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.monthHabits(2026, 10).first.name, 'Read daily');
    expect(store.monthHabits(2026, 10).first.description, 'Before breakfast');
    state.draftHabitName(2026, 10, habit, 'Read two pages');
    state.showMonth(10);
    expect(store.monthHabits(2026, 10).first.name, 'Read two pages');
    state.dispose();
  });

  test('data-folder changes save the current draft before copying', () async {
    final temp = temporary();
    final home = Directory('${temp.path}/home')..createSync();
    final data = DataFolder.load(home, temp);
    final store = Store.open(data.database);
    addTearDown(store.close);
    final state = AppState(store, dataFolder: data, clock: () => DateTime(2026, 10, 25));
    state.draftJournal(state.today, 'Last words');
    final target = Directory('${temp.path}/target');
    await state.useDataFolder(target);
    final copy = Store.open('${target.path}/productivity.db');
    expect(copy.journal('2026-10-25'), 'Last words');
    expect(state.hasJournalDraft(state.today), isFalse);
    copy.close();
  });

  test('shutdown flushes pending typing and closes only once', () async {
    final temp = temporary();
    final path = '${temp.path}/app.db';
    final state = AppState(Store.open(path), clock: () => DateTime(2026, 10, 25));
    state.draftJournal(state.today, 'Before quitting');
    await Future.wait([state.shutdown(), state.shutdown()]);
    final reopened = Store.open(path);
    expect(reopened.journal('2026-10-25'), 'Before quitting');
    reopened.close();
  });

  test('long current streaks and all-time bests keep their full history', () {
    final store = memory();
    final habit = store.addHabit(2025, 1, 'Read');
    final today = DateTime(2026, 10, 25);
    for (var i = 0; i < 400; i++) {
      store.setEntry(dateKey(DateTime(today.year, today.month, today.day - i)), habit.id, HabitStatus.done);
    }
    final state = AppState(store, clock: () => today);
    expect(state.currentStreak(habit), 400);
    expect(state.bestStreak(habit), 400);
    final later = AppState(store, clock: () => DateTime(2028, 1, 1));
    expect(later.bestStreak(habit), 400);
    expect(later.currentStreak(habit), 0);
  });

  test('today can remain open, but an explicit miss breaks the streak', () {
    final store = memory();
    final habit = store.addHabit(2026, 10, 'Read');
    store.setEntry('2026-10-24', habit.id, HabitStatus.done);
    final state = AppState(store, clock: () => DateTime(2026, 10, 25));
    expect(state.currentStreak(habit), 1);
    state.selectStatus(state.today, habit, HabitStatus.done);
    state.selectStatus(state.today, habit, HabitStatus.missed);
    expect(state.currentStreak(habit), 0);
    expect(state.bestStreak(habit), 1);
  });

  test('Tomorrow history and original creation dates survive rollover', () {
    final store = memory();
    final day = DateTime(2026, 10, 24);
    store.addTodo(TodoScope.tomorrow, day, 'Call');
    store.rollTomorrowToToday('2026-10-25');
    expect(store.todoListsOn(day)[TodoScope.tomorrow]!.single.text, 'Call');
    expect(store.todoListsOn(day)[TodoScope.today]!, isEmpty);
    expect(store.todos(TodoScope.today, '2026-10-25').single.since, day);
    expect(store.todoListsOn(DateTime(2026, 10, 25))[TodoScope.today]!.single.text, 'Call');
  });

  test('weekly history preserves completion, reopening, and deletion days', () {
    final store = memory();
    final monday = DateTime(2026, 10, 19);
    final item = store.addTodo(TodoScope.week, monday, 'Call');
    store.setTodoDone(item.id, true, day: DateTime(2026, 10, 20));
    store.setTodoDone(item.id, false, day: DateTime(2026, 10, 21));
    store.deleteTodo(item.id, day: DateTime(2026, 10, 22));
    expect(store.todoListsOn(monday)[TodoScope.week]!.single.done, isFalse);
    expect(store.todoListsOn(DateTime(2026, 10, 20))[TodoScope.today]!.single.done, isTrue);
    expect(store.todoListsOn(DateTime(2026, 10, 21))[TodoScope.week]!.single.done, isFalse);
    expect(store.todoListsOn(DateTime(2026, 10, 22))[TodoScope.week]!, isEmpty);
    final engine = SyncEngine(store, 'a')..claimAll();
    final other = memory();
    SyncEngine(other, 'b').mergeAll([(_sent(engine), 'a')]);
    expect(other.todoListsOn(monday)[TodoScope.week]!.single.text, 'Call');
    expect(other.todoListsOn(DateTime(2026, 10, 20))[TodoScope.today]!.single.done, isTrue);
    expect(other.todoListsOn(DateTime(2026, 10, 22))[TodoScope.week]!, isEmpty);
  });

  test('three overlapping journal merges converge without duplicated revisions', () {
    final stores = [memory(), memory(), memory()];
    final engines = [for (var i = 0; i < 3; i++) SyncEngine(stores[i], 'machine$i')];
    for (var i = 0; i < 3; i++) {
      stores[i].setJournal('2026-10-25', ['AAA', 'BBB', 'CCC'][i]);
      stores[i].raw.execute('UPDATE sync_dirty SET at = ?', [1000 + 1000 * i]);
      engines[i].flush();
    }
    final originals = engines.map(_sent).toList();
    engines[0].mergeAll([(originals[1], 'B')]);
    engines[1].mergeAll([(originals[2], 'C')]);
    engines[0].mergeAll([(_sent(engines[1]), 'B')]);
    engines[2].mergeAll([(originals[0], 'A')]);
    engines[2].mergeAll([(originals[1], 'B')]);
    for (var round = 0; round < 3; round++) {
      for (final a in engines) {
        for (final b in engines) {
          if (a != b) a.mergeAll([(_sent(b), b.me)]);
        }
      }
    }
    for (final store in stores) {
      expect(store.journal('2026-10-25'), 'AAA\n\n---\n\nBBB\n\n---\n\nCCC');
    }
    stores[0].setJournal('2026-10-25', 'Reviewed all three');
    engines[0].flush();
    engines[1].mergeAll([(_sent(engines[0]), 'A')]);
    expect(stores[1].journal('2026-10-25'), 'Reviewed all three');
  });

  test('journal revisions survive database reopen and old seven-field input', () {
    final temp = temporary();
    final path = '${temp.path}/app.db';
    var store = Store.open(path);
    var engine = SyncEngine(store, 'b');
    engine.mergeAll([
      (
        [
          [
            'journal',
            '2026-10-25',
            'text',
            jsonEncode('Old client'),
            1000,
            'a',
            {'a': 1000},
          ],
        ],
        'a',
      ),
    ]);
    store.setJournal('2026-10-25', 'New client');
    engine.flush();
    store.close();
    store = Store.open(path);
    addTearDown(store.close);
    engine = SyncEngine(store, 'b');
    final other = memory();
    SyncEngine(other, 'c').mergeAll([(_sent(engine), 'b')]);
    expect(other.journal('2026-10-25'), 'New client');
  });

  test('account switching is blocked until an explicit transfer, including after restart', () async {
    final temp = temporary();
    final store = memory();
    final a = _Drive(), b = _Drive();
    SyncService load() => SyncService.load(temp, store, connect: (token) => token == 'A' ? a : b);
    var service = load();
    const accountA = GoogleAccount(email: 'a@example.com', id: 'google-a', refreshToken: 'A');
    const accountB = GoogleAccount(email: 'b@example.com', id: 'google-b', refreshToken: 'B');
    store.setJournal('2026-10-25', 'Private to account A');
    await service.look(accountA);
    await service.turnOn(accountA, join: false);
    await service.turnOff();
    service.dispose();
    service = load();
    addTearDown(service.dispose);
    expect(service.isReturning(accountA), isTrue);
    expect(service.needsAccountChoice(accountB), isTrue);
    await service.look(accountB);
    await expectLater(service.turnOn(accountB, join: false), throwsA(isA<DriveError>()));
    expect(b.files, isEmpty);
    await service.turnOn(accountB, join: false, transfer: true);
    expect(b.files.values.any((f) => utf8.decode(f.$2).contains('Private to account A')), isTrue);
  });

  test('joining a different account replaces local history after the backup callback', () async {
    final temp = temporary();
    final store = memory();
    final a = _Drive(), b = _Drive();
    final remote = memory();
    remote.setJournal('2026-10-25', 'B history');
    final engine = SyncEngine(remote, 'remote')..claimAll();
    await b.upload('remote_2026-10-25.json', utf8.encode(jsonEncode({'name': 'remote', 'registers': _sent(engine)})));
    final service = SyncService.load(temp, store, connect: (token) => token == 'A' ? a : b);
    addTearDown(service.dispose);
    const accountA = GoogleAccount(email: 'a@example.com', refreshToken: 'A');
    const accountB = GoogleAccount(email: 'b@example.com', refreshToken: 'B');
    store.setJournal('2026-10-24', 'A history');
    await service.look(accountA);
    await service.turnOn(accountA, join: false);
    await service.turnOff();
    service.beforeJoin = () => expect(store.journal('2026-10-24'), 'A history');
    expect(await service.look(accountB), isTrue);
    await service.turnOn(accountB, join: true);
    expect(store.journal('2026-10-24'), '');
    expect(store.journal('2026-10-25'), 'B history');
    expect(b.files.values.any((f) => utf8.decode(f.$2).contains('A history')), isFalse);
  });

  test('an invalid schema backup is rejected without replacing live data', () async {
    final temp = temporary();
    final store = memory();
    store.setJournal('2026-10-25', 'Current journal');
    final source = Store.open('${temp.path}/bad.db');
    source.raw.execute('DROP TABLE todos');
    source.close();
    await expectLater(store.restoreFrom('${temp.path}/bad.db'), throwsA(anything));
    expect(store.journal('2026-10-25'), 'Current journal');
    expect(store.raw.select("SELECT name FROM sqlite_master WHERE name = 'todos'"), hasLength(1));
  });

  test('future-schema backups are rejected before touching the database', () async {
    final temp = temporary();
    final store = memory();
    store.setJournal('2026-10-25', 'Current journal');
    final source = Store.open('${temp.path}/future.db');
    source.raw.execute('PRAGMA user_version = 100');
    source.close();
    await expectLater(store.restoreFrom('${temp.path}/future.db'), throwsStateError);
    expect(store.journal('2026-10-25'), 'Current journal');
  });

  test('version-eight databases migrate and restore without losing data', () async {
    final temp = temporary();
    final path = '${temp.path}/old.db';
    final old = Store.open(path);
    final habit = old.addHabit(2026, 10, 'Read');
    old.setEntry('2026-10-24', habit.id, HabitStatus.done);
    old.setJournal('2026-10-24', 'Older journal');
    SyncEngine(old, 'old').claimAll();
    old.raw.execute('''
      DROP TABLE habit_months; DROP TABLE todo_history;
      DROP INDEX entries_habit_day; DROP INDEX sleep_notes_item_month;
      ALTER TABLE sync_reg DROP COLUMN journal_versions;
      PRAGMA user_version = 8;
    ''');
    old.close();
    final current = memory();
    await current.restoreFrom(path);
    expect(current.raw.select('PRAGMA user_version').first.columnAt(0), Store.schemaVersion);
    expect(current.monthHabits(2026, 10).single.name, 'Read');
    expect(current.journal('2026-10-24'), 'Older journal');
    expect(current.entriesInMonth(2026, 10).single.status, HabitStatus.done);
    expect(current.hasMonth(2026, 10), isTrue);
    final upgraded = Store.open(path);
    expect(upgraded.journal('2026-10-24'), 'Older journal');
    expect(upgraded.hasMonth(2026, 10), isTrue);
    upgraded.close();
  });

  test('legacy tasks get a baseline before later completion changes history', () {
    final store = memory();
    store.addHabit(2026, 10, 'Read');
    final item = store.addTodo(TodoScope.week, DateTime(2026, 10, 19), 'Call');
    store.raw.execute("UPDATE todos SET due_date = '2026-12-20'");
    store.raw.execute('DELETE FROM todo_history'); // a task from a pre-history version
    var now = DateTime(2026, 10, 20);
    final state = AppState(store, clock: () => now);
    now = DateTime(2026, 10, 22);
    state.checkDate();
    state.toggleTodo(state.todos[TodoScope.week]!.single);
    expect(state.todosOn(TodoScope.week, DateTime(2026, 10, 20)).single.done, isFalse);
    expect(state.todosOn(TodoScope.week, now), isEmpty);
    expect(state.todosOn(TodoScope.today, now).single.done, isTrue);
    expect(store.todos(TodoScope.today, dateKey(now)).single.id, item.id);
  });

  test('journal-only sync preserves unrelated caches and entry sync refreshes marks', () {
    final store = memory();
    final service = SyncService.load(temporary(), store);
    addTearDown(service.dispose);
    final state = AppState(store, sync: service, clock: () => DateTime(2026, 10, 25));
    final habits = state.habits;
    final todos = state.todos[TodoScope.today];
    store.setJournal('2026-10-25', 'Incoming');
    service.onIncoming!(Incoming({('journal', '2026-10-25')}, {'other'}));
    expect(identical(state.habits, habits), isTrue);
    expect(identical(state.todos[TodoScope.today], todos), isTrue);
    final uid = store.raw.select('SELECT uid FROM habits WHERE id = ?', [habits.first.id]).first['uid'];
    store.setEntry('2026-10-25', habits.first.id, HabitStatus.done);
    service.onIncoming!(Incoming({('entry', '2026-10-25/$uid')}, {'other'}));
    expect(state.statusOf(state.today, habits.first), HabitStatus.done);
    expect(identical(state.habits, habits), isTrue);
  });

  test('exclusive data changes wait for an in-flight sync round', () async {
    final store = memory();
    final drive = _Drive();
    final service = SyncService.load(temporary(), store, connect: (_) => drive);
    addTearDown(service.dispose);
    const account = GoogleAccount(email: 'a@example.com', refreshToken: 'A');
    await service.look(account);
    await service.turnOn(account, join: false);
    final gate = Completer<void>();
    drive.waitingForList = gate.future;
    final running = service.run();
    var ran = false;
    final change = service.exclusive(() async {
      ran = true;
      expect(service.busy, isFalse);
    });
    await Future<void>.delayed(Duration.zero);
    expect(ran, isFalse);
    gate.complete();
    await running;
    await change;
    expect(ran, isTrue);
  });

  test('a stopped sync ignores late network failures and retains its sign-in', () async {
    final drive = _Drive();
    final service = SyncService.load(temporary(), memory(), connect: (_) => drive);
    addTearDown(service.dispose);
    const account = GoogleAccount(email: 'a@example.com', refreshToken: 'A');
    await service.look(account);
    await service.turnOn(account, join: false);
    final gate = Completer<void>();
    drive.waitingForList = gate.future;
    final running = service.run();
    service.stop();
    gate.completeError(const DriveError('Late sign-out', signedOut: true));
    await running;
    expect(service.isOn, isTrue);
    expect(service.error, isNull);
  });

  test('release assets select the correct platform and Linux requires installation metadata', () {
    final dir = temporary();
    final executable = '${dir.path}/eclipse';
    expect(LinuxUpdater.forExecutable(executable), isNull);
    final metadata = File('${dir.path}/version')..writeAsStringSync('26.10.1\n');
    final updater = LinuxUpdater('26.10.1', installRoot: dir.path);
    expect(updater.installedVersion, '26.10.1');
    expect(updater.actionLabel, 'Update');
    final release = <String, dynamic>{
      'tag_name': 'v26.10.2',
      'html_url': 'https://example.com/release',
      'assets': [
        {'name': 'Eclipse.dmg', 'browser_download_url': 'https://example.com/mac'},
        {'name': 'Eclipse-26.10.2-windows-x64-setup.exe', 'browser_download_url': 'https://example.com/windows'},
        {'name': 'Eclipse.tar.zst', 'browser_download_url': 'https://example.com/linux'},
      ],
    };
    expect(updater.downloadForRelease(release), 'https://example.com/linux');
    expect(ReleaseUpdater('26.10.1').downloadForRelease(release), 'https://example.com/mac');
    expect(ReleaseUpdater.forWindows(executable)!.downloadForRelease(release), 'https://example.com/windows');
    release['assets'] = <Map<String, dynamic>>[];
    expect(updater.downloadForRelease(release), isNull);
    expect(updater.newerRelease('26.10.2', null), isFalse);
    expect(isNewer('26.10.1', '1.10.31'), isTrue);
    metadata.writeAsStringSync('invalid');
    expect(LinuxUpdater.forExecutable(executable), isNull);
  });

  test('binary or unreadable bundle metadata never prevents startup', () {
    final temp = temporary();
    final contents = Directory('${temp.path}/Eclipse.app/Contents')..createSync(recursive: true);
    File('${contents.path}/Info.plist').writeAsBytesSync(
      base64Decode(
        'YnBsaXN0MDDRAQJfEBpDRkJ1bmRsZVNob3J0VmVyc2lvblN0cmluZ1cxLjEwLjE2CAsoAAAAAAAAAQEAAAAAAAAAAwAAAAAAAAAAAAAAAAAAADA=',
      ),
    );
    final updater = ReleaseUpdater.forBundle('${contents.path}/MacOS/Eclipse');
    if (Platform.isMacOS) {
      expect(updater?.installedVersion, '1.10.16');
    } else {
      expect(updater, isNull);
    }
    File('${contents.path}/Info.plist').writeAsStringSync('invalid plist');
    expect(ReleaseUpdater.forBundle('${contents.path}/MacOS/Eclipse'), isNull);
  });

  test(
    'HTTP deadline includes a response body that stalls after headers',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final gotHeaders = Completer<void>();
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.contentLength = 100;
        request.response.write('partial');
        await request.response.flush();
        gotHeaders.complete();
        // Deliberately leave the body open.
      });
      try {
        final request = sendHttpRequest(
          'GET',
          Uri.parse('http://127.0.0.1:${server.port}'),
          timeout: const Duration(milliseconds: 300),
        );
        final expectation = expectLater(request, throwsA(isA<TimeoutException>()));
        await gotHeaders.future.timeout(const Duration(seconds: 3));
        await expectation;
      } finally {
        await server.close(force: true);
      }
    }, _LoopbackHttpOverrides()),
  );
}
