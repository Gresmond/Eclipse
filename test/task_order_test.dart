import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/todo_panel.dart';

void main() {
  final today = DateTime(2026, 10, 25);
  late Store store;
  late AppState state;
  setUp(() {
    store = Store.memory();
    state = AppState(store, clock: () => today);
    for (final scope in TodoScope.values) {
      for (final task in [...state.todos[scope]!]) {
        state.removeTodo(scope, task);
      }
    }
  });
  tearDown(() {
    state.dispose();
    store.close();
  });

  List<String> texts(TodoScope scope) => [for (final t in state.orderedTodos(scope)) t.text];
  TodoItem named(TodoScope scope, String text) => state.todos[scope]!.singleWhere((t) => t.text == text);

  test('tasks put in order keep it within their group; new and moved ones go after', () {
    for (final text in ['A', 'B', 'C']) {
      state.addTodo(TodoScope.today, text);
    }
    state.addTodo(TodoScope.today, 'Project');
    state.setTodoSubtasks(TodoScope.today, named(TodoScope.today, 'Project'), [const TodoSubtask('Step')]);
    state.orderTodos([
      for (final t in ['C', 'A', 'B']) named(TodoScope.today, t),
    ]);
    expect(texts(TodoScope.today), ['Project', 'C', 'A', 'B'], reason: 'the group with subtasks stays first');

    state.addTodo(TodoScope.today, 'D');
    expect(texts(TodoScope.today), ['Project', 'C', 'A', 'B', 'D']);

    // Moved to another day and back, it goes after those put in order.
    state.moveTodo(TodoScope.today, named(TodoScope.today, 'C'), TodoScope.tomorrow);
    state.moveTodo(TodoScope.tomorrow, named(TodoScope.tomorrow, 'C'), TodoScope.today);
    expect(texts(TodoScope.today), ['Project', 'A', 'B', 'C', 'D']);

    final reopened = AppState(store, clock: () => today);
    addTearDown(reopened.dispose);
    expect([for (final t in reopened.orderedTodos(TodoScope.today)) t.text], ['Project', 'A', 'B', 'C', 'D']);
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  testWidgets('dropped on the top or bottom of a task in its day, a task goes there instead of nesting', (
    tester,
  ) async {
    for (final text in ['First', 'Second', 'Third']) {
      state.addTodo(TodoScope.today, text);
    }
    await show(tester);
    var start = tester.getCenter(find.text('Third'));
    await tester.dragFrom(
      start,
      tester.getTopLeft(find.ancestor(of: find.text('First'), matching: find.byType(TaskRow))) +
          const Offset(20, 1) -
          start,
    );
    await tester.pumpAndSettle();
    expect(texts(TodoScope.today), ['Third', 'First', 'Second']);
    expect(state.todos[TodoScope.today]!.every((t) => t.subtasks.isEmpty), isTrue);

    start = tester.getCenter(find.text('Third'));
    await tester.dragFrom(
      start,
      tester.getBottomLeft(find.ancestor(of: find.text('Second'), matching: find.byType(TaskRow))) +
          const Offset(20, -1) -
          start,
    );
    await tester.pumpAndSettle();
    expect(texts(TodoScope.today), ['First', 'Second', 'Third']);

    // The middle of a task still nests.
    start = tester.getCenter(find.text('Third'));
    await tester.dragFrom(start, tester.getCenter(find.text('First')) - start);
    await tester.pumpAndSettle();
    expect(named(TodoScope.today, 'First').subtasks.single.text, 'Third');
    expect(tester.takeException(), isNull);
  });

  test('unfinished projects, chronological due dates, plain tasks, then ticked ones in the same groups', () {
    final today = DateTime(2026, 10, 26);
    TodoItem task(int id, {int? ticked, DateTime? due, bool project = false}) => TodoItem(
      id,
      '$id',
      since: today,
      done: ticked != null,
      doneAt: ticked == null || ticked == 0 ? null : today.add(Duration(minutes: ticked)),
      dueDate: due,
      subtasks: project ? [const TodoSubtask('Step')] : [],
    );
    final tasks = [
      task(1, ticked: 5, project: true),
      task(2),
      task(3, due: DateTime(2026, 10, 30)),
      task(4, project: true),
      task(5, due: DateTime(2026, 10, 28)),
      task(6),
      task(7, ticked: 3),
      task(8, ticked: 1),
      task(9, ticked: 2, project: true),
      task(10, ticked: 9, due: DateTime(2026, 10, 29)),
      task(11, ticked: 4, due: DateTime(2026, 10, 29)),
      task(12, ticked: 8, due: DateTime(2026, 10, 27)),
      task(13, ticked: 0),
    ];
    // Ticked before tick times were kept (13) counts as ticked first.
    expect(sortTodos(tasks).map((t) => t.id), [4, 5, 3, 2, 6, 9, 1, 12, 11, 10, 13, 8, 7]);
  });

  test('ticking records when, a changed checklist keeps it and unticking clears it', () {
    final localStore = Store.memory();
    addTearDown(localStore.close);
    final day = DateTime(2026, 10, 26);
    final first = localStore.addTodo(TodoScope.today, day, 'First');
    final second = localStore.addTodo(TodoScope.today, day, 'Second');
    localStore.setTodoDone(second.id, true, day: day);
    localStore.setTodoDone(first.id, true, day: day);
    expect(sortTodos(localStore.todos(TodoScope.today, dateKey(day))).map((t) => t.text), ['Second', 'First']);

    final ticked = localStore.todos(TodoScope.today, dateKey(day)).firstWhere((t) => t.id == second.id).doneAt;
    expect(ticked, isNotNull);
    localStore.setTodoDone(second.id, true, day: day, cascade: false);
    expect(localStore.todos(TodoScope.today, dateKey(day)).firstWhere((t) => t.id == second.id).doneAt, ticked);
    expect(localStore.todoListsOn(day)[TodoScope.today]!.firstWhere((t) => t.id == second.id).doneAt, ticked);

    localStore.setTodoDone(second.id, false, day: day);
    expect(localStore.todos(TodoScope.today, dateKey(day)).firstWhere((t) => t.id == second.id).doneAt, isNull);
  });

  test('sortTodos satisfies strict weak ordering with mixed dated and undated subtasks', () {
    final day = DateTime(2026, 11, 5);
    TodoItem project(int id, {DateTime? due, int? position, bool done = false}) => TodoItem(
      id,
      'P$id',
      since: day,
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
    final reversed = sortTodos(items.reversed);
    expect(reversed.map((t) => t.dueDate != null), [true, true, false, false, true, false]);
  });
}
