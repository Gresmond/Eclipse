import 'dart:convert';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/tokens.dart';
import 'package:eclipse/widgets/progress_ring.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
    final bad = offenders(RegExp(r'Radius\.circular\(([0-9.]+)\)'), (v) => Scale.radii.contains(double.parse(v)));
    expect(bad, isEmpty);
  });

  test('literal font sizes are on the scale', () {
    final bad = offenders(RegExp(r'fontSize: ([0-9.]+)'), (v) => Scale.fontSizes.contains(double.parse(v)));
    expect(bad, isEmpty);
  });

  test('font sizes in expressions are on the scale too', () {
    // Sizes in proportion to a drawn shape: the ring's figures, a mark's glyph.
    const proportional = ['widgets/progress_ring.dart', 'widgets/mark.dart'];
    final bad = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        final m = RegExp(r'fontSize: ([^,)]+)').firstMatch(lines[i]);
        if (m == null) continue;
        final expression = m.group(1)!;
        if (proportional.any(f.path.endsWith)) continue;
        final computed = RegExp(r'[*/]').hasMatch(expression);
        final literals = RegExp(r'(?<![\w.])[0-9]+(?:\.[0-9]+)?')
            .allMatches(expression)
            .map((l) => double.parse(l.group(0)!));
        // A comparison's number isn't a size: `size >= 30 ? 14 : 12`.
        final sizes = expression.contains('?')
            ? RegExp(r'[?:]\s*([0-9.]+)').allMatches(expression).map((l) => double.parse(l.group(1)!))
            : literals;
        if (computed || !sizes.every(Scale.fontSizes.contains)) bad.add('${f.path}:${i + 1}  ${m.group(0)}');
      }
    }
    expect(bad, isEmpty);
  });

  test('all tracking looser than none is the one small-caps value', () {
    final bad = offenders(
      RegExp(r'letterSpacing: ([0-9.]+)'),
      (v) => double.parse(v) == 0 || double.parse(v) == Scale.capsSpacing,
    );
    expect(bad, isEmpty);
  });

  test('small-caps labels outside the gym use capsLabel', () {
    final bad = <String>[];
    for (final f in files.where((f) => !f.path.contains('training'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        final caps =
            lines[i].contains('.toUpperCase()') ||
            RegExp(r"Text\(\s*'[A-Z]{2}[A-Z ]*'").hasMatch(lines[i]) ||
            RegExp(r"^\s*'[A-Z]{2}[A-Z ]*',$").hasMatch(lines[i]);
        if (!caps) continue;
        final next = lines.sublist(i, i + 4 > lines.length ? lines.length : i + 4).join(' ');
        if (next.contains('TextStyle(')) bad.add('${f.path}:${i + 1}');
      }
    }
    expect(bad, isEmpty);
  });

  test('text is not faded below AA: hints use inkMuted whole', () {
    expect(offenders(RegExp(r'(hintStyle:.*withValues\(alpha)'), (_) => false), isEmpty);
    expect(offenders(RegExp(r'(backgroundColor: p\.(?:accent|other)\b)'), (_) => false), isEmpty);
  });

  test('every corner card title is the shared one', () {
    final bad = offenders(RegExp(r'(fontFamily: Fonts\.display, fontSize: 18, fontWeight)'), (_) => false);
    expect(bad, isEmpty);
  });

  test('dialogs use the shared system, not Material’s AlertDialog or headline', () {
    final dialogs = files.where((f) => !f.path.endsWith('app_dialog.dart'));
    final bad = <String>[];
    for (final f in dialogs) {
      final source = f.readAsStringSync();
      for (final needle in ['AlertDialog(', 'textTheme.headlineSmall']) {
        final plain = source.replaceAll('AppAlertDialog(', '');
        if (plain.contains(needle)) bad.add('${f.path}: $needle');
      }
    }
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

  group('rendered', () {
    late Store store;
    late AppState state;

    setUpAll(() async {
      final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final family in manifest.cast<Map<String, dynamic>>()) {
        final loader = FontLoader(family['family'] as String);
        for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
          loader.addFont(rootBundle.load(font['asset'] as String));
        }
        await loader.load();
      }
    });

    Future<void> pumpApp(WidgetTester tester, {Size size = const Size(2500, 1380), double scale = 1}) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() {
        tester.view.reset();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      store = Store.memory();
      state = AppState(store, clock: () => DateTime(2026, 11, 3, 10));
      addTearDown(() {
        state.dispose();
        store.close();
      });
      store.addHabit(2026, 11, 'Stretch');
      state.addTodo(TodoScope.today, 'A plain task');
      state.addTodo(TodoScope.today, 'A timed task', time: 600, location: 'Somewhere');
      state.addTodo(
        TodoScope.month,
        'Dentist',
        dueDate: DateTime(2026, 11, 20),
        time: 510,
        location: 'A very long street name that has to give way to the time',
      );
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
    }

    /// Every font size on screen but glyphs and the ring's own figures.
    Set<double> sizesOnScreen(WidgetTester tester) {
      final sizes = <double>{};
      for (final element in find.byType(RichText).evaluate()) {
        if (element.findAncestorWidgetOfExactType<ProgressRing>() != null) continue;
        (element.widget as RichText).text.visitChildren((span) {
          final style = span.style;
          if (style?.fontSize != null && style!.fontFamily != 'MaterialIcons') sizes.add(style.fontSize!);
          return true;
        });
      }
      return sizes;
    }

    testWidgets('every size on Today, the month and the year is on the scale', (tester) async {
      await pumpApp(tester);
      try {
        final seen = <double>{...sizesOnScreen(tester)};
        state.showMonth(11);
        await tester.pumpAndSettle();
        seen.addAll(sizesOnScreen(tester));
        state.showYear();
        await tester.pumpAndSettle();
        seen.addAll(sizesOnScreen(tester));
        expect(seen.difference(Scale.fontSizes), isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a further-ahead caption keeps its time whole at the minimum window', (tester) async {
      await pumpApp(tester, size: const Size(1216, 800));
      try {
        final card = find.byType(FurtherAheadCard);
        final time = find.descendant(of: card, matching: find.text(clockLabel(510)));
        expect(time, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(time);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(paragraph.size.width, greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity) - 0.01));
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a checkbox centres on its task’s name, whatever is above or below it', (tester) async {
      await pumpApp(tester);
      try {
        for (final name in ['A plain task', 'A timed task']) {
          final check = find.ancestor(of: find.text(name), matching: find.byType(Row)).first;
          final paint = find.descendant(of: check, matching: find.byType(CustomPaint)).first;
          expect(tester.getCenter(paint).dy, closeTo(tester.getCenter(find.text(name)).dy, 1));
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
