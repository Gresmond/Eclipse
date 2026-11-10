import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/screens/shell.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/training_log.dart';

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

    setUp(() {
      calendarButtonEnabled = true;
      store = Store.memory();
      state = AppState(store, clock: () => today);
      state.endTour();
    });
    tearDown(() {
      calendarButtonEnabled = false;
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

    testWidgets('the button opens Training and, clicked again, goes back', (tester) async {
      for (var w = 8; w >= 1; w--) {
        _logExample(state.training, today.subtract(Duration(days: w * 7)), (8 - w) * 1.5);
      }
      await show(tester);
      await tester.tap(find.byTooltip('Training'));
      await tester.pumpAndSettle();
      expect(state.showingTraining, isTrue);
      expect(find.text('Estimated one-rep max'), findsOneWidget);

      state.training.setAxis(TrainingAxis.change);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Training'));
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
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching an existing exercise to bodyweight preserves its sets', (tester) async {
      state.showingTraining = true;
      final log = state.training;
      final pullups = log.createExercise('Pullups', MuscleGroup.back, bodyweight: false);
      log.addToDay(today, pullups);
      final set = log.session(today).single.$2.single;
      log.updateSet(set, weight: 5, reps: 22);
      await show(tester);
      expect(find.byType(EditableText), findsNWidgets(3));
      expect(find.text('Over 20 reps, so not charted'), findsOneWidget);

      await tester.tap(find.text('Weighted'));
      await tester.pumpAndSettle();

      final saved = store.exercises().single;
      expect((saved.uid, saved.group, saved.bodyweight), (pullups.uid, MuscleGroup.back, true));
      expect(find.byType(EditableText), findsNWidgets(2));
      expect(find.text('Over 20 reps, so not charted'), findsNothing);
      expect(log.points().values.single.single.value, 22);
      expect(find.text('Bodyweight exercises show in the % change view.'), findsOneWidget);

      await tester.tap(find.text('Bodyweight').first);
      await tester.pumpAndSettle();
      final restored = log.session(today).single;
      expect(restored.$1.bodyweight, isFalse);
      expect((restored.$2.single.uid, restored.$2.single.weight, restored.$2.single.reps), (set.uid, 5.0, 22));
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('the chart starts at the first plotted date on a shared timeline', (tester) async {
      state.showingTraining = true;
      final log = state.training;
      final press = log.createExercise('Bench press', MuscleGroup.chest, bodyweight: false);
      void logSet(DateTime day, Exercise exercise) {
        log.addToDay(day, exercise);
        final set = log.session(day).firstWhere((entry) => entry.$1.uid == exercise.uid).$2.single;
        log.updateSet(set, weight: 50, reps: 5);
      }

      logSet(today, press);
      await show(tester);
      final chart = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.size == Size.infinite);
      const plotLeft = 52.0;
      expect(chart, paints..circle(x: plotLeft, radius: 3.6));

      logSet(DateTime(2026, 10, 25), press);
      final row = log.createExercise('Row', MuscleGroup.back, bodyweight: false);
      logSet(DateTime(2026, 10, 26), row);
      await tester.pumpAndSettle();
      final plotRight = tester.getSize(chart).width - 20;
      expect(
        chart,
        paints
          ..circle(x: plotLeft, radius: 3.6)
          ..circle(x: plotRight, radius: 3.6)
          ..circle(x: (plotLeft + plotRight) / 2, radius: 3.6),
      );
    });
  });
}
