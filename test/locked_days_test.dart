import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/status_cell.dart';
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
}
