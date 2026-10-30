import 'package:flutter/material.dart';

import 'palette_recipe.dart';
import 'oklch.dart';
import 'colour_warmth.dart';
import 'motion.dart';
import 'tokens.dart';

export 'motion.dart';

/// Font families registered in pubspec.yaml.
abstract final class Fonts {
  /// Page titles, card headings and big numbers.
  static const display = 'Greed';

  /// To-dos, ritual names, labels.
  static const body = 'Matter';

  /// Labels, day numerals, stats. Same as [body] for now.
  static const ui = body;

  /// The sleep schedule's times.
  static const time = 'Haffer SemiMono';
}

/// Every colour the app draws with. Each theme is one instance of this.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.name,
    required this.brightness,
    required this.background,
    required this.tile,
    required this.tileBorder,
    required this.ink,
    required this.inkMuted,
    required this.accent,
    required this.onAccent,
    required this.gradient,
    required this.today,
    required this.onToday,
    required this.done,
    required this.missed,
    required this.other,
    required this.empty,
    required this.shadow,
  });

  final String name;
  final Brightness brightness;

  final Color background;

  /// Card surfaces (the "white tiles" of the spreadsheet).
  final Color tile;
  final Color tileBorder;

  final Color ink;
  final Color inkMuted;
  final Color accent;

  /// Text and icons drawn on the gradient or a status colour.
  final Color onAccent;

  /// Signature gradient for selected tabs, headers and the progress ring:
  /// missed, other, then done, so it always ends on done.
  /// Always three stops, so themes can blend into each other.
  final List<Color> gradient;

  /// Solid fill for the current day's tab in the month view: a fourth hue
  /// of the status harmony, lighter than done, so it never reads as a
  /// ticked box.
  final Color today;

  /// The day letter and number drawn on [today].
  final Color onToday;

  /// Habit status colours.
  final Color done;
  final Color missed;
  final Color other;
  final Color empty;

  final Color shadow;

  @override
  Palette copyWith() => this;

  /// Blends every colour, so switching themes cross-fades.
  @override
  Palette lerp(Palette? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return Palette(
      name: t < 0.5 ? name : other.name,
      brightness: t < 0.5 ? brightness : other.brightness,
      background: c(background, other.background),
      tile: c(tile, other.tile),
      tileBorder: c(tileBorder, other.tileBorder),
      ink: c(ink, other.ink),
      inkMuted: c(inkMuted, other.inkMuted),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      gradient: [for (var i = 0; i < gradient.length; i++) c(gradient[i], other.gradient[i])],
      today: c(today, other.today),
      onToday: c(onToday, other.onToday),
      done: c(done, other.done),
      missed: c(missed, other.missed),
      other: c(this.other, other.other),
      empty: c(empty, other.empty),
      shadow: c(shadow, other.shadow),
    );
  }
}

/// Every theme, generated in OKLCH by [PaletteRecipe]. Each dark theme
/// shares its light partner's key hue and harmony.
final solarEclipsePalette = const PaletteRecipe(
  name: 'Solar Eclipse',
  brightness: Brightness.light,
  // Cool surfaces derived from the blue status.
  keyHue: 255,
  statusChroma: 0.085,
  statusLightness: 0.57,
  harmony: Harmony.analogous,
  surfaceSource: PaletteSource.done,
  accentSource: PaletteSource.done,
).build();

final lunarEclipsePalette = const PaletteRecipe(
  name: 'Lunar Eclipse',
  brightness: Brightness.dark,
  // Violet surfaces derived from the missed status.
  keyHue: 255,
  statusChroma: 0.12,
  statusLightness: 0.58,
  harmony: Harmony.analogous,
  surfaceSource: PaletteSource.missed,
  accentSource: PaletteSource.done,
).build();

final morningPastelPalette = const PaletteRecipe(
  name: 'Morning Pastel',
  brightness: Brightness.light,
  keyHue: 265,
  statusChroma: 0.095,
  statusLightness: 0.78,
  harmony: Harmony.triadic,
  // Cyan holds far more colour than blue at this lightness; this keeps
  // today as soft as the statuses look.
  todayChroma: 0.06,
  swapDoneAndOther: true,
  surfaceSource: PaletteSource.other,
  accentSource: PaletteSource.other,
).build();

