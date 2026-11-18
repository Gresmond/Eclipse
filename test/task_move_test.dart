import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/settings_dialog.dart';

void main() {
  late Store store;
  late AppState state;
  final today = DateTime(2026, 10, 25);

  setUp(() {
    store = Store.memory();
    state = AppState(store, clock: () => today);
    for (final scope in TodoScope.values) {
      for (final item in state.todos[scope]!.toList()) {
        state.removeTodo(scope, item);
      }
    }
  });
  tearDown(() {
    state.dispose();
    store.close();
  });

  test('manual moves retain identity and history, clear dates and reset completion routing', () {
    state.addTodo(TodoScope.week, 'Move this', dueDate: DateTime(2026, 10, 29));
    var scope = TodoScope.week;
    final id = state.todos[scope]!.single.id;
    for (final destination in [TodoScope.month, TodoScope.tomorrow, TodoScope.today, TodoScope.week]) {
      state.moveTodo(scope, state.todos[scope]!.single, destination);
      expect(state.todos[scope], isEmpty);
      final moved = state.todos[destination]!.single;
      expect(moved.id, id);
      expect(moved.since, today);
      expect(moved.dueDate, isNull);
      expect(state.todosOn(destination, today).single.id, id);
      scope = destination;
    }
    state.toggleTodo(state.todos[scope]!.single, scope: scope);
    final completed = state.todos[TodoScope.today]!.single;
    state.moveTodo(TodoScope.today, completed, TodoScope.tomorrow);
    expect(state.todos[TodoScope.tomorrow], isEmpty);
    state.toggleTodo(completed);
    expect(state.todos[TodoScope.week]!.single.id, id);
    state.moveTodo(TodoScope.week, state.todos[TodoScope.week]!.single, TodoScope.month);
    state.toggleTodo(state.todos[TodoScope.month]!.single, scope: TodoScope.month);
    state.toggleTodo(state.todos[TodoScope.today]!.single);
    expect(state.todos[TodoScope.month]!.single.id, id);
  });

  Future<void> showApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  /// Tomorrow's heading in the week card, shown with nothing due while
  /// empty days show.
  Finder tomorrow() => find.textContaining('Tomorrow', findRichText: true).first;

  testWidgets('drag moves an unfinished task into an empty section', (tester) async {
    state.toggleWeekEmptyDays();
    state.addTodo(TodoScope.today, 'Drag me');
    await showApp(tester);
    await tester.dragFrom(
      tester.getCenter(find.text('Drag me')),
      tester.getCenter(tomorrow()) - tester.getCenter(find.text('Drag me')),
    );
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today], isEmpty);
    expect(state.todos[TodoScope.tomorrow]!.single.text, 'Drag me');
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed tasks cannot drag; open ones can', (tester) async {
    state.addTodo(TodoScope.today, 'Finished');
    state.toggleTodo(state.todos[TodoScope.today]!.single);
    state.addTodo(TodoScope.today, 'Still open');
    state.toggleWeekEmptyDays();
    await showApp(tester);
    final destination = tester.getCenter(tomorrow());
    final finished = tester.getCenter(find.text('Finished'));
    await tester.dragFrom(finished, destination - finished);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.tomorrow], isEmpty);
    final open = tester.getCenter(find.text('Still open'));
    await tester.dragFrom(open, destination - open);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.tomorrow]!.single.text, 'Still open');
  });

  testWidgets('tour shows General, Data and Appearance and blocks panel interaction', (tester) async {
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(family['family'] as String);
      for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    state.startTour();
    await showApp(tester);
    await tester.tap(find.text('Show me around'));
    await tester.pumpAndSettle();
    for (var i = 1; i < 8; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    expect(find.byType(SettingsDialog), findsOneWidget);
    expect(tester.widget<SettingsDialog>(find.byType(SettingsDialog)).tourRibbon, 0);
    await tester.tap(find.text('Close'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(state.touring, isTrue);
    expect(find.byType(SettingsDialog), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(tester.widget<SettingsDialog>(find.byType(SettingsDialog)).tourRibbon, 1);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Follow the sun'), state.nightLightAvailable ? findsOneWidget : findsNothing);
    final theme = state.themeNotifier.value;
    await tester.tap(find.text('Pluto’s Heartbreak'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(state.themeNotifier.value, theme);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(state.touring, isFalse);
    expect(tester.takeException(), isNull);
  });
}
