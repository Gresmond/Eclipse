import 'dart:convert';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/progress_ring.dart';
import 'package:eclipse/widgets/smooth_task_scroll.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    final store = Store.memory();
    addTearDown(store.close);
    final day = DateTime(2026, 10, 26);
    final first = store.addTodo(TodoScope.today, day, 'First');
    final second = store.addTodo(TodoScope.today, day, 'Second');
    store.setTodoDone(second.id, true, day: day);
    store.setTodoDone(first.id, true, day: day);
    expect(sortTodos(store.todos(TodoScope.today, dateKey(day))).map((t) => t.text), ['Second', 'First']);

    final ticked = store.todos(TodoScope.today, dateKey(day)).firstWhere((t) => t.id == second.id).doneAt;
    expect(ticked, isNotNull);
    store.setTodoDone(second.id, true, day: day, cascade: false);
    expect(store.todos(TodoScope.today, dateKey(day)).firstWhere((t) => t.id == second.id).doneAt, ticked);
    expect(store.todoListsOn(day)[TodoScope.today]!.firstWhere((t) => t.id == second.id).doneAt, ticked);

    store.setTodoDone(second.id, false, day: day);
    expect(store.todos(TodoScope.today, dateKey(day)).firstWhere((t) => t.id == second.id).doneAt, isNull);
  });

  test('existing text is formatted without losing history, and ritual dates sync', () {
    final temp = Directory.systemTemp.createTempSync('eclipse-formatting');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}/app.db';
    var store = Store.open(path);
    final habit = store.addHabit(2026, 10, 'lowercase ritual', addedOn: DateTime(2026, 10, 26));
    store.setEntry('2026-10-26', habit.id, HabitStatus.other);
    store.setNote('2026-10-26', habit.id, 'lowercase note');
    store.setJournal('2026-10-26', 'lowercase journal: 6\' 2"');
    store.raw.execute("INSERT INTO todos (uid, scope, period, text, since, subtasks) VALUES (?, ?, ?, ?, ?, ?)", [
      'test-task',
      'today',
      '2026-10-26',
      'measure 6\' 2"',
      '2026-10-26',
      TodoSubtask.encode([const TodoSubtask('lowercase step')]),
    ]);
    store.raw.execute('INSERT INTO todo_history VALUES (?, ?, ?)', [
      'test-task',
      '2026-10-26',
      jsonEncode({
        'text': 'measure 6\' 2"',
        'subtasks': TodoSubtask.encode([const TodoSubtask('lowercase step')]),
      }),
    ]);
    store.raw.execute('PRAGMA user_version = 14');
    store.close();
    store = Store.open(path);
    addTearDown(store.close);
    expect(store.monthHabits(2026, 10).single.name, 'Lowercase ritual');
    expect(store.journal('2026-10-26'), 'Lowercase journal: 6’ 2”');
    expect(store.todos(TodoScope.today, '2026-10-26').single.text, 'Measure 6’ 2”');
    expect(store.todos(TodoScope.today, '2026-10-26').single.subtasks.single.text, 'Lowercase step');
    final snapshot = jsonDecode(store.raw.select('SELECT snapshot FROM todo_history').single['snapshot'] as String);
    expect(snapshot['text'], 'Measure 6’ 2”');
    final sender = SyncEngine(store, 'a')..claimAll();
    final other = Store.memory();
    addTearDown(other.close);
    final receiver = SyncEngine(other, 'b')..clearForJoining();
    receiver.mergeAll([(sender.changesSince(0).values.expand((v) => v).toList(), 'a')]);
    expect(other.monthHabits(2026, 10).single.addedOn, DateTime(2026, 10, 26));
    other.copyMonth((2026, 10), (2026, 11));
    expect(other.monthHabits(2026, 11).single.addedOn, isNull);
  });

  test('days before a ritual was added are greyed out and left out of its score', () {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 10, 'Read', addedOn: DateTime(2026, 10, 20));
    expect(habit.startedBy(DateTime(2026, 10, 19)), isFalse);
    expect(habit.startedBy(DateTime(2026, 10, 20, 9)), isTrue);
    store.setEntry('2026-10-12', habit.id, HabitStatus.missed);
    store.setEntry('2026-10-21', habit.id, HabitStatus.done);
    expect(store.monthScores(2026, 10)[habit.id], (1, 1));
    expect(store.habitBeforeYear(habit.id, 2026), isFalse);
    expect(store.habitBeforeYear(habit.id, 2027), isTrue);
  });

  testWidgets('completion celebrates immediately and fades when unticked', (tester) async {
    Future<void> show(int done) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(palettes.first),
        home: Scaffold(body: ProgressRing(done: done, total: 1)),
      ),
    );
    double solid() {
      final paint = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere((w) => w.painter.runtimeType.toString() == '_RingPainter');
      return (paint.painter as dynamic).solid as double;
    }

    await show(0);
    await tester.pumpAndSettle();
    await show(1);
    expect(solid(), 1);
    await tester.pumpAndSettle();
    await show(0);
    await tester.pumpAndSettle();
    expect(solid(), 0);
  });

  testWidgets('wheel and edge scrolling work during an actual task drag', (tester) async {
    final store = Store.memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 26));
    addTearDown(() {
      state.dispose();
      store.close();
    });
    for (final item in [...state.todos[TodoScope.today]!]) {
      state.removeTodo(TodoScope.today, item);
    }
    for (var i = 0; i < 40; i++) {
      state.addTodo(TodoScope.today, 'Task $i');
    }
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(palettes.first),
          home: const Scaffold(
            body: SizedBox(width: 420, height: 500, child: TodoPanel(scope: TodoScope.today)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: find.byType(SmoothTaskScroll), matching: find.byType(Scrollable)),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.text('Task 0')));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final bounds = tester.getRect(find.byType(SmoothTaskScroll));
    await tester.sendEventToBinding(PointerScrollEvent(position: bounds.center, scrollDelta: const Offset(0, 100)));
    await tester.pump();
    expect(scroll.position.pixels, closeTo(100, 0.01));
    final beforeEdge = scroll.position.pixels;
    await gesture.moveTo(Offset(bounds.center.dx, bounds.bottom - 5));
    await tester.pump(const Duration(milliseconds: 160));
    expect(scroll.position.pixels, greaterThan(beforeEdge));
    await gesture.moveTo(const Offset(600, 550));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(SmoothTaskScroll.dragPosition.value, isNull);
  });
}
