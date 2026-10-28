import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/display_view.dart';
import 'package:eclipse/widgets/status_cell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppState state;

  Future<void> showApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  setUp(() => state = AppState(Store.memory(), clock: () => DateTime(2026, 10, 28, 12)));

  testWidgets('the toggle switches modes and Display lists the days from today', (tester) async {
    await showApp(tester);
    expect(find.byType(DisplayView), findsNothing);
    await tester.tap(find.text('Display').hitTestable().first);
    await tester.pumpAndSettle();
    expect(state.displayMode, isTrue);
    expect(find.byType(DisplayView), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.textContaining('Oct 28'), findsOneWidget);
    expect(find.textContaining('Tomorrow'), findsWidgets);
    // Today's to-dos and rituals are all there as items.
    expect(find.text(state.todos[TodoScope.today]!.first.text), findsOneWidget);
    expect(find.text(state.habits.first.name), findsOneWidget);

    await tester.tap(find.text('Ritual').hitTestable().first);
    await tester.pumpAndSettle();
    expect(state.displayMode, isFalse);
    expect(find.byType(DisplayView), findsNothing);
  });

  testWidgets('adding under a later day files the task with that due date', (tester) async {
    state.setDisplayMode(true);
    await showApp(tester);
    Future<void> addOn(int day, String text) async {
      // One "Add task" per day, from today.
      await tester.ensureVisible(find.text('Add task').at(day));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add task').at(day));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
    }

    await addOn(3, 'Pack');
    final pack = state.todos[TodoScope.week]!.singleWhere((t) => t.text == 'Pack');
    expect(pack.dueDate, DateTime(2026, 10, 31));
    expect(find.text('Pack'), findsOneWidget);

    await addOn(8, 'Book flights');
    expect(state.todos[TodoScope.month]!.singleWhere((t) => t.text == 'Book flights').dueDate, DateTime(2026, 11, 5));

    await addOn(1, 'Call home');
    expect(state.todos[TodoScope.tomorrow]!.map((t) => t.text), contains('Call home'));
  });

  testWidgets('a ritual ticks from Display', (tester) async {
    state.setDisplayMode(true);
    await showApp(tester);
    final cell = find.byType(StatusCell).first;
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, tester.widget<StatusCell>(cell).habit), HabitStatus.done);
  });
}
