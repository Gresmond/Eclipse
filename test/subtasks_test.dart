import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/motion.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:eclipse/widgets/smooth_task_scroll.dart';

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
  TodoItem task(TodoScope scope) => state.todos[scope]!.single;

  test('numbered subtasks keep their numbering through a round trip and ticks', () {
    state.addTodo(TodoScope.week, 'Steps');
    state.setTodoSubtasks(TodoScope.week, task(TodoScope.week), [
      const TodoSubtask('One', numbered: true),
      const TodoSubtask('Two', numbered: true),
    ]);
    expect(task(TodoScope.week).numbered, isTrue);
    final next = [...task(TodoScope.week).subtasks];
    next[0] = next[0].copyWith(done: true);
    state.setTodoSubtasks(TodoScope.week, task(TodoScope.week), next);
    expect(task(TodoScope.week).numbered, isTrue, reason: 'ticking keeps it');
    expect(task(TodoScope.week).subtasks.map((s) => s.text), ['One', 'Two']);
    expect(store.todoListsOn(today)[TodoScope.week]!.single.numbered, isTrue, reason: 'saved');
    // Older lists, and older versions reading new ones, still decode.
    expect(TodoSubtask.decode('[{"text":"Old","done":false}]').single.numbered, isFalse);
    expect(TodoSubtask.encode([const TodoSubtask('Plain')]), '[{"text":"Plain","done":false}]');
  });

  test('project completion, undo, moves, history and sync preserve subtasks', () {
    state.addTodo(TodoScope.week, 'Big project');
    state.setTodoSubtasks(TodoScope.week, task(TodoScope.week), [
      const TodoSubtask('Research', done: true),
      const TodoSubtask('Build'),
    ]);
    state.moveTodo(TodoScope.week, task(TodoScope.week), TodoScope.month);
    expect(task(TodoScope.month).subtasks.first.done, isTrue);
    expect(task(TodoScope.month).subtasks.last.done, isFalse);
    state.setTodoSubtasks(TodoScope.month, task(TodoScope.month), [
      const TodoSubtask('Research', done: true),
      const TodoSubtask('Build', done: true),
    ]);
    expect(state.todos[TodoScope.month], isEmpty);
    expect(task(TodoScope.today).done, isTrue);
    state.toggleTodo(task(TodoScope.today));
    expect(task(TodoScope.month).subtasks.every((s) => !s.done), isTrue);
    state.toggleTodo(task(TodoScope.month), scope: TodoScope.month);
    expect(task(TodoScope.today).subtasks.every((s) => s.done), isTrue);
    expect(store.todoListsOn(today)[TodoScope.today]!.single.subtasks.length, 2);

    final remote = Store.memory();
    addTearDown(remote.close);
    final sender = SyncEngine(store, 'first')..flush();
    SyncEngine(remote, 'second').mergeAll([(sender.changesSince(0).values.expand((changes) => changes), 'first')]);
    final received = remote.todos(TodoScope.today, dateKey(today)).single;
    expect(received.text, 'Big project');
    expect(received.subtasks.map((s) => s.text), ['Research', 'Build']);
    expect(received.subtasks.every((s) => s.done), isTrue);
  });

  test('subtasks survive reopening, backups and day rollover', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse-subtasks-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final disk = Store.open('${dir.path}/source.db');
    final item = disk.addTodo(TodoScope.tomorrow, today, 'Project');
    disk.setTodoSubtasks(TodoScope.tomorrow, item, [const TodoSubtask('First')], today, live: true);
    disk.saveCopy('${dir.path}/backup.db');
    disk.close();
    final reopened = Store.open('${dir.path}/source.db');
    addTearDown(reopened.close);
    final next = DateTime(2026, 10, 26);
    final app = AppState(reopened, clock: () => next);
    addTearDown(app.dispose);
    expect(app.todos[TodoScope.today]!.singleWhere((item) => item.text == 'Project').subtasks.single.text, 'First');
    expect(reopened.todoListsOn(today)[TodoScope.tomorrow]!.single.subtasks.single.text, 'First');
    await store.restoreFrom('${dir.path}/backup.db');
    expect(store.todos(TodoScope.tomorrow, dateKey(today)).single.subtasks.single.text, 'First');
  });

  test('yesterday subtask corrections preserve today and parent ticks update all children', () {
    final yesterday = DateTime(2026, 10, 24);
    final item = store.addTodo(TodoScope.today, yesterday, 'Historical project');
    store.setTodoSubtasks(TodoScope.today, item, [const TodoSubtask('Original')], yesterday, live: true);
    state.checkDate();
    final historical = store.todoListsOn(yesterday)[TodoScope.today]!.single;
    state.setTodoSubtasks(TodoScope.today, historical, [const TodoSubtask('Corrected', done: true)], day: yesterday);
    expect(store.todoListsOn(yesterday)[TodoScope.today]!.single.subtasks.single.text, 'Corrected');
    expect(store.todos(TodoScope.today, dateKey(yesterday)).single.subtasks.single.text, 'Original');
    final corrected = store.todoListsOn(yesterday)[TodoScope.today]!.single;
    state.toggleTodo(corrected, day: yesterday);
    expect(store.todoListsOn(yesterday)[TodoScope.today]!.single.subtasks.single.done, isFalse);
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  testWidgets('wheel scrolling eases, accumulates ticks and clamps to the end', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 200,
            child: SmoothTaskScroll(
              builder: (context, controller) =>
                  SingleChildScrollView(controller: controller, child: const SizedBox(height: 2000)),
            ),
          ),
        ),
      ),
    );
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    final center = tester.getCenter(find.byType(SmoothTaskScroll));
    Future<void> wheel(double delta) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: Offset(0, delta), kind: PointerDeviceKind.mouse),
      );
      await tester.pump();
    }

    await wheel(120);
    expect(scroll.position.pixels, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(scroll.position.pixels, greaterThan(0));
    expect(scroll.position.pixels, lessThan(120));
    await wheel(120);
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(240, 0.1));
    await wheel(10000);
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, scroll.position.maxScrollExtent);
  });

  testWidgets('dropping on a task name nests across lists and preserves the project', (tester) async {
    state.addTodo(TodoScope.today, 'Read source material');
    state.addTodo(TodoScope.tomorrow, 'Write report', dueDate: DateTime(2026, 10, 29));
    await show(tester);
    final source = tester.getCenter(find.text('Read source material'));
    final target = tester.getCenter(find.text('Write report'));
    await tester.dragFrom(source, target - source);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today], isEmpty);
    expect(task(TodoScope.tomorrow).subtasks.single.text, 'Read source material');
    expect(task(TodoScope.tomorrow).dueDate, DateTime(2026, 10, 29));
    expect(find.byTooltip('Collapse subtasks'), findsOneWidget);
    expect(store.todoListsOn(today)[TodoScope.today]!, isEmpty);
    expect(store.todoListsOn(today)[TodoScope.tomorrow]!.single.subtasks.single.text, 'Read source material');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a collapsed task stays collapsed when a task nests under it', (tester) async {
    state.addTodo(TodoScope.today, 'Small task');
    state.addTodo(TodoScope.today, 'Larger task');
    state.setTodoSubtasks(TodoScope.today, state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Larger task'), [
      const TodoSubtask('First step'),
    ]);
    await show(tester);
    expect(find.byTooltip('Expand subtasks'), findsOneWidget);
    expect(find.text('First step'), findsNothing);
    final start = tester.getCenter(find.text('Small task'));
    await tester.dragFrom(start, tester.getCenter(find.text('Larger task')) - start);
    await tester.pumpAndSettle();
    expect(task(TodoScope.today).subtasks.map((s) => s.text), ['First step', 'Small task']);
    expect(find.byTooltip('Expand subtasks'), findsOneWidget);
    expect(find.text('Small task'), findsNothing);
    expect(find.text('0/2 complete'), findsOneWidget);
  });

  testWidgets('a task nests under a task in the same list', (tester) async {
    state.addTodo(TodoScope.today, 'Small task');
    state.addTodo(TodoScope.today, 'Larger task');
    await show(tester);
    final start = tester.getCenter(find.text('Small task'));
    await tester.dragFrom(start, tester.getCenter(find.text('Larger task')) - start);
    await tester.pumpAndSettle();
    expect(task(TodoScope.today).text, 'Larger task');
    expect(task(TodoScope.today).subtasks.single.text, 'Small task');
    expect(tester.takeException(), isNull);
  });

  test('failed nesting rolls back the checklist change and retains the source', () {
    state.addTodo(TodoScope.today, 'Source');
    state.addTodo(TodoScope.week, 'Destination');
    store.raw.execute(
      "CREATE TRIGGER fail_delete BEFORE DELETE ON todos BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    );
    expect(
      () => state.nestTodo(TodoScope.today, task(TodoScope.today), TodoScope.week, task(TodoScope.week)),
      throwsA(isA<Exception>()),
    );
    expect(store.todos(TodoScope.today, dateKey(today)).single.text, 'Source');
    expect(store.todos(TodoScope.week, TodoScope.week.period(today)).single.subtasks, isEmpty);
  });

  testWidgets('a project cannot nest under another task or under itself', (tester) async {
    state.addTodo(TodoScope.today, 'Existing project');
    state.setTodoSubtasks(TodoScope.today, task(TodoScope.today), [const TodoSubtask('Keep this child')]);
    state.addTodo(TodoScope.today, 'Another task');
    await show(tester);
    final source = tester.getCenter(find.text('Existing project'));
    await tester.dragFrom(source, tester.getCenter(find.text('Another task')) - source);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.length, 2);
    expect(state.todos[TodoScope.today]!.first.subtasks.single.text, 'Keep this child');
    final plain = state.todos[TodoScope.today]!.last;
    expect(state.nestTodo(TodoScope.today, plain, TodoScope.today, plain), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a finished project folds away once it has moved, and stays folded when reopened', (tester) async {
    state.addTodo(TodoScope.today, 'Big project');
    state.setTodoSubtasks(TodoScope.today, task(TodoScope.today), [
      const TodoSubtask('Research', done: true),
      const TodoSubtask('Build'),
    ]);
    state.addTodo(TodoScope.today, 'Plain task');
    await show(tester);
    await tester.tap(find.byTooltip('Expand subtasks'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Build'));
    await tester.pump(Motion.reorder ~/ 2);
    expect(find.text('Build'), findsOneWidget, reason: 'still open while it moves');
    await tester.pumpAndSettle();
    expect(find.text('Build'), findsNothing);
    expect(find.byTooltip('Expand subtasks'), findsOneWidget);

    final project = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Big project');
    state.toggleTodo(project);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Expand subtasks'), findsOneWidget);

    // Ticking the project itself folds it too.
    await tester.tap(find.byTooltip('Expand subtasks'));
    await tester.pumpAndSettle();
    state.toggleTodo(state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Big project'));
    await tester.pumpAndSettle();
    expect(find.text('Build'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('subtasks can be added, collapsed, edited and checked independently', (tester) async {
    const screenshots = String.fromEnvironment('SCREENSHOT_DIR');
    if (screenshots.isNotEmpty) {
      final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final family in manifest.cast<Map<String, dynamic>>()) {
        final loader = FontLoader(family['family'] as String);
        for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
          loader.addFont(rootBundle.load(font['asset'] as String));
        }
        await loader.load();
      }
    }
    state.addTodo(TodoScope.today, 'Big project');
    await show(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Big project')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add subtask'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Research');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Research'), findsOneWidget);
    await tester.tap(find.byTooltip('Collapse subtasks'));
    await tester.pumpAndSettle();
    expect(find.text('Research'), findsNothing);
    await tester.tap(find.byTooltip('Expand subtasks'));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.text('Research')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit subtask'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Research details');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Research details'), findsOneWidget);
    await tester.tap(find.text('Research details'));
    await tester.pumpAndSettle();
    expect(task(TodoScope.today).done, isTrue);
    expect(find.text('1/1 complete'), findsOneWidget);
    const dir = String.fromEnvironment('SCREENSHOT_DIR');
    if (dir.isNotEmpty) {
      final view = tester.binding.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      await tester.runAsync(() async {
        final image = await layer.toImage(Offset.zero & view.size);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/subtasks.png').writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(tester.takeException(), isNull);
  });
}
