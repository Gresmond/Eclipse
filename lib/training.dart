import 'dart:convert';
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
    required this.reps, this.note, this.rpe,
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
  final String? note;
  final double? rpe;

  TrainingSet copyWith({double? weight, bool clearWeight = false, int? reps, int? position, String? note, double? rpe, bool replaceDetails = false}) => TrainingSet(
    uid: uid,
    day: day,
    exercise: exercise,
    position: position ?? this.position,
    weight: clearWeight ? null : weight ?? this.weight,
    reps: reps ?? this.reps,
    note: replaceDetails ? note : this.note, rpe: replaceDetails ? rpe : this.rpe,
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

/// What a set counts for: its estimated 1RM in kg, or for a bodyweight
/// exercise its reps (or total load 1RM when [bodyMass] is supplied and added
/// weight is tracked). Null when it doesn't count.
double? setWorth(TrainingSet s, {required bool bodyweight, double? bodyMass}) {
  if (bodyweight) {
    if (bodyMass != null) {
      return estimateOneRepMax(bodyMass + (s.weight ?? 0), s.reps);
    }
    return s.reps > 0 ? s.reps.toDouble() : null;
  }
  return estimateOneRepMax(s.weight ?? 0, s.reps);
}

/// One exercise on one day, as the chart plots it.
class TrainingPoint {
  const TrainingPoint(this.day, this.value, {required this.rough, this.sets = const []});

  final DateTime day;

  /// Where the line is, in kg of estimated 1RM or for a bodyweight exercise
  /// in reps. The first day it's the average of the day's sets; after that
  /// it moves by how each set compares with the same set last time (see
  /// [trainingPoints]), so it can differ from the day's own average.
  final double value;

  /// Some set had [roughEstimateReps] or more, so the estimate is rough.
  final bool rough;

  /// The day's sets that count, in order.
  final List<TrainingSet> sets;
}

/// One exercise's points from its [days], oldest first, each with that
/// day's sets in order.
///
/// A plain average of the day's sets falls when a tired extra set is added
/// and rises when a session is cut short, though nothing got weaker or
/// stronger. So each set is compared only with the same set (first, second
/// and so on) the last time there was one, and the line moves by the average
/// of those changes. A set with nothing to compare against moves nothing; it
/// is what the next one is compared with. With the same number of sets every
/// day this is the plain average.
List<TrainingPoint> trainingPoints(
  Iterable<(DateTime, List<TrainingSet>)> days, {
  required bool bodyweight,
  double? Function(DateTime day)? bodyMassFor,
}) {
  double mean(Iterable<double> values) => values.reduce((a, b) => a + b) / values.length;
  final last = <int, double>{};
  final lastSeen = <int, int>{};
  final points = <TrainingPoint>[];
  double? value;
  var sessionIndex = 0;
  for (final (day, sets) in days) {
    final mass = bodyMassFor?.call(day);
    final worth = <int, double>{};
    final counted = <TrainingSet>[];
    for (final s in sets) {
      final w = setWorth(s, bodyweight: bodyweight, bodyMass: mass);
      if (w == null) continue;
      worth[counted.length] = w;
      counted.add(s);
    }
    if (worth.isEmpty) continue;
    last.removeWhere((i, _) => sessionIndex - (lastSeen[i] ?? sessionIndex) > 5);
    final changes = [
      for (final MapEntry(key: i, value: w) in worth.entries)
        if (last[i] case final was?) w - was,
    ];
    final dayMin = worth.values.reduce(math.min);
    final dayMax = worth.values.reduce(math.max);
    final next = value == null
        ? mean(worth.values)
        : changes.isEmpty
        ? value
        : value + mean(changes);
    value = next.clamp(dayMin * 0.5, dayMax * 1.5);
    for (final i in worth.keys) {
      last[i] = worth[i]!;
      lastSeen[i] = sessionIndex;
    }
    sessionIndex++;
    points.add(
      TrainingPoint(
        day,
        value,
        rough: (!bodyweight || mass != null) && counted.any((s) => s.reps >= roughEstimateReps),
        sets: counted,
      ),
    );
  }
  return points;
}

/// The point for [sets] of one exercise on a [day] by itself: their average.
/// Null when no set counts.
TrainingPoint? trainingPoint(DateTime day, List<TrainingSet> sets, {required bool bodyweight}) =>
    trainingPoints([(day, sets)], bodyweight: bodyweight).firstOrNull;

/// A routine stores exercise IDs and starting weights. Applied sets begin
/// with zero reps so they enter the charts only after the workout.
bool validRoutine(String encoded) {
  try {
    final rows = jsonDecode(encoded);
    return rows is List && rows.isNotEmpty && rows.every((r) =>
      r is List && r.length == 2 && r.first is String &&
      (r.last == null || r.last is num && (r.last as num).isFinite && (r.last as num) >= 0));
  } on FormatException { return false; }
}
