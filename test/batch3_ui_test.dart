import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/today_view.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/appear.dart';
import 'package:eclipse/widgets/fade_menu.dart';
import 'package:eclipse/widgets/search_dialog.dart';
import 'package:eclipse/widgets/status_cell.dart';
import 'package:eclipse/widgets/tile.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Appear hides safely under reduced motion without setState-during-build', (tester) async {
    var hiddenCalls = 0;
    var shown = true;
    late StateSetter rebuild;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: themeNamed(null),
          home: ThemeMorph(
            target: paletteNamed(null),
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return Appear(
                  animate: true,
                  shown: shown,
                  onHidden: () {
                    hiddenCalls++;
                    // Parent removing the widget synchronously in onHidden must not throw.
                    setState(() {});
                  },
                  child: const Text('Closing item'),
                );
              },
            ),
          ),
        ),
      ),
    );

    rebuild(() => shown = false);
    await tester.pump();
    await tester.pump();
    expect(hiddenCalls, 1);
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

  testWidgets('HeaderIconButton highlights background and icon when active', (tester) async {
    final palette = paletteNamed(null);
    Widget buildButton(bool active) => MaterialApp(
      theme: themeNamed(palette.name),
      home: ThemeMorph(
        target: palette,
        child: Scaffold(
          body: HeaderIconButton(
            icon: Icons.calendar_today_rounded,
            tooltip: 'Toggle empty days',
            active: active,
            onPressed: () {},
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildButton(true));
    final activeButton = tester.widget<IconButton>(find.byType(IconButton));
    expect(activeButton.style?.backgroundColor?.resolve({}), palette.done);
    expect(activeButton.style?.foregroundColor?.resolve({}), palette.onDone);

    await tester.pumpWidget(buildButton(false));
    final inactiveButton = tester.widget<IconButton>(find.byType(IconButton));
    expect(inactiveButton.style?.backgroundColor?.resolve({}), Colors.transparent);
  });

  testWidgets('Ctrl+K opens SearchDialog shortcut', (tester) async {
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

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byType(SearchDialog), findsOneWidget);
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

  testWidgets('showFadeMenu clamps and scrolls cleanly on short viewports', (tester) async {
    tester.view.physicalSize = const Size(800, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: themeNamed(null),
        home: ThemeMorph(
          target: paletteNamed(null),
          child: Scaffold(
            body: Builder(
              builder: (context) => Align(
                alignment: Alignment.topRight,
                child: ElevatedButton(
                  onPressed: () => showFadeMenu(
                    context,
                    builder: (_) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 20; i++) SizedBox(height: 40, child: Text('Menu item $i')),
                      ],
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Menu item 0'), findsOneWidget);
  });
}
