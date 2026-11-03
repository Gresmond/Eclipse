import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 10, 23);
  late AppState state;

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    state = AppState(store, clock: () => DateTime(2026, 10, 23, 9));
    addTearDown(state.dispose);
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  Future<void> drag(WidgetTester tester, String text, Offset to) async {
    final gesture = await tester.startGesture(tester.getCenter(find.text(text)), kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  TodoItem task(String text) => state.todos.values.expand((t) => t).firstWhere((t) => t.text == text);

  testWidgets('Week ahead to Further ahead asks the day, from past the week', (tester) async {
    await show(tester);
    state.addTodo(TodoScope.today, 'Move me');
    state.addTodo(TodoScope.month, 'Far', dueDate: DateTime(2026, 11, 20));
    await open(tester);
    await drag(tester, 'Move me', tester.getCenter(find.text('Far')));
    expect(find.text('Due date'), findsOneWidget, reason: 'a task there moves rather than nesting');
    expect(task('Far').subtasks, isEmpty);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(task('Move me').dueDate, isNull, reason: 'cancelled, it stays');

    await drag(tester, 'Move me', tester.getCenter(find.text('Further ahead')));
    final dialog = find.byType(AlertDialog);
    // 24 Oct is in the week, so it can't be chosen; 30 Oct, the first past it, can.
    await tester.tap(find.descendant(of: dialog, matching: find.text('24')));
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    await tester.tap(find.descendant(of: dialog, matching: find.text('31')));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing, reason: 'a day moves it, with no OK');
    expect(task('Move me').dueDate, DateTime(2026, 10, 31));
    expect(find.descendant(of: find.byType(FurtherAheadCard), matching: find.text('Move me')), findsOneWidget);
  });

  testWidgets('Further ahead to Week ahead: on a day goes straight there, elsewhere asks', (tester) async {
    await show(tester);
    state.addTodo(TodoScope.today, 'Here');
    state.addTodo(TodoScope.month, 'Far', dueDate: DateTime(2026, 11, 20));
    state.addTodo(TodoScope.month, 'Further', dueDate: DateTime(2026, 11, 21));
    await open(tester);
    await drag(tester, 'Far', tester.getCenter(find.text('Here')));
    expect(find.text('Due date'), findsNothing);
    expect(find.descendant(of: find.byType(WeekCard), matching: find.text('Far')), findsOneWidget);
    expect(task('Here').subtasks, isEmpty);

    await drag(tester, 'Further', tester.getCenter(find.text('Week ahead')));
    expect(find.text('Due date'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('28')));
    await tester.pumpAndSettle();
    expect(task('Further').dueDate, DateTime(2026, 10, 28));
  });

  testWidgets('within its own card, a drop asks nothing', (tester) async {
    await show(tester);
    state.addTodo(TodoScope.today, 'Stay');
    await open(tester);
    await drag(tester, 'Stay', tester.getCenter(find.text('Week ahead')));
    expect(find.text('Due date'), findsNothing);
  });

  testWidgets('the editor shows the calendar, and a new day files the task', (tester) async {
    await show(tester);
    state.addTodo(TodoScope.today, 'Soon');
    await open(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Soon')));
    addTearDown(mouse.removePointer);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(WeekCard), matching: find.byTooltip('Edit task')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('31')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.where((t) => t.text == 'Soon'), isEmpty);
    expect(task('Soon').dueDate, DateTime(2026, 10, 31));
    expect(today.isBefore(task('Soon').dueDate!), isTrue);
    expect(find.descendant(of: find.byType(FurtherAheadCard), matching: find.text('Soon')), findsOneWidget);
  });
}
