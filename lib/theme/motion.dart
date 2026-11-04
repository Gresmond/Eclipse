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

  /// Something that opens and then fades in (or fades and then closes):
  /// the room over the first half, the fade over the second.
  static const firstHalf = Interval(0, 0.5, curve: morphCurve);
  static const secondHalf = Interval(0.5, 1, curve: morphCurve);

  /// A page or month fading in under another: plain ease-in.
  static const fadeInCurve = Curves.easeIn;

  /// How long hovering waits before a tooltip shows.
  static const tooltipDelay = Duration(milliseconds: 600);

  /// How long a notice (the undo card, a sync update) stays up.
  static const notice = Duration(seconds: 6);

  /// Reorder overlaps the tick, rather than delaying movement until it lands.
  static const reorder = morph;
  static const scroll = Duration(milliseconds: 120);
  static const page = Duration(milliseconds: 320);

  /// The Training page's corner turning over: a whole page, handled slowly.
  static const turn = Duration(milliseconds: 680);

  /// The light on a task found by search: up, held, then away on
  /// [glowFadeCurve]; [glowBrief] on a task whose subtask was found, and
  /// the subtask's own after [glowDelay], once its task's has gone. One
  /// built within [glowCatch] of the search (as its day fades in) still
  /// lights.
  static const glow = Duration(seconds: 4);
  static const glowBrief = Duration(seconds: 1);
  static const glowDelay = Duration(milliseconds: 700);
  static const glowCatch = Duration(milliseconds: 1500);
  static const glowFadeCurve = Curves.easeInOut;

  /// A fade-through, split in two: the old thing eases out over the first
  /// ~55% of [t] and the new one eases in over the last ~55%, so the two
  /// never show together at any real strength. Both ends are gentle: a
  /// sharp easeOut here blinked to the bare background in about two frames.
  static const incoming = Interval(0.45, 1.0, curve: Curves.easeInOutSine);
  static double outgoing(double t) => incoming.transform(1 - t);
}
