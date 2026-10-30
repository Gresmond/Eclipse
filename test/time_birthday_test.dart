import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/todo_panel.dart';

void main() {
  test('a task keeps its time and birthday, and they reach the other computer', () {
    final today = DateTime(2026, 10, 28);
    final first = Store.memory(), second = Store.memory();
    addTearDown(first.close);
    addTearDown(second.close);
    final a = SyncEngine(first, 'first'), b = SyncEngine(second, 'second');
    final item = first.addTodo(TodoScope.month, today, 'Dentist');
    first.editTodo(item.id, 'Dentist', DateTime(2026, 11, 20), today, time: 15 * 60 + 30);
    first.addRepeat('Mum', const RepeatRule.yearly(1), DateTime(2026, 12, 3), time: 9 * 60, birthday: true);
    a.flush();
    b.mergeAll([(a.changesSince(0).values.expand((changes) => changes), 'first')]);

    final there = second.todos(TodoScope.month, '2026-10').single;
    expect((there.dueTime, there.birthday), (15 * 60 + 30, false));
    final repeat = second.repeats().single;
    expect((repeat.time, repeat.birthday), (9 * 60, true));

    // Its times are made with them.
    second.makeOccurrence(repeat, DateTime(2026, 12, 3));
    final made = second.todos(TodoScope.month, '2026-12').singleWhere((t) => t.text == 'Mum');
    expect((made.dueTime, made.birthday), (9 * 60, true));

    // And the history keeps them.
    final lists = second.todoListsOn(today);
    final dentist = lists[TodoScope.month]!.singleWhere((t) => t.text == 'Dentist');
    expect(dentist.dueTime, 15 * 60 + 30);
  });

  test('categories from before birthdays: only Birthday carries over', () {
    final store = Store.memory();
    addTearDown(store.close);
    final today = DateTime(2026, 10, 28);
    final party = store.addTodo(TodoScope.month, today, 'Party');
    final mum = store.addTodo(TodoScope.month, today, 'Mum');
    store.raw.execute("UPDATE todos SET category = 'event' WHERE id = ?", [party.id]);
    store.raw.execute("UPDATE todos SET category = 'birthday' WHERE id = ?", [mum.id]);
    final todos = store.todos(TodoScope.month, '2026-10');
    expect({for (final t in todos) t.text: t.birthday}, {'Party': false, 'Mum': true});
  });

  testWidgets('Further ahead ticks like the week, and a ticked task goes to Today; birthdays stay as they are', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 9));
    state.addTodo(TodoScope.month, 'Rego', dueDate: DateTime(2026, 11, 21));
    state.addRepeat('Rates', const RepeatRule.yearly(1), DateTime(2026, 11, 25));
    state.addRepeat('Papa', const RepeatRule.yearly(1), DateTime(2026, 11, 20), birthday: true);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final week = find.byType(WeekCard), later = find.byType(FurtherAheadCard);
    Finder row(String text) => find.ancestor(of: find.text(text), matching: find.byType(TaskRow));
    expect(find.descendant(of: later, matching: row('Rego')), findsOneWidget);
    expect(find.descendant(of: later, matching: row('Rates')), findsOneWidget);
    expect(find.descendant(of: later, matching: row('Papa')), findsNothing);

    // A task ticks off into Today.
    await tester.tap(find.descendant(of: later, matching: find.text('Rego')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: later, matching: find.text('Rego')), findsNothing);
    expect(find.descendant(of: week, matching: find.text('Rego')), findsOneWidget);
    expect(state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Rego').done, isTrue);

    // A repeat's next time is made as it's ticked, and goes the same way.
    await tester.tap(find.descendant(of: later, matching: find.text('Rates')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: later, matching: find.text('Rates')), findsNothing);
    expect(find.descendant(of: week, matching: find.text('Rates')), findsOneWidget);
    final rates = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Rates');
    expect((rates.done, rates.repeatDay), (true, DateTime(2026, 11, 25)));

    // Unticked, it goes back to its day.
    await tester.tap(find.descendant(of: week, matching: find.text('Rego')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: later, matching: row('Rego')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timed tasks lead their day, and Further ahead hides birthdays', (tester) async {
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
    state.addTodo(TodoScope.month, 'Rego', dueDate: DateTime(2026, 11, 21));
    state.addRepeat('Papa', const RepeatRule.yearly(1), DateTime(2026, 11, 20), birthday: true);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final week = find.byType(WeekCard);
    double top(String text) => tester.getTopLeft(find.descendant(of: week, matching: find.textContaining(text))).dy;
    expect(top('Morning'), lessThan(top('Afternoon')));
    expect(top('Afternoon'), lessThan(top('Untimed')));
    expect(find.descendant(of: week, matching: find.textContaining('3:30 pm')), findsOneWidget);

    // A birthday has its own mark and no "Every year" under it.
    final later = find.byType(FurtherAheadCard);
    expect(find.descendant(of: later, matching: find.text('Papa')), findsOneWidget);
    expect(find.descendant(of: later, matching: find.text('Every year')), findsNothing);
    expect(find.descendant(of: later, matching: find.byIcon(Icons.celebration_rounded)), findsNWidgets(2));
    expect(find.descendant(of: later, matching: find.bySemanticsLabel('2 PLANNED')), findsOneWidget);

    await tester.tap(find.byTooltip('Hide birthdays'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: later, matching: find.text('Papa')), findsNothing);
    expect(find.descendant(of: later, matching: find.text('Rego')), findsOneWidget);
    expect(find.descendant(of: later, matching: find.bySemanticsLabel('1 PLANNED')), findsOneWidget);
    expect(state.laterBirthdays, isFalse);
    expect(AppState(store, clock: () => DateTime(2026, 10, 23, 9)).laterBirthdays, isFalse);
  });

  testWidgets('birthdays pop in and out of Further ahead at once, where they belong', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 9));
    state.addTodo(TodoScope.month, 'Party', dueDate: DateTime(2026, 11, 20), time: 18 * 60);
    state.addTodo(TodoScope.month, 'Gran', dueDate: DateTime(2026, 11, 20), time: 8 * 60, birthday: true);
    state.addRepeat('Papa', const RepeatRule.yearly(1), DateTime(2026, 11, 1), birthday: true);
    state.toggleLaterBirthdays();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final later = find.byType(FurtherAheadCard);
    Finder row(String text) => find.descendant(of: later, matching: find.textContaining(text));
    double top(String text) => tester.getTopLeft(row(text)).dy;
    // Shown, they're there on the next frame, fully drawn, above Party.
    await tester.tap(find.byTooltip('Show birthdays'));
    await tester.pump();
    expect(top('Gran'), lessThan(top('Party')));
    final heights = [tester.getSize(later).height, top('Party')];
    for (final name in ['Gran', 'Papa']) {
      final fades = find.ancestor(of: row(name), matching: find.byType(FadeTransition));
      for (final fade in tester.widgetList<FadeTransition>(fades)) {
        expect(fade.opacity.value, 1);
      }
    }
    await tester.pumpAndSettle();
    expect([tester.getSize(later).height, top('Party')], heights);

    // Hidden, they're gone on the next frame.
    await tester.tap(find.byTooltip('Hide birthdays'));
    await tester.pump();
    expect(row('Gran'), findsNothing);
    expect(row('Papa'), findsNothing);
    expect(row('Party'), findsOneWidget);
  });

  testWidgets('in the week, a birthday looks like any other task', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 28, 9));
    state.addRepeat('Papa', const RepeatRule.yearly(1), DateTime(2026, 10, 30), birthday: true);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final week = find.byType(WeekCard);
    expect(find.descendant(of: week, matching: find.text('Papa')), findsOneWidget);
    expect(find.descendant(of: week, matching: find.text('Every year')), findsNothing);
    expect(find.descendant(of: week, matching: find.byIcon(Icons.repeat_rounded)), findsNothing);
  });

  testWidgets('the date dialog only fades in, and Birthday repeats yearly', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 9));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    // Only a task further ahead can be a birthday.
    await tester.tap(find.descendant(of: find.byType(WeekCard), matching: find.byTooltip('Pick a day')));
    await tester.pumpAndSettle();
    expect(find.text('Not a birthday'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(FurtherAheadCard), matching: find.byTooltip('Pick a day')));
    // It only fades in, never slides.
    final opening = <Offset>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      opening.add(tester.getCenter(find.byTooltip('Next month')));
    }
    expect(opening.toSet(), hasLength(1));
    await tester.pumpAndSettle();

    // Making it a birthday folds the time and repeat away; it comes round
    // every year, all day.
    expect(find.text('Doesn’t repeat').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Not a birthday'));
    await tester.pumpAndSettle();
    expect(find.text('Doesn’t repeat').hitTestable(), findsNothing);
    expect(find.text('Add a time').hitTestable(), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(FurtherAheadCard), matching: find.byType(TextField));
    await tester.enterText(field, 'Gran');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final repeat = state.repeats.single;
    expect((repeat.rule, repeat.birthday), (const RepeatRule.yearly(1), true));
  });

  testWidgets('time, repeat and its last day open in place, not in dialogs on top', (tester) async {
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
    final panel = find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first;
    final width = tester.getSize(panel).width;

    await tester.tap(find.text('Add a time'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Clear time'), findsNothing, reason: 'Cancel does that');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget, reason: 'Escape goes back, not out');
    expect(find.text('Add a time'), findsNothing, reason: 'opening it set a time');

    // Cancel goes back too, but puts back what the page changed.
    await tester.tap(find.text('Doesn’t repeat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget, reason: 'Cancel goes back one step');
    expect(find.text('Doesn’t repeat'), findsOneWidget, reason: 'and undoes the repeat');
    expect(find.text('Add a time'), findsNothing, reason: 'but not the time, kept before');

    await tester.tap(find.text('Doesn’t repeat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('months'));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, width, reason: 'one width throughout, as Settings');
    await tester.tap(find.text('No end date'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Repeat until'), findsOneWidget);
    await tester.tap(find.text('31'));
    await tester.pumpAndSettle();
    expect(find.text('Until 31/12/2026'), findsNothing);
    expect(find.textContaining('Until 31/'), findsOneWidget, reason: 'a day goes back to the repeat');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Every 2 months until'), findsOneWidget, reason: 'Save keeps it and goes back');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing, reason: 'and on the main page, it confirms');
  });

  testWidgets("a day's line in Week ahead is a field from the start, with only a time", (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 9));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final week = find.byType(WeekCard);
    final line = find.descendant(of: week, matching: find.byType(TextField)).first;
    expect(
      find.descendant(of: line, matching: find.text('Add task')),
      findsOneWidget,
      reason: 'its look before a click',
    );
    expect(
      find.descendant(of: week, matching: find.byTooltip('Add a time')),
      findsNothing,
      reason: 'until clicked',
    );
    final before = tester.getRect(line);
    await tester.tap(line);
    await tester.pumpAndSettle();
    final after = tester.getRect(line);
    expect((after.top, after.height), (before.top, before.height), reason: 'clicking it only puts the cursor in');
    await tester.enterText(line, 'Call the bank');

    expect(find.descendant(of: week, matching: find.byTooltip('Time, repeat and birthday')), findsNothing);
    await tester.tap(find.descendant(of: week, matching: find.byTooltip('Add a time')).first);
    await tester.pumpAndSettle();
    expect(find.text('Doesn’t repeat'), findsNothing, reason: 'only a time');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: week, matching: find.text('9:00 am')), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final task = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Call the bank');
    expect(task.dueTime, 9 * 60);
  });
}
