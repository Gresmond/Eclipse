import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Store store;
  late AppState state;

  setUp(() {
    collapseAllTasks();
    store = Store.memory();
    state = AppState(store, clock: () => DateTime(2026, 10, 26));
    for (final task in [...state.todos[TodoScope.today]!]) {
      state.removeTodo(TodoScope.today, task);
    }
  });

  tearDown(() {
    state.dispose();
    store.close();
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(palettes.first),
          home: const Scaffold(
            body: SizedBox(width: 420, height: 550, child: WeekCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('main task preserves its tick animation while gliding down and back up', (tester) async {
    for (final name in ['Alpha', 'Bravo', 'Charlie']) {
      state.addTodo(TodoScope.today, name);
    }
    await show(tester);
    double top(String name) => tester.getTopLeft(find.text(name)).dy;
    final start = top('Alpha');
    final end = top('Charlie');
    final tick = find
        .descendant(
          of: find.byKey(ValueKey((TodoScope.today, state.todos[TodoScope.today]!.first.id))),
          matching: find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_Check'),
        )
        .first;
    final tickState = tester.state(tick);

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(
      tester.state(tick),
      same(tickState),
      reason: 'the tick must animate rather than be recreated already filled',
    );
    await tester.pump(Motion.reorder ~/ 4);
    expect(top('Alpha'), allOf(greaterThan(start), lessThan(end)), reason: 'the tick and glide overlap');
    await tester.pump(Motion.reorder ~/ 4);
    expect(top('Alpha'), allOf(greaterThan(start), lessThan(end)));
    await tester.pumpAndSettle();
    expect(top('Alpha'), closeTo(end, 0.01));

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.pump(Motion.reorder ~/ 2);
    expect(top('Alpha'), allOf(greaterThan(start), lessThan(end)));
    await tester.pumpAndSettle();
    expect(top('Alpha'), closeTo(start, 0.01));
  });

  for (final interrupt in [false, true]) {
    testWidgets('subtasks glide in both directions; interrupt midway: $interrupt', (tester) async {
      state.addTodo(TodoScope.today, 'Project');
      state.setTodoSubtasks(TodoScope.today, state.todos[TodoScope.today]!.single, [
        const TodoSubtask('Alpha step'),
        const TodoSubtask('Bravo step'),
        const TodoSubtask('Charlie step'),
      ]);
      await show(tester);
      await tester.tap(find.byTooltip('Expand subtasks'));
      await tester.pumpAndSettle();
      double top(String name) => tester.getTopLeft(find.text(name)).dy;
      final start = top('Alpha step');
      final end = top('Charlie step');

      await tester.tap(find.byTooltip('Complete subtask').first);
      await tester.pump();
      await tester.pump(Motion.reorder ~/ 4);
      expect(top('Alpha step'), allOf(greaterThan(start), lessThan(end)));
      await tester.pump(Motion.reorder ~/ 4);
      expect(top('Alpha step'), allOf(greaterThan(start), lessThan(end)));
      if (!interrupt) {
        await tester.pumpAndSettle();
        expect(top('Alpha step'), closeTo(end, 0.01));
      }
      final turningPoint = top('Alpha step');
      await tester.tap(find.byTooltip('Reopen subtask'));
      await tester.pump();
      expect(top('Alpha step'), closeTo(turningPoint, 0.01), reason: 'reversing must start where the row is drawn');
      await tester.pump(Motion.reorder ~/ 2);
      expect(top('Alpha step'), allOf(greaterThan(start), lessThan(turningPoint)));
      await tester.pumpAndSettle();
      expect(top('Alpha step'), closeTo(start, 0.01));
      expect(top('Bravo step'), lessThan(top('Charlie step')));
      expect(tester.takeException(), isNull);
    });
  }
}