final eveningPastelPalette = const PaletteRecipe(
  name: 'Evening Pastel',
  brightness: Brightness.dark,
  // Midnight blue.
  keyHue: 265,
  statusChroma: 0.09,
  statusLightness: 0.76,
  harmony: Harmony.triadic,
  // Cyan holds far more colour than blue at this lightness; this keeps
  // today as soft as the statuses look.
  todayChroma: 0.06,
  swapDoneAndOther: true,
  surfaceSource: PaletteSource.other,
  accentSource: PaletteSource.other,
).build();

final sunrisePalette = const PaletteRecipe(
  name: 'Sunrise',
  brightness: Brightness.light,
  // Blush.
  // A fire sky, soft: apricot, coral-pink and orchid.
  keyHue: 55,
  statusChroma: 0.10,
  statusLightness: 0.58,
  harmony: Harmony.sky,
  vivid: true,
  softness: 0.5,
  surfaceSource: PaletteSource.missed,
  accentSource: PaletteSource.other,
).build();

final sunsetPalette = const PaletteRecipe(
  name: 'Sunset',
  brightness: Brightness.dark,
  // Dark wine.
  // A fire sky, soft: apricot, coral-pink and orchid.
  keyHue: 55,
  statusChroma: 0.10,
  statusLightness: 0.58,
  harmony: Harmony.sky,
  vivid: true,
  softness: 0.5,
  surfaceSource: PaletteSource.other,
  accentSource: PaletteSource.other,
).build();

final orchardDawnPalette = const PaletteRecipe(
  name: 'Orchard Dawn',
  brightness: Brightness.light,
  // Warm cream surfaces derived from the orange status.
  // Pastel apples: green done, orange other, red missed.
  keyHue: 135,
  statusChroma: 0.095,
  statusLightness: 0.78,
  harmony: Harmony.orchard,
  surfaceSource: PaletteSource.other,
  accentSource: PaletteSource.done,
).build();

final orchardDuskPalette = const PaletteRecipe(
  name: 'Orchard Dusk',
  brightness: Brightness.dark,
  // Orange-tinted surfaces, lighter than the other night themes.
  surfaceLift: 0.17,
  // Pastel apples: green done, orange other, red missed.
  keyHue: 135,
  statusChroma: 0.095,
  statusLightness: 0.78,
  harmony: Harmony.orchard,
  surfaceSource: PaletteSource.other,
  accentSource: PaletteSource.done,
).build();

final summerSolsticePalette = const PaletteRecipe(
  name: 'Summer Solstice',
  brightness: Brightness.light,
  // Violet-white surfaces derived from the violet status.
  // Royal blue done, ruby red missed, deep violet other, brighter violet today.
  // Rotate the whole harmony toward ruby; cusp-based colours use the same
  // fraction of available chroma, as Sunrise/Sunset do, without softening.
  keyHue: 255,
  statusChroma: 0.20,
  statusLightness: 0.46,
  harmony: Harmony.celestial,
  vivid: true,
  lightnessSpread: 0.08,
  surfaceSource: PaletteSource.other,
  accentSource: PaletteSource.done,
).build();

final winterSolsticePalette = const PaletteRecipe(
  name: 'Winter Solstice',
  brightness: Brightness.dark,
  // Midnight purple derived from the same violet status as Summer Solstice.
  keyHue: 255,
  statusChroma: 0.20,
  statusLightness: 0.46,
  harmony: Harmony.celestial,
  vivid: true,
  lightnessSpread: 0.08,
  surfaceSource: PaletteSource.other,
  accentSource: PaletteSource.done,
).build();

// A close red/rose harmony: lightness separates the three statuses even
// when their hues look alike. Every surface, ink and gradient still comes
// from the four main colours through the shared palette derivation.
final plutosHeartbreakPalette = derivePalette(
  name: 'Pluto’s Heartbreak',
  brightness: Brightness.light,
  missed: const Oklch(0.56, 0.19, 25).toColor(),
  other: const Oklch(0.71, 0.13, 8).toColor(),
  done: const Oklch(0.86, 0.065, 355).toColor(),
  today: const Oklch(0.94, 0.035, 340).toColor(),
  surfaceSource: PaletteSource.other,
  accentSource: PaletteSource.missed,
);

