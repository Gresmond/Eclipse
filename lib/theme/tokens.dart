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

  /// The glyph for a role, the same wherever that role appears: a cross
  /// that dismisses or removes, an action on a row, and a step back or on.
  static const dismissIcon = 16.0, rowActionIcon = 14.0, navIcon = 18.0;
}

/// The app's one small-caps label: card counts, page kickers, column and
/// weekday heads. The guard test holds every caps label to it.
TextStyle capsLabel(Color color) => TextStyle(
  fontFamily: Fonts.ui,
  fontSize: 12,
  fontWeight: FontWeight.w600,
  letterSpacing: Scale.capsSpacing,
  color: color,
);

/// The title of every corner card: sync, update, reminder.
TextStyle cornerCardTitle(Color color) =>
    TextStyle(fontFamily: Fonts.display, fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: color);

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
