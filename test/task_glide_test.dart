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
          home: const Scaffold(body: SizedBox(width: 420, height: 550, child: WeekCard())),
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

  // Rows are hit where they're drawn, and the crossing row is drawn on top.
  for (final (direction, startTicked) in [('down', false), ('back up', true)]) {
    testWidgets('a click mid-glide lands on the row that shows there, going $direction', (tester) async {
      for (final name in ['Alpha', 'Bravo', 'Charlie', 'Delta']) {
        state.addTodo(TodoScope.today, name);
      }
      await show(tester);
      if (startTicked) {
        await tester.tap(find.text('Alpha'));
        await tester.pumpAndSettle();
      }
      bool ticked(String name) => state.todos[TodoScope.today]!.firstWhere((t) => t.text == name).done;

      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.pump(Motion.reorder ~/ 2);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      expect(ticked('Alpha'), startTicked);
      for (final name in ['Bravo', 'Charlie', 'Delta']) {
        expect(ticked(name), isFalse, reason: '$name was only passed under');
      }
    });
  }

  testWidgets('a click mid-glide lands on the subtask that shows there, going back up', (tester) async {
    state.addTodo(TodoScope.today, 'Project');
    state.setTodoSubtasks(TodoScope.today, state.todos[TodoScope.today]!.single, [
      const TodoSubtask('Alpha step'),
      const TodoSubtask('Bravo step'),
      const TodoSubtask('Charlie step'),
      const TodoSubtask('Delta step'),
    ]);
    await show(tester);
    await tester.tap(find.byTooltip('Expand subtasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha step'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alpha step'));
    await tester.pump();
    await tester.pump(Motion.reorder ~/ 2);
    await tester.tap(find.text('Alpha step'));
    await tester.pumpAndSettle();

    final ticked = {for (final s in state.todos[TodoScope.today]!.single.subtasks) s.text: s.done};
    expect(ticked, {'Alpha step': true, 'Bravo step': false, 'Charlie step': false, 'Delta step': false});
  });

  // MOTION-01: the panel's tint shows under gliding rows; no slab is drawn.
  testWidgets('rows glide with nothing painted behind them, the crossing one cutting the others away', (tester) async {
    for (final name in ['Alpha', 'Bravo', 'Charlie', 'Delta']) {
      state.addTodo(TodoScope.today, name);
    }
    await show(tester);
    final tile = palettes.first.tile;
    final list = tester.renderObject(find.ancestor(of: find.text('Bravo'), matching: find.byType(SliverList)).first);
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(list, isNot(paints..rrect(color: tile)), reason: 'frame $i of the glide');
    }
    expect(list, paints..clipPath(), reason: 'rows the ticked one passes are cut away under it');
    await tester.pumpAndSettle();
    expect(list, isNot(paints..clipPath()), reason: 'nothing is cut once it lands');
  });

  // MOTION-06: a newly typed task appears in its final place.
  testWidgets('a new task fades in above the ticked ones rather than gliding up past them', (tester) async {
    state.addTodo(TodoScope.today, 'Alpha');
    state.addTodo(TodoScope.today, 'Bravo');
    state.toggleTodo(state.todos[TodoScope.today]!.last);
    await show(tester);
    state.addTodo(TodoScope.today, 'Charlie');
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      expect(
        tester.getTopLeft(find.text('Charlie')).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('Bravo')).dy),
        reason: 'frame $i: it opens its room above Bravo, never below it',
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Charlie')).dy, lessThan(tester.getTopLeft(find.text('Bravo')).dy));
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

      await tester.tap(find.text('Alpha step'));
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
      await tester.tap(find.text('Alpha step'));
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
