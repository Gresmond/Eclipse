import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/category_label.dart';
import 'package:eclipse/widgets/todo_panel.dart';

void main() {
  test('a task keeps its time and category, and they reach the other computer', () {
    final today = DateTime(2026, 10, 28);
    final first = Store.memory(), second = Store.memory();
    addTearDown(first.close);
    addTearDown(second.close);
    final a = SyncEngine(first, 'first'), b = SyncEngine(second, 'second');
    final item = first.addTodo(TodoScope.month, today, 'Dentist');
    first.editTodo(
      item.id,
      'Dentist',
      DateTime(2026, 11, 20),
      today,
      time: 15 * 60 + 30,
      category: TaskCategory.appointment,
    );
    first.addRepeat(
      'Mum',
      const RepeatRule.yearly(1),
      DateTime(2026, 12, 3),
      time: 9 * 60,
      category: TaskCategory.birthday,
    );
    a.flush();
    b.mergeAll([(a.changesSince(0).values.expand((changes) => changes), 'first')]);

    final there = second.todos(TodoScope.month, '2026-10').single;
    expect((there.dueTime, there.category), (15 * 60 + 30, TaskCategory.appointment));
    final repeat = second.repeats().single;
    expect((repeat.time, repeat.category), (9 * 60, TaskCategory.birthday));

    // Its times are made with them.
    second.makeOccurrence(repeat, DateTime(2026, 12, 3));
    final made = second.todos(TodoScope.month, '2026-12').singleWhere((t) => t.text == 'Mum');
    expect((made.dueTime, made.category), (9 * 60, TaskCategory.birthday));

    // And the history keeps them.
    final lists = second.todoListsOn(today);
    final dentist = lists[TodoScope.month]!.singleWhere((t) => t.text == 'Dentist');
    expect((dentist.dueTime, dentist.category), (15 * 60 + 30, TaskCategory.appointment));
  });

  testWidgets('timed tasks lead their day, and Further ahead filters by category', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 9));
    final friday = DateTime(2026, 10, 28);
    state.addTodo(TodoScope.week, 'Untimed', dueDate: friday);
    state.addTodo(TodoScope.week, 'Afternoon', dueDate: friday, time: 15 * 60 + 30);
    state.addTodo(TodoScope.week, 'Morning', dueDate: friday, time: 8 * 60);
    state.addTodo(TodoScope.month, 'Party', dueDate: DateTime(2026, 11, 20), category: TaskCategory.event);
    state.addTodo(TodoScope.month, 'Rego', dueDate: DateTime(2026, 11, 21), category: TaskCategory.bill);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final week = find.byType(WeekCard);
    double top(String text) => tester.getTopLeft(find.descendant(of: week, matching: find.textContaining(text))).dy;
    expect(top('Morning'), lessThan(top('Afternoon')));
    expect(top('Afternoon'), lessThan(top('Untimed')));
    expect(find.descendant(of: week, matching: find.textContaining('3:30 pm')), findsOneWidget);

    final later = find.byType(FurtherAheadCard);
    expect(find.descendant(of: later, matching: find.text('Party')), findsOneWidget);
    await tester.tap(find.descendant(of: later, matching: find.text('Bill')).first);
    await tester.pumpAndSettle();
    expect(find.descendant(of: later, matching: find.text('Party')), findsNothing);
    expect(find.descendant(of: later, matching: find.text('Rego')), findsOneWidget);
    expect(state.laterFilter, {TaskCategory.bill});
  });

  testWidgets('Further ahead shows a repeat once, every row alike', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 28, 9));
    // A week away: made already, but past the end of the week.
    state.addRepeat('Papa', const RepeatRule.yearly(1), DateTime(2026, 11, 4), category: TaskCategory.birthday);
    state.addTodo(TodoScope.month, 'Dentist', dueDate: DateTime(2026, 11, 20), category: TaskCategory.appointment);
    expect(state.todos[TodoScope.month]!.where((t) => t.text == 'Papa'), hasLength(1));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final later = find.byType(FurtherAheadCard);
    expect(find.descendant(of: later, matching: find.text('Papa')), findsOneWidget);
    expect(find.descendant(of: later, matching: find.textContaining('2027')), findsNothing);
    final labels = find.descendant(of: later, matching: find.byType(CategoryLabel));
    expect(labels, findsNWidgets(2));
    expect(tester.getRect(labels.first).right, tester.getRect(labels.last).right);
  });

  testWidgets('the date dialog keeps its arrows still from month to month', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 9));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(FurtherAheadCard), matching: find.byTooltip('Pick a day')));
    await tester.pumpAndSettle();
    final next = find.byTooltip('Next month');
    final places = <Offset>[];
    for (var i = 0; i < 6; i++) {
      places.add(tester.getCenter(next));
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    expect(places.toSet(), hasLength(1));

    // Categories wait behind "Add a category"; Birthday sets it to come
    // round every year.
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Birthday')), findsNothing);
    await tester.tap(find.text('Add a category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Birthday').last);
    await tester.pumpAndSettle();
    expect(find.text('Every year'), findsOneWidget);
  });
}
