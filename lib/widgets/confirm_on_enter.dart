import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Gives a panel a default confirmation while preserving focused buttons,
/// modified Enter, and text composition. Repeat events never confirm twice.
class ConfirmOnEnter extends StatelessWidget {
  const ConfirmOnEnter({
    super.key,
    required this.onConfirm,
    required this.child,
    this.preserveTextInput = false,
    this.preserveButtons = true,
  });

  final VoidCallback? onConfirm;
  final Widget child;
  final bool preserveTextInput;
  final bool preserveButtons;

  @override
  Widget build(BuildContext context) => FocusScope(
    autofocus: true,
    skipTraversal: true,
    onKeyEvent: (_, event) {
      if (event.logicalKey != LogicalKeyboardKey.enter && event.logicalKey != LogicalKeyboardKey.numpadEnter) {
        return KeyEventResult.ignored;
      }
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isShiftPressed || keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      var preserve = false;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
        final widget = element.widget;
        if (preserveButtons && widget is ButtonStyleButton) preserve = true;
        if (widget is EditableText) {
          final composing = widget.controller.value.composing;
          if (preserveTextInput || (composing.isValid && !composing.isCollapsed)) preserve = true;
        }
        return true;
      });
      if (preserve || onConfirm == null) return KeyEventResult.ignored;
      if (event is KeyDownEvent) onConfirm!();
      return KeyEventResult.handled;
    },
    child: child,
  );
}
