// State and UI logic found in the 3 Nov 2026 audit (LOGIC-01 to LOGIC-19):
// each test holds the behaviour the spec, or the rest of the app, implies.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/todo_panel.dart';

void main() {
  late Store store;
  late AppState state;
  late DateTime now;
  var opened = false;

  void open(DateTime at) {
    opened = true;
    now = at;
    store = Store.memory();
    state = AppState(store, clock: () => now);
    for (final scope in TodoScope.values) {
      for (final task in [...state.todos[scope]!]) {
        state.removeTodo(scope, task);
      }
    }
    state.hideUndoCard(state.shownRemoval ?? (throw StateError('no removal')));
  }

  tearDown(() {
    if (!opened) return;
    opened = false;
    state.dispose();
    store.close();
  });

  Future<void> show(WidgetTester tester) async {
    collapseAllTasks();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  Future<TestGesture> mouse(WidgetTester tester) async {
    final m = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await m.addPointer(location: Offset.zero);
    addTearDown(m.removePointer);
    return m;
  }

  // LOGIC-01
  testWidgets('adding a step to a checklist repeat in Further ahead keeps its other steps', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    state.addTodo(TodoScope.today, 'Pack');
    final item = state.todos[TodoScope.today]!.single;
    state.setTodoSubtasks(TodoScope.today, item, [const TodoSubtask('Passport'), const TodoSubtask('Tickets')]);
    state.makeRepeating(
      TodoScope.today,
      state.todos[TodoScope.today]!.single,
      'Pack',
      const RepeatRule.monthly(20),
      start: DateTime(2026, 11, 20),
    );
    expect(state.repeats.single.subtasks.map((s) => s.text), ['Passport', 'Tickets']);
    await show(tester);

    // The next time, Fri 20 Nov, is beyond the week: it's in Further ahead.
    final row = find.ancestor(of: find.text('Pack'), matching: find.byType(TaskRow)).first;
    // LOGIC-01b (display): the unmade time is drawn without its checklist.
    final showsSteps = find.descendant(of: row, matching: find.text('0 of 2 subtasks complete')).evaluate().isNotEmpty;
    final m = await mouse(tester);
    await m.moveTo(tester.getCenter(find.text('Pack')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Add subtask')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Subtask'), 'Charger');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This and future ones'));
    await tester.pumpAndSettle();
    expect(state.repeats.single.subtasks.map((s) => s.text), [
      'Passport',
      'Tickets',
      'Charger',
    ], reason: 'the repeat’s checklist template (showed its steps: $showsSteps)');
  });

  // LOGIC-02
  testWidgets('a holiday added in the past can still be seen and removed in Settings', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    await show(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Add').first);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    await tester.tap(find.descendant(of: dialog, matching: find.byIcon(Icons.chevron_left_rounded)));
    await tester.pumpAndSettle();
    expect(find.descendant(of: dialog, matching: find.text('October 2026')), findsOneWidget);
    await tester.tap(find.descendant(of: dialog, matching: find.text('20')));
    await tester.pump();
    await tester.tap(find.descendant(of: dialog, matching: find.text('22')));
    await tester.pump();
    await tester.tap(find.descendant(of: dialog, matching: find.text('Add')));
    await tester.pumpAndSettle();
    expect(state.holidays, hasLength(1), reason: 'it was added');
    expect(find.byTooltip('Remove holiday'), findsOneWidget, reason: 'but there is no way to see or remove it');
  });

  // LOGIC-03
  test('adding a holiday that touches a past one, then removing it, keeps the past rest days', () {
    open(DateTime(2026, 11, 3, 10));
    state.addHoliday(DateTime(2026, 10, 20), DateTime(2026, 11, 2)); // past, hidden in Settings
    state.addHoliday(DateTime(2026, 11, 3), DateTime(2026, 11, 5));
    // The new one stays its own, so its x takes only its days away.
    expect(state.holidays, hasLength(2));
    state.removeHoliday(state.holidays.last);
    expect(state.holidays.single, (start: DateTime(2026, 10, 20), end: DateTime(2026, 11, 2)));
    expect(state.isRestDay(DateTime(2026, 10, 25)), isTrue, reason: 'a past holiday was never removed by the user');
  });

  // LOGIC-04
  testWidgets('a task edit saved just after midnight changes the task, not yesterday’s record', (tester) async {
    open(DateTime(2026, 11, 3, 23, 59));
    state.addTodo(TodoScope.today, 'Buy milk');
    await show(tester);
    final m = await mouse(tester);
    await m.moveTo(tester.getCenter(find.text('Buy milk')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Task'), 'Buy oat milk');
    now = DateTime(2026, 11, 4, 0, 1);
    state.checkDate();
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.map((t) => t.text), ['Buy oat milk']);
  });

  // LOGIC-05
  testWidgets('opening a far Further-ahead task from search scrolls to it and lights it', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    for (var i = 0; i < 16; i++) {
      state.addTodo(TodoScope.month, 'Later task $i', dueDate: DateTime(2026, 11, 12 + i));
    }
    await show(tester);
    expect(find.text('Later task 0'), findsOneWidget, reason: 'sanity: Further ahead shows the first');
    expect(find.text('Later task 15'), findsNothing, reason: 'sanity: the last is below the fold, not built');
    final target = state.todos[TodoScope.month]!.firstWhere((t) => t.text == 'Later task 15');
    state.showFound(DateTime(2026, 11, 27), target.uid!);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Later task 15'), findsOneWidget, reason: 'search said it would scroll to the task and light it');
    expect(find.text('Later task 15').hitTestable(), findsOneWidget, reason: 'scrolled into view');
    await tester.pumpAndSettle();
  });

  // LOGIC-06
  test('a carried timed task reminds the same whether it was added to Today or for a later day', () {
    open(DateTime(2026, 11, 1, 10));
    const quarter = 4; // Reminder.quarterBefore
    // Planned on the 1st for the 3rd, 3 pm.
    state.addTodo(TodoScope.week, 'Planned', dueDate: DateTime(2026, 11, 3), time: 15 * 60, reminders: quarter);
    now = DateTime(2026, 11, 3, 9);
    state.checkDate();
    // Added on the 3rd to Today, 3 pm.
    state.addTodo(TodoScope.today, 'Added today', time: 15 * 60, reminders: quarter);
    now = DateTime(2026, 11, 3, 14, 46);
    state.checkReminders();
    expect(state.reminderCards.map((a) => a.text).toSet(), {'Planned', 'Added today'});
    state.reminderCards.clear();
    // Neither was ticked; both carry into the 4th's Today at 3 pm.
    now = DateTime(2026, 11, 4, 14, 46);
    state.checkDate();
    state.checkReminders();
    final fired = state.reminderCards.map((a) => a.text).toSet();
    expect(fired.contains('Planned'), fired.contains('Added today'), reason: 'fired: $fired');
  });

  // LOGIC-07
  test('dragging a task to another day settles past reminders as editing its day does', () {
    open(DateTime(2026, 11, 3, 22));
    const dayBefore = 1; // Reminder.dayBefore
    for (final name in ['Dragged', 'Edited']) {
      state.addTodo(TodoScope.week, name, dueDate: DateTime(2026, 11, 6), time: 9 * 60, reminders: dayBefore);
    }
    TodoItem task(String name) => state.todos.values.expand((t) => t).firstWhere((t) => t.text == name);
    state.moveTodoTo(TodoScope.week, task('Dragged'), DateTime(2026, 11, 4));
    state.editTodo(TodoScope.week, task('Edited'), 'Edited', DateTime(2026, 11, 4), time: 9 * 60, reminders: dayBefore);
    state.checkReminders();
    final fired = state.reminderCards.map((a) => a.text).toSet();
    expect(fired.contains('Dragged'), fired.contains('Edited'), reason: 'fired: $fired');
  });

  // LOGIC-08: what differs between light and dark themes eases through a
  // fade by the palette's darkness, rather than flipping at its midpoint.
  test('light and dark picks have no step at the midpoint of a theme fade', () {
    for (final (light, dark) in palettePairs) {
      expect(light.darkness, 0);
      expect(dark.darkness, 1);
      final (before, after) = (light.lerp(dark, 0.4999), light.lerp(dark, 0.5001));
      expect((after.darkness - before.darkness).abs(), lessThan(0.001), reason: light.name);
      // The Tile's foot, as drawn.
      Color foot(Palette p) => Color.lerp(p.tile, p.background, p.byDarkness(0.14, 0))!;
      double d(double a, double b) => (a - b).abs() * 255;
      final (x, y) = (foot(before), foot(after));
      expect(
        [d(x.r, y.r), d(x.g, y.g), d(x.b, y.b)].reduce((a, b) => a > b ? a : b),
        lessThan(0.1),
        reason: light.name,
      );
    }
  });

  // LOGIC-09
  testWidgets('a reminder card that goes off while a dialog is open can be seen and clicked, as Undo can', (
    tester,
  ) async {
    open(DateTime(2026, 11, 3, 14));
    state.addTodo(TodoScope.today, 'Dentist', time: 15 * 60, reminders: 4);
    await show(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    now = DateTime(2026, 11, 3, 14, 46);
    state.checkReminders();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.reminderCards.map((a) => a.text), ['Dentist']);
    Finder card() => find.ancestor(of: find.textContaining('In 14 min'), matching: find.byType(Row)).first;
    expect(card(), findsOneWidget, reason: 'the card is drawn');
    final underDialog = card().hitTestable().evaluate().isNotEmpty;
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(card().hitTestable(), findsOneWidget, reason: 'control: with no dialog it can be clicked');
    expect(underDialog, isTrue, reason: 'while the dialog was open the card sat under its barrier');
  });

  // LOGIC-10
  testWidgets('switching Settings ribbons General, Data, General quickly doesn’t throw', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    await show(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Data'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('General'));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });

  // LOGIC-11 (only with "New day starts at 4am")
  test('with a 4am day start, a Today task at 1:00 am reminds at 12:45 am that night', () {
    open(DateTime(2026, 11, 3, 18));
    state.setDayStartHour(4);
    state.addTodo(TodoScope.today, 'Late call', time: 60, reminders: 4);
    now = DateTime(2026, 11, 4, 0, 46); // still "Tuesday · until 4am"
    state.checkDate();
    expect(state.today, DateTime(2026, 11, 3));
    state.checkReminders();
    expect(state.reminderCards.map((a) => a.text), ['Late call']);
  });

  // LOGIC-12
  testWidgets('a birthday further ahead shows its place, as it does in the week', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    state.addTodo(TodoScope.month, 'Ana', dueDate: DateTime(2026, 11, 20), birthday: true, location: 'Rundle Mall');
    await show(tester);
    expect(find.text('Rundle Mall'), findsOneWidget);
    expect(find.text('Birthday'), findsOneWidget);
  });

  // LOGIC-13
  test('dates read day first everywhere', () {
    final today = DateTime(2026, 11, 3);
    expect(dayAndMonth(DateTime(2026, 11, 4), today: today), '4 Nov');
    expect(dayAndMonth(DateTime(2027, 1, 4), today: today), '4 Jan 2027');
    expect(dayAndMonth(DateTime(2026, 11, 4)), '4 Nov 2026');
    expect(shortDay(DateTime(2026, 11, 4), today: today), 'Wed 4 Nov');
  });

  testWidgets('Week ahead heads a day day first', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    state.addTodo(TodoScope.week, 'Soon', dueDate: DateTime(2026, 11, 5));
    await show(tester);
    expect(find.textContaining('5 Nov', findRichText: true), findsOneWidget);
    expect(find.textContaining('Nov 5', findRichText: true), findsNothing);
  });

  // LOGIC-15
  test('one rule files a day under Today, Tomorrow, This week or This month', () {
    final tuesday = DateTime(2026, 11, 3);
    expect(scopeForDay(tuesday, DateTime(2026, 11, 2)), (TodoScope.today, null));
    expect(scopeForDay(tuesday, tuesday), (TodoScope.today, null));
    expect(scopeForDay(tuesday, DateTime(2026, 11, 4)), (TodoScope.tomorrow, null));
    expect(scopeForDay(tuesday, DateTime(2026, 11, 8)), (TodoScope.week, DateTime(2026, 11, 8)));
    expect(scopeForDay(tuesday, DateTime(2026, 11, 9)), (TodoScope.month, DateTime(2026, 11, 9)));
  });

  // LOGIC-19
  test('a 29 February birthday comes round on 28 February in other years', () {
    final repeat = Repeat(
      uid: 'leap',
      text: 'Leap',
      rule: const RepeatRule.yearly(1),
      start: DateTime(2028, 2, 29),
      birthday: true,
    );
    expect(repeat.next(DateTime(2028, 3, 1)), DateTime(2029, 2, 28));
    expect(repeat.on(DateTime(2029, 2, 28)), isTrue);
    expect(repeat.on(DateTime(2029, 3, 1)), isFalse);
    expect(repeat.next(DateTime(2031, 3, 1)), DateTime(2032, 2, 29));
    expect(repeat.on(DateTime(2032, 2, 28)), isFalse, reason: 'a leap year has its own day');
  });

  // LOGIC-14
  testWidgets('every calendar shows six weeks and keeps its arrows put', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    await show(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Add').first);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    final next = find.descendant(of: dialog, matching: find.byTooltip('Next month'));
    final at = tester.getCenter(next);
    // February 2027 fits in four weeks; the arrows don't move.
    for (var i = 0; i < 3; i++) {
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    expect(find.descendant(of: dialog, matching: find.text('February 2027')), findsOneWidget);
    expect(tester.getCenter(next), at);
  });
}
