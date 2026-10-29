import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  setUpAll(() async {
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(family['family'] as String);
      for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
  });

  setUp(() {
    collapseAllTasks();
    store = Store.memory();
    state = AppState(store, clock: () => today);
    for (final scope in TodoScope.values) {
      for (final task in [...state.todos[scope]!]) {
        state.removeTodo(scope, task);
      }
    }
    state.addTodo(TodoScope.today, 'Research the project');
    state.addTodo(TodoScope.tomorrow, 'Launch the project');
  });
  tearDown(() {
    state.dispose();
    store.close();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  double opacity(WidgetTester tester, String text) => tester
      .widget<FadeTransition>(find.ancestor(of: find.text(text), matching: find.byType(FadeTransition)).first)
      .opacity
      .value;

  Future<void> drop(WidgetTester tester) async {
    final start = tester.getCenter(find.text('Research the project'));
    await tester.dragFrom(start, tester.getCenter(find.text('Launch the project')) - start);
    await tester.pump();
  }

  for (final existing in [false, true]) {
    testWidgets('nesting fades the original before revealing the subtask; existing checklist $existing', (
      tester,
    ) async {
      if (existing) {
        state.setTodoSubtasks(TodoScope.tomorrow, state.todos[TodoScope.tomorrow]!.single, [
          const TodoSubtask('Existing step'),
        ]);
      }
      await show(tester);
      if (existing) {
        await tester.tap(find.byTooltip('Expand subtasks'));
        await tester.pumpAndSettle();
      }
      await drop(tester);
      expect(state.todos[TodoScope.today]!.single.text, 'Research the project');
      expect(opacity(tester, 'Research the project'), 1);
      await tester.pump(const Duration(milliseconds: 105));
      expect(opacity(tester, 'Research the project'), greaterThan(0));
      expect(opacity(tester, 'Research the project'), lessThan(1));
      expect(state.todos[TodoScope.tomorrow]!.single.subtasks.length, existing ? 1 : 0);
      if (existing) expect(opacity(tester, 'Existing step'), 1);
      await tester.pump(const Duration(milliseconds: 315));
      expect(state.todos[TodoScope.today], isEmpty);
      expect(state.todos[TodoScope.tomorrow]!.single.subtasks.last.text, 'Research the project');
      expect(opacity(tester, 'Research the project'), 0);
      await tester.pump(); // Start the enclosing size animation on its own frame.
      await tester.pump(const Duration(milliseconds: 210));
      expect(opacity(tester, 'Research the project'), greaterThan(0));
      expect(opacity(tester, 'Research the project'), lessThan(1));
      if (existing) expect(opacity(tester, 'Existing step'), 1);
      expect(find.text('Research the project').hitTestable(), findsOneWidget);
      await tester.pumpAndSettle();
      expect(opacity(tester, 'Research the project'), 1);
      // Opening the parent later must not replay the arrival animation.
      await tester.tap(find.byTooltip('Collapse subtasks'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand subtasks'));
      await tester.pump();
      expect(opacity(tester, 'Research the project'), 1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('subtasks drag to a new place in their task, the others gliding aside', (tester) async {
    state.setTodoSubtasks(TodoScope.tomorrow, state.todos[TodoScope.tomorrow]!.single, [
      for (final text in ['Step one', 'Step two', 'Step three']) TodoSubtask(text, numbered: true),
    ]);
    await show(tester);
    await tester.tap(find.byTooltip('Expand subtasks'));
    await tester.pumpAndSettle();
    final start = tester.getCenter(find.textContaining('Step one'));
    final below = tester.getCenter(find.textContaining('Step two')).dy - start.dy;
    final drag = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 10; i++) {
      await drag.moveBy(Offset(0, below * 1.2 / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Shown in its new place before it's let go, and only saved when it is.
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.textContaining('Step two')).dy, lessThan(start.dy + 4), reason: 'Step two glides up');
    expect(state.todos[TodoScope.tomorrow]!.single.subtasks.first.text, 'Step one');
    await drag.up();
    await tester.pumpAndSettle();
    final task = state.todos[TodoScope.tomorrow]!.single;
    expect(task.subtasks.map((s) => s.text), ['Step two', 'Step one', 'Step three']);
    expect(task.numbered, isTrue);
    expect(state.todos[TodoScope.today]!.single.text, 'Research the project', reason: 'the task itself stayed');
    expect(find.text('1. Step two'), findsOneWidget, reason: 'renumbered once dropped');
    expect(find.text('2. Step one'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a source fades back in if the parent disappears during conversion', (tester) async {
    await show(tester);
    await drop(tester);
    await tester.pump(const Duration(milliseconds: 210));
    state.removeTodo(TodoScope.tomorrow, state.todos[TodoScope.tomorrow]!.single);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.single.text, 'Research the project');
    expect(opacity(tester, 'Research the project'), 1);
    expect(state.todos[TodoScope.tomorrow], isEmpty);
    expect(tester.takeException(), isNull);
  });
}
