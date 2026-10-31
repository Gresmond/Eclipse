import 'dart:convert';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _fonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  final icons = File('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  final loader = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
  await loader.load();
}

void main() {
  Future<AppState> open(WidgetTester tester) async {
    await _fonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 14, 45));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> pickDay(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(FurtherAheadCard), matching: find.byTooltip('Pick a day')));
    await tester.pumpAndSettle();
  }

  testWidgets('timed', (tester) async {
    await open(tester);
    await pickDay(tester);
    await tester.tap(find.text('Add a time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notify'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 day'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(Dialog), matchesGoldenFile('timed.png'));
  });

  testWidgets('off', (tester) async {
    await open(tester);
    await pickDay(tester);
    await tester.tap(find.text('Add a time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await expectLater(find.byType(Dialog), matchesGoldenFile('off.png'));
  });

  testWidgets('birthday', (tester) async {
    await open(tester);
    await pickDay(tester);
    await tester.tap(find.text('Repeat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Birthday'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notify'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Day before'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(Dialog), matchesGoldenFile('birthday.png'));
  });

  testWidgets('card', (tester) async {
    final state = await open(tester);
    final today = DateTime(2026, 10, 23);
    final item = state.store.addTodo(TodoScope.today, today, 'Dentist appointment');
    state.store.editTodo(item.id, item.text, null, today, time: 15 * 60, reminders: Reminder.quarterBefore.bit);
    state.checkReminders();
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('card.png'));
  });
}
