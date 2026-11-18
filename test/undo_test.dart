import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/undo_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 28, 9);
  late Store store;
  late AppState state;
  setUp(() {
    store = Store.memory();
    state = AppState(store, clock: () => now);
  });
  tearDown(() {
    state.dispose();
    store.close();
  });

  List<String> today() => [for (final t in state.todos[TodoScope.today]!) t.text];

  test('a removed task comes back as it was, and the card names it', () {
    state.addTodo(TodoScope.today, 'Buy milk');
    final milk = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Buy milk');
    state.removeTodo(TodoScope.today, milk);
    expect(today(), isNot(contains('Buy milk')));
    expect(state.shownRemoval?.label, 'Removed “Buy milk”');

    state.undo();
    final back = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Buy milk');
    expect((back.id, back.uid), (milk.id, milk.uid));
    expect(state.shownRemoval, isNull);
    expect(state.canUndo, isFalse);
  });

  test('Ctrl+Z steps back through the last three removals', () {
    for (final text in ['One', 'Two', 'Three', 'Four']) {
      state.addTodo(TodoScope.today, text);
    }
    for (final text in ['One', 'Two', 'Three', 'Four']) {
      state.removeTodo(TodoScope.today, state.todos[TodoScope.today]!.singleWhere((t) => t.text == text));
    }
    state.undo();
    expect(today(), contains('Four'));
    state.undo();
    state.undo();
    expect(today(), containsAll(['Two', 'Three']));
    expect(state.canUndo, isFalse);
    expect(today(), isNot(contains('One')));
  });

  test('a repeat removed from now on comes back with its times', () {
    state.addRepeat('Gym', RepeatRule.weekly({1, 3, 5}), DateTime(2026, 10, 28));
    List<DateTime?> gym() => [
      for (final scope in TodoScope.values)
        for (final t in state.todos[scope]!)
          if (t.text == 'Gym') t.repeatDay,
    ]..sort((a, b) => a!.compareTo(b!));
    final before = gym();
    final friday = [for (final scope in TodoScope.values) ...state.todos[scope]!]
        .singleWhere((t) => t.repeatDay == DateTime(2026, 10, 30));
    state.removeTogether(() {
      state.removeTodo(TodoScope.month, friday);
      state.endRepeat(state.repeatOf(friday)!, friday.repeatDay!);
    });
    expect(gym(), [DateTime(2026, 10, 28)]);
    expect(state.shownRemoval?.label, 'Removed “Gym” and later ones');

    state.undo();
    expect(gym(), before);
    expect(state.repeats.single.until, isNull);
    expect(state.canUndo, isFalse, reason: 'one action, one undo');
  });

  test('a removed ritual comes back in its place', () {
    final names = [for (final h in state.habitsFor(2026, 10)) h.name];
    final second = state.habitsFor(2026, 10)[1];
    state.removeHabit(2026, 10, second);
    expect(state.shownRemoval?.label, 'Removed “${second.name}” from October');
    state.undo();
    expect([for (final h in state.habitsFor(2026, 10)) h.name], names);
  });

  test('an undone removal reaches the other computer', () {
    final engine = SyncEngine(store, 'a')..claimAll();
    final other = Store.memory();
    addTearDown(other.close);
    final peer = SyncEngine(other, 'b');
    void send() {
      engine.flush();
      peer.mergeAll([(engine.changesSince(0).values.expand((v) => v), 'a')]);
    }

    bool there() => other.todos(TodoScope.today, dateKey(now)).any((t) => t.text == 'Buy milk');
    state.addTodo(TodoScope.today, 'Buy milk');
    send();
    expect(there(), isTrue);
    state.removeTodo(TodoScope.today, state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Buy milk'));
    send();
    expect(there(), isFalse);
    state.undo();
    send();
    expect(there(), isTrue);
  });

  testWidgets('Ctrl+Z undoes, except while typing', (tester) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: themeNamed(null),
          builder: (context, child) => UndoLayer(child: child!),
          home: Scaffold(body: TextField(focusNode: field)),
        ),
      ),
    );
    state.addTodo(TodoScope.today, 'Buy milk');
    state.removeTodo(TodoScope.today, state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Buy milk'));
    await tester.pumpAndSettle();
    expect(find.text('Removed “Buy milk”'), findsOneWidget);

    field.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(today(), isNot(contains('Buy milk')));

    field.unfocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(today(), contains('Buy milk'));
    await tester.pumpAndSettle();
  });

  testWidgets('the card goes after a few seconds, but not while hovered', (tester) async {
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: themeNamed(null),
          builder: (context, child) => UndoLayer(child: child!),
          home: const Scaffold(),
        ),
      ),
    );
    state.addTodo(TodoScope.today, 'Buy milk');
    state.removeTodo(TodoScope.today, state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Buy milk'));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Removed “Buy milk”')));
    await tester.pump(const Duration(seconds: 10));
    expect(state.shownRemoval, isNotNull);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 7));
    expect(state.shownRemoval, isNull);
    expect(state.canUndo, isTrue, reason: 'Ctrl+Z still reaches it');
    await tester.pumpAndSettle();
  });
}
