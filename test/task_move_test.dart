import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';

void main() {
  late Store store;
  late AppState state;
  final today = DateTime(2026, 10, 25);

  setUp(() {
    store = Store.memory();
    state = AppState(store, clock: () => today);
    for (final scope in TodoScope.values) {
      for (final item in state.todos[scope]!.toList()) {
        state.removeTodo(scope, item);
      }
    }
  });
  tearDown(() {
    state.dispose();
    store.close();
  });

  test('manual moves retain identity and history, clear dates and reset completion routing', () {
    state.addTodo(TodoScope.week, 'Move this', dueDate: DateTime(2026, 10, 29));
    var scope = TodoScope.week;
    final id = state.todos[scope]!.single.id;
    for (final destination in [TodoScope.month, TodoScope.tomorrow, TodoScope.today, TodoScope.week]) {
      state.moveTodo(scope, state.todos[scope]!.single, destination);
      expect(state.todos[scope], isEmpty);
      final moved = state.todos[destination]!.single;
      expect(moved.id, id);
      expect(moved.since, today);
      expect(moved.dueDate, isNull);
      expect(state.todosOn(destination, today).single.id, id);
      scope = destination;
    }
    state.toggleTodo(state.todos[scope]!.single, scope: scope);
    final completed = state.todos[TodoScope.today]!.single;
    state.moveTodo(TodoScope.today, completed, TodoScope.tomorrow);
    expect(state.todos[TodoScope.tomorrow], isEmpty);
    state.toggleTodo(completed);
    expect(state.todos[TodoScope.week]!.single.id, id);
    state.moveTodo(TodoScope.week, state.todos[TodoScope.week]!.single, TodoScope.month);
    state.toggleTodo(state.todos[TodoScope.month]!.single, scope: TodoScope.month);
    state.toggleTodo(state.todos[TodoScope.today]!.single);
    expect(state.todos[TodoScope.month]!.single.id, id);
  });

  Future<void> showApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  /// Tomorrow's heading in the week card, shown with nothing due while
  /// empty days show.
  Finder tomorrow() => find.textContaining('Tomorrow', findRichText: true).first;

  testWidgets('drag moves an unfinished task into an empty section', (tester) async {
    state.toggleWeekEmptyDays();
    state.addTodo(TodoScope.today, 'Drag me');
    await showApp(tester);
    await tester.dragFrom(
      tester.getCenter(find.text('Drag me')),
      tester.getCenter(tomorrow()) - tester.getCenter(find.text('Drag me')),
    );
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today], isEmpty);
    expect(state.todos[TodoScope.tomorrow]!.single.text, 'Drag me');
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed tasks cannot drag; open ones can', (tester) async {
    state.addTodo(TodoScope.today, 'Finished');
    state.toggleTodo(state.todos[TodoScope.today]!.single);
    state.addTodo(TodoScope.today, 'Still open');
    state.toggleWeekEmptyDays();
    await showApp(tester);
    final destination = tester.getCenter(tomorrow());
    final finished = tester.getCenter(find.text('Finished'));
    await tester.dragFrom(finished, destination - finished);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.tomorrow], isEmpty);
    final open = tester.getCenter(find.text('Still open'));
    await tester.dragFrom(open, destination - open);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.tomorrow]!.single.text, 'Still open');
  });

  group('promotion and rollover history', () {
    Store memory() {
      final s = Store.memory();
      addTearDown(s.close);
      return s;
    }

    List<List<Object?>> sent(SyncEngine e) => e.changesSince(0).values.expand((v) => v).toList();

    test('adding a dated task schedules it immediately and preserves past-day edits', () {
      final s = memory();
      final day = DateTime(2026, 10, 25);
      final st = AppState(s, clock: () => day);
      addTearDown(st.dispose);
      st.addTodo(TodoScope.week, 'Due now', dueDate: day);
      st.addTodo(TodoScope.month, 'Due tomorrow', dueDate: DateTime(2026, 10, 26));
      st.addTodo(TodoScope.week, 'Later', dueDate: DateTime(2026, 10, 28));
      expect(st.todos[TodoScope.today]!.map((t) => t.text), contains('Due now'));
      expect(st.todos[TodoScope.tomorrow]!.map((t) => t.text), contains('Due tomorrow'));
      expect(st.todos[TodoScope.week]!.firstWhere((t) => t.text == 'Later').dueDate, DateTime(2026, 10, 28));
      final yesterday = DateTime(2026, 10, 24);
      st.addTodo(TodoScope.month, 'Past entry', day: yesterday, dueDate: DateTime(2026, 10, 30));
      expect(
        st.todosOn(TodoScope.month, yesterday).firstWhere((t) => t.text == 'Past entry').dueDate,
        DateTime(2026, 10, 30),
      );
      expect(st.todos[TodoScope.month]!.any((t) => t.text == 'Past entry'), isFalse);
    });

    test('scheduled tasks promote through Tomorrow and Today, retaining history and sync', () {
      final s = memory();
      s.addHabit(2026, 10, 'Read');
      var now = DateTime(2026, 10, 25);
      final st = AppState(s, clock: () => now);
      for (final scope in [TodoScope.week, TodoScope.month]) {
        st.addTodo(scope, scope.name);
        final task = st.todos[scope]!.single;
        st.editTodo(scope, task, 'Scheduled ${scope.name}', DateTime(2026, 10, 28));
      }
      expect(st.todos[TodoScope.month], isEmpty);
      expect(st.todos[TodoScope.week]!.map((t) => t.dueDate), [DateTime(2026, 10, 28), DateTime(2026, 10, 28)]);
      final sender = SyncEngine(s, 'a')..claimAll();
      final other = memory();
      final receiver = SyncEngine(other, 'b')..clearForJoining();
      receiver.mergeAll([(sent(sender), 'a')]);
      expect(other.todos(TodoScope.week, '2026-10-19').map((t) => t.dueDate), [
        DateTime(2026, 10, 28),
        DateTime(2026, 10, 28),
      ]);
      now = DateTime(2026, 10, 27);
      st.checkDate();
      expect(st.todos[TodoScope.tomorrow], hasLength(2));
      expect(st.todos[TodoScope.week], isEmpty);
      expect(st.todos[TodoScope.month], isEmpty);
      now = DateTime(2026, 10, 28);
      st.checkDate();
      expect(st.todos[TodoScope.today], hasLength(2));
      expect(st.todos[TodoScope.tomorrow], isEmpty);
      expect(st.todosOn(TodoScope.tomorrow, DateTime(2026, 10, 27)), hasLength(2));
      final reopened = AppState(other, clock: () => DateTime(2026, 11, 2));
      expect(reopened.todos[TodoScope.today], hasLength(2));
      expect(reopened.todosOn(TodoScope.tomorrow, DateTime(2026, 10, 27)), hasLength(2));
      expect(reopened.todosOn(TodoScope.today, DateTime(2026, 10, 28)), hasLength(2));
      st.dispose();
      reopened.dispose();
    });

    test('a monthly task moves to This week 7 days before it is due, then back there after an untick', () {
      final s = memory();
      s.addHabit(2026, 10, 'Read');
      var now = DateTime(2026, 10, 20);
      final st = AppState(s, clock: () => now);
      addTearDown(st.dispose);
      st.addTodo(TodoScope.month, 'Book flights', dueDate: DateTime(2026, 11, 4));
      now = DateTime(2026, 10, 27);
      st.checkDate();
      expect(st.todos[TodoScope.month]!.single.text, 'Book flights');
      now = DateTime(2026, 10, 29);
      st.checkDate();
      expect(st.todos[TodoScope.month], isEmpty);
      expect(st.todos[TodoScope.week]!.single.text, 'Book flights');
      expect(st.todosOn(TodoScope.week, DateTime(2026, 10, 28)).single.text, 'Book flights');
      st.toggleTodo(st.todos[TodoScope.week]!.single, scope: TodoScope.week);
      st.toggleTodo(st.todos[TodoScope.today]!.single);
      expect(st.todos[TodoScope.week]!.single.done, isFalse);
      expect(st.todos[TodoScope.month], isEmpty);
    });

    test('due today or overdue moves immediately; completed tasks remain on their completion day', () {
      final s = memory();
      s.addHabit(2026, 10, 'Read');
      var now = DateTime(2026, 10, 31);
      final st = AppState(s, clock: () => now);
      st.addTodo(TodoScope.month, 'Due now');
      st.editTodo(TodoScope.month, st.todos[TodoScope.month]!.single, 'Updated', now);
      expect(st.todos[TodoScope.today]!.single.text, 'Updated');
      expect(st.todosOn(TodoScope.today, DateTime(2026, 10, 30)), isEmpty);
      st.addTodo(TodoScope.month, 'Completed');
      st.toggleTodo(st.todos[TodoScope.month]!.single);
      st.editTodo(TodoScope.today, st.todos[TodoScope.today]!.last, 'Completed', DateTime(2026, 11, 2));
      now = DateTime(2026, 11, 2);
      st.checkDate();
      expect(st.todos[TodoScope.tomorrow], isEmpty);
      expect(st.todos[TodoScope.today]!.single.text, 'Updated');
      expect(s.todos(TodoScope.today, '2026-10-31').single.done, isTrue);
      st.addTodo(TodoScope.week, 'Overdue');
      st.editTodo(TodoScope.week, st.todos[TodoScope.week]!.last, 'Overdue', DateTime(2026, 10, 29));
      expect(st.todos[TodoScope.today]!.last.text, 'Overdue');
      st.dispose();
    });

    test('early Tomorrow completion and undo survive reopen, edits, sync and rollover', () {
      final s = memory();
      s.addHabit(2026, 10, 'Read');
      var now = DateTime(2026, 10, 25);
      var st = AppState(s, clock: () => now);
      st.addTodo(TodoScope.tomorrow, 'Prepare breakfast', dueDate: DateTime(2026, 10, 26));
      final task = st.todos[TodoScope.tomorrow]!.single;
      st.toggleTodo(task, scope: TodoScope.tomorrow);
      expect(st.todos[TodoScope.tomorrow], isEmpty);
      expect(st.todos[TodoScope.today]!.single.done, isTrue);
      st.editTodo(TodoScope.today, st.todos[TodoScope.today]!.single, 'Prepare breakfast early', task.dueDate);
      st.dispose();
      st = AppState(s, clock: () => now);
      final sender = SyncEngine(s, 'a')..claimAll();
      final other = memory();
      final receiver = SyncEngine(other, 'b')..clearForJoining();
      receiver.mergeAll([(sent(sender), 'a')]);
      final synced = AppState(other, clock: () => now);
      expect(synced.todos[TodoScope.today]!.single.done, isTrue);
      synced.toggleTodo(synced.todos[TodoScope.today]!.single);
      expect(synced.todos[TodoScope.today], isEmpty);
      expect(synced.todos[TodoScope.tomorrow]!.single.done, isFalse);
      expect(synced.todos[TodoScope.tomorrow]!.single.uid, task.uid);
      expect(synced.todos[TodoScope.tomorrow]!.single.dueDate, task.dueDate);
      synced.dispose();
      now = DateTime(2026, 10, 26);
      st.checkDate();
      expect(st.todos[TodoScope.today], isEmpty);
      final yesterday = DateTime(2026, 10, 25);
      st.toggleTodo(st.todosOn(TodoScope.today, yesterday).single, day: yesterday);
      expect(st.todosOn(TodoScope.today, yesterday), isEmpty);
      expect(st.todosOn(TodoScope.tomorrow, yesterday).single.done, isFalse);
      expect(st.todos[TodoScope.today]!.single.done, isFalse);
      st.dispose();
    });

    test('weekly and monthly completion returns to its source after reopen and sync', () {
      for (final scope in [TodoScope.week, TodoScope.month]) {
        final s = memory();
        final now = DateTime(2026, 10, 25);
        s.addHabit(2026, 10, 'Read');
        var st = AppState(s, clock: () => now);
        st.addTodo(scope, 'Plan trip', dueDate: DateTime(2026, 11, 12));
        final task = st.todos[scope]!.single;
        st.toggleTodo(task, scope: scope);
        expect(st.todos[scope], isEmpty);
        expect(st.todos[TodoScope.today]!.single.done, isTrue);
        st.dispose();
        st = AppState(s, clock: () => now);
        final sender = SyncEngine(s, 'a')..claimAll();
        final other = memory();
        final receiver = SyncEngine(other, 'b')..clearForJoining();
        receiver.mergeAll([(sent(sender), 'a')]);
        final synced = AppState(other, clock: () => now);
        synced.toggleTodo(synced.todos[TodoScope.today]!.single);
        expect(synced.todos[TodoScope.today], isEmpty);
        expect(synced.todos[scope]!.single.done, isFalse);
        expect(synced.todos[scope]!.single.uid, task.uid);
        expect(synced.todos[scope]!.single.dueDate, task.dueDate);
        synced.dispose();
        st.dispose();
      }
    });

    test('undo restores dated plans until rollover, including after reopen and sync', () {
      for (final scope in [TodoScope.week, TodoScope.month]) {
        final s = memory();
        s.addHabit(2026, 10, 'Read');
        var now = DateTime(2026, 10, 24);
        var st = AppState(s, clock: () => now);
        st.addTodo(scope, 'Dated plan');
        st.toggleTodo(st.todos[scope]!.single, scope: scope);
        st.editTodo(TodoScope.today, st.todos[TodoScope.today]!.single, 'Dated plan', DateTime(2026, 10, 25));
        now = DateTime(2026, 10, 25);
        st.checkDate();
        final yesterday = DateTime(2026, 10, 24);
        st.toggleTodo(st.todosOn(TodoScope.today, yesterday).single, day: yesterday);
        expect(st.todos[scope]!.single.done, isFalse);
        expect(st.todos[TodoScope.today], isEmpty);
        st.dispose();
        st = AppState(s, clock: () => now);
        expect(st.todos[scope]!.single.done, isFalse);
        final sender = SyncEngine(s, 'a')..claimAll();
        final other = memory();
        SyncEngine(other, 'b').mergeAll([(sent(sender), 'a')]);
        final synced = AppState(other, clock: () => now);
        expect(synced.todos[scope]!.single.done, isFalse);
        synced.dispose();
        now = DateTime(2026, 10, 26);
        st.checkDate();
        expect(st.todos[scope], isEmpty);
        expect(st.todos[TodoScope.today]!.single.done, isFalse);
        expect(st.todosOn(scope, yesterday).single.done, isFalse);
        expect(st.todosOn(scope, DateTime(2026, 10, 25)).single.done, isFalse);
        st.dispose();
      }
    });

    test('yesterday completion removes carryover and undo restores it across reopen and sync', () {
      for (final scope in TodoScope.values) {
        final s = memory();
        s.addHabit(2026, 10, 'Read');
        var now = DateTime(2026, 10, 24);
        var st = AppState(s, clock: () => now);
        final due = scope == TodoScope.week || scope == TodoScope.month ? DateTime(2026, 12, 20) : null;
        st.addTodo(scope, 'Collect prescription', dueDate: due);
        st.addTodo(scope, 'Collect prescription', dueDate: due);
        now = DateTime(2026, 10, 25);
        st.checkDate();
        final yesterday = DateTime(2026, 10, 24);
        final task = st.todosOn(scope, yesterday).first;
        st.toggleTodo(task, scope: scope, day: yesterday);
        const completedScope = TodoScope.today;
        expect(st.todosOn(completedScope, yesterday).first.done, isTrue);
        if (scope == TodoScope.tomorrow) {
          expect(st.todosOn(scope, yesterday).any((t) => t.uid == task.uid), isFalse);
        }
        final liveScope = scope == TodoScope.tomorrow ? TodoScope.today : scope;
        expect(st.todos[liveScope], hasLength(1));
        expect(st.todosOn(liveScope, now), hasLength(1));
        st.dispose();
        st = AppState(s, clock: () => now);
        expect(st.todos[liveScope], hasLength(1));
        final sender = SyncEngine(s, 'a')..claimAll();
        final other = memory();
        final receiver = SyncEngine(other, 'b')..clearForJoining();
        receiver.mergeAll([(sent(sender), 'a')]);
        final synced = AppState(other, clock: () => now);
        expect(synced.todos[liveScope], hasLength(1));
        expect(synced.todosOn(completedScope, yesterday).singleWhere((t) => t.uid == task.uid).done, isTrue);
        synced.dispose();

        st.toggleTodo(st.todosOn(completedScope, yesterday).first, scope: completedScope, day: yesterday);
        expect(st.todosOn(scope, yesterday).singleWhere((t) => t.uid == task.uid).done, isFalse);
        expect(st.todos[liveScope], hasLength(2));
        expect(st.todos[liveScope]!.every((t) => !t.done), isTrue);
        expect(st.todosOn(liveScope, now), hasLength(2));
        sender.flush();
        receiver.mergeAll([(sent(sender), 'a')]);
        final syncedUndo = AppState(other, clock: () => now);
        expect(syncedUndo.todos[liveScope], hasLength(2));
        expect(syncedUndo.todos[liveScope]!.every((t) => !t.done), isTrue);
        syncedUndo.dispose();
        st.dispose();
        final reopened = AppState(s, clock: () => now);
        expect(reopened.todos[liveScope], hasLength(2));
        reopened.dispose();
      }
    });

    test('yesterday text corrections stay isolated, completion updates live tasks, and edits lock after midnight', () {
      final s = memory();
      s.addHabit(2026, 10, 'Read');
      var now = DateTime(2026, 10, 31);
      final st = AppState(s, clock: () => now);
      st.addTodo(TodoScope.today, 'Live');
      st.addTodo(TodoScope.today, 'Deleted later');
      now = DateTime(2026, 11, 1);
      st.checkDate();
      st.removeTodo(TodoScope.today, st.todos[TodoScope.today]!.last);
      final yesterday = DateTime(2026, 10, 31);
      expect(st.canEditDay(yesterday), isTrue);
      expect(st.canEditDay(DateTime(2026, 10, 30)), isFalse);
      final task = st.todosOn(TodoScope.today, yesterday).first;
      st.editTodo(TodoScope.today, task, 'Corrected', null, day: yesterday);
      expect(st.todos[TodoScope.today]!.single.text, 'Live');
      st.toggleTodo(task, day: yesterday);
      final deleted = st.todosOn(TodoScope.today, yesterday).last;
      st.editTodo(TodoScope.today, deleted, 'Recovered record', null, day: yesterday);
      st.toggleTodo(deleted, day: yesterday);
      st.toggleTodo(deleted, day: yesterday);
      expect(st.todos[TodoScope.today], isEmpty);
      st.addTodo(TodoScope.today, 'Forgot to record', day: yesterday);
      expect(st.todosOn(TodoScope.today, yesterday).map((t) => t.text), [
        'Corrected',
        'Recovered record',
        'Forgot to record',
      ]);
      expect(st.todosOn(TodoScope.today, yesterday).first.done, isTrue);
      expect(st.todos[TodoScope.today], isEmpty);
      final sender = SyncEngine(s, 'a')..claimAll();
      final other = memory();
      final receiver = SyncEngine(other, 'b')..clearForJoining();
      receiver.mergeAll([(sent(sender), 'a')]);
      expect(other.todoListsOn(yesterday)[TodoScope.today]!, hasLength(3));
      expect(other.todoListsOn(now)[TodoScope.today]!, isEmpty);
      st.removeTodo(TodoScope.today, task, day: yesterday);
      expect(st.todosOn(TodoScope.today, yesterday), hasLength(2));
      now = DateTime(2026, 11, 2);
      st.checkDate();
      st.addTodo(TodoScope.today, 'Too late', day: yesterday);
      st.editTodo(TodoScope.today, deleted, 'Too late', null, day: yesterday);
      expect(st.canEditDay(yesterday), isFalse);
      expect(st.todosOn(TodoScope.today, yesterday), hasLength(2));
      expect(st.todosOn(TodoScope.today, yesterday).first.text, 'Recovered record');
      st.dispose();
    });

    test('legacy tasks get a baseline before later completion changes history', () {
      final s = memory();
      s.addHabit(2026, 10, 'Read');
      final item = s.addTodo(TodoScope.week, DateTime(2026, 10, 19), 'Call');
      s.raw.execute("UPDATE todos SET due_date = '2026-12-20'");
      s.raw.execute('DELETE FROM todo_history');
      var now = DateTime(2026, 10, 20);
      final st = AppState(s, clock: () => now);
      addTearDown(st.dispose);
      now = DateTime(2026, 10, 22);
      st.checkDate();
      st.toggleTodo(st.todos[TodoScope.week]!.single);
      expect(st.todosOn(TodoScope.week, DateTime(2026, 10, 20)).single.done, isFalse);
      expect(st.todosOn(TodoScope.week, now), isEmpty);
      expect(st.todosOn(TodoScope.today, now).single.done, isTrue);
      expect(s.todos(TodoScope.today, dateKey(now)).single.id, item.id);
    });
  });
}
