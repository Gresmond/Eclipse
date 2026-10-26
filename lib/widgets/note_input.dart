import 'package:flutter/services.dart';

import '../models.dart';

/// Desktop inputs need explicit capitalisation; keep the selection intact.
class NoteInputFormatter extends TextInputFormatter {
  const NoteInputFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (!newValue.composing.isCollapsed) return newValue;
    final text = normaliseNote(newValue.text);
    if (text == newValue.text) return newValue;
    // Dashes shorten the text; the caret keeps its place after them.
    int place(int offset) => offset < 0 ? offset : autoDashes(newValue.text.substring(0, offset)).length;
    final selection = newValue.selection;
    return newValue.copyWith(
      text: text,
      selection: selection.copyWith(
        baseOffset: place(selection.baseOffset),
        extentOffset: place(selection.extentOffset),
      ),
      composing: TextRange.empty,
    );
  }
}
