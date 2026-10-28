import 'package:flutter/material.dart';
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
    expect(find.descendant(of: later, matching: find.text('2 PLANNED')), findsOneWidget);

    await tester.tap(find.byTooltip('Hide birthdays'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: later, matching: find.text('Papa')), findsNothing);
    expect(find.descendant(of: later, matching: find.text('Rego')), findsOneWidget);
    expect(find.descendant(of: later, matching: find.text('1 PLANNED')), findsOneWidget);
    expect(state.laterBirthdays, isFalse);
    expect(AppState(store, clock: () => DateTime(2026, 10, 23, 9)).laterBirthdays, isFalse);
  });

  testWidgets('birthdays open up and close up where they belong in Further ahead', (tester) async {
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
    // Opening from nothing, a row starts with no height, so counts as offstage.
    Finder row(String text) =>
        find.descendant(of: later, matching: find.textContaining(text, skipOffstage: false), skipOffstage: false);
    double top(String text) => tester.getTopLeft(row(text)).dy;
    await tester.tap(find.byTooltip('Show birthdays'));
    await tester.pump();
    // Gran opens up above Party, where she belongs, not at the foot of the
    // day waiting to glide up; Papa's day opens with him.
    final opacities = <double>[];
    for (var i = 0; i < 16; i++) {
      expect(top('Gran'), lessThanOrEqualTo(top('Party')));
      opacities.add(
        tester
            .widget<FadeTransition>(
              find.ancestor(of: row('Papa'), matching: find.byType(FadeTransition, skipOffstage: false)).first,
            )
            .opacity
            .value,
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(opacities.first, lessThan(0.1));
    await tester.pumpAndSettle();
    expect(top('Gran'), lessThan(top('Party')));

    // Hidden, they close up rather than vanish.
    await tester.tap(find.byTooltip('Hide birthdays'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(row('Gran'), findsOneWidget);
    expect(row('Papa'), findsOneWidget);
    await tester.pumpAndSettle();
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

  testWidgets('the date dialog keeps its arrows still, and Birthday repeats yearly', (tester) async {
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
    await tester.pumpAndSettle();
    final next = find.byTooltip('Next month');
    final places = <Offset>[];
    for (var i = 0; i < 6; i++) {
      places.add(tester.getCenter(next));
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    expect(places.toSet(), hasLength(1));

    // Making it a birthday folds the repeat away; it comes round every year.
    expect(find.text("Doesn't repeat").hitTestable(), findsOneWidget);
    await tester.tap(find.text('Not a birthday'));
    await tester.pumpAndSettle();
    expect(find.text("Doesn't repeat").hitTestable(), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(FurtherAheadCard), matching: find.byType(TextField));
    await tester.enterText(field, 'Gran');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final repeat = state.repeats.single;
    expect((repeat.rule, repeat.birthday), (const RepeatRule.yearly(1), true));
  });
}
