import 'dart:math' as math;

import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/theme/colour_warmth.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('D65 neutrals have zero chroma and model baseline warmth', () {
    for (final c in [const Color(0xff000000), const Color(0xff808080), const Color(0xffffffff)]) {
      expect(colourWarmth(c), closeTo(-0.5, 1e-6));
    }
  });

  test('sRGB red agrees with independently tabulated D65 CIELAB coordinates', () {
    // #ff0000: approximately L*=53.24, a*=80.09, b*=67.20.
    final c = math.sqrt(80.09 * 80.09 + 67.20 * 67.20);
    final h = math.atan2(67.20, 80.09);
    final expected = -0.5 + 0.02 * math.pow(c, 1.07) * math.cos(h - 50 * math.pi / 180);
    expect(colourWarmth(const Color(0xffff0000)), closeTo(expected, 0.002));
    expect(colourWarmth(const Color(0xffff0000)), greaterThan(colourWarmth(const Color(0xff0000ff))));
  });

  test('report actual palette scores and keep pairs ordered by their average', () {
    for (var i = 0; i < palettePairs.length; i++) {
      final pair = palettePairs[i];
      // Retain a reproducible report: flutter test test/colour_warmth_test.dart.
      // ignore: avoid_print
      print(
        '${pair.$1.name} / ${pair.$2.name}: ${palettePairWarmth(pair).toStringAsFixed(4)} '
        '(light ${paletteWarmth(pair.$1).toStringAsFixed(4)}, dark ${paletteWarmth(pair.$2).toStringAsFixed(4)})',
      );
      if (i > 0) expect(palettePairWarmth(pair), greaterThanOrEqualTo(palettePairWarmth(palettePairs[i - 1])));
      expect(partnerOf(pair.$1.name, dark: true), pair.$2);
    }
  });
}
