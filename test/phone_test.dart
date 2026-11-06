import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/phone/phone_app.dart';
import 'package:flutter/material.dart';
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
}