final plutosRevengePalette = derivePalette(
  name: 'Pluto’s Revenge',
  brightness: Brightness.dark,
  missed: const Oklch(0.56, 0.21, 25).toColor(),
  other: const Oklch(0.69, 0.18, 8).toColor(),
  done: const Oklch(0.82, 0.10, 355).toColor(),
  today: const Oklch(0.92, 0.045, 340).toColor(),
  surfaceSource: PaletteSource.missed,
  accentSource: PaletteSource.missed,
);

/// Equal weighting of the four main colours is our palette aggregation
/// choice, not a claim that the single-colour model was validated for UIs.
double paletteWarmth(Palette p) => [p.done, p.missed, p.other, p.today].map(colourWarmth).reduce((a, b) => a + b) / 4;

double palettePairWarmth((Palette, Palette) pair) => (paletteWarmth(pair.$1) + paletteWarmth(pair.$2)) / 2;

/// Each light theme and its dark partner, sorted by predicted warmth.
/// Keep partners together and give both themes equal weight.
final palettePairs = [
  (morningPastelPalette, eveningPastelPalette),
  (solarEclipsePalette, lunarEclipsePalette),
  (summerSolsticePalette, winterSolsticePalette),
  (plutosHeartbreakPalette, plutosRevengePalette),
  (sunrisePalette, sunsetPalette),
  (orchardDawnPalette, orchardDuskPalette),
]..sort((a, b) => palettePairWarmth(a).compareTo(palettePairWarmth(b)));

final palettes = [
  for (final (light, dark) in palettePairs) ...[light, dark],
];

/// The light or dark theme of [name]'s pair.
Palette partnerOf(String? name, {required bool dark}) {
  final p = paletteNamed(name);
  final pair = palettePairs.firstWhere((pair) => pair.$1 == p || pair.$2 == p);
  return dark ? pair.$2 : pair.$1;
}

Palette paletteNamed(String? name) => palettes.firstWhere((p) => p.name == name, orElse: () => sunrisePalette);

final _themes = {for (final p in palettes) p.name: buildTheme(p)};

/// The cached ThemeData for a palette name (Sunrise when unknown).
ThemeData themeNamed(String? name) => _themes[paletteNamed(name).name]!;

ThemeData buildTheme(Palette p) {
  final scheme = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: p.brightness,
  ).copyWith(surface: p.tile, primary: p.accent, onSurface: p.ink);

  final theme = ThemeData(
    useMaterial3: true,
    dialogTheme: DialogThemeData(
      elevation: 0,
      backgroundColor: p.tile,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(dialogRadius)),
    ),
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    fontFamily: Fonts.ui,
    textSelectionTheme: TextSelectionThemeData(cursorColor: p.accent, selectionColor: p.other.withValues(alpha: 0.3)),
    tooltipTheme: TooltipThemeData(
      waitDuration: Motion.tooltipDelay,
      decoration: BoxDecoration(color: p.ink, borderRadius: BorderRadius.circular(12)),
      textStyle: TextStyle(fontFamily: Fonts.body, color: p.tile, fontSize: 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
    // Flutter's buttons keep the arrow on desktop; everything clickable
    // here shows the hand.
    iconButtonTheme: const IconButtonThemeData(style: _clickable),
    textButtonTheme: const TextButtonThemeData(style: _clickable),
    filledButtonTheme: const FilledButtonThemeData(style: _clickable),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: _clickable),
    elevatedButtonTheme: const ElevatedButtonThemeData(style: _clickable),
    extensions: [p],
  );
  // Body-sized Material text reads one point larger; headlines keep their size.
  // Sizes live in the typography geometry; ThemeData's own textTheme has none.
  final g = theme.typography.englishLike;
  TextStyle up(TextStyle? s) => TextStyle(fontSize: s!.fontSize! + 1);
  return theme.copyWith(
    textTheme: theme.textTheme.merge(TextTheme(
      titleMedium: up(g.titleMedium),
      titleSmall: up(g.titleSmall),
      bodyLarge: up(g.bodyLarge),
      bodyMedium: up(g.bodyMedium),
      bodySmall: up(g.bodySmall),
      labelLarge: up(g.labelLarge),
      labelMedium: up(g.labelMedium),
      labelSmall: up(g.labelSmall),
    )),
  );
}

const _clickable = ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable);

extension PaletteContext on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>()!;
}
