import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// OKLCH, a perceptual colour space: equal steps of lightness [l] (0-1),
/// chroma [c] and hue [h] (degrees) look like equal steps to the eye.
/// From Björn Ottosson's OKLab.
@immutable
class Oklch {
  const Oklch(this.l, this.c, this.h);

  final double l, c, h;

  /// The sRGB colour, with chroma reduced until it fits (keeping lightness
  /// and hue, which matter more to the eye).
  Color toColor() {
    if (_inGamut(_linear(l, c, h))) return _encode(_linear(l, c, h));
    var lo = 0.0, hi = c;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      _inGamut(_linear(l, mid, h)) ? lo = mid : hi = mid;
    }
    return _encode(_linear(l, lo, h));
  }

  /// The most chroma sRGB can show at lightness [l] and hue [h].
  static double maxChroma(double l, double h) {
    var lo = 0.0, hi = 0.5;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      _inGamut(_linear(l, mid, h)) ? lo = mid : hi = mid;
    }
    return lo;
  }

  /// Hue [h] at its most vivid: the lightness where sRGB shows it with the
  /// most chroma. Yellow peaks bright, blue and purple deep.
  static Oklch cusp(double h) {
    var best = Oklch(0.5, 0, h);
    for (var l = 0.2; l < 0.99; l += 0.005) {
      final c = maxChroma(l, h);
      if (c > best.c) best = Oklch(l, c, h);
    }
    return best;
  }

  static Oklch of(Color color) {
    final (r, g, b) = (_toLinear(color.r), _toLinear(color.g), _toLinear(color.b));
    final lab = _labFromLinear(r, g, b);
    final c = math.sqrt(lab.$2 * lab.$2 + lab.$3 * lab.$3);
    final h = (math.atan2(lab.$3, lab.$2) * 180 / math.pi) % 360;
    return Oklch(lab.$1, c, h);
  }

  @override
  String toString() => 'oklch(${l.toStringAsFixed(3)} ${c.toStringAsFixed(3)} ${h.toStringAsFixed(1)})';
}

/// Hue [a] turned by [degrees], kept within 0-360.
double turn(double a, double degrees) => (a + degrees) % 360;

/// Angle between two hues, 0-180.
double hueDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// WCAG 2 contrast ratio, 1-21. Text wants 4.5, icons and shapes 3.
double contrast(Color a, Color b) {
  final (la, lb) = (_luminance(a), _luminance(b));
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Distance in OKLab; about 0.02 is just noticeable, 0.1 clearly different.
double deltaE(Color a, Color b) {
  final x = _lab(a), y = _lab(b);
  return math.sqrt(math.pow(x.$1 - y.$1, 2) + math.pow(x.$2 - y.$2, 2) + math.pow(x.$3 - y.$3, 2));
}

enum ColourBlindness { protanopia, deuteranopia, tritanopia }

/// How [color] looks with full [type] colour blindness (Machado, Oliveira
/// and Fernandes 2009, severity 1).
Color simulate(Color color, ColourBlindness type) {
  final m = switch (type) {
    ColourBlindness.protanopia => const [
      [0.152286, 1.052583, -0.204868],
      [0.114503, 0.786281, 0.099216],
      [-0.003882, -0.048116, 1.051998],
    ],
    ColourBlindness.deuteranopia => const [
      [0.367322, 0.860646, -0.227968],
      [0.280085, 0.672501, 0.047413],
      [-0.011820, 0.042940, 0.968881],
    ],
    ColourBlindness.tritanopia => const [
      [1.255528, -0.076749, -0.178779],
      [-0.078411, 0.930809, 0.147602],
      [0.004733, 0.691367, 0.303900],
    ],
  };
  final v = [_toLinear(color.r), _toLinear(color.g), _toLinear(color.b)];
  double row(int i) => (m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2]).clamp(0.0, 1.0);
  return _encode((row(0), row(1), row(2)));
}

double _luminance(Color c) => 0.2126 * _toLinear(c.r) + 0.7152 * _toLinear(c.g) + 0.0722 * _toLinear(c.b);

(double, double, double) _lab(Color c) => _labFromLinear(_toLinear(c.r), _toLinear(c.g), _toLinear(c.b));

(double, double, double) _labFromLinear(double r, double g, double b) {
  final l = _cbrt(0.4122214708 * r + 0.5363494308 * g + 0.0514459929 * b);
  final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return (
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  );
}

(double, double, double) _linear(double lightness, double chroma, double hue) {
  final rad = hue * math.pi / 180;
  final a = chroma * math.cos(rad), b = chroma * math.sin(rad);
  final l = math.pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3).toDouble();
  final m = math.pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3).toDouble();
  final s = math.pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3).toDouble();
  return (
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  );
}

bool _inGamut((double, double, double) rgb) {
  const e = 1e-6;
  return [rgb.$1, rgb.$2, rgb.$3].every((v) => v >= -e && v <= 1 + e);
}

Color _encode((double, double, double) rgb) {
  double enc(double v) {
    v = v.clamp(0.0, 1.0);
    return v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
  }

  return Color.from(alpha: 1, red: enc(rgb.$1), green: enc(rgb.$2), blue: enc(rgb.$3));
}

double _toLinear(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
