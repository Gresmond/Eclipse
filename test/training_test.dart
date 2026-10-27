import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/training_log.dart';

const _shots = String.fromEnvironment('SCREENSHOT_DIR');

Future<void> _shot(WidgetTester tester, String name) async {
  if (_shots.isEmpty) return;
  final view = tester.binding.renderViews.first;
  await tester.runAsync(() async {
    final image = await (view.debugLayer! as OffsetLayer).toImage(Offset.zero & view.size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

/// The user's own example session, logged on [day] with [extra] kg added
/// to every weight, so a few days make a rising line.
void _logExample(TrainingLog log, DateTime day, double extra) {
  Exercise named(String name, MuscleGroup g, {bool bodyweight = false}) =>
      log.exercises.where((e) => e.name == name).firstOrNull ?? log.createExercise(name, g, bodyweight: bodyweight);
  for (final (name, group, bw, sets) in [
    ('Pec deck', MuscleGroup.chest, false, [(106.0, 7), (106.0, 6)]),
    ('Pullups', MuscleGroup.back, true, [(0.0, 8), (0.0, 7)]),
    ('Lateral raises', MuscleGroup.shoulders, false, [(15.0, 14), (15.0, 12)]),
    ('Tricep pushdowns', MuscleGroup.triceps, false, [(32.5, 12), (32.5, 9)]),
    ('Calf raises', MuscleGroup.calves, false, [(145.0, 18), (145.0, 16)]),
  ]) {
    final e = named(name, group, bodyweight: bw);
    log.addToDay(day, e);
    for (var i = 1; i < sets.length; i++) {
      log.addSet(day, e);
    }
    final logged = log.session(day).firstWhere((s) => s.$1.uid == e.uid).$2;
    for (final (i, (w, r)) in sets.indexed) {
      log.updateSet(logged[i], reps: r + (extra ~/ 4), weight: bw ? null : w + extra, clearWeight: bw);
    }
  }
}

void main() {
  group('1RM estimate', () {
    test('one rep is the weight itself', () => expect(estimateOneRepMax(100, 1), 100));
    test('Epley up to 10', () {
      expect(estimateOneRepMax(106, 7), closeTo(106 * (1 + 7 / 30), 1e-9));
      expect(estimateOneRepMax(100, 10), closeTo(133.333, 1e-3));
    });
    test('blends from Epley at 10 to Mayhew at 12, with no jump', () {
      double mayhew(double w, int r) => w * 100 / (52.2 + 41.9 * math.exp(-0.055 * r));
      expect(estimateOneRepMax(100, 12), closeTo(mayhew(100, 12), 1e-6));
      final at11 = estimateOneRepMax(100, 11)!;
      expect(at11, closeTo(0.5 * 100 * (1 + 11 / 30) + 0.5 * mayhew(100, 11), 1e-6));
    });
    test('Mayhew to 20; beyond that, none', () {
      expect(estimateOneRepMax(145, 18), closeTo(145 * 100 / (52.2 + 41.9 * math.exp(-0.055 * 18)), 1e-9));
      expect(estimateOneRepMax(145, 21), isNull);
    });
    test("a day's point averages its sets and is rough from 10 reps", () {
      const day = '2026-10-27';
      TrainingSet set(double? w, int r) =>
          TrainingSet(uid: '$w$r', day: day, exercise: 'e', position: 0, weight: w, reps: r);
      final pec = trainingPoint(DateTime(2026, 10, 27), [set(106, 7), set(106, 6)], bodyweight: false)!;
      expect(pec.value, closeTo((estimateOneRepMax(106, 7)! + estimateOneRepMax(106, 6)!) / 2, 1e-9));
      expect(pec.rough, isFalse);
      expect(trainingPoint(DateTime(2026), [set(15, 14), set(15, 9)], bodyweight: false)!.rough, isTrue);
      expect(trainingPoint(DateTime(2026), [set(null, 8), set(null, 7)], bodyweight: true)!.value, 7.5);
      // Over 20 reps is kept off the average, not counted as zero.
      expect(
        trainingPoint(DateTime(2026), [set(50, 25), set(50, 5)], bodyweight: false)!.value,
        estimateOneRepMax(50, 5),
      );
    });
  });

  test('training syncs between computers, deletions too', () {
    final a = Store.memory(), b = Store.memory();
    final ea = SyncEngine(a, 'pc'), eb = SyncEngine(b, 'laptop');
    void send(SyncEngine from, SyncEngine to) {
      from.flush();
      to.mergeAll([(from.changesSince(0).values.expand((d) => d), from.me)]);
    }

    final log = TrainingLog(a, () {});
    _logExample(log, DateTime(2026, 10, 27), 0);
    send(ea, eb);
    final there = TrainingLog(b, () {});
    expect(there.exercises.map((e) => e.name), containsAll(['Pec deck', 'Pullups', 'Calf raises']));
    final session = there.session(DateTime(2026, 10, 27));
    expect(session.length, 5);
    expect(session.first.$2.map((s) => (s.weight, s.reps)), [(106.0, 7), (106.0, 6)]);
    expect(session[1].$1.bodyweight, isTrue);

    there.removeFromDay(DateTime(2026, 10, 27), session.first.$1);
    send(eb, ea);
    log.reload();
    expect(log.session(DateTime(2026, 10, 27)).map((s) => s.$1.name), isNot(contains('Pec deck')));
    a.close();
    b.close();
  });

  group('Training page', () {
    final today = DateTime(2026, 10, 27);
    late Store store;
    late AppState state;

    setUpAll(() async {
      if (_shots.isEmpty) return;
      final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final family in manifest.cast<Map<String, dynamic>>()) {
        final loader = FontLoader(family['family'] as String);
        for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
          loader.addFont(rootBundle.load(font['asset'] as String));
        }
        await loader.load();
      }
    });

    setUp(() {
      store = Store.memory();
      state = AppState(store, clock: () => today);
      state.endTour();
    });
    tearDown(() {
      state.dispose();
      store.close();
    });

    Future<void> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(2000, 1104);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
    }

    testWidgets('the corner turns to Training and back', (tester) async {
      for (var w = 8; w >= 1; w--) {
        _logExample(state.training, today.subtract(Duration(days: w * 7)), (8 - w) * 1.5);
      }
      await show(tester);
      await _shot(tester, 'training_0_today');
      await tester.tap(find.byTooltip('Training'));
      await tester.pump();
      for (final ms in [200, 140, 140]) {
        await tester.pump(Duration(milliseconds: ms));
        await _shot(tester, 'training_1_turning_$ms${tester.binding.clock.now().millisecond}');
      }
      await tester.pumpAndSettle();
      expect(state.showingTraining, isTrue);
      expect(find.text('Estimated one-rep max'), findsOneWidget);
      await _shot(tester, 'training_2_kg');

      state.training.setAxis(TrainingAxis.change);
      await tester.pumpAndSettle();
      await _shot(tester, 'training_3_percent');

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(state.showingTraining, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('logging a new exercise from the session tile', (tester) async {
      state.showingTraining = true;
      await show(tester);
      await tester.enterText(find.byType(EditableText).first, 'pec deck');
      await tester.pumpAndSettle();
      await tester.tap(find.text('CHEST').first);
      await tester.pumpAndSettle();
      final e = state.training.exercises.single;
      expect((e.name, e.group, e.bodyweight), ('Pec deck', MuscleGroup.chest, false));
      // The new set's weight box has focus; type the weight, then the reps.
      await tester.enterText(find.byType(EditableText).at(0), '106');
      await tester.enterText(find.byType(EditableText).at(1), '7');
      await tester.pumpAndSettle();
      final set = state.training.session(today).single.$2.single;
      expect((set.weight, set.reps), (106.0, 7));
      await tester.tap(find.text('Add set'));
      await tester.pumpAndSettle();
      expect(state.training.session(today).single.$2.last.weight, 106.0);
      await _shot(tester, 'training_4_session');
      expect(tester.takeException(), isNull);
    });
  });
}
