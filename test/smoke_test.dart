import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/phone/phone_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop app opens and switches across Today, Month, Year, Training and themes', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 10, 9));
    addTearDown(state.dispose);

    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    state.showMonth(11);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    state.showYear();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    state.toggleTraining();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    state.showToday();
    state.setTheme('Lunar Eclipse');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('phone app opens cleanly', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 10, 9));
    addTearDown(state.dispose);

    await tester.pumpWidget(PhoneApp(state: state, schedule: (_) async {}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
