import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/theme/oklch.dart' show contrast;
import 'package:eclipse/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG AA, on every theme: 4.5:1 for all text, labels on fills included,
/// and 3:1 for marks and glyphs that carry meaning.
void main() {
  const text = 4.5, mark = 3.0;

  Color over(Color top, Color bottom) => Color.alphaBlend(top, bottom);

  test('there are twelve themes to check', () => expect(palettes, hasLength(12)));

  for (final p in palettes) {
    group(p.name, () {
      final panel = over(p.todayPanel, p.tile);
      final surfaces = {'tile': p.tile, 'background': p.background};

      void passes(String what, Color foreground, Color background, double least) {
        expect(contrast(foreground, background), greaterThanOrEqualTo(least), reason: what);
      }

      test('secondary text reads on every surface it sits on', () {
        for (final MapEntry(key: name, value: surface) in {
          ...surfaces,
          'today panel': panel,
          'pill': over(p.empty.withValues(alpha: 0.6), p.tile),
        }.entries) {
          passes('ink on $name', p.ink, surface, text);
          passes('inkMuted on $name', p.inkMuted, surface, text);
          passes('accent on $name', p.accent, surface, text);
        }
      });

      test('error and status-coloured text reads', () {
        for (final MapEntry(key: name, value: surface) in surfaces.entries) {
          passes('missedInk on $name', p.missedInk, surface, text);
          passes('otherInk on $name', p.otherInk, surface, text);
        }
      });

      test('a carried task’s glyph reads on its pill', () {
        passes('missedInk on carried pill', p.missedInk, over(p.missed.withValues(alpha: 0.12), panel), mark);
      });

      test('labels on a done fill read', () => passes('onDone on done', p.onDone, p.done, text));

      test('labels read all along the gradient', () {
        final (a, b, c) = (p.gradient[0], p.gradient[1], p.gradient[2]);
        for (var t = 0.0; t <= 1; t += 0.1) {
          passes('onAccent at $t', p.onAccent, Color.lerp(a, b, t)!, text);
          passes('onAccent at 1+$t', p.onAccent, Color.lerp(b, c, t)!, text);
        }
      });

      test('marks read on every status', () {
        for (final status in [p.done, p.missed, p.other]) {
          passes('onAccent mark', p.onAccent, status, mark);
        }
      });

      test('today’s letter reads', () => passes('onToday on today', p.onToday, p.today, text));

      test('the theme’s filled buttons are the done fill with its ink', () {
        final style = buildTheme(p).filledButtonTheme.style!;
        expect(style.backgroundColor!.resolve({}), p.done);
        expect(style.foregroundColor!.resolve({}), p.onDone);
      });

      test('the theme’s tooltips read', () => passes('tooltip', p.tile, p.ink, text));
    });
  }

  test('the theme’s text styles are on the type scale, with no tracking of their own', () {
    for (final p in palettes) {
      final t = buildTheme(p).textTheme;
      for (final style in [
        t.displayLarge, t.displayMedium, t.displaySmall,
        t.headlineLarge, t.headlineMedium, t.headlineSmall,
        t.titleLarge, t.titleMedium, t.titleSmall,
        t.bodyLarge, t.bodyMedium, t.bodySmall,
        t.labelLarge, t.labelMedium, t.labelSmall,
      ]) {
        expect(Scale.fontSizes, contains(style!.fontSize), reason: '$style');
        expect(style.letterSpacing, 0, reason: '$style');
      }
    }
  });
}
