import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/theme/tokens.dart';

/// Every size, corner and edge in lib/ comes from the scales in
/// theme/tokens.dart. A new value is a decision made there, not a literal.
void main() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('theme/tokens.dart') && !f.path.contains('/data/'))
      .toList();

  List<String> offenders(RegExp pattern, bool Function(String value) allowed) {
    final found = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        for (final m in pattern.allMatches(lines[i])) {
          if (!allowed(m.group(1)!)) found.add('${f.path}:${i + 1}  ${m.group(0)}');
        }
      }
    }
    return found;
  }

  test('corner radii are on the scale', () {
    final bad = offenders(
      RegExp(r'Radius\.circular\(([0-9.]+)\)'),
      (v) => Scale.radii.contains(double.parse(v)),
    );
    expect(bad, isEmpty);
  });

  test('literal font sizes are on the scale', () {
    final bad = offenders(
      RegExp(r'fontSize: ([0-9.]+)'),
      (v) => Scale.fontSizes.contains(double.parse(v)),
    );
    expect(bad, isEmpty);
  });

  test('small-caps letter-spacing is one value', () {
    final bad = offenders(
      RegExp(r'letterSpacing: (1\.[0-9]+)'),
      (v) => double.parse(v) == Scale.capsSpacing,
    );
    expect(bad, isEmpty);
  });

  test('icons are rounded and on the size scale', () {
    expect(offenders(RegExp(r'(Icons\.\w+_(?:outlined|sharp))'), (_) => false), isEmpty);
    final bad = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final m = RegExp(r'\b(?:size|iconSize): ([0-9.]+)').firstMatch(lines[i]);
        if (m == null || lines[i].contains('fontSize')) continue;
        final context = lines.sublist(i < 3 ? 0 : i - 3, i + 1).join(' ');
        if (!context.contains('Icons.') && !lines[i].contains('iconSize')) continue;
        final v = double.parse(m.group(1)!);
        if (v <= 22 && !Scale.iconSizes.contains(v)) bad.add('${f.path}:${i + 1}  ${m.group(0)}');
      }
    }
    expect(bad, isEmpty);
  });

  test('card edges use the border tiers, not ad-hoc opacity', () {
    final bad = offenders(
      RegExp(r'(tileBorder\.withValues\(alpha: [0-9.]+\))'),
      (_) => false,
    ).where((s) => !s.contains('theme/')).toList();
    expect(bad, isEmpty);
  });
}
