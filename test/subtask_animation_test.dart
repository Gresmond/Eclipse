import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/todo_panel.dart';

const _shots = String.fromEnvironment('SCREENSHOT_DIR');

Future<void> _shot(WidgetTester tester, String name) async {
  if (_shots.isEmpty) return;
  final view = tester.binding.renderViews.first;
  await tester.runAsync(() async {
    final image = await (view.debugLayer! as OffsetLayer).toImage(Offset.zero & view.size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

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
    state.addTodo(TodoScope.week, 'Launch the project');
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
        state.setTodoSubtasks(TodoScope.week, state.todos[TodoScope.week]!.single, [
          const TodoSubtask('Existing step'),
        ]);
      }
      await show(tester);
      if (existing) {
        await tester.tap(find.byTooltip('Expand subtasks'));
        await tester.pumpAndSettle();
      }
      await _shot(tester, 'nest_${existing}_before');
      await drop(tester);
      expect(state.todos[TodoScope.today]!.single.text, 'Research the project');
      expect(opacity(tester, 'Research the project'), 1);
      await tester.pump(const Duration(milliseconds: 105));
      expect(opacity(tester, 'Research the project'), greaterThan(0));
      expect(opacity(tester, 'Research the project'), lessThan(1));
      expect(state.todos[TodoScope.week]!.single.subtasks.length, existing ? 1 : 0);
      if (existing) expect(opacity(tester, 'Existing step'), 1);
      await _shot(tester, 'nest_${existing}_source_fading');
      await tester.pump(const Duration(milliseconds: 315));
      expect(state.todos[TodoScope.today], isEmpty);
      expect(state.todos[TodoScope.week]!.single.subtasks.last.text, 'Research the project');
      expect(opacity(tester, 'Research the project'), 0);
      await tester.pump(); // Start the enclosing size animation on its own frame.
      await tester.pump(const Duration(milliseconds: 210));
      expect(opacity(tester, 'Research the project'), greaterThan(0));
      expect(opacity(tester, 'Research the project'), lessThan(1));
      if (existing) expect(opacity(tester, 'Existing step'), 1);
      expect(find.text('Research the project').hitTestable(), findsOneWidget);
      await _shot(tester, 'nest_${existing}_subtask_fading');
      await tester.pumpAndSettle();
      expect(opacity(tester, 'Research the project'), 1);
      await _shot(tester, 'nest_${existing}_settled');
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
    state.setTodoSubtasks(TodoScope.week, state.todos[TodoScope.week]!.single, [
      for (final text in ['Step one', 'Step two', 'Step three']) TodoSubtask(text, numbered: true),
    ]);
    await show(tester);
    await tester.tap(find.byTooltip('Expand subtasks'));
    await tester.pumpAndSettle();
    final start = tester.getCenter(find.text('Step one'));
    final below = tester.getCenter(find.text('Step two')).dy - start.dy;
    final drag = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 10; i++) {
      await drag.moveBy(Offset(0, below * 1.2 / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Shown in its new place before it's let go, and only saved when it is.
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('Step two')).dy, lessThan(start.dy + 4), reason: 'Step two glides up');
    expect(state.todos[TodoScope.week]!.single.subtasks.first.text, 'Step one');
    await drag.up();
    await tester.pumpAndSettle();
    final task = state.todos[TodoScope.week]!.single;
    expect(task.subtasks.map((s) => s.text), ['Step two', 'Step one', 'Step three']);
    expect(task.numbered, isTrue);
    expect(state.todos[TodoScope.today]!.single.text, 'Research the project', reason: 'the task itself stayed');
    expect(find.text('1.'), findsOneWidget);
    expect(
      tester.getCenter(find.text('1.')).dy,
      closeTo(tester.getCenter(find.text('Step two')).dy, 2),
      reason: 'renumbered once dropped',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a source fades back in if the parent disappears during conversion', (tester) async {
    await show(tester);
    await drop(tester);
    await tester.pump(const Duration(milliseconds: 210));
    state.removeTodo(TodoScope.week, state.todos[TodoScope.week]!.single);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.single.text, 'Research the project');
    expect(opacity(tester, 'Research the project'), 1);
    expect(state.todos[TodoScope.week], isEmpty);
    expect(tester.takeException(), isNull);
  });
}
