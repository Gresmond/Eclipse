import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/models.dart';

void main() {
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
      expect(state.nextOccurrence(repeat, DateTime(2026, 11, 5)), DateTime(2026, 11, 6));
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
      expect(state.nextOccurrence(state.repeatOf(last)!, DateTime(2026, 11, 3)), isNull);
    });

    test('a task made to repeat starts from its day', () {
      state.addTodo(TodoScope.month, 'Pay rent', dueDate: DateTime(2026, 11, 1));
      final rent = state.todos[TodoScope.week]!.single; // due within the week
      state.makeRepeating(TodoScope.week, rent, 'Pay rent', const RepeatRule.monthly(1));
      expect(days('Pay rent'), [DateTime(2026, 11, 1)]);
      expect(state.nextOccurrence(state.repeats.single, DateTime(2026, 11, 5)), DateTime(2026, 12, 1));
    });

    test('a later time can be taken away or changed before it is made', () {
      state.addRepeat('Bins', RepeatRule.weekly({4}), DateTime(2026, 10, 28));
      final repeat = state.repeats.single;
      final next = state.nextOccurrence(repeat, DateTime(2026, 11, 5))!;
      expect(next, DateTime(2026, 11, 5));
      state.removeTodo(TodoScope.month, state.occurrence(repeat, next));
      expect(state.nextOccurrence(repeat, DateTime(2026, 11, 5)), DateTime(2026, 11, 12));
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
}
