import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/status_cell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('x-height is kept and clamped, and starts at standard Matter', () {
    final store = Store.memory();
    expect(AppState(store).xHeight.value, 0);
    final state = AppState(store)..xHeight.value = 60;
    state.saveXHeight();
    expect(AppState(store).xHeight.value, 60);
    store.setSetting('xHeight', '400');
    expect(AppState(store).xHeight.value, 100);
    store.close();
  });

  test('the theme carries the x-height, and leaves standard Matter untouched', () {
    expect(themeNamed('Sunrise', xHeight: 0), same(themeNamed('Sunrise')));
    final tall = themeNamed('Sunrise', xHeight: 50).textTheme.bodyMedium!;
    expect(tall.fontVariations, [const FontVariation('XHGT', 50)]);
  });

  testWidgets('dragging a new value reaches text in the app', (tester) async {
    final store = Store.memory();
    final state = AppState(store);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    state.xHeight.value = 80;
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    expect(DefaultTextStyle.of(context).style.fontVariations, [const FontVariation('XHGT', 80)]);
    expect(XHeight.of(context), 80);
    store.close();
  });

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
}
