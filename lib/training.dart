import 'dart:math' as math;

/// What an exercise mainly trains. One per exercise; it sets the colour of
/// its line on the chart.
enum MuscleGroup {
  chest('Chest'),
  back('Back'),
  shoulders('Shoulders'),
  biceps('Biceps'),
  triceps('Triceps'),
  forearms('Forearms'),
  quads('Quads'),
  hamstrings('Hamstrings'),
  glutes('Glutes'),
  calves('Calves'),
  core('Core');

  const MuscleGroup(this.label);
  final String label;

  static MuscleGroup? named(String? name) {
    for (final g in values) {
      if (g.name == name) return g;
    }
    return null;
  }
}

class Exercise {
  const Exercise({required this.uid, required this.name, required this.group, required this.bodyweight});

  final String uid;
  final String name;
  final MuscleGroup group;

  /// Sets are reps only, so it charts average reps rather than a 1RM.
  final bool bodyweight;
}

class TrainingSet {
  const TrainingSet({
    required this.uid,
    required this.day,
    required this.exercise,
    required this.position,
    required this.weight,
    required this.reps,
  });

  final String uid;

  /// yyyy-mm-dd, as [dateKey] writes it.
  final String day;

  /// The [Exercise.uid] it belongs to.
  final String exercise;

  /// Order within the day: exercises in the order first logged, sets in
  /// order within those.
  final int position;

  /// Kilograms; null for a bodyweight set.
  final double? weight;
  final int reps;

  TrainingSet copyWith({double? weight, bool clearWeight = false, int? reps, int? position}) => TrainingSet(
    uid: uid,
    day: day,
    exercise: exercise,
    position: position ?? this.position,
    weight: clearWeight ? null : weight ?? this.weight,
    reps: reps ?? this.reps,
  );
}

/// Most reps a 1RM can be estimated from; sets beyond it are kept but left
/// off the chart.
const maxEstimateReps = 20;

/// From this many reps an estimate is only rough (about ±5–10%).
const roughEstimateReps = 10;

/// The weight you could lift once, estimated from [reps] at [weight]: Epley
/// up to 10 reps, Mayhew from 12, blended in between so there is no jump at
/// 10. Null past [maxEstimateReps] or for nothing lifted.
double? estimateOneRepMax(double weight, int reps) {
  if (reps < 1 || reps > maxEstimateReps || weight <= 0) return null;
  if (reps == 1) return weight;
  double epley() => weight * (1 + reps / 30);
  double mayhew() => weight * 100 / (52.2 + 41.9 * math.exp(-0.055 * reps));
  if (reps <= 10) return epley();
  if (reps <= 12) {
    final t = (reps - 10) / 2;
    return (1 - t) * epley() + t * mayhew();
  }
  return mayhew();
}

/// One exercise on one day, as the chart plots it.
class TrainingPoint {
  const TrainingPoint(this.day, this.value, {required this.rough});

  final DateTime day;

  /// The average estimated 1RM of the day's sets in kg, or for a bodyweight
  /// exercise their average reps.
  final double value;

  /// Some set had [roughEstimateReps] or more, so the estimate is rough.
  final bool rough;
}

/// The day's point for [sets] of one exercise, or null when no set counts.
TrainingPoint? trainingPoint(DateTime day, List<TrainingSet> sets, {required bool bodyweight}) {
  final values = <double>[];
  var rough = false;
  for (final s in sets) {
    if (bodyweight) {
      if (s.reps > 0) values.add(s.reps.toDouble());
      continue;
    }
    final estimate = estimateOneRepMax(s.weight ?? 0, s.reps);
    if (estimate == null) continue;
    values.add(estimate);
    if (s.reps >= roughEstimateReps) rough = true;
  }
  if (values.isEmpty) return null;
  return TrainingPoint(day, values.reduce((a, b) => a + b) / values.length, rough: rough);
}
