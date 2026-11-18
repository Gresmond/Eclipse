import 'package:eclipse/widgets/confirm_on_enter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Return and keypad Enter confirm once, with modifiers preserved', (tester) async {
    var confirmations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ConfirmOnEnter(onConfirm: () => confirmations++, child: const SizedBox()),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(confirmations, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    expect(confirmations, 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(confirmations, 2);
  });

  testWidgets('multiline drafts and text composition do not confirm', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var confirmations = 0;
    Future<void> show({required bool preserveTextInput}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: ConfirmOnEnter(
              onConfirm: () => confirmations++,
              preserveTextInput: preserveTextInput,
              child: TextField(controller: controller, autofocus: true, maxLines: null),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await show(preserveTextInput: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(confirmations, 0);
    await show(preserveTextInput: false);
    controller.value = const TextEditingValue(text: 'draft', composing: TextRange(start: 0, end: 5));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(confirmations, 0);
    controller.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(confirmations, 1);
  });

  testWidgets('disabled confirmation never fires', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ConfirmOnEnter(onConfirm: null, child: SizedBox())));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(tester.takeException(), isNull);
  });
}
