import 'dart:async';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/startup_error.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/phone/phone_app.dart';
import 'package:eclipse/widgets/rolling_number.dart';
import 'package:eclipse/widgets/tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  (Store, AppState) make() {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 6, 9));
    addTearDown(state.dispose);
    state.endTour();
    return (store, state);
  }

  Future<void> show(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(PhoneApp(state: state, schedule: (_) async {}));
    await tester.pumpAndSettle();
  }

  testWidgets('phone draws while opening storage and offers retry if storage is unavailable', (tester) async {
    final directory = Completer<Directory>();
    final startup = phoneMain(supportDirectory: () => directory.future);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    directory.completeError(const FileSystemException('Storage unavailable'));
    await startup;
    await tester.pump();
    expect(tester.widget<StartupErrorApp>(find.byType(StartupErrorApp)).onRetry, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in-app capture previews and saves a timed recurring task', (tester) async {
    final (store, state) = make();
    await show(tester, state);
    await tester.tap(find.byTooltip('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Train every Monday at 8pm at Gym and remind me 20 minutes before');
    await tester.pump();
    expect(find.textContaining('Gym · Every Mon · Remind Mon 9 Nov at 7:40 pm'), findsOneWidget);
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    final series = store.repeats().single;
    expect((series.text, series.start, series.time), ('Train', DateTime(2026, 11, 9), 1200));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('tapping a ritual goes round its marks', (tester) async {
    final (_, state) = make();
    await show(tester, state);
    final read = state.habits.single;
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, read), HabitStatus.done);
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, read), HabitStatus.missed);
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, read), HabitStatus.other);
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, read), HabitStatus.none);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a task is added for tomorrow, and one for today can be ticked', (tester) async {
    final (_, state) = make();
    await show(tester, state);
    await tester.tap(find.byTooltip('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    final added = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Buy milk');

    await tester.dragUntilVisible(find.text('Buy milk'), find.byType(ListView), const Offset(0, -200));
    await tester.tap(find.text('Buy milk'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.singleWhere((t) => t.id == added.id).done, isTrue);

    await tester.tap(find.byTooltip('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Call Sam');
    await tester.tap(find.text('Tomorrow'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.map((t) => t.text), isNot(contains('Call Sam')));
    expect(state.todos.values.expand((list) => list).map((t) => t.text), contains('Call Sam'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Plan, Training and Journal share the desktop records', (tester) async {
    final (store, state) = make();
    state.addTodo(TodoScope.tomorrow, 'Pack gym shoes');
    final exercise = state.training.createExercise('Squat', MuscleGroup.quads, bodyweight: false);
    state.training.addSet(DateTime(2026, 11, 5), exercise, reps: 8, loggedWeight: 62.25);
    state.training.addToDay(state.today, exercise);
    store.setSetting('restSeconds', '0');
    await show(tester, state);
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.text('Pack gym shoes'), findsOneWidget);
    await tester.tap(find.text('Training'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log set'));
    await tester.pumpAndSettle();
    expect(find.text('62.25'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).last, '9');
    await tester.tap(find.widgetWithText(FilledButton, 'Log set'));
    await tester.pumpAndSettle();
    expect(state.training.session(state.today).single.$2.single.reps, 9);
    expect(find.text('PB'), findsOneWidget);
    await tester.tap(find.text('Journal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Added one rep.');
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(state.journalOf(state.today), 'Added one rep.');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('sign-in waits for the phone to come back from the browser', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    var back = false;
    unawaited(whenBackFromBrowser().then((_) => back = true));
    await tester.pump();
    expect(back, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(back, isTrue);
  });

  test('upcoming reminders list what\'s still to go off, soonest first', () {
    final (_, state) = make();
    state.addTodo(
      TodoScope.today,
      'Dentist',
      dueDate: state.today,
      time: 15 * 60,
      reminders: Reminder.hourBefore.bit | Reminder.quarterBefore.bit,
    );
    final upcoming = state.upcomingReminders();
    expect(upcoming.map((r) => r.at), [DateTime(2026, 11, 6, 14), DateTime(2026, 11, 6, 14, 45)]);
    expect(upcoming.first.title, 'Dentist');
    expect(upcoming.first.body, 'In 1 hour, at 3:00 pm');
  });

  testWidgets('off-day and future-added rituals are hidden on phone Today', (tester) async {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    // 2026-11-06 is a Friday. Add a Monday-only ritual and one added tomorrow.
    final mondayOnly = store.addHabit(2026, 11, 'Monday sprint');
    store.setHabitDays(2026, 11, mondayOnly.id, [(null, weekdayBit(DateTime.monday))]);
    store.addHabit(2026, 11, 'Starts tomorrow', addedOn: DateTime(2026, 11, 7));
    final state = AppState(store, clock: () => DateTime(2026, 11, 6, 9))..endTour();
    addTearDown(state.dispose);
    expect(state.habits, hasLength(3));

    await show(tester, state);

    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Monday sprint'), findsNothing);
    expect(find.text('Starts tomorrow'), findsNothing);
    final ritualsHeader = find.ancestor(of: find.text('RITUALS'), matching: find.byType(TileHeader));
    expect(find.descendant(of: ritualsHeader, matching: find.text(' OF 1')), findsOneWidget);
    expect(
      tester.widget<RollingNumber>(find.descendant(of: ritualsHeader, matching: find.byType(RollingNumber))).value,
      0,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('phone tasks show metadata and subtasks, and swipe-to-delete can be undone', (tester) async {
    final (_, state) = make();
    state.addTodo(TodoScope.today, 'Dentist', time: 10 * 60, location: 'Rundle Mall');
    final timed = state.todos[TodoScope.today]!.last;
    state.setTodoSubtasks(TodoScope.today, timed, [const TodoSubtask('Bring card')]);
    state.addRepeat('Vitamins', const RepeatRule.every(1), DateTime(2026, 11, 6));
    await show(tester, state);

    await tester.dragUntilVisible(find.text('Dentist'), find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.text('10:00 am'), findsOneWidget);
    expect(find.text('Rundle Mall'), findsOneWidget);
    expect(find.text('Bring card'), findsOneWidget);
    expect(find.byIcon(Icons.repeat_rounded), findsOneWidget);

    await tester.tap(find.text('Bring card'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.firstWhere((t) => t.id == timed.id).subtasks.single.done, isTrue);

    await tester.drag(find.text('Dentist'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Dentist'), findsNothing);
    expect(find.text('Removed “Dentist”'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Dentist'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('phone settings shows Days controls and opens Holiday dialog without overflow', (tester) async {
    final (_, state) = make();
    await show(tester, state);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('DAYS'), findsOneWidget);
    expect(find.text('Weekends as rest days'), findsOneWidget);
    expect(find.text('New day starts at'), findsOneWidget);
    expect(find.text('Holidays'), findsOneWidget);

    await tester.tap(find.text('Weekends as rest days'));
    await tester.pumpAndSettle();
    expect(state.restWeekends, isTrue);

    await tester.tap(find.text('4am'));
    await tester.pumpAndSettle();
    expect(state.dayStartHour, 4);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Add a holiday'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('repeating task swipe confirms scope, weekly ritual omits streak, and long-press opens action sheet', (
    tester,
  ) async {
    final (store, state) = make();
    final weekly = store.addHabit(2026, 11, 'Long run');
    state.setRitualGoal(2026, 11, weekly, weekly: 3);
    final savedWeekly = state.habits.firstWhere((h) => h.id == weekly.id);
    state.selectStatus(DateTime(2026, 11, 5), savedWeekly, HabitStatus.done);
    state.selectStatus(state.today, savedWeekly, HabitStatus.done);
    state.addRepeat('Daily pills', const RepeatRule.every(1), state.today);
    await show(tester, state);

    expect(find.text('Long run · 2/3 this week'), findsOneWidget);
    expect(find.text('2'), findsNothing);

    await tester.longPress(find.text('Long run · 2/3 this week'));
    await tester.pumpAndSettle();
    expect(find.text('Mark not done'), findsOneWidget);
    await tester.tap(find.text('Mark not done'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, weekly), HabitStatus.missed);

    await tester.ensureVisible(find.text('Daily pills'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Daily pills'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Remove repeating task'), findsOneWidget);
    await tester.tap(find.text('Only this one'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.any((t) => t.text == 'Daily pills'), isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Plan uses formatted headings and Workout edits sets, weighted bodyweight, and rest timer', (
    tester,
  ) async {
    final (store, state) = make();
    final laterDay = DateTime(2026, 11, 20);
    state.addTodo(TodoScope.month, 'Haircut', dueDate: laterDay);
    state.addTodo(TodoScope.month, 'Alex birthday', dueDate: laterDay, birthday: true);
    final pullup = state.training.createExercise('Pull-ups', MuscleGroup.back, bodyweight: true);
    state.training.addToDay(state.today, pullup);
    store.setSetting('restSeconds', '60');
    const channel = MethodChannel('eclipse/phone');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final restCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startRest' || call.method == 'cancelRest') restCalls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await show(tester, state);

    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.text('Fri 20 Nov'), findsOneWidget);
    expect(find.text('2026-11-20'), findsNothing);
    expect(find.text('Alex birthday'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide birthdays'));
    await tester.pumpAndSettle();
    expect(find.text('Alex birthday'), findsNothing);
    await tester.tap(find.byTooltip('Show birthdays'));
    await tester.pumpAndSettle();
    expect(find.text('Alex birthday'), findsOneWidget);

    await tester.tap(find.text('Training'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log set'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '10');
    await tester.enterText(find.byType(TextFormField).last, '8');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Log set'));
    await tester.pumpAndSettle();
    expect(find.text('+10 kg × 8 reps'), findsOneWidget);
    expect(find.text('Rest 1:00'), findsOneWidget);
    expect(restCalls.single.method, 'startRest');
    expect(restCalls.single.arguments, isA<int>());

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Rest timer · 1:00'), findsOneWidget);
    expect(restCalls.last.method, 'cancelRest');

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Rest 1:00'), findsOneWidget);
    expect(restCalls.last.method, 'startRest');

    await tester.tap(find.text('+10 kg × 8 reps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('+10 kg × 8 reps'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
