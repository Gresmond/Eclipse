import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/status_cell.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Store store;
  late AppState state;
  setUp(() {
    store = Store.memory();
    state = AppState(store, clock: () => DateTime(2026, 10, 26));
  });
  tearDown(() {
    state.dispose();
    store.close();
  });

  Future<void> show(WidgetTester tester, Habit habit, {bool enabled = true}) async {
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(palettes.first),
          home: Scaffold(
            body: Center(
              child: StatusCell(day: state.today, habit: habit, enabled: enabled),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final sleep in [false, true]) {
    testWidgets('${sleep ? 'sleep' : 'ritual'} mouse buttons select directly and repeat to clear', (tester) async {
      final habit = sleep ? state.sleepHabits.first : state.habits.first;
      await show(tester, habit);
      final observed = <HabitStatus>[];
      state.addListener(() => observed.add(state.statusOf(state.today, habit)));
      final square = find.byType(StatusCell);
      await tester.tap(square, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(observed, [HabitStatus.missed], reason: 'not done never passes through done');
      expect(store.entriesInMonth(2026, 10).single.status, HabitStatus.missed);
      await tester.tap(square, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(state.statusOf(state.today, habit), HabitStatus.none);
      expect(store.entriesInMonth(2026, 10), isEmpty);

      await tester.tap(square);
      await tester.pumpAndSettle();
      expect(state.statusOf(state.today, habit), HabitStatus.done);
      await tester.tap(square);
      await tester.pumpAndSettle();
      expect(state.statusOf(state.today, habit), HabitStatus.none);

      await tester.tap(square, buttons: kMiddleMouseButton);
      await tester.pumpAndSettle();
      expect(state.statusOf(state.today, habit), HabitStatus.other);
      expect(find.text('What happened?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'under the weather');
      await tester.tap(find.text('Save note'));
      await tester.pumpAndSettle();
      expect(state.noteOf(state.today, habit), 'Under the weather');
      await tester.tap(square, buttons: kMiddleMouseButton);
      await tester.pumpAndSettle();
      expect(state.statusOf(state.today, habit), HabitStatus.none);
      expect(state.noteOf(state.today, habit), isNull);
      expect(store.entriesInMonth(2026, 10), isEmpty);
      expect(find.text('What happened?'), findsNothing);
    });
  }

  testWidgets('switching buttons replaces the mark and removes its previous other note', (tester) async {
    final habit = state.habits.first;
    await show(tester, habit);
    final square = find.byType(StatusCell);
    await tester.tap(square);
    await tester.pumpAndSettle();
    await tester.tap(square, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, habit), HabitStatus.missed);
    await tester.tap(square, buttons: kMiddleMouseButton);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A note');
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    await tester.tap(square);
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, habit), HabitStatus.done);
    expect(state.noteOf(state.today, habit), isNull);
    expect(store.entriesInMonth(2026, 10).single.note, isNull);
  });

  testWidgets('disabled squares ignore every mouse button', (tester) async {
    final habit = state.habits.first;
    await show(tester, habit, enabled: false);
    for (final button in [kPrimaryMouseButton, kSecondaryMouseButton, kMiddleMouseButton]) {
      await tester.tap(find.byType(StatusCell), buttons: button);
      await tester.pumpAndSettle();
      expect(state.statusOf(state.today, habit), HabitStatus.none);
      expect(find.text('What happened?'), findsNothing);
    }
  });
}
