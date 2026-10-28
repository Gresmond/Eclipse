import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/settings_dialog.dart';
import 'package:eclipse/widgets/appear.dart';
import 'package:eclipse/widgets/app_dialog.dart';
import 'package:eclipse/widgets/fade_through.dart';
import 'package:eclipse/widgets/tile.dart';
import 'package:eclipse/widgets/welcome_tour.dart';

void main() {
  testWidgets('tour menus animate on entry and the sync spotlight travels between frames', (tester) async {
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(family['family'] as String);
      for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 25));
    addTearDown(() {
      state.dispose();
      store.close();
    });
    state.startTour();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show me around'));
    await tester.pumpAndSettle();
    for (var step = 1; step < 7; step++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    Rect maskHole() {
      final paint = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).where((widget) {
        if (widget.painter.runtimeType.toString() != '_SpotlightPainter') return false;
        return (widget.painter as dynamic).surface == null;
      }).first;
      return (paint.painter as dynamic).hole as Rect;
    }

    final tourBox = tester.renderObject<RenderBox>(find.byType(WelcomeTour));
    final guide = find.byKey(const ValueKey('tour-guide'));

    // From the month tabs to Settings: the real menu transition starts at zero.
    await tester.tap(find.text('Next'));
    await tester.pump();
    final settingsFade = find.ancestor(of: find.byType(SettingsDialog), matching: find.byType(FadeTransition)).first;
    double settingsOpacity() => tester.widget<FadeTransition>(settingsFade).opacity.value;
    expect(settingsOpacity(), 0);
    await tester.pump(const Duration(milliseconds: 110));
    expect(settingsOpacity(), greaterThan(0));
    expect(settingsOpacity(), lessThan(1));
    await tester.pumpAndSettle();
    expect(settingsOpacity(), 1);
    expect(maskHole(), TourTarget.rectOf(TourSpot.settingsPreview, tourBox, layoutBounds: true));
    final shade = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.painter.runtimeType.toString() == '_SpotlightPainter' &&
          (widget.painter as dynamic).surface != null,
    );
    expect(
      find.ancestor(of: shade, matching: find.byWidget(tester.widget(settingsFade))),
      findsOneWidget,
      reason: 'the shade must fade with the panel, avoiding a dark ghost',
    );
    expect(
      find.ancestor(of: find.byType(SettingsDialog), matching: find.byType(ScaleTransition)),
      findsNothing,
      reason: 'a scaling panel makes its text and toggles wobble',
    );

    final settingsGuide = tester.getTopLeft(guide);
    final guidePositions = [settingsGuide];
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text('Data and backups'), findsOneWidget);
    guidePositions.add(tester.getTopLeft(guide));
    for (var frame = 0; frame < 55; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      guidePositions.add(tester.getTopLeft(guide));
      expect(
        maskHole(),
        TourTarget.rectOf(TourSpot.settingsPreview, tourBox, layoutBounds: true),
        reason: 'the spotlight follows the already-animated dialog height directly',
      );
    }
    await tester.pump(); // Paint the final post-layout measurement.
    final resizedGuide = tester.getTopLeft(guide);
    expect(resizedGuide, isNot(settingsGuide));
    for (var frame = 1; frame < guidePositions.length; frame++) {
      expect(
        (guidePositions[frame] - guidePositions[frame - 1]).distance,
        lessThan(110),
        reason: 'the Settings-to-Data guide must glide instead of jumping between placements',
      );
    }
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(guide),
      resizedGuide,
      reason: 'the guide stays at its destination once its glide completes',
    );

    final before = maskHole();
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(maskHole(), before);
    await tester.pump(); // Apply the newly measured target before advancing time.
    await tester.pump(const Duration(milliseconds: 210));
    final halfway = maskHole();
    expect(halfway, isNot(before));
    await tester.pumpAndSettle();
    final after = maskHole();
    expect(halfway, isNot(after));
    expect(after.width, lessThan(before.width));
    expect(after.height, lessThan(before.height));

    final syncHole = maskHole();
    await tester.tap(find.text('Next'));
    await tester.pump();
    final appearance = find.byWidgetPredicate(
      (widget) => widget is TourTarget && widget.spot == TourSpot.appearancePreview,
    );
    final fade = find.ancestor(of: appearance, matching: find.byType(FadeTransition)).first;
    final scale = find.ancestor(of: appearance, matching: find.byType(ScaleTransition)).first;
    expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
    expect(tester.widget<ScaleTransition>(scale).scale.value, 0.96);
    await tester.pump(); // Apply the menu's final layout bounds.
    final destination = TourTarget.rectOf(TourSpot.appearancePreview, tourBox, layoutBounds: true)!;
    expect(maskHole(), syncHole);
    await tester.pump(const Duration(milliseconds: 210));
    expect(maskHole(), isNot(syncHole));
    expect(maskHole(), isNot(destination));
    expect(TourTarget.rectOf(TourSpot.appearancePreview, tourBox, layoutBounds: true), destination);
    expect(tester.widget<FadeTransition>(fade).opacity.value, greaterThan(0));
    expect(tester.widget<FadeTransition>(fade).opacity.value, lessThan(1));
    expect(tester.widget<ScaleTransition>(scale).scale.value, greaterThan(0.96));
    expect(tester.widget<ScaleTransition>(scale).scale.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 210));
    expect(maskHole(), destination);
    final guideAtArrival = tester.getTopLeft(guide.last);
    await tester.pump(const Duration(milliseconds: 230));
    expect(
      tester.getTopLeft(guide.last),
      guideAtArrival,
      reason: 'the guide finishes with the spotlight instead of trailing the growing menu',
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);

    // Reverse twice before the exits finish; none of the outgoing targets may
    // become the new spotlight destination or leave a stale mask behind.
    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowLeft,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump(const Duration(milliseconds: 45));
    }
    await tester.pumpAndSettle();
    expect(maskHole(), TourTarget.rectOf(TourSpot.settingsPreview, tourBox, layoutBounds: true));
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(maskHole(), TourTarget.rectOf(TourSpot.settingsPreview, tourBox, layoutBounds: true));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(state.touring, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tour and month motion keep heavy content out of per-frame builds', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 25));
    addTearDown(() {
      state.dispose();
      store.close();
    });
    final builds = <String, int>{};
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final type = element.widget.runtimeType.toString();
      builds[type] = (builds[type] ?? 0) + 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    state.startTour();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    for (var step = 0; step < 8; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    // Re-enter Settings and let its initial layout settle before sampling.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();
    builds.clear();
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds['SettingsDialog'] ?? 0, 0);
    expect(builds['_Ribbons'] ?? 0, 0);
    expect(builds['_Card'] ?? 0, 0);
    await tester.pumpAndSettle();
    state.endTour();
    state.showMonth(1);
    await tester.pumpAndSettle();
    state.showMonth(2);
    await tester.pump();
    builds.clear();
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds['_DayHeader'] ?? 0, 0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('an interrupted list exit can return smoothly', (tester) async {
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    var hidden = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (_, value, _) =>
              Appear(animate: false, shown: value, onHidden: () => hidden++, child: const Text('Item')),
        ),
      ),
    );
    shown.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    final fade = find.byType(FadeTransition).last;
    final midway = tester.widget<FadeTransition>(fade).opacity.value;
    expect(midway, inExclusiveRange(0, 1));
    shown.value = true;
    await tester.pump();
    expect(tester.widget<FadeTransition>(fade).opacity.value, midway);
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    expect(hidden, 0);
  });

  testWidgets('dialogs share menu timing on entry and interrupted dismissal', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppDialog<void>(
              context: context,
              builder: (_) => const Dialog(child: Text('Panel')),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    final fade = find.ancestor(of: find.text('Panel'), matching: find.byType(FadeTransition)).first;
    expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
    expect(
      find.ancestor(of: find.text('Panel'), matching: find.byType(ScaleTransition)),
      findsNothing,
      reason: 'dialogs fade without growing, so nothing in them wobbles',
    );
    await tester.pump(Motion.morph ~/ 2);
    expect(tester.widget<FadeTransition>(fade).opacity.value, closeTo(Motion.morphCurve.transform(0.5), 0.001));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Panel'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('open counts roll their digits while the word stays put', (tester) async {
    // A short word, so the test font's wide glyphs still fit the badge.
    final count = ValueNotifier('9 due');
    addTearDown(count.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: themeNamed(null),
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<String>(
              valueListenable: count,
              builder: (_, value, _) => TileHeader(title: 'Today', caption: value),
            ),
          ),
        ),
      ),
    );
    final badge = tester.getRect(find.byType(FadeThrough));
    final word = find.text(' DUE');
    final wordTop = tester.getTopLeft(word).dy;
    final wordLeft = tester.getTopLeft(word).dx;
    count.value = '10 due';
    await tester.pump();
    // The word is the same widget throughout: no fade, no blink.
    final wordElement = tester.element(word);
    double opacity(Finder f) => tester
        .widget<FadeTransition>(find.ancestor(of: f, matching: find.byType(FadeTransition)).first)
        .opacity
        .value;
    expect(opacity(word), 1);
    // Halfway, the new leading 1 is rolling in from below and the word is
    // gliding left to stay centred, part way there.
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.element(word), same(wordElement));
    expect(tester.getTopLeft(word).dy, wordTop);
    final halfway = tester.getTopLeft(word).dx;
    await tester.pumpAndSettle();
    final settled = tester.getTopLeft(word).dx;
    expect(settled, greaterThan(wordLeft));
    expect(halfway, allOf(greaterThan(wordLeft), lessThan(settled)));
    expect(tester.element(word), same(wordElement));
    expect(find.bySemanticsLabel('10 DUE'), findsOneWidget);
    expect(tester.getRect(find.byType(FadeThrough)), badge);
    // A new word fades through instead.
    count.value = 'All clear';
    await tester.pumpAndSettle();
    expect(find.text(' DUE'), findsNothing);
    expect(tester.getCenter(find.text('ALL CLEAR')).dx, moreOrLessEquals(badge.center.dx));
  });
}
