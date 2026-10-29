import 'package:flutter/animation.dart';

/// Shared timings by interaction purpose.
abstract final class Motion {
  /// Hover and press: highlights, lifts and dips.
  static const hover = Duration(milliseconds: 110);
  static const hoverCurve = Curves.easeOutCubic;

  /// A click's result: a tick, a toggle, a swapped word.
  static const click = Duration(milliseconds: 160);
  static const clickCurve = Curves.easeOutCubic;

  /// Things that move or arrive: month changes, gliding pills, new items,
  /// rest days, theme changes.
  static const morph = Duration(milliseconds: 240);
  static const morphCurve = Curves.easeInOutCubic;

  /// Reorder overlaps the tick, rather than delaying movement until it lands.
  static const reorder = morph;
  static const scroll = Duration(milliseconds: 120);
  static const page = Duration(milliseconds: 320);

  /// The Training page's corner turning over: a whole page, handled slowly.
  static const turn = Duration(milliseconds: 680);

  /// A fade-through, split in two: the old thing eases out over the first
  /// ~55% of [t] and the new one eases in over the last ~55%, so the two
  /// never show together at any real strength. Both ends are gentle: a
  /// sharp easeOut here blinked to the bare background in about two frames.
  static const incoming = Interval(0.45, 1.0, curve: Curves.easeInOutSine);
  static double outgoing(double t) => incoming.transform(1 - t);
}
