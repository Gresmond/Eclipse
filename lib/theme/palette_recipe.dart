import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'oklch.dart';

/// How the three status hues, and today's, sit around the key hue on the
/// colour wheel.
enum Harmony {
  /// Neighbours 45° either side: calm and cohesive. Today carries the run
  /// on one more step.
  analogous(45, -45, -90),

  /// The two hues either side of the key's opposite: lively, well apart.
  /// Today takes the opposite itself.
  splitComplementary(150, 210, 180),

  /// Three hues 120° apart: the most separation. Today sits halfway
  /// between the key and its neighbour, on the same 60° grid.
  triadic(120, 240, 300),

  /// Neighbours along a fifth of the wheel, in the order a sky fades at
  /// dusk: orange, then crimson, then magenta, and today the violet after.
  sky(-40, -75, -110),

  /// An apple orchard: from a green apple round to an orange and a red
  /// one, on the same 35° steps as [sky] once past the orange, and today
  /// the apple-blossom pink one step further.
  orchard(-75, -110, -145),

  /// A deep-space sky: royal blue, ruby red and violet, with a brighter
  /// blue-violet for today.
  celestial(120, 40, 20);

  const Harmony(this.first, this.second, this.today);

  final double first, second, today;
}

/// One of the four main colours, selected by role rather than a new hue.
enum PaletteSource { done, missed, other, today }

/// A recipe for four main colours; [derivePalette] produces every other
/// slot from those colours alone, with shared rules for each brightness.
/// The three status colours share one chroma (or a fraction of their
/// available gamut in vivid mode). Their hues are set by [harmony]
/// around [keyHue], and a lightness step ([lightnessSpread]) puts done
/// above [statusLightness] and missed below, so they stay apart for
/// colour-blind eyes, which mostly see lightness.
/// Done takes the key hue and missed the other hue nearest red, so it
/// still reads as a warning. Today is a fourth hue of the same harmony,
/// one lightness step above done, so it belongs to the set without
/// passing for any status.
@immutable
class PaletteRecipe {
  const PaletteRecipe({
    required this.name,
    required this.brightness,
    required this.keyHue,
    required this.statusChroma,
    required this.statusLightness,
    this.harmony = Harmony.splitComplementary,
    this.lightnessSpread = 0.12,
    this.vivid = false,
    this.softness = 0,
    this.surfaceLift = 0,
    this.todayChroma,
    this.surfaceSource = PaletteSource.done,
    this.accentSource = PaletteSource.done,
    this.swapDoneAndOther = false,
  });

  final String name;
  final Brightness brightness;
  final double keyHue, statusChroma, statusLightness;
  final Harmony harmony;
  final double lightnessSpread;

  /// Each status at its hue's cusp (see [Oklch.cusp]) with 85% of the
  /// chroma it can have there, instead of one shared lightness and chroma.
  /// Warm hues at a shared mid lightness turn brown (orange) and olive
  /// (yellow); at their cusps they stay as bright as a sky. All three are
  /// still equally vivid, relative to what each hue can reach.
  final bool vivid;

  /// How far a [vivid] theme's statuses move from their cusps toward
  /// pastel, 0-1: lighter, and with less of the chroma they could have.
  final double softness;

  /// How far a dark theme's surfaces sit above the usual night-time ladder,
  /// in OKLCH lightness: a dusk rather than a midnight.
  final double surfaceLift;

  /// Today's chroma, when it shouldn't share [statusChroma]: cyan can hold
  /// far more colour than blue or pink at a pastel's lightness, so the
  /// shared chroma that is gentle on them turns it neon.
  final double? todayChroma;

  /// Which main colour supplies the hue and chroma for surfaces and ink.
  final PaletteSource surfaceSource;

  /// Which main colour supplies the accent, adjusted only for readability.
  final PaletteSource accentSource;

  /// Preserve the exact status shades while exchanging their roles.
  final bool swapDoneAndOther;

  /// Hues of done, missed and other.
  (double, double, double) get statusHues {
    final a = turn(keyHue, harmony.first), b = turn(keyHue, harmony.second);
    // Red sits near 25° in OKLCH.
    return hueDistance(a, 25) <= hueDistance(b, 25) ? (keyHue, a, b) : (keyHue, b, a);
  }

