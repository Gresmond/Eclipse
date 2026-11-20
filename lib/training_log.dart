import 'dart:convert';

import 'package:flutter/foundation.dart' show VoidCallback;

import 'data/store.dart';
import 'models.dart';
import 'training.dart';

/// How the chart's y-axis reads.
enum TrainingAxis { kg, change }

/// What the chart tile shows: every exercise on one chart, a small chart
/// per exercise, or one per muscle group with its exercises as lines.
enum TrainingLayout {
  all('All'),
  exercises('Exercises'),
  muscles('Muscles');

  const TrainingLayout(this.label);
  final String label;
}

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

/// The same day of the month [months] earlier, or that month's last day when
/// it is shorter: a month before 31 March is 28 February, not 3 March.
DateTime monthsBefore(DateTime day, int months) {
  final first = DateTime(day.year, day.month - months);
  final last = DateTime(first.year, first.month + 1, 0).day;
  return DateTime(first.year, first.month, day.day < last ? day.day : last);
}

/// Exercises and logged sets, kept in memory and written straight through
/// to [store]. Changes tell AppState, so AppScope watchers redraw.
class TrainingLog {
  TrainingLog(this.store, this._changed, {this.onRemoved, this.onActivityChanged}) {
    reload();
  }

  final Store store;
  final void Function() _changed;
  final void Function(String label, List<RowsBefore> before)? onRemoved;
  final VoidCallback? onActivityChanged;

  /// Bumped on every change, for AppScope.watch.
  int revision = 0;

  List<Exercise> exercises = [];
  Map<String, Exercise> _byUid = {};
  List<TrainingSet> _sets = [];
  List<(String, String)> _routines = [];
  List<(String, double)> _weighIns = [];
  final Map<DateTime?, Map<Exercise, List<TrainingPoint>>> _pointsCache = {};
  int? _pointsRevision;

  /// The day being logged or edited; null for today.
  DateTime? day;

  TrainingAxis axis = TrainingAxis.kg;
  TrainingLayout layout = TrainingLayout.all;
  TrainingRange range = TrainingRange.quarter;

  /// Exercise uids and muscle group names hidden from the chart.
  Set<String> hidden = {};

  void reload() {
    axis = TrainingAxis.values.asNameMap()[store.setting('trainingAxis')] ?? TrainingAxis.kg;
    layout = TrainingLayout.values.asNameMap()[store.setting('trainingLayout')] ?? TrainingLayout.all;
    range = TrainingRange.values.asNameMap()[store.setting('trainingRange')] ?? TrainingRange.quarter;
    hidden = {...?store.setting('trainingHidden')?.split(',').where((s) => s.isNotEmpty)};
    exercises = store.exercises();
    _byUid = {for (final e in exercises) e.uid: e};
    _sets = store.trainingSets();
    _routines = [
      for (final row in store.raw.select('SELECT uid, name FROM routines ORDER BY name COLLATE NOCASE'))
        (row['uid'] as String, row['name'] as String),
    ];
    _weighIns = [
      for (final row in store.raw.select('SELECT uid, kg FROM weigh_ins ORDER BY uid'))
        (row['uid'] as String, (row['kg'] as num).toDouble()),
    ];
    _pointsCache.clear();
    revision++;
  }

  void _done() {
    _pointsCache.clear();
    revision++;
    _changed();
  }

  Exercise? exercise(String uid) => _byUid[uid];

  void showDay(DateTime? d) {
    day = d == null ? null : dateOnly(d);
    _done();
  }

  /// Days with anything logged, newest first.
  List<String> get loggedDays => {
    for (final s in _sets)
      if (_byUid.containsKey(s.exercise)) s.day,
  }.toList().reversed.toList();

  /// [day]'s sets, grouped by exercise in the order they were first logged.
  List<(Exercise, List<TrainingSet>)> session(DateTime day) {
    final key = dateKey(day);
    return _grouped(_sets.where((s) => s.day == key))[key] ?? const [];
  }

  /// Every logged day's [session], by day key, in one pass over the sets.
  Map<String, List<(Exercise, List<TrainingSet>)>> get sessions => _grouped(_sets);

  Map<String, List<(Exercise, List<TrainingSet>)>> _grouped(Iterable<TrainingSet> sets) {
    final days = <String, Map<String, List<TrainingSet>>>{};
    for (final s in sets) {
      if (_byUid.containsKey(s.exercise)) ((days[s.day] ??= {})[s.exercise] ??= []).add(s);
    }
    return {
      for (final MapEntry(key: day, value: groups) in days.entries)
        day: [for (final MapEntry(:key, :value) in groups.entries) (_byUid[key]!, value)],
    };
  }

  /// Exercise uids in the order each was first logged: by day, then by its
  /// place in that day's session.
  List<String> get loggedOrder => {
    for (final s in _sets)
      if (_byUid.containsKey(s.exercise)) s.exercise,
  }.toList();

