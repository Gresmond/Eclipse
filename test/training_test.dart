import 'dart:math' as math;

import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/training_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TrainingSet setOf(String uid, double? w, int r, {int pos = 0, String day = '2026-10-27'}) =>
      TrainingSet(uid: uid, day: day, exercise: 'e', position: pos, weight: w, reps: r);

  test('1RM estimation blends Epley to Mayhew and ignores >20 reps', () {
    expect(estimateOneRepMax(100, 1), 100);
    expect(estimateOneRepMax(106, 7), closeTo(106 * (1 + 7 / 30), 1e-9));
    final mayhew12 = 100 * 100 / (52.2 + 41.9 * math.exp(-0.055 * 12));
    expect(estimateOneRepMax(100, 12), closeTo(mayhew12, 1e-6));
    expect(estimateOneRepMax(145, 21), isNull);

    final pt = trainingPoint(DateTime(2026, 10, 27), [setOf('1', 50, 25), setOf('2', 50, 5)], bodyweight: false)!;
    expect(pt.value, estimateOneRepMax(50, 5));
    expect(trainingPoint(DateTime(2026, 10, 27), [setOf('3', 15, 14)], bodyweight: false)!.rough, isTrue);
    expect(trainingPoint(DateTime(2026, 10, 27), [setOf('4', null, 8), setOf('5', null, 7)], bodyweight: true)!.value, 7.5);
  });

  test('trainingPoints tracks set-by-set deltas cleanly and stays positive without drift', () {
    var n = 0;
    List<double> line(List<List<int>> days) => [
      for (final p in trainingPoints([
        for (final (i, reps) in days.indexed)
          (DateTime(2026, 10, 1 + i * 7), [for (final r in reps) setOf('${n++}', null, r, pos: n)]),
      ], bodyweight: true))
        p.value,
    ];
    expect(line([[8], [8, 7]]), [8, 8]);
    expect(line([[8, 6], [8, 7]]), [7, 7.5]);
    expect(line([[8, 7], [8]]), [7.5, 7.5]);

    final counted = trainingPoints([
      (DateTime(2026, 11, 1), [setOf('1', 20, 25, pos: 0), setOf('2', 100, 5, pos: 1)]),
      (DateTime(2026, 11, 3), [setOf('3', 100, 5, pos: 0)]),
    ], bodyweight: false);
    expect(counted[1].value, closeTo(counted[0].value, 1e-9));

    final extreme = trainingPoints([
      (DateTime(2026, 11, 1), [setOf('a1', null, 20, pos: 0), setOf('a2', null, 2, pos: 1)]),
      (DateTime(2026, 11, 2), [setOf('b1', null, 2, pos: 0)]),
    ], bodyweight: true);
    expect(extreme.last.value, greaterThanOrEqualTo(1.0));
  });

  test('personalBests, validation, orphan filtering, date order and microplates behave properly', () {
    final store = Store.memory();
    addTearDown(store.close);
    store.addTrainingSet('2026-11-01', 'deleted-exercise', position: 0, weight: 50, reps: 5);
    final log = TrainingLog(store, () {});
    expect(log.loggedDays, isEmpty);
    expect(() => log.createExercise('   ', MuscleGroup.chest, bodyweight: false), throwsArgumentError);

    final bench = log.createExercise('Bench', MuscleGroup.chest, bodyweight: false);
    log.addToDay(DateTime(2026, 11, 1), bench);
    log.updateSet(log.session(DateTime(2026, 11, 1)).single.$2.single, weight: 60, reps: 0);
    log.addToDay(DateTime(2026, 11, 3), bench);
    log.updateSet(log.session(DateTime(2026, 11, 3)).single.$2.single, weight: 40, reps: 25);
    expect(log.personalBests(DateTime(2026, 11, 3), bench), isEmpty);
    log.addToDay(DateTime(2026, 11, 5), bench);
    log.updateSet(log.session(DateTime(2026, 11, 5)).single.$2.single, weight: 20, reps: 5);
    expect(log.personalBests(DateTime(2026, 11, 5), bench), isEmpty);

    final squat = log.createExercise('Squat', MuscleGroup.quads, bodyweight: false);
    log.addToDay(DateTime(2026, 11, 10), squat);
    log.updateSet(log.session(DateTime(2026, 11, 10)).single.$2.single, weight: 100, reps: 5);
    log.updateSet(log.session(DateTime(2026, 11, 10)).single.$2.single, weight: -10);
    expect(log.session(DateTime(2026, 11, 10)).single.$2.single.weight, 100);
    log.addToDay(DateTime(2026, 11, 5), squat);
    final squatNov5 = log.session(DateTime(2026, 11, 5)).firstWhere((g) => g.$1.uid == squat.uid).$2.single;
    log.updateSet(squatNov5, weight: 62.25, reps: 5);
    log.addToDay(DateTime(2026, 11, 7), squat);
    expect(log.session(DateTime(2026, 11, 7)).single.$2.single.weight, 62.25);
  });

  test('training exercises and sets sync between computers, including deletions', () {
    final a = Store.memory(), b = Store.memory();
    addTearDown(a.close);
    addTearDown(b.close);
    final ea = SyncEngine(a, 'pc'), eb = SyncEngine(b, 'laptop');
    void send(SyncEngine from, SyncEngine to) {
      from.flush();
      to.mergeAll([(from.changesSince(0).values.expand((d) => d), from.me)]);
    }

    final log = TrainingLog(a, () {});
    final day = DateTime(2026, 10, 27);
    final pec = log.createExercise('Pec deck', MuscleGroup.chest, bodyweight: false);
    log.addToDay(day, pec);
    log.updateSet(log.session(day).single.$2.single, weight: 106, reps: 7);
    send(ea, eb);

    final there = TrainingLog(b, () {});
    expect(there.session(day).single.$1.name, 'Pec deck');
    expect(there.session(day).single.$2.single.weight, 106);

    there.removeFromDay(day, there.session(day).single.$1);
    send(eb, ea);
    log.reload();
    expect(log.session(day), isEmpty);
  });
}
