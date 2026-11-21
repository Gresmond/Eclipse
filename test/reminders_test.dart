import 'dart:async';

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

  group('passed times before', () {
    final today = DateTime(2026, 11, 18);
    final now = DateTime(2026, 11, 18, 19, 50);

    test('a one-off today drops what has passed', () {
      expect(Reminder.gone(today, 20 * 60 + 30, now), day | hour);
      expect(Reminder.gone(today, 23 * 60, now), day);
      expect(Reminder.gone(DateTime(2026, 11, 19), 9 * 60, now), day);
      expect(Reminder.gone(DateTime(2026, 11, 19), 21 * 60, now), 0);
      expect(Reminder.gone(null, 20 * 60, now), 0);
    });

    test('a time before a 4am day start is after midnight, still to come', () {
      // 1:30 am on today's list is tonight's small hours, 19 Nov.
      expect(Reminder.gone(today, 90, now, startHour: 4), day);
      expect(Reminder.gone(today, 90, now), day | hour | quarter | Reminder.twentyBefore.bit);
      expect(Reminder.gone(today, 5 * 60, now, startHour: 4), day | hour | quarter | Reminder.twentyBefore.bit);
    });

    test('all chosen gone: 15 min stands in, or nothing', () {
      expect(Reminder.given(day, birthday: false, time: 23 * 60, gone: day), quarter);
      expect(Reminder.given(day | hour, birthday: false, time: 23 * 60, gone: day), hour);
      expect(Reminder.given(day, birthday: false, time: 19 * 60 + 55, gone: day | hour | quarter), 0);
      expect(Reminder.given(day, birthday: false, time: 23 * 60), day);
    });
  });

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

    test('held for a sync, then goes off with what it brought, or after the limit', () async {
      state.addTodo(TodoScope.today, 'Dentist', time: 15 * 60, reminders: quarter);
      state.addTodo(TodoScope.today, 'Call', time: 16 * 60, reminders: quarter);
      now = DateTime(2026, 10, 30, 14, 45);
      final sync = Completer<void>();
      state.holdReminders(sync.future);
      state.checkReminders();
      expect(notifier.shown, isEmpty, reason: 'waits for the sync');
      sync.complete();
      await Future<void>.delayed(Duration.zero);
      expect(notifier.shown, hasLength(1), reason: 'goes off as it ends');

      now = DateTime(2026, 10, 30, 15, 45);
      state.holdReminders(Completer<void>().future, limit: const Duration(milliseconds: 10));
      state.checkReminders();
      expect(notifier.shown, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.shown, hasLength(2), reason: 'a stuck sync holds nothing for long');
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

  test('carried-over undated Today task fires reminder when time/reminder is added today', () {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    var now = DateTime(2026, 11, 4, 10);
    final notifier = _Notifier();
    final state = AppState(store, notifier: notifier, clock: () => now);
    addTearDown(state.dispose);

    state.addTodo(TodoScope.today, 'Call bank');
    now = DateTime(2026, 11, 5, 10);
    state.checkDate();

    final carried = state.todos[TodoScope.today]!.single;
    state.editTodo(
      TodoScope.today,
      carried,
      carried.text,
      carried.dueDate,
      time: 15 * 60,
      reminders: Reminder.quarterBefore.bit,
    );

    now = DateTime(2026, 11, 5, 14, 46);
    state.checkReminders();
    expect(notifier.shown, [('Call bank', 'In 14 min, at 3:00 pm')]);
  });

  test('carried-over past-due task anchors dueDate to today when time/reminders change', () {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    var now = DateTime(2026, 11, 4, 10);
    final notifier = _Notifier();
    final state = AppState(store, notifier: notifier, clock: () => now);
    addTearDown(state.dispose);

    state.addTodo(TodoScope.today, 'Submit report', dueDate: DateTime(2026, 11, 4));
    now = DateTime(2026, 11, 5, 10);
    state.checkDate();

    final carried = state.todos[TodoScope.today]!.single;
    state.editTodo(
      TodoScope.today,
      carried,
      carried.text,
      carried.dueDate,
      time: 16 * 60,
      reminders: Reminder.quarterBefore.bit,
    );

    expect(state.todos[TodoScope.today]!.single.dueDate, isNull);
    now = DateTime(2026, 11, 5, 15, 46);
    state.checkReminders();
    expect(notifier.shown, [('Submit report', 'In 14 min, at 4:00 pm')]);
  });

  test('reminderCards prune on edit/complete/delete, openReminder removes all matching cards, and holdReminders guards dispose', () async {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    var now = DateTime(2026, 11, 5, 14);
    final state = AppState(store, clock: () => now);

    state.addTodo(TodoScope.today, 'Dentist', time: 15 * 60, reminders: Reminder.quarterBefore.bit);
    state.addTodo(TodoScope.today, 'Call', time: 16 * 60, reminders: Reminder.quarterBefore.bit);
    now = DateTime(2026, 11, 5, 14, 46);
    state.checkReminders();
    expect(state.reminderCards, hasLength(1));

    // Renaming updates the shown reminder card text.
    var dentist = state.todos[TodoScope.today]!.firstWhere((t) => t.text == 'Dentist');
    state.editTodo(
      TodoScope.today,
      dentist,
      'Orthodontist',
      dentist.dueDate,
      time: dentist.dueTime,
      reminders: dentist.reminders,
    );
    expect(state.reminderCards.single.text, 'Orthodontist');

    // Moving to tomorrow removes the stale card.
    dentist = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Orthodontist');
    state.moveTodoTo(TodoScope.today, dentist, DateTime(2026, 11, 6));
    expect(state.reminderCards, isEmpty);

    // Completing a task removes its card; openReminder removes all cards for that uid.
    now = DateTime(2026, 11, 5, 15, 46);
    state.checkReminders();
    expect(state.reminderCards.single.text, 'Call');
    final call = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Call');
    state.reminderCards.add(state.reminderCards.single);
    state.openReminder(call.uid!);
    expect(state.reminderCards, isEmpty);

    // Malformed remindersShown setting does not crash.
    store.setSetting('remindersShown', '{"not":"a list"}');
    state.checkReminders();
    store.setSetting('remindersShown', '["badkey"]');
    state.checkReminders();

    // Disposing during holdReminders does not throw or notify.
    final sync = Completer<void>();
    state.holdReminders(sync.future);
    state.dispose();
    sync.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('ReminderAlert.body and dueReminders respect dayStartHour', () {
    const startHour = 4;
    final item = TodoItem(
      1,
      'Late call',
      since: DateTime(2026, 11, 3),
      uid: 'late',
      dueTime: 60, // 1:00 am
      reminders: Reminder.dayBefore.bit,
    );
    // 1:00 am on logical day Nov 3 is calendar Nov 4 01:00.
    final calendarDay = DateTime(2026, 11, 4);
    final [(alert, _)] = dueReminders(
      [(item, calendarDay)],
      DateTime(2026, 11, 3, 22),
      const {},
      startHour: startHour,
    );
    expect(alert.body(DateTime(2026, 11, 3, 22), startHour: startHour), 'In 3 hours, at 1:00 am');

    final mum = TodoItem(
      2,
      'Mum',
      since: DateTime(2026, 11, 3),
      uid: 'mum',
      birthday: true,
      reminders: Reminder.dayBefore.bit | Reminder.onTheDay.bit,
    );
    // At 1:00 am on Nov 4 with 4am day start, it's still Nov 3 ("Birthday tomorrow").
    final [(bdayAlert, _)] = dueReminders(
      [(mum, DateTime(2026, 11, 4))],
      DateTime(2026, 11, 4, 1),
      const {},
      startHour: startHour,
    );
    expect(bdayAlert.reminder, Reminder.dayBefore);
    expect(bdayAlert.body(DateTime(2026, 11, 4, 1), startHour: startHour), 'Birthday tomorrow');
  });
}