  /// Whether [e] tracks total load (bodyweight + added weight) in kg instead
  /// of reps alone: true for bodyweight exercises with added weight and at
  /// least one weigh-in logged.
  bool usesTotalLoad(Exercise e) =>
      e.bodyweight &&
      _weighIns.isNotEmpty &&
      _sets.any((s) => s.exercise == e.uid && (s.weight ?? 0) > 0);

  double? _bodyMassForKey(String dayKey) {
    if (_weighIns.isEmpty) return null;
    double? found;
    for (final (uid, kg) in _weighIns) {
      if (uid.compareTo(dayKey) > 0) break;
      found = kg;
    }
    return found;
  }

  /// Each exercise's points, oldest first, from [from] on (all with null).
  /// A point follows from the days before it, those before [from] too, so
  /// it reads the same in every range.
  Map<Exercise, List<TrainingPoint>> points({DateTime? from}) {
    final normalizedFrom = from == null ? null : dateOnly(from);
    if (_pointsRevision != revision) {
      _pointsCache.clear();
      _pointsRevision = revision;
    }
    if (_pointsCache[normalizedFrom] case final cached?) return cached;
    final byExercise = <String, Map<String, List<TrainingSet>>>{};
    for (final s in _sets) {
      ((byExercise[s.exercise] ??= {})[s.day] ??= []).add(s);
    }
    final result = <Exercise, List<TrainingPoint>>{};
    for (final MapEntry(key: uid, value: days) in byExercise.entries) {
      final e = _byUid[uid];
      if (e == null) continue;
      final totalLoad = usesTotalLoad(e);
      final points = trainingPoints(
        [for (final MapEntry(key: day, value: sets) in days.entries) (DateTime.parse(day), sets)],
        bodyweight: e.bodyweight,
        bodyMassFor: totalLoad ? (d) => _bodyMassForKey(dateKey(d)) : null,
      ).where((p) => normalizedFrom == null || !p.day.isBefore(normalizedFrom)).toList();
      if (points.isNotEmpty) result[e] = points;
    }
    return _pointsCache[normalizedFrom] = result;
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

  double? _worth(TrainingSet s, Exercise e, {bool totalLoad = false}) => setWorth(
    s,
    bodyweight: e.bodyweight,
    bodyMass: totalLoad ? _bodyMassForKey(s.day) : null,
  );

  /// The sets of [e] on [day] that beat every set before them, on earlier
  /// days and earlier that day. None on the first day [e] is logged.
  Set<String> personalBests(DateTime day, Exercise e) {
    final key = dateKey(day);
    final totalLoad = usesTotalLoad(e);
    var hadPriorDay = false;
    double? best;
    for (final s in _sets) {
      if (s.exercise != e.uid || s.day.compareTo(key) >= 0) continue;
      final performed = s.reps > 0 && (e.bodyweight || (s.weight ?? 0) > 0);
      if (!performed) continue;
      hadPriorDay = true;
      final mass = totalLoad ? _bodyMassForKey(s.day) : null;
      final worth =
          _worth(s, e, totalLoad: totalLoad) ??
          (s.reps > maxEstimateReps && (!e.bodyweight || mass != null)
              ? estimateOneRepMax((mass ?? 0) + (s.weight ?? 0), maxEstimateReps)
              : null);
      if (worth != null && (best == null || worth > best)) best = worth;
    }
    if (!hadPriorDay) return const {};
    final result = <String>{};
    for (final s in _sets) {
      if (s.exercise != e.uid || s.day != key) continue;
      final worth = _worth(s, e, totalLoad: totalLoad);
      if (worth != null && (best == null || worth > best)) {
        best = worth;
        result.add(s.uid);
      }
    }
    return result;
  }

  // Editing

  void _sortExercises() => exercises.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.uid.compareTo(b.uid);
  });

  Exercise createExercise(String name, MuscleGroup group, {required bool bodyweight}) {
    final cleaned = normaliseNote(name.trim());
    if (cleaned.isEmpty) throw ArgumentError.value(name, 'name', 'Exercise name cannot be empty');
    final e = store.addExercise(cleaned, group, bodyweight: bodyweight);
    exercises.add(e);
    _sortExercises();
    _byUid[e.uid] = e;
    _done();
    return e;
  }

  void updateExercise(Exercise e, {String? name, MuscleGroup? group, bool? bodyweight}) {
    final trimmed = name == null ? null : normaliseNote(name.trim());
    final updated = Exercise(
      uid: e.uid,
      name: trimmed == null || trimmed.isEmpty ? e.name : trimmed,
      group: group ?? e.group,
      bodyweight: bodyweight ?? e.bodyweight,
    );
    store.saveExercise(updated);
    final i = exercises.indexWhere((x) => x.uid == e.uid);
    if (i >= 0) {
      exercises[i] = updated;
      _sortExercises();
    }
    _byUid[updated.uid] = updated;
    _done();
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
    // Nothing left of it to hide.
    if (hidden.remove(e.uid)) store.setSetting('trainingHidden', hidden.join(','));
    if (uids.isNotEmpty) onActivityChanged?.call();
    exercises.removeWhere((x) => x.uid == e.uid);
    _byUid.remove(e.uid);
    _sets.removeWhere((s) => s.exercise == e.uid);
    onRemoved?.call('Deleted “${e.name}” and all its sets', before);
    _done();
  }

  double? _keptWeight(Exercise e, double? weight) =>
      e.bodyweight ? (weight != null && weight > 0 ? weight : null) : weight;

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
              store.addTrainingSet(key, e.uid, position: at++, weight: _keptWeight(e, s.weight)),
      ],
    );
    if (added.isEmpty) return;
    _sets.addAll(added);
    _sort();
    onActivityChanged?.call();
    _done();
  }

  /// Puts [e] on [day] with one empty set, after what's already there.
  void addToDay(DateTime day, Exercise e) {
    final key = dateKey(day);
    final last = _sets.where((s) => s.day == key).fold(-1, (m, s) => s.position > m ? s.position : m);
    final previous = _lastSet(e.uid, beforeOrOn: key);
    _sets.add(store.addTrainingSet(key, e.uid, position: last + 1, weight: _keptWeight(e, previous?.weight)));
    _sort();
    onActivityChanged?.call();
    _done();
  }

  /// Oldest day first, in order within each day, as [Store.trainingSets]
  /// reads them: the days logged, the chart's points and the latest weight
  /// all go by it, and a set added to an earlier day lands at the end.
  void _sort() => _sets.sort((a, b) {
    final day = a.day.compareTo(b.day);
    if (day != 0) return day;
    final pos = a.position.compareTo(b.position);
    return pos != 0 ? pos : a.uid.compareTo(b.uid);
  });

  /// Adds a set to [e] on [day], at the weight of the set before it.
  TrainingSet? lastPerformed(DateTime day, Exercise e) {
    final key = dateKey(day);
    return _sets.reversed.where((s) => s.exercise == e.uid && s.reps > 0 && s.day.compareTo(key) <= 0).firstOrNull;
  }

  void addSet(DateTime day, Exercise e, {int reps = 0, double? loggedWeight}) {
    final key = dateKey(day);
    final mine = _sets.where((s) => s.day == key && s.exercise == e.uid).toList();
    final weight = mine.isEmpty ? _lastSet(e.uid, beforeOrOn: key)?.weight : mine.last.weight;
    final at = mine.isEmpty
        ? _sets.where((s) => s.day == key).fold(-1, (m, s) => s.position > m ? s.position : m) + 1
        : mine.last.position + 1;
    final (shifted, added) = store.transaction(() {
      final shifted = <(int, TrainingSet)>[];
      // Make room: everything after shifts down one.
      for (final (i, s) in _sets.indexed) {
        if (s.day == key && s.position >= at) {
          final updated = s.copyWith(position: s.position + 1);
          store.saveTrainingSet(updated);
          shifted.add((i, updated));
        }
      }
      final added = store.addTrainingSet(
        key,
        e.uid,
        position: at,
        weight: _keptWeight(e, loggedWeight ?? weight),
        reps: reps,
      );
      return (shifted, added);
    });
    for (final (i, updated) in shifted) {
      _sets[i] = updated;
    }
    _sets.add(added);
    _sort();
    onActivityChanged?.call();
    _done();
  }

  void updateSet(TrainingSet set, {double? weight, bool clearWeight = false, int? reps}) {
    if (weight != null && (!weight.isFinite || weight < 0)) return;
    if (reps != null && reps < 0) return;
    final i = _sets.indexWhere((s) => s.uid == set.uid);
    if (i < 0) return;
    _sets[i] = _sets[i].copyWith(weight: weight, clearWeight: clearWeight, reps: reps);
    store.saveTrainingSet(_sets[i]);
    onActivityChanged?.call();
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
    onActivityChanged?.call();
    _done();
  }

  /// The latest weighted set of [exercise], preferring on or before
  /// [beforeOrOn] when given, to start the next one from.
  TrainingSet? _lastSet(String exercise, {String? beforeOrOn}) {
    TrainingSet? fallback;
    for (final s in _sets.reversed) {
      if (s.exercise != exercise || s.weight == null) continue;
      if (beforeOrOn == null || s.day.compareTo(beforeOrOn) <= 0) return s;
      fallback ??= s;
    }
    return fallback;
  }

  List<(String, String)> get routines => List.unmodifiable(_routines);

  void _reloadRoutines() {
    _routines = [
      for (final row in store.raw.select('SELECT uid, name FROM routines ORDER BY name COLLATE NOCASE'))
        (row['uid'] as String, row['name'] as String),
    ];
  }

  void saveRoutine(String name, DateTime day) {
    final sets = [
      for (final (e, sets) in session(day))
        for (final s in sets) [e.uid, s.weight],
    ];
    final cleaned = normaliseNote(name.trim());
    if (cleaned.isEmpty || sets.isEmpty) return;
    store.raw.execute('INSERT INTO routines(uid,name,sets) VALUES(lower(hex(randomblob(8))),?,?)', [
      cleaned,
      jsonEncode(sets),
    ]);
    _reloadRoutines();
    _done();
  }

  void renameRoutine(String uid, String name) {
    final cleaned = normaliseNote(name.trim());
    if (cleaned.isEmpty) return;
    store.raw.execute('UPDATE routines SET name=? WHERE uid=?', [cleaned, uid]);
    _reloadRoutines();
    _done();
  }

  void deleteRoutine(String uid) {
    store.raw.execute('DELETE FROM routines WHERE uid=?', [uid]);
    _reloadRoutines();
    _done();
  }

  void applyRoutine(String uid, DateTime day) {
    final rows = store.raw.select('SELECT sets FROM routines WHERE uid=?', [uid]);
    if (rows.isEmpty) return;
    final encoded = rows.first['sets'] as String;
    if (!validRoutine(encoded)) return;
    final key = dateKey(day);
    final existing = {for (final (e, _) in session(day)) e.uid};
    var pos = _sets.where((s) => s.day == key).fold(-1, (m, s) => m > s.position ? m : s.position) + 1;
    final added = store.transaction(() {
      final made = <TrainingSet>[];
      for (final row in jsonDecode(encoded) as List) {
        final id = row[0] as String;
        final ex = exercise(id);
        if (!existing.contains(id) && ex != null) {
          made.add(
            store.addTrainingSet(
              key,
              id,
              position: pos++,
              weight: _keptWeight(ex, (row[1] as num?)?.toDouble()),
            ),
          );
        }
      }
      return made;
    });
    if (added.isEmpty) return;
    _sets.addAll(added);
    _sort();
    onActivityChanged?.call();
    _done();
  }

  double? bodyMass(DateTime day) => _bodyMassForKey(dateKey(day));

  void weighIn(DateTime day, double kg) {
    if (!kg.isFinite || kg <= 0) return;
    store.raw.execute('INSERT INTO weigh_ins(uid,kg) VALUES(?,?) ON CONFLICT(uid) DO UPDATE SET kg=excluded.kg', [
      dateKey(day),
      kg,
    ]);
    _weighIns = [
      for (final row in store.raw.select('SELECT uid, kg FROM weigh_ins ORDER BY uid'))
        (row['uid'] as String, (row['kg'] as num).toDouble()),
    ];
    onActivityChanged?.call();
    _done();
  }

  void setDetails(TrainingSet set, String note, double? rpe, {double? addedWeight, bool clearWeight = false}) {
    if (rpe != null && (!rpe.isFinite || rpe < 1 || rpe > 10)) return;
    if (addedWeight != null && (!addedWeight.isFinite || addedWeight < 0)) return;
    final i = _sets.indexWhere((s) => s.uid == set.uid);
    if (i < 0) return;
    final changed = _sets[i].copyWith(
      note: cleanNote(note),
      rpe: rpe,
      weight: clearWeight ? null : addedWeight,
      clearWeight: clearWeight,
      replaceDetails: true,
    );
    store.saveTrainingSet(changed);
    _sets[i] = changed;
    _done();
  }

  Map<MuscleGroup, (int, double)> weeklyVolume(DateTime day) {
    final monday = DateTime(day.year, day.month, day.day - day.weekday + 1);
    final start = dateKey(monday), end = dateKey(DateTime(monday.year, monday.month, monday.day + 7));
    final totals = <MuscleGroup, (int, double)>{};
    for (final set in _sets) {
      final ex = exercise(set.exercise);
      if (ex == null || set.reps <= 0 || set.day.compareTo(start) < 0 || set.day.compareTo(end) >= 0) continue;
      if (!ex.bodyweight && (set.weight ?? 0) <= 0) continue;
      final prior = totals[ex.group] ?? (0, 0.0);
      final load = (set.weight ?? 0) + (ex.bodyweight ? _bodyMassForKey(set.day) ?? 0 : 0);
      totals[ex.group] = (prior.$1 + 1, prior.$2 + load * set.reps);
    }
    return totals;
  }

  // Chart preferences, per computer

  void setAxis(TrainingAxis a) {
    axis = a;
    store.setSetting('trainingAxis', a.name);
    _done();
  }

  void setLayout(TrainingLayout l) {
    layout = l;
    store.setSetting('trainingLayout', l.name);
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
