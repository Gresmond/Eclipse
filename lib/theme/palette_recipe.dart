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
    this.surfaceHue,
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

  /// The hue of surfaces, when none of the main colours has the right one.
  final double? surfaceHue;

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
      surfaceHue: surfaceHue,
    );
  }
}

/// The only colour inputs to the 17 palette slots are the four main colours.
/// Source selectors refer to those inputs for hue; brightness and surface
/// lift set lightness. Surface chroma and all tint strengths are shared
/// across themes, and sRGB fitting preserves each source's hue.
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
  double? surfaceHue,
}) {
  final dark = brightness == Brightness.dark;
  Color source(PaletteSource role) => switch (role) {
    PaletteSource.done => done,
    PaletteSource.missed => missed,
    PaletteSource.other => other,
    PaletteSource.today => today,
  };
  final surfaceH = surfaceHue ?? Oklch.of(source(surfaceSource)).h;
  final neutralChroma = dark ? _nightNeutralChroma : _dayNeutralChroma;
  Color neutral(double l, [double chromaScale = 1]) => Oklch(l, neutralChroma * chromaScale, surfaceH).toColor();
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
  // Text on a done fill takes whichever ink reads best on it.
  final onDone = contrast(white, done) >= contrast(darkInk, done) ? white : darkInk;
  final backgroundL = dark ? night(_nightBackgroundL) : _dayBackground.$1;
  final backgroundC = dark ? Oklch.maxChroma(backgroundL, surfaceH) * _nightBackgroundShare : _dayBackground.$2;
  final background = Oklch(backgroundL, backgroundC, surfaceH).toColor();
  // Night surfaces carry most of the background's colour, so none of them
  // turns grey beside a strong one.
  Color nightSurface(double l) => Oklch(night(l), backgroundC * _nightSurfaceShare, surfaceH).toColor();
  // Colour stays in the window's frame: cards sit near white by day and
  // below the background at night.
  final tile = dark ? nightSurface(0.155) : neutral(0.992, 0.5);
  // Runs from missed through other to done, so it ends on the goal. Labels
  // sit on it in [onAccent], so the whole run moves away from that ink,
  // in one lightness step, until its worst stop reads as text.
  final stops = [missed, other, done].map((c) {
    final o = Oklch.of(c);
    return Oklch(o.l, o.c * 1.1, o.h);
  }).toList();
  final away = onAccent == white ? -1 : 1;
  var shift = 0.0;
  List<Color> shifted() => [
    for (final o in stops)
      shift == 0 ? o.toColor() : Oklch(o.l + shift, math.min(o.c, Oklch.maxChroma(o.l + shift, o.h)), o.h).toColor(),
  ];
  while (shifted().any((c) => contrast(onAccent, c) < _textContrast) && shift.abs() < 0.5) {
    shift += away * 0.005;
  }

  final empty = dark ? nightSurface(0.255) : neutral(0.94);

  return Palette(
    name: name,
    brightness: brightness,
    background: background,
    tile: tile,
    tileBorder: dark ? nightSurface(0.285) : neutral(0.905),
    ink: ink,
    // Lifted surfaces need lighter muted text to keep its contrast.
    inkMuted: readable(neutral(dark ? 0.73 + surfaceLift / 2 : 0.52, 2), [background, tile], dark: dark),
    accent: readable(Oklch(accentL, accentC, accent.h).toColor(), [background, tile, empty], dark: dark),
    onAccent: onAccent,
    onDone: onDone,
    gradient: shifted(),
    today: today,
    onToday: onToday,
    done: done,
    missed: missed,
    missedInk: readable(missed, [tile, background], dark: dark),
    other: other,
    otherInk: readable(other, [tile, background], dark: dark),
    empty: empty,
    shadow: neutral(dark ? 0.12 : 0.35),
  );
}

/// Every light theme's background, as OKLCH lightness and chroma.
const _dayBackground = (0.9325, 0.03);

/// Every dark theme's background lightness, and its share of the chroma sRGB
/// can hold at that lightness and hue, so all of them are equally colourful
/// relative to what their hue can reach. One fixed chroma leaves red and
/// orange looking grey beside blue and violet.
const _nightBackgroundL = 0.1875, _nightBackgroundShare = 0.8;

/// A dark theme's cards, borders, chips and panels, as a share of its
/// background's chroma.
const _nightSurfaceShare = 0.75;

/// The chroma of ink and shadows, and by day of every surface but the
/// background, below the background's so the colour stays in the window's
/// frame.
const _dayNeutralChroma = 0.017, _nightNeutralChroma = 0.03;

/// WCAG AA for body text.
const _textContrast = 4.5;

/// [colour] with its lightness moved away from [surfaces] (darker on a
/// light theme, lighter on a dark one) until it clears 4.5:1 on all of
/// them; its hue stays, and its chroma only as far as the gamut allows.
Color readable(Color colour, List<Color> surfaces, {required bool dark}) {
  final o = Oklch.of(colour);
  var l = o.l;
  Color at(double l) => Oklch(l, math.min(o.c, Oklch.maxChroma(l, o.h)), o.h).toColor();
  while (surfaces.any((s) => contrast(at(l), s) < _textContrast) && l > 0 && l < 1) {
    l += dark ? 0.005 : -0.005;
  }
  return l == o.l ? colour : at(l);
}
