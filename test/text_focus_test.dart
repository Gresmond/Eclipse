import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/todo_panel.dart';

void main() {
  Future<AppState> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 10, 23, 12));
    state.addTodo(TodoScope.week, 'Original task', dueDate: DateTime(2026, 10, 27));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> click(WidgetTester tester, Finder finder) async {
    await tester.tap(finder, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
  }

  EditableTextState field(WidgetTester tester, Finder of) =>
      tester.state<EditableTextState>(find.descendant(of: of, matching: find.byType(EditableText)));

  testWidgets("a task dialog's buttons and pages leave the cursor in its name", (tester) async {
    await show(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Original task')));
    addTearDown(mouse.removePointer);
    await tester.pumpAndSettle();
    await click(tester, find.descendant(of: find.byType(WeekCard), matching: find.byTooltip('Edit task')).last);
    final dialog = find.byType(Dialog);
    final name = field(tester, dialog).widget.controller;
    name.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();

    for (final (open, back) in [('Due 27/10/2026', 'Cancel'), ('Add a time', 'Save'), ("Doesn't repeat", 'Cancel')]) {
      await click(tester, find.text(open));
      await click(tester, find.text(back));
      final now = field(tester, dialog);
      expect(now.widget.focusNode.hasFocus, isTrue, reason: 'back from $open, the cursor is in the name');
      expect(now.widget.controller.selection, const TextSelection.collapsed(offset: 4), reason: 'where it was');
    }
  });

  testWidgets('numbering the subtasks leaves the cursor in the subtask', (tester) async {
    await show(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Original task')));
    addTearDown(mouse.removePointer);
    await tester.pumpAndSettle();
    await click(tester, find.descendant(of: find.byType(WeekCard), matching: find.byTooltip('Add subtask')).last);
    await tester.enterText(find.byType(TextField).last, 'Research');
    await click(tester, find.text('Number the subtasks'));
    expect(field(tester, find.byType(Dialog)).widget.focusNode.hasFocus, isTrue);
  });

  testWidgets("picking a day from a card's add box leaves the cursor where it was", (tester) async {
    await show(tester);
    final card = find.byType(FurtherAheadCard);
    final box = find.descendant(of: card, matching: find.byType(TextField));
    await click(tester, box);
    await tester.enterText(box, 'Dentist');
    field(tester, card).widget.controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();
    await click(tester, find.descendant(of: card, matching: find.byTooltip('Pick a day')));
    await click(tester, find.text('OK'));
    final now = field(tester, card);
    expect(now.widget.focusNode.hasFocus, isTrue);
    expect(now.widget.controller.selection, const TextSelection.collapsed(offset: 3));
  });
}
