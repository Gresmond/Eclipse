import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Notifier implements ReminderNotifier {
  final shown = <(String, String)>[];

  @override
  void show(ReminderAlert alert, String body) => shown.add((alert.text, body));

  @override
  set onOpen(void Function(String uid)? open) {}
}

void main() {
  const quarter = 4, hour = 2, day = 1, onTheDay = 8;

  group('what goes off', () {
    final dentist = TodoItem(1, 'Dentist', since: DateTime(2026, 10, 1), uid: 'd', dueTime: 15 * 60);

    List<String> due(TodoItem item, DateTime now, [Set<String> shown = const {}]) => [
      for (final (alert, _) in dueReminders([(item, DateTime(2026, 10, 30))], now, shown)) alert.reminder.name,
    ];

    test('each at its time, and none once the task is due', () {
      dentist.reminders = day | hour | quarter;
      expect(due(dentist, DateTime(2026, 10, 29, 14, 59)), isEmpty);
      expect(due(dentist, DateTime(2026, 10, 29, 15)), ['dayBefore']);
      expect(due(dentist, DateTime(2026, 10, 30, 14, 45)), ['quarterBefore']);
      expect(due(dentist, DateTime(2026, 10, 30, 15)), isEmpty);
    });

    test('missed ones go together as the latest, and once shown, not again', () {
      dentist.reminders = day | hour;
      final now = DateTime(2026, 10, 30, 14, 20);
      final [(alert, keys)] = dueReminders([(dentist, DateTime(2026, 10, 30))], now, {});
      expect(alert.reminder, Reminder.hourBefore);
      expect(keys, hasLength(2));
      expect(alert.body(now), 'In 40 min, at 3:00 pm');
      expect(due(dentist, now, keys.toSet()), isEmpty);
    });

    test('a birthday: the day before, and on the day, at 9am; the day before only that day', () {
      final mum = TodoItem(2, 'Mum', since: DateTime(2026, 10, 1), uid: 'm', birthday: true)
        ..reminders = day | onTheDay;
      expect(due(mum, DateTime(2026, 10, 29, 8, 59)), isEmpty);
      expect(due(mum, DateTime(2026, 10, 29, 9)), ['dayBefore']);
      // Opened late on the day, the day before's has gone.
      expect(due(mum, DateTime(2026, 10, 30, 20)), ['onTheDay']);
      expect(due(mum..reminders = day, DateTime(2026, 10, 30, 20)), isEmpty);
      expect(due(mum..reminders = onTheDay, DateTime(2026, 10, 31)), isEmpty);
    });

    test('no time, no reminders, unless a birthday', () {
      final untimed = TodoItem(3, 'Shop', since: DateTime(2026, 10, 1), uid: 's')..reminders = quarter;
      expect(due(untimed, DateTime(2026, 10, 30, 23)), isEmpty);
    });
  });

  group('in the app', () {
    var now = DateTime(2026, 10, 30, 14);
    late Store store;
    late AppState state;
    late _Notifier notifier;
    setUp(() {
      now = DateTime(2026, 10, 30, 14);
      store = Store.memory();
      notifier = _Notifier();
      state = AppState(store, notifier: notifier, clock: () => now);
    });
    tearDown(() {
      state.dispose();
      store.close();
    });

    test('goes off once, by the system and in the window', () {
      state.addTodo(TodoScope.today, 'Dentist', time: 15 * 60, reminders: quarter);
      state.checkReminders();
      expect(notifier.shown, isEmpty);
      now = DateTime(2026, 10, 30, 14, 45);
      state.checkReminders();
      state.checkReminders();
      expect(notifier.shown, [('Dentist', 'In 15 min, at 3:00 pm')]);
      expect(state.reminderCards.single.text, 'Dentist');
    });

    test('with the window hidden, only by the system', () {
      state.windowOpen = false;
      state.addTodo(TodoScope.today, 'Dentist', time: 15 * 60, reminders: quarter);
      now = DateTime(2026, 10, 30, 14, 50);
      state.checkReminders();
      expect(notifier.shown, hasLength(1));
      expect(state.reminderCards, isEmpty);
    });

    test('one set when its time has already passed stays quiet', () {
      state.addTodo(TodoScope.today, 'Call', time: 14 * 60 + 10, reminders: quarter | hour);
      state.checkReminders();
      expect(notifier.shown, isEmpty);
    });

    test('a ticked task gives none', () {
      state.addTodo(TodoScope.today, 'Dentist', time: 15 * 60, reminders: quarter);
      state.toggleTodo(state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Dentist'));
      now = DateTime(2026, 10, 30, 14, 50);
      state.checkReminders();
      expect(notifier.shown, isEmpty);
    });

    test('a repeat gives every time its reminders, and they sync', () {
      state.addRepeat('Gym', const RepeatRule.every(1), DateTime(2026, 10, 30), time: 18 * 60, reminders: hour);
      final made = store.todos(TodoScope.month, '2026-10').firstWhere((t) => t.text == 'Gym');
      expect(made.reminders, hour);
      now = DateTime(2026, 10, 30, 17, 5);
      state.checkReminders();
      expect(notifier.shown, [('Gym', 'In 55 min, at 6:00 pm')]);

      final other = Store.memory();
      addTearDown(other.close);
      final a = SyncEngine(store, 'a'), b = SyncEngine(other, 'b');
      a.flush();
      b.mergeAll([(a.changesSince(0).values.expand((changes) => changes), 'a')]);
      expect(other.repeats().single.reminders, hour);
    });
  });

  testWidgets('Notify shows once there is a time, under it, and its chips are any of three', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 9));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(FurtherAheadCard), matching: find.byType(TextField));
    await tester.enterText(field, 'Dentist');
    await tester.tap(find.descendant(of: find.byType(FurtherAheadCard), matching: find.byTooltip('Pick a day')));
    await tester.pumpAndSettle();
    expect(find.text('Notify').hitTestable(), findsNothing, reason: 'no time yet');

    await tester.tap(find.text('Add a time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    final notify = find.text('Notify').hitTestable();
    expect(notify, findsOneWidget);
    expect(
      tester.getTopLeft(notify).dy,
      allOf(
        greaterThan(tester.getTopLeft(find.text('9:00 am')).dy),
        lessThan(tester.getTopLeft(find.text('Repeat')).dy),
      ),
      reason: 'under the time, over the repeat',
    );
    await tester.tap(notify);
    await tester.pumpAndSettle();
    expect(find.text('Notify 15 min before'), findsOneWidget);
    await tester.tap(find.text('1 day'));
    await tester.pumpAndSettle();
    expect(find.text('Notify 1 day and 15 min before'), findsOneWidget);
    await tester.tap(find.text('15 min'));
    await tester.pump();
    await tester.tap(find.text('1 day'));
    await tester.pumpAndSettle();
    expect(find.text('Notify 1 day before'), findsOneWidget, reason: 'the last one chosen stays');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    await tester.showKeyboard(field);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final added = store.raw.select("SELECT reminders FROM todos WHERE text = 'Dentist'").single;
    expect(added['reminders'], Reminder.dayBefore.bit);
  });
}
