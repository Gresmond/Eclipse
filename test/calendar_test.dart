import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 11, 6);
  late Store store;
  late AppState state;

  setUp(() {
    pageButtonsEnabled = true;
    store = Store.memory();
    state = AppState(store, clock: () => today)..endTour();
  });
  tearDown(() {
    pageButtonsEnabled = false;
    state.dispose();
    store.close();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2500, 1380);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  testWidgets('switched off, the header offers neither page', (tester) async {
    pageButtonsEnabled = false;
    await show(tester);
    expect(find.byTooltip('Calendar'), findsNothing);
    expect(find.byTooltip('Training'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the button opens the calendar and goes back to the view it opened over', (tester) async {
    await show(tester);
    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Calendar'));
    await tester.pumpAndSettle();
    expect(state.showingCalendar, isTrue);
    expect(find.text('MON'), findsOneWidget);
    expect(find.byTooltip('Next year'), findsNothing);

    await tester.tap(find.byTooltip('Training'));
    await tester.pumpAndSettle();
    expect((state.showingCalendar, state.showingTraining), (false, true));

    await tester.tap(find.byTooltip('Training'));
    await tester.pumpAndSettle();
    expect((state.showingTraining, state.viewingYear), (false, true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the arrows sit left of the page buttons, and months go on past this year', (tester) async {
    await show(tester);
    state.toggleCalendar();
    await tester.pumpAndSettle();
    final next = tester.getCenter(find.byTooltip('Next month'));
    expect(next.dx, lessThan(tester.getCenter(find.byTooltip('Calendar')).dx));
    expect(next.dx, greaterThan(tester.getTopRight(find.text('November')).dx + 200));

    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(state.calendarMonth, DateTime(2027, 1));

    await tester.tap(find.text('This month'));
    await tester.pumpAndSettle();
    expect(state.calendarMonth, DateTime(2026, 11));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a repeat shows every coming time, and ticking one makes only that one', (tester) async {
    state.addRepeat('Take out the bins', const RepeatRule.every(1, weeks: true), DateTime(2026, 11, 9));
    await show(tester);
    state.toggleCalendar();
    await tester.pumpAndSettle();
    // The 9th, 16th, 23rd and 30th.
    expect(find.text('Take out the bins'), findsNWidgets(4));

    final last = find.text('Take out the bins').last;
    await tester.tapAt(tester.getTopLeft(last) - const Offset(14, -8));
    await tester.pumpAndSettle();
    expect(store.madeOccurrencesFrom(today).values.single, contains(contains('2026-11-30')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a day with too many tasks says how many more, and its panel lists them', (tester) async {
    for (var i = 0; i < 12; i++) {
      state.addTodo(TodoScope.month, 'Item $i', dueDate: DateTime(2026, 11, 24));
    }
    await show(tester);
    state.toggleCalendar();
    await tester.pumpAndSettle();
    final more = find.textContaining(' more');
    expect(more, findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Item 11'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging a task moves it to the day it is dropped on', (tester) async {
    state.addTodo(TodoScope.month, 'Move me', dueDate: DateTime(2026, 11, 24));
    await show(tester);
    state.toggleCalendar();
    await tester.pumpAndSettle();
    final from = tester.getCenter(find.text('Move me'));
    await tester.dragFrom(from, tester.getCenter(find.text('25')) - from);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.month]!.single.dueDate, DateTime(2026, 11, 25));
    expect(tester.takeException(), isNull);
  });
}
