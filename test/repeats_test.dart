import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/todo_panel.dart';

void main() {
  test('every so many weeks finds its next time however far apart', () {
    final start = DateTime(2026, 10, 31);
    final repeat = Repeat(uid: 'r', text: 'Renew', rule: const RepeatRule.every(99, weeks: true), start: start);
    expect(repeat.next(start), start);
    expect(repeat.next(DateTime(2026, 11, 1)), DateTime(2028, 9, 23));
    final ended = Repeat(
      uid: 'r',
      text: 'Renew',
      rule: const RepeatRule.every(99, weeks: true),
      start: start,
      until: DateTime(2028, 1, 1),
    );
    expect(ended.next(DateTime(2026, 11, 1)), isNull);
    final days = Repeat(uid: 'd', text: 'Water', rule: const RepeatRule.every(3), start: start);
    expect(days.next(DateTime(2026, 11, 1)), DateTime(2026, 11, 3));
  });

  test('a checklist made repeating keeps its steps, and each time starts unticked', () {
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 31));
    addTearDown(state.dispose);
    List<TodoItem> times() =>
        state.todos.values.expand((items) => items).where((t) => t.text == 'Pack').toList()
          ..sort((a, b) => a.repeatDay!.compareTo(b.repeatDay!));
    List<(String, bool)> steps(TodoItem item) => [for (final s in item.subtasks) (s.text, s.done)];
    TodoScope scopeOf(TodoItem item) => state.todos.entries.firstWhere((e) => e.value.any((t) => t.id == item.id)).key;

    state.addTodo(TodoScope.today, 'Pack');
    var item = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Pack');
    state.setTodoSubtasks(TodoScope.today, item, [
      const TodoSubtask('Passport', done: true),
      const TodoSubtask('Tickets'),
    ]);
    item = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Pack');
    state.makeRepeating(TodoScope.today, item, item.text, const RepeatRule.every(1));
    expect(steps(times()[0]), [('Passport', true), ('Tickets', false)], reason: 'this time keeps its ticks');
    expect(steps(times()[1]), [('Passport', false), ('Tickets', false)]);
    final repeat = state.repeatOf(times()[0])!;
    expect(repeat.subtasks.map((s) => s.text), ['Passport', 'Tickets']);

    // Only this one: the others keep the template.
    final tomorrow = times()[1];
    state.setTodoSubtasks(scopeOf(tomorrow), tomorrow, [...tomorrow.subtasks, const TodoSubtask('Snacks')]);
    expect(steps(times()[1]).length, 3);
    expect(steps(times()[2]).length, 2);

    // This and future ones: later times change too, and a step they had
    // keeps its tick.
    final later = times()[2];
    state.setTodoSubtasks(scopeOf(later), later, [const TodoSubtask('Passport', done: true), later.subtasks[1]]);
    final from = times()[1];
    state.setRepeatSubtasks(scopeOf(from), from, repeat, [const TodoSubtask('Passport'), const TodoSubtask('Charger')]);
    expect(steps(times()[1]), [('Passport', false), ('Charger', false)]);
    expect(steps(times()[2]), [('Passport', true), ('Charger', false)]);
    expect(steps(times()[0]).length, 2, reason: 'times before it stay as they were');
    expect(state.repeatOf(times()[0])!.subtasks.map((s) => (s.text, s.done)), [
      ('Passport', false),
      ('Charger', false),
    ]);
  });

  test('rules come round on their days, and keep their shape', () {
    final start = DateTime(2026, 10, 28); // Wednesday
    final weekly = RepeatRule.weekly({1, 3, 5});
    expect(
      [for (var d = 26; d <= 31; d++) weekly.on(DateTime(2026, 10, d), start)],
      [
        false, // Monday, before it starts
        false,
        true,
        false,
        true,
        false,
      ],
    );
    expect(const RepeatRule.every(2).on(DateTime(2026, 10, 30), start), isTrue);
    expect(const RepeatRule.every(2).on(DateTime(2026, 10, 31), start), isFalse);
    expect(const RepeatRule.every(2, weeks: true).on(DateTime(2026, 11, 11), start), isTrue);
    expect(const RepeatRule.every(2, weeks: true).on(DateTime(2026, 11, 4), start), isFalse);
    // The 31st falls on a shorter month's last day.
    expect(const RepeatRule.monthly(31).on(DateTime(2026, 11, 30), start), isTrue);
    expect(const RepeatRule.monthly(31).on(DateTime(2027, 2, 28), start), isTrue);
    for (final rule in [
      weekly,
      const RepeatRule.every(3),
      const RepeatRule.every(2, weeks: true),
      const RepeatRule.monthly(15),
    ]) {
      expect(RepeatRule.decode(rule.encode()), rule);
    }
    expect(RepeatRule.decode('weekly:'), isNull);
    expect(RepeatRule.decode('monthly:40'), isNull);
    expect(weekly.label, 'Every Mon, Wed, Fri');
    expect(const RepeatRule.monthly(22).label, 'Monthly on the 22nd');
  });

  test('a yearly rule comes round on its date every so many years', () {
    final start = DateTime(2026, 10, 28);
    expect(const RepeatRule.yearly(1).on(DateTime(2027, 10, 28), start), isTrue);
    expect(const RepeatRule.yearly(1).on(DateTime(2027, 10, 29), start), isFalse);
    expect(const RepeatRule.yearly(2).on(DateTime(2027, 10, 28), start), isFalse);
    expect(const RepeatRule.yearly(2).on(DateTime(2028, 10, 28), start), isTrue);
    expect(RepeatRule.decode(const RepeatRule.yearly(3).encode()), const RepeatRule.yearly(3));
    expect(RepeatRule.decode('yearly:0'), isNull);
    expect(const RepeatRule.yearly(1).label, 'Every year');
    expect(const RepeatRule.yearly(5).label, 'Every 5 years');
    final every2 = Repeat(uid: 'a', text: 'Passport', rule: const RepeatRule.yearly(2), start: start);
    expect(every2.next(DateTime(2026, 10, 29)), DateTime(2028, 10, 28));
    expect(every2.next(DateTime(2040, 1, 1)), DateTime(2040, 10, 28));
    final ended = Repeat(
      uid: 'b',
      text: 'x',
      rule: const RepeatRule.yearly(1),
      start: start,
      until: DateTime(2027, 1, 1),
    );
    expect(ended.next(DateTime(2026, 11, 1)), isNull);
    // 29 February falls on the 28th in other years.
    final leap = Repeat(uid: 'c', text: 'Leap day', rule: const RepeatRule.yearly(1), start: DateTime(2028, 2, 29));
    expect(leap.next(DateTime(2028, 3, 1)), DateTime(2029, 2, 28));
    expect(leap.on(DateTime(2029, 2, 28)), isTrue);
    expect(leap.on(DateTime(2029, 3, 1)), isFalse);
  });

  test('every so many months comes round on its date, or a shorter month’s last day', () {
    final start = DateTime(2026, 10, 15);
    const quarterly = RepeatRule.months(3);
    expect(quarterly.on(DateTime(2027, 1, 15), start), isTrue);
    expect(quarterly.on(DateTime(2026, 11, 15), start), isFalse);
    expect(quarterly.on(DateTime(2027, 1, 16), start), isFalse);
    expect(quarterly.on(DateTime(2026, 7, 15), start), isFalse, reason: 'not before it starts');
    expect(RepeatRule.decode(quarterly.encode()), quarterly);
    expect(RepeatRule.decode('months:0'), isNull);
    expect(const RepeatRule.months(1).label, 'Every month');
    expect(quarterly.label, 'Every 3 months');
    final rent = Repeat(uid: 'a', text: 'Rent', rule: quarterly, start: start);
    expect(rent.next(DateTime(2026, 10, 16)), DateTime(2027, 1, 15));
    expect(rent.next(DateTime(2030, 3, 1)), DateTime(2030, 4, 15));
    // Two years apart is more than the day-by-day search would reach.
    final rare = Repeat(uid: 'b', text: 'x', rule: const RepeatRule.months(24), start: start);
    expect(rare.next(DateTime(2026, 10, 16)), DateTime(2028, 10, 15));
    // The 31st falls on a shorter month's last day, and back on the 31st after.
    final end = Repeat(uid: 'c', text: 'x', rule: const RepeatRule.months(1), start: DateTime(2027, 1, 31));
    expect(end.next(DateTime(2027, 2, 1)), DateTime(2027, 2, 28));
    expect(end.next(DateTime(2027, 3, 1)), DateTime(2027, 3, 31));
    expect(end.on(DateTime(2027, 4, 30)), isTrue);
    final ended = Repeat(uid: 'd', text: 'x', rule: quarterly, start: start, until: DateTime(2026, 12, 31));
    expect(ended.next(DateTime(2026, 10, 16)), isNull);
  });

  group('repeating tasks', () {
    var now = DateTime(2026, 10, 28, 9); // Wednesday
    late Store store;
    late AppState state;
    setUp(() {
      now = DateTime(2026, 10, 28, 9);
      store = Store.memory();
      state = AppState(store, clock: () => now);
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

    List<TodoItem> all() => [for (final scope in TodoScope.values) ...state.todos[scope]!];
    List<DateTime?> days(String text) => [
      for (final t in all())
        if (t.text == text) t.repeatDay,
    ]..sort((a, b) => a!.compareTo(b!));

    test('each time is a to-do, made a week ahead', () {
      state.addRepeat('Gym', RepeatRule.weekly({1, 3, 5}), DateTime(2026, 10, 28));
      expect(days('Gym'), [
        DateTime(2026, 10, 28),
        DateTime(2026, 10, 30),
        DateTime(2026, 11, 2),
        DateTime(2026, 11, 4),
      ]);
      expect(state.todos[TodoScope.today]!.single.text, 'Gym', reason: 'today’s is in Today');
      final friday = all().singleWhere((t) => t.repeatDay == DateTime(2026, 10, 30));
      expect(friday.dueDate, DateTime(2026, 10, 30));
      // Beyond the week, only the next time shows, not made yet.
      final repeat = state.repeats.single;
      expect(state.comingOccurrence(repeat, DateTime(2026, 11, 5)), DateTime(2026, 11, 6));
      expect(state.repeatOf(friday), repeat);
    });

    test('missed times pile up in Today; a day starting makes the next ones', () {
      state.addRepeat('Stretch', const RepeatRule.every(1), DateTime(2026, 10, 28));
      now = DateTime(2026, 10, 30, 9);
      state.checkDate();
      final today = state.todos[TodoScope.today]!.where((t) => t.text == 'Stretch').toList();
      expect(
        [for (final t in today) t.repeatDay],
        [DateTime(2026, 10, 28), DateTime(2026, 10, 29), DateTime(2026, 10, 30)],
      );
      expect(days('Stretch').last, DateTime(2026, 11, 6));
    });

    test('a time taken away stays away; ending stops the rest', () {
      state.addRepeat('Water plants', const RepeatRule.every(2), DateTime(2026, 10, 28));
      final repeat = state.repeats.single;
      final first = state.todos[TodoScope.today]!.single;
      state.removeTodo(TodoScope.today, first);
      state.checkDate();
      expect(days('Water plants').first, DateTime(2026, 10, 30), reason: 'not made again');

      state.endRepeat(repeat, DateTime(2026, 11, 1));
      expect(days('Water plants'), [DateTime(2026, 10, 30)]);
      expect(state.repeats.single.until, DateTime(2026, 10, 31));
      now = DateTime(2026, 11, 5, 9);
      state.checkDate();
      expect(days('Water plants'), [DateTime(2026, 10, 30)]);
    });

    test('renaming from a time on, and a new rule from a time on', () {
      state.addRepeat('Read', const RepeatRule.every(1), DateTime(2026, 10, 28));
      final repeat = state.repeats.single;
      state.renameRepeat(repeat, 'Read a chapter', DateTime(2026, 10, 30));
      expect(days('Read'), [DateTime(2026, 10, 28), DateTime(2026, 10, 29)]);
      expect(days('Read a chapter').first, DateTime(2026, 10, 30));

      state.changeRepeat(state.repeats.single, DateTime(2026, 11, 2), 'Read a chapter', RepeatRule.weekly({1}));
      expect(state.repeats, hasLength(2));
      expect(days('Read a chapter'), [
        DateTime(2026, 10, 30),
        DateTime(2026, 10, 31),
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 2),
      ]);
      expect(state.repeats.first.until, DateTime(2026, 11, 1));

      // Without a rule, it stops after that time, which stays.
      final last = all().singleWhere((t) => t.repeatDay == DateTime(2026, 11, 2));
      state.changeRepeat(state.repeatOf(last)!, DateTime(2026, 11, 2), 'Read a chapter', null);
      expect(days('Read a chapter').last, DateTime(2026, 11, 2));
      expect(state.repeatOf(last), isNull);
      expect(state.comingOccurrence(state.repeats.last, DateTime(2026, 11, 3)), isNull);
    });

    test('a task made to repeat starts from its day', () {
      state.addTodo(TodoScope.month, 'Pay rent', dueDate: DateTime(2026, 11, 1));
      final rent = state.todos[TodoScope.week]!.single; // due within the week
      state.makeRepeating(TodoScope.week, rent, 'Pay rent', const RepeatRule.monthly(1));
      expect(days('Pay rent'), [DateTime(2026, 11, 1)]);
      expect(state.comingOccurrence(state.repeats.single, DateTime(2026, 11, 5)), DateTime(2026, 12, 1));
    });

    test('a later time can be taken away or changed before it is made', () {
      state.addRepeat('Bins', RepeatRule.weekly({4}), DateTime(2026, 10, 28));
      final repeat = state.repeats.single;
      final next = state.comingOccurrence(repeat, DateTime(2026, 11, 5))!;
      expect(next, DateTime(2026, 11, 5));
      state.removeTodo(TodoScope.month, state.occurrence(repeat, next));
      expect(state.comingOccurrence(repeat, DateTime(2026, 11, 5)), DateTime(2026, 11, 12));
    });

    test('tasks from before every task had a day go to Today', () {
      final week = store.addTodo(TodoScope.week, DateTime(2026, 10, 28), 'Undated plan');
      store.addTodo(TodoScope.month, DateTime(2026, 10, 28), 'Undated idea');
      state.checkDate();
      now = DateTime(2026, 10, 29, 9);
      state.checkDate();
      expect(state.todos[TodoScope.week], isEmpty);
      expect(state.todos[TodoScope.month], isEmpty);
      expect(state.todos[TodoScope.today]!.map((t) => t.text), containsAll(['Undated plan', 'Undated idea']));
      expect(state.todos[TodoScope.today]!.firstWhere((t) => t.id == week.id).since, DateTime(2026, 10, 28));
    });
  });

  test('both computers make the same times, and a tick on one reaches the other', () {
    final today = DateTime(2026, 10, 28);
    final first = Store.memory(), second = Store.memory();
    addTearDown(first.close);
    addTearDown(second.close);
    final a = SyncEngine(first, 'first'), b = SyncEngine(second, 'second');
    first.addRepeat('Gym', RepeatRule.weekly({3, 5}), today);
    first.makeRepeats(today);
    a.flush();
    b.mergeAll([(a.changesSince(0).values.expand((changes) => changes), 'first')]);
    second.makeRepeats(today);
    b.flush();
    Set<String> uids(Store store) => {
      for (final scope in TodoScope.values)
        for (final t
            in store
                .todos(scope, scope.period(today))
                .followedBy(store.todos(scope, scope.period(DateTime(2026, 11, 4)))))
          if (t.text == 'Gym') t.uid!,
    };
    expect(uids(second), uids(first));
    expect(uids(first), hasLength(3));

    final friday = first.todos(TodoScope.month, '2026-10').singleWhere((t) => t.repeatDay == DateTime(2026, 10, 30));
    first.setTodoDone(friday.id, true, day: today);
    a.flush();
    a.mergeAll([(b.changesSince(0).values.expand((changes) => changes), 'second')]);
    b.mergeAll([(a.changesSince(0).values.expand((changes) => changes), 'first')]);
    expect(uids(first), uids(second), reason: 'no doubles either way');
    expect(second.todos(TodoScope.today, dateKey(today)).singleWhere((t) => t.uid == friday.uid).done, isTrue);
  });

  testWidgets('RepeatPanel lets users click Ends never to set an end date with left-click', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 10, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 12));
    addTearDown(state.dispose);

    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: find.byType(FurtherAheadCard), matching: find.byTooltip('Pick a day')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repeat'));
    await tester.pumpAndSettle();

    expect(find.text('Starts 30 Oct'), findsOneWidget);
    expect(find.text('Ends never'), findsOneWidget);

    // Click 'Ends never' to enter end-date picking mode, then left-click Nov 6 (7 days later).
    await tester.tap(find.text('Ends never'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('6'));
    await tester.pumpAndSettle();

    expect(find.text('Ends 6 Nov'), findsOneWidget);
    expect(find.byTooltip('No end date'), findsOneWidget);
  });

  group('repeat editing and view checks', () {
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
      state.openedTasks.clear();
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

    void packEveryMonth() {
      state.addTodo(TodoScope.today, 'Pack');
      state.setTodoSubtasks(TodoScope.today, state.todos[TodoScope.today]!.single, [
        const TodoSubtask('Passport'),
        const TodoSubtask('Tickets'),
      ]);
      state.makeRepeating(
        TodoScope.today,
        state.todos[TodoScope.today]!.single,
        'Pack',
        const RepeatRule.monthly(20),
        start: DateTime(2026, 11, 20),
      );
    }

    testWidgets('ticking a step of a repeat’s time in Further ahead, not made yet, ticks it', (tester) async {
      open(DateTime(2026, 11, 3, 10));
      packEveryMonth();
      expect(state.todos[TodoScope.month], isEmpty, reason: 'its time on the 20th isn’t made yet');
      await show(tester);

      final row = find.ancestor(of: find.text('Pack'), matching: find.byType(TaskRow)).first;
      await tester.tap(find.descendant(of: row, matching: find.byTooltip('Expand subtasks')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Passport'));
      await tester.pumpAndSettle();

      final made = state.todos[TodoScope.month]!.single;
      expect(made.uid, endsWith('@2026-11-20'));
      expect({for (final s in made.subtasks) s.text: s.done}, {'Passport': true, 'Tickets': false});
      expect(state.repeats.single.subtasks.every((s) => !s.done), isTrue, reason: 'the times after start unticked');
    });

    testWidgets('stopping a repeat and moving its time in one edit does both', (tester) async {
      open(DateTime(2026, 11, 3, 10));
      state.addRepeat('Water the plants', const RepeatRule.every(1), DateTime(2026, 11, 3));
      await show(tester);

      final row = find.ancestor(of: find.text('Water the plants'), matching: find.byType(TaskRow)).first;
      final m = await mouse(tester);
      await m.moveTo(tester.getCenter(find.descendant(of: row, matching: find.text('Water the plants'))));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: row, matching: find.byTooltip('Edit task')));
      await tester.pumpAndSettle();
      final dialog = find.byType(Dialog);
      await tester.tap(find.descendant(of: dialog, matching: find.byTooltip('Stop repeating')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: dialog, matching: find.text('5')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: dialog, matching: find.text('Save')));
      await tester.pumpAndSettle();

      final left = [
        for (final scope in TodoScope.values)
          for (final item in state.todos[scope]!)
            if (item.text == 'Water the plants') item,
      ];
      expect(left.map((t) => t.dueDate), [DateTime(2026, 11, 5)], reason: 'the one time left, on its new day');
      now = DateTime(2026, 11, 12, 10);
      state.checkDate();
      expect([
        for (final scope in TodoScope.values)
          for (final item in state.todos[scope]!)
            if (item.text == 'Water the plants') item,
      ], hasLength(1));
    });

    testWidgets('looking back, Further ahead counts its days from the day shown', (tester) async {
      open(DateTime(2026, 11, 3, 10));
      state.addTodo(TodoScope.month, 'Dentist', dueDate: DateTime(2026, 11, 20));
      now = DateTime(2026, 11, 25, 10);
      state.checkDate();
      await show(tester);
      state.showDay(DateTime(2026, 11, 3));
      await tester.pumpAndSettle();

      expect(find.text('Dentist'), findsOneWidget, reason: 'as the 3rd had it');
      expect(find.text('In 17 days'), findsOneWidget);
      expect(find.textContaining('In -'), findsNothing);
    });
  });

  test('changeRepeat preserves note, subtask progress/notes, and carried-over occurrences', () {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    var now = DateTime(2026, 11, 1, 9);
    final state = AppState(store, clock: () => now);
    addTearDown(state.dispose);

    state.addRepeat('Pack', const RepeatRule.every(1), DateTime(2026, 11, 1));
    now = DateTime(2026, 11, 3, 9);
    state.checkDate();

    final nov3 = state.todos[TodoScope.today]!.firstWhere((t) => t.repeatDay == DateTime(2026, 11, 3));
    state.setTodoNote(TodoScope.today, nov3, 'Keep this note');
    state.setTodoSubtasks(TodoScope.today, nov3, const [
      TodoSubtask('Passport', done: true, note: 'Top drawer'),
      TodoSubtask('Tickets'),
    ]);
    final repeat = state.repeatOf(nov3)!;
    state.changeRepeat(repeat, DateTime(2026, 11, 3), 'Pack', const RepeatRule.every(2));

    final carried = state.todos[TodoScope.today]!.where((t) => t.repeatDay == DateTime(2026, 11, 1)).toList();
    expect(carried, hasLength(1));

    final updated = state.todos[TodoScope.today]!.firstWhere((t) => t.repeatDay == DateTime(2026, 11, 3));
    expect(updated.note, 'Keep this note');
    expect(updated.subtasks.first.done, isTrue);
    expect(updated.subtasks.first.note, 'Top drawer');
  });

  test('makeRepeating handles TodoScope.tomorrow, completed tasks, and holiday starts', () {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 5, 9));
    addTearDown(state.dispose);

    state.addHoliday(DateTime(2026, 11, 6), DateTime(2026, 11, 6));
    state.addTodo(TodoScope.tomorrow, 'Stretch');
    final tomorrowItem = state.todos[TodoScope.tomorrow]!.single;
    state.makeRepeating(TodoScope.tomorrow, tomorrowItem, 'Stretch', const RepeatRule.every(1));
    expect(state.repeats.single.start, DateTime(2026, 11, 6));
    expect(state.todos[TodoScope.tomorrow], isEmpty);
    expect(
      state.todos.values.expand((l) => l).any((t) => t.repeatDay == DateTime(2026, 11, 7) && t.text == 'Stretch'),
      isTrue,
    );

    state.addTodo(TodoScope.today, 'Vitamins');
    final doneItem = state.todos[TodoScope.today]!.single;
    state.toggleTodo(doneItem);
    state.makeRepeating(
      TodoScope.today,
      state.todos[TodoScope.today]!.single,
      'Vitamins',
      const RepeatRule.every(1),
    );
    final todayOcc = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Vitamins');
    expect(todayOcc.done, isTrue);
    expect(todayOcc.repeatDay, DateTime(2026, 11, 5));
  });
}