  Palette build() {
    final (doneHue, missedHue, otherHue) = statusHues;
    Color status(double hue, double step, [double? chroma]) {
      if (!vivid) return Oklch(statusLightness + step * lightnessSpread / 2, chroma ?? statusChroma, hue).toColor();
      final cusp = Oklch.cusp(hue);
      // Softening pulls the cusps together, so the lightness step still
      // applies.
      final l = cusp.l + (0.88 - cusp.l) * softness + step * lightnessSpread / 2;
      return Oklch(l, Oklch.maxChroma(l, hue) * 0.85 * (1 - 0.5 * softness), hue).toColor();
    }

    final originalDone = status(doneHue, 1), originalOther = status(otherHue, 0);
    final done = swapDoneAndOther ? originalOther : originalDone;
    final other = swapDoneAndOther ? originalDone : originalOther;
    final missed = status(missedHue, -1);
    final today = status(turn(keyHue, harmony.today), 2, todayChroma);

    return derivePalette(
      name: name,
      brightness: brightness,
      done: done,
      missed: missed,
      other: other,
      today: today,
      surfaceSource: surfaceSource,
      accentSource: accentSource,
      surfaceLift: surfaceLift,
    );
  }
}

/// The only colour inputs to the 17 palette slots are the four main colours.
/// Source selectors refer to those inputs; brightness and surface lift set
/// lightness, never an independent hue or chroma. All tint strengths are
/// shared across themes, and sRGB fitting preserves each source's hue.
Palette derivePalette({
  required String name,
  required Brightness brightness,
  required Color done,
  required Color missed,
  required Color other,
  required Color today,
  PaletteSource surfaceSource = PaletteSource.done,
  PaletteSource accentSource = PaletteSource.done,
  double surfaceLift = 0,
}) {
  final dark = brightness == Brightness.dark;
  Color source(PaletteSource role) => switch (role) {
    PaletteSource.done => done,
    PaletteSource.missed => missed,
    PaletteSource.other => other,
    PaletteSource.today => today,
  };
  final surface = Oklch.of(source(surfaceSource));
  final neutralChroma = surface.c * (dark ? 0.30 : 0.20);
  Color neutral(double l, [double chromaScale = 1]) => Oklch(l, neutralChroma * chromaScale, surface.h).toColor();
  double night(double l) => l + surfaceLift;

  final ink = neutral(dark ? 0.955 : 0.24, 2);
  // Marks drawn on the status colours: white when it clears 3:1 on all
  // three, else the darkest ink.
  final white = neutral(1, 0);
  final darkInk = neutral(0.22, 2);
  final onAccent = [done, missed, other].every((c) => contrast(white, c) >= 3) ? white : darkInk;
  final accent = Oklch.of(source(accentSource));
  final accentL = dark ? 0.80 : 0.50;
  final accentC = math.min(accent.c, Oklch.maxChroma(accentL, accent.h) * 0.85);
  final onToday = contrast(white, today) >= contrast(darkInk, today) ? white : darkInk;

  return Palette(
    name: name,
    brightness: brightness,
    background: neutral(dark ? night(0.165) : 0.965),
    tile: neutral(dark ? night(0.205) : 0.992, dark ? 1 : 0.5),
    tileBorder: neutral(dark ? night(0.285) : 0.905),
    ink: ink,
    // Lifted surfaces need lighter muted text to keep its contrast.
    inkMuted: neutral(dark ? 0.73 + surfaceLift / 2 : 0.52, 2),
    accent: Oklch(accentL, accentC, accent.h).toColor(),
    onAccent: onAccent,
    // Runs from missed through other to done, so it ends on the goal.
    gradient: [missed, other, done].map((c) {
      final o = Oklch.of(c);
      return Oklch(o.l, o.c * 1.1, o.h).toColor();
    }).toList(),
    today: today,
    onToday: onToday,
    done: done,
    missed: missed,
    other: other,
    empty: neutral(dark ? night(0.255) : 0.94),
    shadow: neutral(dark ? 0.12 : 0.35),
  );
}
