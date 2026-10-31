import 'package:flutter/painting.dart';

import 'app_theme.dart';

/// The shared scales the UI is drawn from. `ui_consistency_test.dart` fails
/// on a literal outside them, so a new value is a decision made here.
abstract final class Scale {
  /// Corner radii: bars and handles, chips, controls, cards, dialogs, pills.
  static final radii = <double>{4, 8, 12, 16, 20, 24, 30};

  /// Text: caption, secondary, body, card heading, section heading, dialog
  /// title, page title.
  static final fontSizes = <double>{12, 14, 15, 16, 18, 22, 28, 38};

  /// Letter-spacing on small-caps labels. Looser than this is unreadable,
  /// tighter loses the caps.
  static const capsSpacing = 1.2;

  /// Glyph sizes beside text.
  static final iconSizes = <double>{12, 14, 16, 18, 22};
}

/// Corner cards (sync, update) share one width; the undo card sizes to its text.
const cornerCardWidth = 360.0;

/// A dialog's outer corners and inner padding, so every dialog matches.
const dialogRadius = 24.0;
const dialogPadding = EdgeInsets.fromLTRB(28, 28, 28, 20);

/// `tileBorder` in three strengths, so edges of the same rank match.
extension PaletteBorders on Palette {
  /// Hairlines inside a card: dividers, quiet outlines.
  Color get borderSoft => tileBorder.withValues(alpha: 0.55);

  /// The outline of a card, field or chip.
  Color get border => tileBorder.withValues(alpha: 0.85);

  /// A deliberate edge, such as an unfilled control.
  Color get borderStrong => tileBorder;
}
