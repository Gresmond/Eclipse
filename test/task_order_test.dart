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
    collapseAllTasks();
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
    state.orderTodos([for (final t in ['C', 'A', 'B']) named(TodoScope.today, t)]);
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
    await tester.dragFrom(start, tester.getTopLeft(find.text('First')) + const Offset(20, 1) - start);
    await tester.pumpAndSettle();
    expect(texts(TodoScope.today), ['Third', 'First', 'Second']);
    expect(state.todos[TodoScope.today]!.every((t) => t.subtasks.isEmpty), isTrue);

    start = tester.getCenter(find.text('Third'));
    await tester.dragFrom(start, tester.getBottomLeft(find.text('Second')) + const Offset(20, 1) - start);
    await tester.pumpAndSettle();
    expect(texts(TodoScope.today), ['First', 'Second', 'Third']);

    // The middle of a task still nests.
    start = tester.getCenter(find.text('Third'));
    await tester.dragFrom(start, tester.getCenter(find.text('First')) - start);
    await tester.pumpAndSettle();
    expect(named(TodoScope.today, 'First').subtasks.single.text, 'Third');
    expect(tester.takeException(), isNull);
  });
}
