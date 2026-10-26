import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Predicted perceived warmth from Ou, Luo, Woodcock & Wright (2004),
/// equation 2: WC = -0.5 + 0.02 C*^1.07 cos(h - 50°).
/// https://doi.org/10.1002/col.20010
/// Higher values mean warmer; these are model scores, not temperatures.
/// Input is opaque sRGB, converted to CIELAB with a D65 reference white
/// (matching sRGB and the study's illumination). Do not substitute OKLCH hue.
double colourWarmth(Color colour) {
  double linear(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = linear(colour.r), g = linear(colour.g), b = linear(colour.b);
  // sRGB -> XYZ (D65), using the CSS Color 4 conversion matrix.
  final x = (506752 / 1228815) * r + (87881 / 245763) * g + (12673 / 70218) * b;
  final y = (87098 / 409605) * r + (175762 / 245763) * g + (12673 / 175545) * b;
  final z = (7918 / 409605) * r + (87881 / 737289) * g + (1001167 / 1053270) * b;
  double f(double t) => t > 216 / 24389 ? math.pow(t, 1 / 3).toDouble() : (24389 / 27 * t + 16) / 116;
  // D65 xy = (0.3127, 0.3290), Y = 1.
  final aStar = 500 * (f(x / (0.3127 / 0.3290)) - f(y));
  final bStar = 200 * (f(y) - f(z / ((1 - 0.3127 - 0.3290) / 0.3290)));
  final chroma = math.sqrt(aStar * aStar + bStar * bStar);
  final hue = math.atan2(bStar, aStar);
  return -0.5 + 0.02 * math.pow(chroma, 1.07) * math.cos(hue - 50 * math.pi / 180);
}
