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
  TrainingLog(this.store, this._changed, {this.onRemoved}) {
    reload();
  }

  final Store store;
  final void Function() _changed;
  final void Function(String label, List<RowsBefore> before)? onRemoved;

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
  /// A point follows from the days before it, those before [from] too, so
  /// it reads the same in every range.
  Map<Exercise, List<TrainingPoint>> points({DateTime? from}) {
    final byExercise = <String, Map<String, List<TrainingSet>>>{};
    for (final s in _sets) {
      ((byExercise[s.exercise] ??= {})[s.day] ??= []).add(s);
    }
    final result = <Exercise, List<TrainingPoint>>{};
    for (final MapEntry(key: uid, value: days) in byExercise.entries) {
      final e = _byUid[uid];
      if (e == null) continue;
      final points = trainingPoints([
        for (final MapEntry(key: day, value: sets) in days.entries) (DateTime.parse(day), sets),
      ], bodyweight: e.bodyweight).where((p) => from == null || !p.day.isBefore(from)).toList();
      if (points.isNotEmpty) result[e] = points;
    }
    return result;
  }

  /// The exercises logged on the most days, of those the latest first,
  /// leaving out [except]: the ones to offer before anything is typed.
  List<Exercise> mostUsed({Set<String> except = const {}, int count = 6}) {
    final days = <String, Set<String>>{};
    for (final s in _sets) {
      if (_byUid.containsKey(s.exercise) && !except.contains(s.exercise)) (days[s.exercise] ??= {}).add(s.day);
    }
    // Sets are oldest first, so a day set's last is its latest.
    final uids = days.keys.toList()
      ..sort((a, b) {
        final (da, db) = (days[a]!, days[b]!);
        if (da.length != db.length) return db.length - da.length;
        final latest = db.last.compareTo(da.last);
        return latest != 0 ? latest : _byUid[a]!.name.compareTo(_byUid[b]!.name);
      });
    return [for (final uid in uids.take(count)) _byUid[uid]!];
  }

  /// How many sets of [e] are logged, on any day.
  int setsOf(Exercise e) => _sets.where((s) => s.exercise == e.uid).length;

  double? _worth(TrainingSet s, Exercise e) => setWorth(s, bodyweight: e.bodyweight);

  /// The sets of [e] on [day] that beat every set before them, on earlier
  /// days and earlier that day. None on the first day [e] is logged.
  Set<String> personalBests(DateTime day, Exercise e) {
    final key = dateKey(day);
    double? best;
    for (final s in _sets) {
      if (s.exercise != e.uid || s.day.compareTo(key) >= 0) continue;
      final worth = _worth(s, e);
      if (worth != null && (best == null || worth > best)) best = worth;
    }
    if (best == null) return const {};
    final result = <String>{};
    for (final s in _sets) {
      if (s.exercise != e.uid || s.day != key) continue;
      final worth = _worth(s, e);
      if (worth != null && worth > best!) {
        best = worth;
        result.add(s.uid);
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

  void updateExercise(Exercise e, {String? name, MuscleGroup? group, bool? bodyweight}) {
    final trimmed = name == null ? null : normaliseNote(name.trim());
    store.saveExercise(
      Exercise(
        uid: e.uid,
        name: trimmed == null || trimmed.isEmpty ? e.name : trimmed,
        group: group ?? e.group,
        bodyweight: bodyweight ?? e.bodyweight,
      ),
    );
    reload();
    _changed();
  }

  /// Removes [e] for good, with every set of it on every day.
  void deleteExercise(Exercise e) {
    final uids = [
      for (final s in _sets)
        if (s.exercise == e.uid) s.uid,
    ];
    final before = store.transaction(() {
      final before = [
        if (onRemoved != null) ...[
          store.rowsBefore('exercises', ['uid'], 'uid = ?', [e.uid]),
          for (final uid in uids) store.rowsBefore('training_sets', ['uid'], 'uid = ?', [uid]),
        ],
      ];
      for (final uid in uids) {
        store.deleteTrainingSet(uid);
      }
      store.deleteExercise(e.uid);
      return before;
    });
    reload();
    onRemoved?.call('Deleted “${e.name}” and all its sets', before);
    _changed();
  }

  /// Puts the exercises of [from] on [to] with the same sets at the same
  /// weights, reps left to fill in. Ones already on [to] stay as they are.
  void repeatSession(DateTime from, DateTime to) {
    final key = dateKey(to);
    final there = {for (final (e, _) in session(to)) e.uid};
    var at = _sets.where((s) => s.day == key).fold(-1, (m, s) => s.position > m ? s.position : m) + 1;
    final added = store.transaction(
      () => [
        for (final (e, sets) in session(from))
          if (!there.contains(e.uid))
            for (final s in sets)
              store.addTrainingSet(key, e.uid, position: at++, weight: e.bodyweight ? null : s.weight),
      ],
    );
    if (added.isEmpty) return;
    _sets.addAll(added);
    _sort();
    _done();
  }

  /// Puts [e] on [day] with one empty set, after what's already there.
  void addToDay(DateTime day, Exercise e) {
    final key = dateKey(day);
    final last = _sets.where((s) => s.day == key).fold(-1, (m, s) => s.position > m ? s.position : m);
    final previous = _lastSet(e.uid);
    _sets.add(store.addTrainingSet(key, e.uid, position: last + 1, weight: e.bodyweight ? null : previous?.weight));
    _sort();
    _done();
  }

  /// Oldest day first, in order within each day, as [Store.trainingSets]
  /// reads them: the days logged, the chart's points and the latest weight
  /// all go by it, and a set added to an earlier day lands at the end.
  void _sort() => _sets.sort((a, b) => a.day == b.day ? a.position.compareTo(b.position) : a.day.compareTo(b.day));

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
    _sort();
    _done();
  }

  void updateSet(TrainingSet set, {double? weight, bool clearWeight = false, int? reps}) {
    final i = _sets.indexWhere((s) => s.uid == set.uid);
    if (i < 0) return;
    _sets[i] = _sets[i].copyWith(weight: weight, clearWeight: clearWeight, reps: reps);
    store.saveTrainingSet(_sets[i]);
    _done();
  }

  void deleteSet(TrainingSet set) => _removeSets(_sets.where((s) => s.uid == set.uid), 'Removed a set');

  /// Takes [e] off [day], with all its sets that day.
  void removeFromDay(DateTime day, Exercise e) {
    final key = dateKey(day);
    _removeSets(_sets.where((s) => s.day == key && s.exercise == e.uid), 'Removed “${e.name}” from the session');
  }

  void _removeSets(Iterable<TrainingSet> sets, String label) {
    final uids = {for (final set in sets) set.uid};
    if (uids.isEmpty) return;
    final before = store.transaction(() {
      // Snapshot by UID so undo leaves sets logged after this removal alone.
      final before = [
        if (onRemoved != null)
          for (final uid in uids) store.rowsBefore('training_sets', ['uid'], 'uid = ?', [uid]),
      ];
      for (final uid in uids) {
        store.deleteTrainingSet(uid);
      }
      return before;
    });
    _sets.removeWhere((s) => uids.contains(s.uid));
    onRemoved?.call(label, before);
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
