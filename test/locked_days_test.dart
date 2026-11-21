import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/today_view.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/status_cell.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('in a month, only today and yesterday can be marked', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    store.addHabit(2026, 11, 'Sketch');
    final state = AppState(store, clock: () => DateTime(2026, 11, 5, 10));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nov').hitTestable());
    await tester.pumpAndSettle();
    final cells = tester.widgetList<StatusCell>(find.byType(StatusCell));
    bool enabled(int day) => cells.firstWhere((c) => c.day == DateTime(2026, 11, day)).enabled;
    expect(enabled(3), isFalse, reason: 'two days ago is locked');
    expect(enabled(4), isTrue, reason: 'yesterday');
    expect(enabled(5), isTrue, reason: 'today');
    expect(enabled(6), isFalse, reason: 'the future stays locked');
    store.close();
  });

  testWidgets('a locked day fades only while blank', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    final habit = store.addHabit(2026, 11, 'Sketch', addedOn: DateTime(2026, 11, 1));
    final state = AppState(store, clock: () => DateTime(2026, 11, 5, 10));
    store.setEntry('2026-11-02', habit.id, HabitStatus.done);
    store.setEntry('2026-11-01', habit.id, HabitStatus.missed);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nov').hitTestable());
    await tester.pumpAndSettle();
    double fade(int day) {
      final cell = find.byWidgetPredicate((w) => w is StatusCell && w.day == DateTime(2026, 11, day));
      final paint = tester.widget<CustomPaint>(find.descendant(of: cell, matching: find.byType(CustomPaint)).first);
      return ((paint.painter as dynamic).opacity as Animation<double>).value;
    }

    expect(fade(2), 1, reason: 'a tick on a locked day');
    expect(fade(1), 1, reason: 'a cross on a locked day');
    expect(fade(3), lessThan(1), reason: 'blank and locked');
    store.close();
  });

  testWidgets('locked past day remains scrollable and shows note tooltips without allowing edits', (tester) async {
    tester.view.physicalSize = const Size(1440, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = Store.memory();
    addTearDown(store.close);
    for (var i = 1; i <= 16; i++) {
      store.addHabit(2026, 10, 'Habit $i');
    }
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 12));
    addTearDown(state.dispose);

    final lockedDay = DateTime(2026, 10, 20);
    final firstHabit = state.habits.first;
    store.setEntry('2026-10-20', firstHabit.id, HabitStatus.other);
    store.setNote('2026-10-20', firstHabit.id, 'Resting knee');
    state.showDay(lockedDay);

    await tester.pumpWidget(
      MaterialApp(
        theme: themeNamed(null),
        home: ThemeMorph(
          target: paletteNamed(null),
          child: AppScope(state: state, child: const Scaffold(body: TodayView())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Hovering first habit cell displays its note tooltip on locked past day.
    final cell = find.byWidgetPredicate((w) => w is StatusCell && w.habit.id == firstHabit.id).first;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(cell));
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('Resting knee'), findsOneWidget);

    // Tapping does not change locked day's status.
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(state.statusOf(lockedDay, firstHabit), HabitStatus.other);

    // Scrolling the habits list reveals later habits even though the day is readOnly.
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('Habit 16'), findsOneWidget);
  });
}
