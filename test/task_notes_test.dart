import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/search.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<List<Object?>> _sent(SyncEngine e) => e.changesSince(0).values.expand((v) => v).toList();

void main() {
  Store memory() {
    final store = Store.memory();
    addTearDown(store.close);
    return store;
  }

  test('tasks and subtasks keep notes through ticks, nesting, search and sync', () {
    final store = memory();
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 18, 9));
    addTearDown(state.dispose);
    state.addTodo(TodoScope.today, 'Email clinics');
    state.addTodo(TodoScope.today, 'Call May Health');
    var item = state.todos[TodoScope.today]!.first;

    state.setTodoNote(TodoScope.today, item, '  replied: may health \$80\nwaiting: Pioneer  ');
    item = state.todos[TodoScope.today]!.first;
    expect(item.note, 'Replied: may health \$80\nwaiting: Pioneer');
    expect(SearchIndex(store).search('pioneer').single.text, 'Email clinics');

    // A task nested into another becomes a subtask with its note.
    final call = state.todos[TodoScope.today]!.last;
    state.setTodoNote(TodoScope.today, call, 'Open 9 to 5');
    expect(
      state.nestTodo(TodoScope.today, state.todos[TodoScope.today]!.last, TodoScope.today, item),
      isTrue,
    );
    item = state.todos[TodoScope.today]!.single;
    expect(item.subtasks.single.note, 'Open 9 to 5');
    expect(SearchIndex(store).search('open 9').single.subtask, 'Call May Health');

    // Ticking keeps it; a blank note takes it away.
    state.toggleTodo(item);
    item = state.todos[TodoScope.today]!.single;
    expect(item.done, isTrue);
    expect(item.subtasks.single.note, 'Open 9 to 5');
    state.setTodoSubtasks(TodoScope.today, item, [item.subtasks.single.withNote('   ')]);
    expect(state.todos[TodoScope.today]!.single.subtasks.single.note, isNull);
    state.setTodoSubtasks(TodoScope.today, item, [item.subtasks.single.withNote('Rang back')]);

    final sender = SyncEngine(store, 'a')..claimAll();
    final other = memory();
    SyncEngine(other, 'b')
      ..clearForJoining()
      ..mergeAll([(_sent(sender), 'a')]);
    final there = other.todos(TodoScope.today, '2026-11-18').single;
    expect(there.note, 'Replied: may health \$80\nwaiting: Pioneer');
    expect(there.subtasks.single.note, 'Rang back');

    state.setTodoNote(TodoScope.today, state.todos[TodoScope.today]!.single, '');
    expect(state.todos[TodoScope.today]!.single.note, isNull);
  });

  test("a past day's note shows on that day and on the task", () {
    final store = memory();
    store.addHabit(2026, 11, 'Read');
    var now = DateTime(2026, 11, 17, 9);
    final state = AppState(store, clock: () => now);
    addTearDown(state.dispose);
    state.addTodo(TodoScope.today, 'Quotes');
    now = DateTime(2026, 11, 18, 9);
    state.checkDate();
    final yesterday = DateTime(2026, 11, 17);
    state.setTodoNote(
      TodoScope.today,
      state.todosOn(TodoScope.today, yesterday).single,
      'Two of five back',
      day: yesterday,
    );
    expect(state.todosOn(TodoScope.today, yesterday).single.note, 'Two of five back');
    expect(state.todos[TodoScope.today]!.single.note, 'Two of five back');
  });

  test("a repeat's times keep their own notes, and its checklist takes none", () {
    final store = memory();
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 18, 9));
    addTearDown(state.dispose);
    state.addTodo(TodoScope.today, 'Gym');
    var item = state.todos[TodoScope.today]!.single;
    state.setTodoSubtasks(TodoScope.today, item, [const TodoSubtask('Squat', note: '100 kg')]);
    state.setTodoNote(TodoScope.today, state.todos[TodoScope.today]!.single, 'Leg day');
    item = state.todos[TodoScope.today]!.single;
    state.makeRepeating(TodoScope.today, item, 'Gym', const RepeatRule.every(1));
    final first = state.todos[TodoScope.today]!.single;
    expect(first.note, 'Leg day');
    expect(first.subtasks.single.note, '100 kg');
    expect(state.repeats.single.subtasks.single.note, isNull);
  });

  testWidgets('a note shows under its task and opens from its line', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = memory();
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 18, 9));
    addTearDown(state.dispose);
    state.addTodo(TodoScope.today, 'Email clinics');
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    // Added from the task's editor, and kept when it's saved.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Email clinics')));
    addTearDown(mouse.removePointer);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'May Health replied');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.single.note, isNull, reason: 'not until the task is saved');
    expect(find.text('May Health replied'), findsOneWidget);
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.single.note, 'May Health replied');
    final line = find.textContaining('May Health replied', findRichText: true);
    expect(line, findsOneWidget);
    expect(tester.getTopLeft(line).dy, greaterThan(tester.getTopLeft(find.text('Email clinics')).dy));

    // Clicking the note opens it rather than ticking the task.
    await tester.tap(line);
    await tester.pumpAndSettle();
    expect(find.text('Edit note'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.single.note, isNull);
    expect(state.todos[TodoScope.today]!.single.done, isFalse);
  });
}
