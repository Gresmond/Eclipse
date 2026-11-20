import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/training_log.dart';
import 'package:eclipse/widgets/glide_pill.dart';
import 'package:eclipse/widgets/rolling_number.dart';

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

  test('the line goes set by set, so an extra or a missing set does not move it', () {
    var n = 0;
    List<double> line(List<List<int>> days) => [
      for (final p in trainingPoints([
        for (final (i, reps) in days.indexed)
          (
            DateTime(2026, 10, 1 + i * 7),
            [
              for (final r in reps)
                TrainingSet(uid: '${n++}', day: '', exercise: 'pullups', position: n, weight: null, reps: r),
            ],
          ),
      ], bodyweight: true))
        p.value,
    ];
    expect(
      line([
        [8],
        [8, 7],
      ]),
      [8, 8],
      reason: 'a second set is not a step back',
    );
    expect(
      line([
        [8, 6],
        [8, 7],
      ]),
      [7, 7.5],
      reason: 'a better second set shows',
    );
    expect(
      line([
        [8, 7],
        [8],
      ]),
      [7.5, 7.5],
      reason: 'a session cut short is not a gain',
    );
    expect(
      line([
        [8],
        [8, 6],
        [9],
        [9, 7],
      ]),
      [8, 8, 9, 9.5],
      reason: 'a set is compared with the last one there was',
    );
    expect(
      line([
        [8, 6],
        [9, 7],
        [9, 8],
      ]),
      [7, 8, 8.5],
      reason: 'the plain average while the sets stay as many',
    );
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

    testWidgets('the chart splits into a card per exercise or per muscle group', (tester) async {
      for (var w = 4; w >= 1; w--) {
        _logExample(state.training, today.subtract(Duration(days: w * 7)), (4 - w) * 1.5);
      }
      state.showingTraining = true;
      await show(tester);
      final charts = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.size == Size.infinite);
      expect(charts, findsOneWidget);

      await tester.tap(find.text('Exercises'));
      await tester.pumpAndSettle();
      expect(state.training.layout, TrainingLayout.exercises);
      // Five exercises, Pullups among them in reps though the chart is in kg.
      expect(charts, findsNWidgets(5));
      expect(
        find.byWidgetPredicate((w) => w is RollingFigure && RegExp(r'^[0-9.]+ reps$').hasMatch(w.text)),
        findsOneWidget,
      );
      expect(find.text('Bodyweight exercises show in the % change view.'), findsNothing);
      // The cards fill the tile, down to its bottom and out to its right.
      Rect cards() => find
          .ancestor(of: charts, matching: find.byType(AnimatedPositioned))
          .evaluate()
          .map((e) => tester.getRect(find.byWidget(e.widget)))
          .reduce((a, b) => a.expandToInclude(b));
      final area = tester.getRect(find.ancestor(of: charts.first, matching: find.byType(SingleChildScrollView)));
      expect(cards().bottom, closeTo(area.bottom, 1));
      expect(cards().right, closeTo(area.right, 6));

      // Hiding one: it fades where it was while the others glide to fill.
      final pullups = state.training.exercises.firstWhere((e) => e.name == 'Pullups');
      state.training.toggleHidden(pullups.uid);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(charts, findsNWidgets(5));
      await tester.pumpAndSettle();
      expect(charts, findsNWidgets(4));
      expect(cards().bottom, closeTo(area.bottom, 1));
      state.training.toggleHidden(pullups.uid);
      await tester.pumpAndSettle();

      final layoutPills = find.ancestor(of: find.text('Exercises'), matching: find.byType(SegmentedPills));
      final exercisePills = tester.getRect(layoutPills);
      await tester.tap(find.text('Muscles'));
      await tester.pumpAndSettle();
      expect(tester.getRect(layoutPills), exercisePills);
      // Back has only Pullups, which aren't plotted here on a kg axis.
      expect(charts, findsNWidgets(4));
      expect(find.text('Bodyweight exercises show in the % change view.'), findsNothing);

      state.training.setAxis(TrainingAxis.change);
      await tester.pumpAndSettle();
      expect(charts, findsNWidgets(5));
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
      state.training.setDetails(set, 'Pause at the top', 8);
      await tester.pumpAndSettle();
      expect(find.text('Pause at the top'), findsOneWidget);
      expect(find.text('RPE 8'), findsOneWidget);
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
      expect(find.text('Bodyweight exercises show in the % change view.'), findsNothing);

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

    testWidgets('hovering stacked points lists every exercise on them, solid points over hollow', (tester) async {
      state.showingTraining = true;
      final log = state.training;
      void logSet(Exercise exercise, double weight, int reps) {
        log.addToDay(today, exercise);
        final set = log.session(today).firstWhere((entry) => entry.$1.uid == exercise.uid).$2.single;
        log.updateSet(set, weight: weight, reps: reps);
      }

      // Both an estimated 60 kg, so on one spot; ten reps makes the first hollow.
      logSet(log.createExercise('Bench press', MuscleGroup.chest, bodyweight: false), 45, 10);
      logSet(log.createExercise('Row', MuscleGroup.back, bodyweight: false), 60, 1);
      await show(tester);
      final chart = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.size == Size.infinite);
      // The hollow point's centre and ring, then the solid one on top.
      expect(
        chart,
        paints
          ..circle(radius: 3.6)
          ..drrect()
          ..circle(radius: 3.6),
      );
      bool halo(Symbol method, List<dynamic> args) => method == #drawCircle && args[1] == 5.5;
      expect(chart, isNot(paints..something(halo)));

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      final box = tester.getRect(chart);
      for (var y = box.top; y < box.bottom; y += 4) {
        await mouse.moveTo(Offset(box.left + 52, y));
        await tester.pump();
        if (((paints..something(halo)) as Matcher).matches(chart, {})) break;
      }
      // A highlight on each of the two, not only the nearest.
      expect(
        chart,
        paints
          ..something(halo)
          ..something(halo),
      );
    });

    test('exercises are ordered by when they were first logged, not by name', () {
      final log = state.training;
      final row = log.createExercise('Row', MuscleGroup.back, bodyweight: false);
      final chin = log.createExercise('Chin-up', MuscleGroup.back, bodyweight: true);
      final never = log.createExercise('Deadlift', MuscleGroup.back, bodyweight: false);
      log.addToDay(today, row);
      log.addToDay(today, chin);
      expect(log.loggedOrder, [row.uid, chin.uid]);
      // Logged later on an earlier day, it comes first.
      log.addToDay(today.subtract(const Duration(days: 3)), chin);
      expect(log.loggedOrder, [chin.uid, row.uid]);
      expect(log.loggedOrder, isNot(contains(never.uid)));
    });

    testWidgets('a seventh exercise in a group repeats the first dash with square points', (tester) async {
      state.showingTraining = true;
      final log = state.training;
      for (var i = 0; i < 7; i++) {
        final e = log.createExercise('Press $i', MuscleGroup.chest, bodyweight: false);
        log.addToDay(today, e);
        log.updateSet(log.session(today).last.$2.single, weight: 40.0 + 10 * i, reps: 5);
      }
      await show(tester);
      final chart = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.size == Size.infinite);
      expect(chart, paints..rect());
      expect(
        chart,
        isNot(
          paints
            ..rect()
            ..rect(),
        ),
      );
    });

    test('a range of months starts on a real day at a month end', () {
      expect(monthsBefore(DateTime(2026, 3, 31), 1), DateTime(2026, 2, 28));
      expect(monthsBefore(DateTime(2026, 8, 31), 6), DateTime(2026, 2, 28));
      expect(monthsBefore(DateTime(2026, 1, 15), 3), DateTime(2025, 10, 15));
      expect(monthsBefore(DateTime(2028, 2, 29), 12), DateTime(2027, 2, 28));
    });

    testWidgets('a line shows its nearest session to the mouse or a tap, and a tap elsewhere clears it', (
      tester,
    ) async {
      state.showingTraining = true;
      final log = state.training;
      final press = log.createExercise('Bench press', MuscleGroup.chest, bodyweight: false);
      for (final day in [today, today.subtract(const Duration(days: 10))]) {
        log.addToDay(day, press);
        log.updateSet(log.session(day).single.$2.single, weight: 50, reps: 5);
      }
      log.setRange(TrainingRange.all);
      await show(tester);
      final chart = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.size == Size.infinite);
      bool halo(Symbol method, List<dynamic> args) => method == #drawCircle && args[1] == 5.5;
      final box = tester.getRect(chart);
      final empty = Offset(box.left + box.width * 0.4, box.top + 12);

      // Down the chart well between the two sessions until it meets the line.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      var line = empty;
      for (; line.dy < box.bottom; line += const Offset(0, 4)) {
        await mouse.moveTo(line);
        await tester.pump();
        if (((paints..something(halo)) as Matcher).matches(chart, {})) break;
      }
      expect(chart, paints..something(halo));
      await mouse.moveTo(empty);
      await tester.pump();
      expect(chart, isNot(paints..something(halo)));
      await mouse.moveTo(Offset.zero);
      await tester.pump();

      await tester.tapAt(line);
      await tester.pump();
      expect(chart, paints..something(halo));
      await tester.pump(const Duration(seconds: 2));
      expect(chart, paints..something(halo), reason: 'stays until a tap elsewhere');
      await tester.tapAt(empty);
      await tester.pump();
      expect(chart, isNot(paints..something(halo)));
    });

    testWidgets('a line whose points would touch has none until one is pointed at', (tester) async {
      state.showingTraining = true;
      final log = state.training;
      final press = log.createExercise('Bench press', MuscleGroup.chest, bodyweight: false);
      for (var i = 0; i < 400; i++) {
        final day = today.subtract(Duration(days: i));
        log.addToDay(day, press);
        for (final set in log.session(day).single.$2) {
          log.updateSet(set, weight: 50, reps: 5);
        }
      }
      log.setRange(TrainingRange.all);
      await show(tester);
      final chart = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.size == Size.infinite);
      bool dot(Symbol method, List<dynamic> args) => method == #drawCircle && args[1] == 3.6;
      expect(chart, isNot(paints..something(dot)));

      final box = tester.getRect(chart);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      for (var y = box.top; y < box.bottom; y += 4) {
        await mouse.moveTo(Offset(box.center.dx, y));
        await tester.pump();
        if (((paints..something(dot)) as Matcher).matches(chart, {})) break;
      }
      expect(chart, paints..something(dot));
    });

    testWidgets('a set changed elsewhere, as by sync, shows its new weight and reps', (tester) async {
      state.showingTraining = true;
      final log = state.training;
      final press = log.createExercise('Bench press', MuscleGroup.chest, bodyweight: false);
      log.addToDay(today, press);
      await show(tester);
      String field(int i) => tester.widgetList<TextField>(find.byType(TextField)).elementAt(i).controller!.text;
      expect([field(0), field(1)], ['', '']);

      log.updateSet(log.session(today).single.$2.single, weight: 62.5, reps: 8);
      await tester.pumpAndSettle();
      expect([field(0), field(1)], ['62.5', '8']);
    });

    testWidgets('the Undo card restores a removed set or all sets removed from a session', (tester) async {
      state.showingTraining = true;
      final log = state.training;
      final press = log.createExercise('Bench press', MuscleGroup.chest, bodyweight: false);
      log.addToDay(today, press);
      log.addSet(today, press);
      final sets = log.session(today).single.$2;
      log.updateSet(sets.first, weight: 50, reps: 8);
      log.updateSet(sets.last, weight: 60, reps: 6);
      await show(tester);

      List<(String, double?, int)> savedSets() => [
        for (final set in store.trainingSets()) (set.uid, set.weight, set.reps),
      ];
      final original = savedSets();
      final undo = find.text('Undo');

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: Offset.zero);
      addTearDown(pointer.removePointer);
      await pointer.moveTo(tester.getCenter(find.byTooltip('Remove set').first));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove set').first);
      await tester.pumpAndSettle();
      expect(savedSets(), [original.last]);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(savedSets(), original);
      expect(find.byTooltip('Remove set'), findsNWidgets(2));

      await tester.tap(find.byTooltip('Remove from this session'));
      await tester.pumpAndSettle();
      expect(savedSets(), isEmpty);
      expect(log.points(), isEmpty);
      expect(find.text('Bench press ×2'), findsNothing);

      // Logging another set before clicking Undo should keep that set, too.
      log.addToDay(today, press);
      final added = savedSets().single;
      await tester.pumpAndSettle();
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(savedSets(), unorderedEquals([...original, added]));
      expect(log.points(), hasLength(1));
      expect(find.text('Bench press ×3'), findsOneWidget);
      expect(find.byTooltip('Remove set'), findsNWidgets(3));
    });

    testWidgets('repeating a session, personal bests, most-used chips and deleting an exercise', (tester) async {
      state.showingTraining = true;
      final log = state.training;
      final before = today.subtract(const Duration(days: 7));
      final press = log.createExercise('Bench press', MuscleGroup.chest, bodyweight: false);
      final curl = log.createExercise('Curl', MuscleGroup.biceps, bodyweight: false);
      for (final (e, w) in [(press, 50.0), (curl, 12.0)]) {
        log.addToDay(before, e);
        log.addSet(before, e);
        for (final s in log.session(before).firstWhere((x) => x.$1.uid == e.uid).$2) {
          log.updateSet(s, weight: w, reps: 8);
        }
      }
      expect(log.personalBests(before, press), isEmpty, reason: 'nothing to beat on the first day');
      await show(tester);

      // Hovering a past session offers to repeat it today.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Bench press ×2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Repeat today'));
      await tester.pumpAndSettle();
      final repeated = log.session(today);
      expect(
        [
          for (final (e, sets) in repeated)
            for (final s in sets) '${e.name} ${s.weight} x ${s.reps}',
        ],
        ['Bench press 50.0 x 0', 'Bench press 50.0 x 0', 'Curl 12.0 x 0', 'Curl 12.0 x 0'],
      );
      // Again changes nothing: both are on today already.
      log.repeatSession(before, today);
      expect(store.trainingSets(), hasLength(8));

      // Only a set that beats everything before it is a best.
      final sets = repeated.first.$2;
      log.updateSet(sets[0], reps: 8);
      log.updateSet(sets[1], weight: 52.5, reps: 8);
      await tester.pumpAndSettle();
      expect(log.personalBests(today, press), {sets[1].uid});
      expect(find.text('Personal best'), findsOneWidget);

      // The empty field offers what isn't on the day yet, most used first.
      log.removeFromDay(today, curl);
      await tester.pumpAndSettle();
      expect(find.text('Curl'), findsOneWidget, reason: 'only in the chart legend');
      await tester.tap(find.byType(EditableText).last);
      await tester.pumpAndSettle();
      expect(find.text('Curl'), findsNWidgets(2));
      await tester.tap(find.text('Curl').last);
      await tester.pumpAndSettle();
      expect(log.session(today).last.$1.uid, curl.uid);

      // Deleting asks once in place, takes every set, and Undo brings all of it back.
      final all = store.trainingSets().length;
      await tester.tap(find.byTooltip('Delete this exercise').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete with all 4 sets'));
      await tester.pumpAndSettle();
      expect(log.exercises.single.uid, curl.uid);
      expect(store.trainingSets().length, all - 4);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(log.exercises, hasLength(2));
      expect(store.trainingSets().length, all);
      expect(tester.takeException(), isNull);
    });

    testWidgets('personalBests awards a best after a high-rep day and Escape cancels inline rename', (tester) async {
      state.showingTraining = true;
      final log = state.training;
      final squats = log.createExercise('Squat', MuscleGroup.quads, bodyweight: false);
      final day1 = today.subtract(const Duration(days: 3));
      log.addToDay(day1, squats);
      // Over 20 reps returns null from Brzycki estimate, but day 1 is still a prior logged day.
      log.updateSet(log.session(day1).single.$2.single, weight: 40, reps: 25);

      log.addToDay(today, squats);
      final setToday = log.session(today).single.$2.single;
      log.updateSet(setToday, weight: 80, reps: 5);
      expect(log.personalBests(today, squats), {setToday.uid});

      await show(tester);
      await tester.tap(find.byTooltip('Rename').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Squat'), 'Front squat');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(log.exercises.single.name, 'Squat');
      expect(find.text('Front squat'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
