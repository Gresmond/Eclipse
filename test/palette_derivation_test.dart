import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/theme/oklch.dart';
import 'package:eclipse/theme/palette_recipe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<Color> _slots(Palette p) => [
  p.background,
  p.tile,
  p.tileBorder,
  p.ink,
  p.inkMuted,
  p.accent,
  p.onAccent,
  ...p.gradient,
  p.today,
  p.onToday,
  p.done,
  p.missed,
  p.other,
  p.empty,
  p.shadow,
];

void main() {
  test('all 17 slots stay within each theme’s four main hue families', () {
    for (final p in palettes) {
      final hues = [p.done, p.missed, p.other, p.today].map((c) => Oklch.of(c).h).toList();
      expect(_slots(p), hasLength(17));
      for (final colour in _slots(p)) {
        final o = Oklch.of(colour);
        // Achromatic endpoints (for example white marks) have no meaningful hue.
        if (o.c < 0.0005) continue;
        expect(
          // Allow small conversion drift in nearly white, low-chroma surfaces.
          hues.any((h) => hueDistance(h, o.h) < 2),
          isTrue,
          reason: '${p.name}: $o must come from one of its four main hues',
        );
      }
    }
  });

  test('any of the four main colours can supply surfaces in either brightness', () {
    final colours = [
      const Oklch(0.65, 0.12, 265).toColor(),
      const Oklch(0.55, 0.12, 20).toColor(),
      const Oklch(0.60, 0.12, 310).toColor(),
      const Oklch(0.75, 0.12, 145).toColor(),
    ];
    for (final brightness in Brightness.values) {
      for (final source in PaletteSource.values) {
        final p = derivePalette(
          name: 'Four inputs',
          brightness: brightness,
          done: colours[0],
          missed: colours[1],
          other: colours[2],
          today: colours[3],
          surfaceSource: source,
          accentSource: source,
        );
        final base = Oklch.of(colours[source.index]);
        for (final colour in [p.background, p.tile, p.tileBorder, p.ink, p.inkMuted, p.empty, p.shadow, p.accent]) {
          expect(hueDistance(Oklch.of(colour).h, base.h), lessThan(2));
        }
        expect([p.done, p.missed, p.other, p.today], colours);
      }
    }
  });
}
