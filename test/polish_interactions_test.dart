import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/year_heatmap.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/widgets/ritual_goal.dart';
import 'package:eclipse/widgets/workout_tools.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('YearHeatmap hover shows day details without recomputing and clicks navigate to day or month', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = Store.memory();
    addTearDown(store.close);
    final read = store.addHabit(2026, 11, 'Read');
    final stretch = store.addHabit(2026, 11, 'Stretch');
    store.setEntry('2026-11-05', read.id, HabitStatus.done);
    store.setEntry('2026-11-05', stretch.id, HabitStatus.missed);
    store.setEntry('2026-11-06', read.id, HabitStatus.done);
    store.setEntry('2026-11-06', stretch.id, HabitStatus.done);

    final state = AppState(store, clock: () => DateTime(2026, 11, 10, 9));
    addTearDown(state.dispose);
    state.addHoliday(DateTime(2026, 11, 4), DateTime(2026, 11, 4));
    state.showYear();

    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final squareWidgets = find.descendant(
      of: find.byType(YearHeatmap),
      matching: find.byWidgetPredicate((w) => w is Positioned && w.width != null && w.width == w.height),
    );
    expect(squareWidgets, findsNothing);

    final gridPaint = find.descendant(
      of: find.byType(YearHeatmap),
      matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null && w.size.width > 300),
    );
    expect(gridPaint, findsOneWidget);
    final paintTopLeft = tester.getTopLeft(gridPaint);
    final paintWidth = tester.getSize(gridPaint).width;

    Offset centerOf(DateTime day) => paintTopLeft + YearHeatmap.dayCenterInGrid(2026, paintWidth, day);

    final computesBefore = YearHeatmap.debugComputes;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(centerOf(DateTime(2026, 11, 5)));
    await tester.pump();
    expect(find.text('5 Nov · 1 of 2 done (50%)'), findsOneWidget);

    await mouse.moveTo(centerOf(DateTime(2026, 11, 4)));
    await tester.pump();
    expect(find.text('4 Nov · On holiday'), findsOneWidget);

    await mouse.moveTo(centerOf(DateTime(2026, 11, 7)));
    await tester.pump();
    expect(find.text('7 Nov · Rest day'), findsOneWidget);

    await mouse.moveTo(centerOf(DateTime(2026, 11, 2)));
    await tester.pump();
    expect(find.text('2 Nov · Nothing logged'), findsOneWidget);

    expect(YearHeatmap.debugComputes, computesBefore);

    await tester.tapAt(centerOf(DateTime(2026, 11, 5)));
    await tester.pumpAndSettle();
    expect(state.viewingYear, isFalse);
    expect(state.viewDay, DateTime(2026, 11, 5));

    state.showYear();
    await tester.pumpAndSettle();

    final novInHeatmap = find.descendant(of: find.byType(YearHeatmap), matching: find.text('NOV'));
    await tester.tap(novInHeatmap);
    await tester.pumpAndSettle();
    expect(state.viewingYear, isFalse);
    expect(state.viewMonth, 11);
  });

  testWidgets('YearView table month headers and cells jump to that month', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = Store.memory();
    addTearDown(store.close);
    final read = store.addHabit(2026, 10, 'Read');
    store.setEntry('2026-10-10', read.id, HabitStatus.done);

    final state = AppState(store, clock: () => DateTime(2026, 11, 10, 9));
    addTearDown(state.dispose);
    state.showYear();

    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('OCT').last);
    await tester.pumpAndSettle();
    expect(state.viewMonth, 10);

    state.showYear();
    await tester.pumpAndSettle();

    final ritualsTable = find.ancestor(of: find.text('All rituals'), matching: find.byType(Column)).first;
    await tester.tap(find.descendant(of: ritualsTable, matching: find.text('100%')).first);
    await tester.pumpAndSettle();
    expect(state.viewMonth, 10);
  });

  testWidgets('editRitualGoal switches frequency mode, picks weekly count, and saves daily target', (tester) async {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 10, 9));
    addTearDown(state.dispose);

    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: themeNamed(null),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => editRitualGoal(context, state.habitsFor(2026, 11).single, 2026, 11),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Times a week'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4'));
    await tester.pumpAndSettle();
    expect(find.text('4 times each week'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, '20');
    await tester.enterText(find.byType(TextFormField).last, 'pages');
    await tester.pump();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = state.habitsFor(2026, 11).firstWhere((h) => h.id == habit.id);
    expect(saved.weekly, 4);
    expect(saved.target, 20);
    expect(saved.unit, 'pages');
  });

  testWidgets('enterRitualAmount quick-step pills update progress bar and save', (tester) async {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 10, 9));
    addTearDown(state.dispose);
    state.setRitualGoal(2026, 11, habit, target: 20, unit: 'pages');

    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: themeNamed(null),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => enterRitualAmount(context, state.today, state.habitsFor(2026, 11).single),
                child: const Text('Amount'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Amount'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('+5'));
    await tester.pumpAndSettle();
    expect(find.text('5 of 20 pages'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);

    await tester.tap(find.text('+1'));
    await tester.pumpAndSettle();
    expect(find.text('6 of 20 pages'), findsOneWidget);

    await tester.tap(find.text('−1'));
    await tester.pumpAndSettle();
    expect(find.text('5 of 20 pages'), findsOneWidget);

    await tester.tap(find.text('Done (20)'));
    await tester.pumpAndSettle();
    expect(find.text('20 of 20 pages'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final savedHabit = state.habitsFor(2026, 11).single;
    expect(state.amountOn(state.today, savedHabit), 20);
    expect(state.statusOf(state.today, savedHabit), HabitStatus.done);
  });

  testWidgets('WorkoutToolsButton and editSetDetails bespoke dialogs save weigh-in, routines, volume, and RPE', (
    tester,
  ) async {
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 11, 10, 9));
    addTearDown(state.dispose);
    final squat = state.training.createExercise('Squat', MuscleGroup.quads, bodyweight: false);
    state.training.addSet(state.today, squat, reps: 5, loggedWeight: 100);

    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: themeNamed(null),
          home: Scaffold(
            body: Column(
              children: [
                WorkoutToolsButton(day: state.today),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () =>
                        editSetDetails(context, state.training.session(state.today).single.$2.single, squat),
                    child: const Text('Set details'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Workout tools'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '74.5');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save').first);
    await tester.pumpAndSettle();
    expect(find.text('Latest weigh-in · 74.5 kg'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).last, 'Leg day');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await tester.pumpAndSettle();
    expect(find.text('Leg day'), findsOneWidget);

    await tester.tap(find.text('Volume (kg)'));
    await tester.pumpAndSettle();
    expect(find.text('500.0 kg'), findsOneWidget);

    await tester.tap(find.byTooltip('Rename routine'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'Lower A');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await tester.pumpAndSettle();
    expect(find.text('Lower A'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete routine'));
    await tester.pumpAndSettle();
    expect(find.text('Lower A'), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Set details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('9'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(state.training.session(state.today).single.$2.single.rpe, 9.0);
  });
}
