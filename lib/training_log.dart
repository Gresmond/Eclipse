import 'data/store.dart';
import 'models.dart';
import 'training.dart';

/// How the chart's y-axis reads.
enum TrainingAxis { kg, change }

/// How far back the chart looks.
enum TrainingRange {
  month('1M', 1),
  quarter('3M', 3),
  half('6M', 6),
  year('1Y', 12),
  all('All', null);

  const TrainingRange(this.label, this.months);
  final String label;
  final int? months;
}

/// Exercises and logged sets, kept in memory and written straight through
/// to [store]. Changes tell AppState, so AppScope watchers redraw.
class TrainingLog {
  TrainingLog(this.store, this._changed) {
    reload();
  }

  final Store store;
  final void Function() _changed;

  /// Bumped on every change, for AppScope.watch.
  int revision = 0;

  List<Exercise> exercises = [];
  Map<String, Exercise> _byUid = {};
  List<TrainingSet> _sets = [];

  /// The day being logged or edited; null for today.
  DateTime? day;

  late TrainingAxis axis = TrainingAxis.values.asNameMap()[store.setting('trainingAxis')] ?? TrainingAxis.kg;
  late TrainingRange range = TrainingRange.values.asNameMap()[store.setting('trainingRange')] ?? TrainingRange.quarter;

  /// Exercise uids and muscle group names hidden from the chart.
  late Set<String> hidden = {...?store.setting('trainingHidden')?.split(',').where((s) => s.isNotEmpty)};

  void reload() {
    exercises = store.exercises();
    _byUid = {for (final e in exercises) e.uid: e};
    _sets = store.trainingSets();
    revision++;
  }

  void _done() {
    revision++;
    _changed();
  }

  Exercise? exercise(String uid) => _byUid[uid];

  void showDay(DateTime? d) {
    day = d;
    _done();
  }

  /// Days with anything logged, newest first.
  List<String> get loggedDays => {for (final s in _sets) s.day}.toList().reversed.toList();

  /// [day]'s sets, grouped by exercise in the order they were first logged.
  List<(Exercise, List<TrainingSet>)> session(DateTime day) {
    final key = dateKey(day);
    final groups = <String, List<TrainingSet>>{};
    for (final s in _sets) {
      if (s.day == key && _byUid.containsKey(s.exercise)) (groups[s.exercise] ??= []).add(s);
    }
    return [for (final MapEntry(:key, :value) in groups.entries) (_byUid[key]!, value)];
  }

  /// Each exercise's points, oldest first, from [from] on (all with null).
  Map<Exercise, List<TrainingPoint>> points({DateTime? from}) {
    final byDay = <String, Map<String, List<TrainingSet>>>{};
    final fromKey = from == null ? null : dateKey(from);
    for (final s in _sets) {
      if (fromKey != null && s.day.compareTo(fromKey) < 0) continue;
      ((byDay[s.day] ??= {})[s.exercise] ??= []).add(s);
    }
    final result = <Exercise, List<TrainingPoint>>{};
    for (final MapEntry(key: day, value: perExercise) in byDay.entries) {
      for (final MapEntry(key: uid, value: sets) in perExercise.entries) {
        final e = _byUid[uid];
        if (e == null) continue;
        final point = trainingPoint(DateTime.parse(day), sets, bodyweight: e.bodyweight);
        if (point != null) (result[e] ??= []).add(point);
      }
    }
    return result;
  }

  // Editing

  Exercise createExercise(String name, MuscleGroup group, {required bool bodyweight}) {
    final e = store.addExercise(normaliseNote(name.trim()), group, bodyweight: bodyweight);
    reload();
    _changed();
    return e;
  }

  void updateExercise(Exercise e, {String? name, MuscleGroup? group}) {
    final trimmed = name == null ? null : normaliseNote(name.trim());
    store.saveExercise(
      Exercise(
        uid: e.uid,
        name: trimmed == null || trimmed.isEmpty ? e.name : trimmed,
        group: group ?? e.group,
        bodyweight: e.bodyweight,
      ),
    );
    reload();
    _changed();
  }

  /// Puts [e] on [day] with one empty set, after what's already there.
  void addToDay(DateTime day, Exercise e) {
    final key = dateKey(day);
    final last = _sets.where((s) => s.day == key).fold(-1, (m, s) => s.position > m ? s.position : m);
    final previous = _lastSet(e.uid);
    _sets.add(store.addTrainingSet(key, e.uid, position: last + 1, weight: e.bodyweight ? null : previous?.weight));
    _done();
  }

  /// Adds a set to [e] on [day], at the weight of the set before it.
  void addSet(DateTime day, Exercise e) {
    final key = dateKey(day);
    final mine = _sets.where((s) => s.day == key && s.exercise == e.uid).toList();
    final weight = mine.isEmpty ? _lastSet(e.uid)?.weight : mine.last.weight;
    final at = mine.isEmpty ? 0 : mine.last.position + 1;
    store.transaction(() {
      // Make room: everything after shifts down one.
      for (final (i, s) in _sets.indexed.toList()) {
        if (s.day == key && s.position >= at) {
          _sets[i] = s.copyWith(position: s.position + 1);
          store.saveTrainingSet(_sets[i]);
        }
      }
      _sets.add(store.addTrainingSet(key, e.uid, position: at, weight: e.bodyweight ? null : weight));
    });
    _sets.sort((a, b) => a.day == b.day ? a.position.compareTo(b.position) : a.day.compareTo(b.day));
    _done();
  }

  void updateSet(TrainingSet set, {double? weight, bool clearWeight = false, int? reps}) {
    final i = _sets.indexWhere((s) => s.uid == set.uid);
    if (i < 0) return;
    _sets[i] = _sets[i].copyWith(weight: weight, clearWeight: clearWeight, reps: reps);
    store.saveTrainingSet(_sets[i]);
    _done();
  }

  void deleteSet(TrainingSet set) {
    store.deleteTrainingSet(set.uid);
    _sets.removeWhere((s) => s.uid == set.uid);
    _done();
  }

  /// Takes [e] off [day], with all its sets that day.
  void removeFromDay(DateTime day, Exercise e) {
    final key = dateKey(day);
    store.transaction(() {
      for (final s in _sets.where((s) => s.day == key && s.exercise == e.uid)) {
        store.deleteTrainingSet(s.uid);
      }
    });
    _sets.removeWhere((s) => s.day == key && s.exercise == e.uid);
    _done();
  }

  /// The latest weighted set of [exercise], to start the next one from.
  TrainingSet? _lastSet(String exercise) {
    for (final s in _sets.reversed) {
      if (s.exercise == exercise && s.weight != null) return s;
    }
    return null;
  }

  // Chart preferences, per computer

  void setAxis(TrainingAxis a) {
    axis = a;
    store.setSetting('trainingAxis', a.name);
    _done();
  }

  void setRange(TrainingRange r) {
    range = r;
    store.setSetting('trainingRange', r.name);
    _done();
  }

  void toggleHidden(String key) {
    hidden.contains(key) ? hidden.remove(key) : hidden.add(key);
    store.setSetting('trainingHidden', hidden.join(','));
    _done();
  }
}
