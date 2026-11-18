import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 2, 9);

  (Store, AppState) make() {
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => now);
    addTearDown(state.dispose);
    return (store, state);
  }

  Set<String> times(AppState state, String name) => {
    for (final t in state.todos.values.expand((list) => list))
      if (t.text == name && t.uid!.contains('@')) t.uid!.split('@').last,
  };

  test('a holiday pauses repeats, keeps birthdays, and removing it brings the times back', () {
    final (_, state) = make();
    state.addRepeat('Water plants', const RepeatRule.every(1), DateTime(2026, 11, 2));
    state.addRepeat('Sam', const RepeatRule.yearly(1), DateTime(2026, 11, 4), birthday: true);
    expect(times(state, 'Water plants'), contains('2026-11-04'));

    state.addHoliday(DateTime(2026, 11, 3), DateTime(2026, 11, 5));
    final paused = times(state, 'Water plants');
    expect(paused, isNot(contains('2026-11-03')));
    expect(paused, isNot(contains('2026-11-04')));
    expect(paused, isNot(contains('2026-11-05')));
    expect(paused, containsAll(['2026-11-02', '2026-11-06']));
    expect(times(state, 'Sam'), contains('2026-11-04'), reason: 'birthdays keep going');

    state.removeHoliday(state.holidays.single);
    expect(times(state, 'Water plants'), containsAll(['2026-11-03', '2026-11-04', '2026-11-05']));
  });

  test('a time moved off its day, or ticked, stays through a holiday', () {
    final (_, state) = make();
    state.addRepeat('Water plants', const RepeatRule.every(1), DateTime(2026, 11, 2));
    state.toggleTodo(state.todos.values.expand((list) => list).firstWhere((t) => t.uid!.endsWith('@2026-11-02')));
    state.addHoliday(DateTime(2026, 11, 2), DateTime(2026, 11, 2));
    expect(times(state, 'Water plants'), contains('2026-11-02'));
  });

  testWidgets('Ctrl+N adds a task from anywhere and stays on the page', (tester) async {
    tester.view.physicalSize = const Size(1920, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (store, state) = make();
    store.addHabit(2026, 11, 'Read');
    state.endTour();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    state.showYear();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('New task'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Task name'), 'Call the bank');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('New task'), findsNothing);
    expect(state.viewingYear, isTrue);
    expect(state.todos.values.expand((list) => list).map((t) => t.text), contains('Call the bank'));
  });
}
