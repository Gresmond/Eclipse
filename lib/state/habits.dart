part of '../app_state.dart';

/// Rituals: each month's list, the sleep schedule, the marks on each day,
/// and streaks.
mixin _Habits on ChangeNotifier {
  Store get store;
  DateTime get today;
  bool get restWeekends;

  int habitsRevision = 0, entriesRevision = 0;
  final _monthHabits = LruCache<(int, int), List<Habit>>(24);

  /// Unsaved copies shown for months without their own list, until any
  /// list or the day changes.
  final _previewHabits = LruCache<(int, int), List<Habit>>(24);
  final _entryMonths = LruCache<(int, int), Map<String, (HabitStatus, String?)>>(12);
  final _monthScores = LruCache<(int, int), Map<int, (int, int)>>(24);

  void _habitsChanged() {
    _previewHabits.clear();
    _trails.clear();
    habitsRevision++;
    notifyListeners();
  }

  void _entriesChanged(DateTime day) {
    _monthScores.remove((day.year, day.month));
    entriesRevision++;
    notifyListeners();
  }

  /// (current, best) streak by ritual id, until a mark or the day changes.
  final _streaks = LruCache<int, (int, int)>(256);

  /// The days behind each ritual's week trail, by ritual and day, until its days change.
  final _trails = LruCache<(int, DateTime), List<DateTime>>(256);

  /// The ritual's last 7 days before [day], latest first; fewer when it's new.
  List<DateTime> trailDays(Habit h, DateTime day) =>
      _trails[(h.id, dateOnly(day))] ??= store.pastDays(h.id, dateOnly(day), 7);

  String _cell(DateTime day, Habit h) => '${dateKey(day)}|${h.id}';

  bool isFutureMonth(int year, int month) => year * 12 + month > today.year * 12 + today.month;

  /// Today's month's rituals.
  List<Habit> get habits => habitsFor(today.year, today.month);

  /// Today's month's sleep schedule.
  List<Habit> get sleepHabits => sleepHabitsFor(today.year, today.month);

  final _monthSleep = LruCache<(int, int), List<Habit>>(24);

  /// The sleep schedule: the same four items in every month, each month
  /// with its own times.
  List<Habit> sleepHabitsFor(int year, int month) => _monthSleep[(year, month)] ??= store.sleepHabits(year, month);

  /// This month's time for a sleep item; null clears it. A new month
  /// starts with the month before's, and a change stays in its own month:
  /// the month after keeps what it had.
  void setSleepTime(int year, int month, Habit h, int? minutes) {
    final item = SleepItem.values[sleepHabitsFor(year, month).indexWhere((x) => x.id == h.id)];
    String key(int? m) => m == null ? '' : clockKey(m);
    final next = DateTime(year, month + 1);
    if (!isFutureMonth(next.year, next.month) && store.sleepNote(next.year, next.month, item, own: true) == null) {
      // Kept as it was, not set: a time set there on another computer wins.
      store.weak(
        () => store.setSleepNote(
          next.year,
          next.month,
          item,
          key(sleepHabitsFor(next.year, next.month)[item.index].minutes),
        ),
      );
    }
    store.setSleepNote(year, month, item, key(minutes));
    _monthSleep.clear();
    _habitsChanged();
  }

  /// A month's ritual list. A month between your first list and today is
  /// saved as a copy of the month before it. Future months, and months
  /// before your first list, are previews: nothing is saved until a ritual
  /// there is ticked or edited.
  List<Habit> habitsFor(int year, int month) {
    final cached = _monthHabits[(year, month)] ?? _previewHabits[(year, month)];
    if (cached != null) return cached;

    final source = store.hasMonth(year, month) ? (year, month) : store.nearestMonthWithHabits(year, month);
    if (source == null) return const [];
    final beforeFirst = source.$1 * 12 + source.$2 > year * 12 + month;
    if (source != (year, month) && (beforeFirst || isFutureMonth(year, month))) {
      return _previewHabits[(year, month)] = [
        for (final h in store.monthHabits(source.$1, source.$2))
          // Not one added partway through a later month: it didn't exist yet.
          if (!beforeFirst || h.addedOn == null)
            Habit(h.id, h.name, description: h.description, days: [if (h.weekdays != everyDay) (null, h.weekdays)]),
      ];
    }
    return _savedList(year, month);
  }

  /// Whether [habitsFor] is showing an unsaved copy for this month.
  bool isPreviewMonth(int year, int month) =>
      habitsFor(year, month).isNotEmpty && _previewHabits.containsKey((year, month));

  /// The month's saved list, copying the nearest month first if needed.
  List<Habit> _savedList(int year, int month) {
    final cached = _monthHabits[(year, month)];
    if (cached != null) return cached;
    if (store.ensureMonth(year, month)) {
      _previewHabits.clear();
      habitsRevision++;
    }
    return _monthHabits[(year, month)] = store.monthHabits(year, month);
  }

  // Edits take the habit's id, because [h] may come from a preview list.

  final Map<(int, int, int, String), void Function()> _habitDrafts = {};
  Timer? _habitTimer;

  void _draftHabit(int year, int month, Habit habit, String field, void Function() save) {
    _habitDrafts[(year, month, habit.id, field)] = save;
    _habitTimer?.cancel();
    _habitTimer = Timer(const Duration(milliseconds: 400), saveHabitDrafts);
  }

  void draftHabitName(int year, int month, Habit habit, String text) =>
      _draftHabit(year, month, habit, 'name', () => renameHabit(year, month, habit, text));

  void draftHabitNote(int year, int month, Habit habit, String text) =>
      _draftHabit(year, month, habit, 'note', () => setHabitNote(year, month, habit, text));

  void saveHabitDrafts() {
    _habitTimer?.cancel();
    _habitTimer = null;
    final saves = _habitDrafts.values.toList();
    _habitDrafts.clear();
    for (final save in saves) {
      save();
    }
  }

  /// A new ritual, on the weekdays in [days] (see [weekdayBit]).
  void addHabit(int year, int month, String name, {int days = everyDay}) {
    if (name.trim().isEmpty) return;
    final h = store.addHabit(
      year,
      month,
      normaliseNote(name.trim()),
      addedOn: year == today.year && month == today.month ? today : null,
    );
    if (days & everyDay != 0 && days != everyDay) {
      h.days = [(null, days)];
      store.setHabitDays(year, month, h.id, h.days);
    }
    _savedList(year, month).add(h);
    _habitsChanged();
  }

  void renameHabit(int year, int month, Habit h, String name) {
    if (name.trim().isEmpty) return;
    final saved = _savedList(year, month).firstWhere((x) => x.id == h.id);
    saved.name = normaliseNote(name.trim());
    store.renameHabit(year, month, h.id, saved.name);
    _habitsChanged();
  }

  /// This month's note on the ritual; blank removes it.
  void setHabitNote(int year, int month, Habit h, String note) {
    final saved = _savedList(year, month).firstWhere((x) => x.id == h.id);
    saved.description = note.trim().isEmpty ? null : normaliseNote(note.trim());
    store.setHabitNote(year, month, h.id, saved.description);
    _habitsChanged();
  }

  /// The weekdays the ritual is on, as bits (see [weekdayBit]). In the current month
  /// they change from today on, so earlier days keep the ones they had;
  /// any other month changes as a whole.
  void setHabitDays(int year, int month, Habit h, int bits) {
    if (bits & everyDay == 0) return;
    final saved = _savedList(year, month).firstWhere((x) => x.id == h.id);
    final from = year == today.year && month == today.month && today.day > 1 ? today : null;
    saved.days = changeDays(saved.days, from, bits);
    store.setHabitDays(year, month, h.id, saved.days);
    _monthScores.remove((year, month));
    _streaks.remove(h.id);
    _habitsChanged();
  }

  void removeHabit(int year, int month, Habit h) {
    saveHabitDrafts();
    _savedList(year, month).removeWhere((x) => x.id == h.id);
    store.removeHabit(year, month, h.id);
    _habitsChanged();
  }

  void reorderHabit(int year, int month, int from, int to) {
    final list = _savedList(year, month);
    list.insert(to, list.removeAt(from));
    store.reorderHabits(year, month, [for (final h in list) h.id]);
    _habitsChanged();
  }

  // Entries

  Map<String, (HabitStatus, String?)> _entriesFor(DateTime day) => _entryMonths.putIfAbsent((
    day.year,
    day.month,
  ), () => {for (final e in store.entriesInMonth(day.year, day.month)) '${e.day}|${e.habitId}': (e.status, e.note)});

  HabitStatus statusOf(DateTime day, Habit h) => _entriesFor(day)[_cell(day, h)]?.$1 ?? HabitStatus.none;

  String? noteOf(DateTime day, Habit h) => _entriesFor(day)[_cell(day, h)]?.$2;

  /// Select a mark directly; repeating that mark clears the square.
  HabitStatus selectStatus(DateTime day, Habit h, HabitStatus status) {
    if (status == HabitStatus.none || statusOf(day, h) == status) {
      clear(day, h);
      return HabitStatus.none;
    }
    _savedList(day.year, day.month);
    final key = _cell(day, h);
    _entriesFor(day)[key] = (status, null);
    _streaks.remove(h.id);
    store.setEntry(dateKey(day), h.id, status, clearNote: true);
    _entriesChanged(day);
    return status;
  }

  /// Back to blank, whatever the mark was.
  void clear(DateTime day, Habit h) {
    final key = _cell(day, h);
    if (_entriesFor(day).remove(key) == null) return;
    _streaks.remove(h.id);
    store.setEntry(dateKey(day), h.id, HabitStatus.none);
    _entriesChanged(day);
  }

  void setNote(DateTime day, Habit h, String note) {
    final key = _cell(day, h);
    final trimmed = normaliseNote(note.trim());
    _entriesFor(day)[key] = (statusOf(day, h), trimmed.isEmpty ? null : trimmed);
    store.setNote(dateKey(day), h.id, trimmed.isEmpty ? null : trimmed);
    _entriesChanged(day);
  }

  /// Done among the rituals that are on [day].
  int doneOn(DateTime day, List<Habit> habits) =>
      habits.where((h) => h.onDay(day) && statusOf(day, h) == HabitStatus.done).length;

  (int, int) scoreOf(int year, int month, Habit habit) =>
      _monthScores.putIfAbsent((year, month), () => store.monthScores(year, month))[habit.id] ?? (0, 0);

  /// Consecutive done days ending today (or yesterday, if today is still
  /// open). An "other" day, or a blank rest day, is excused: it neither
  /// breaks nor extends a streak.
  int currentStreak(Habit h) => _streaksOf(h).$1;

  int bestStreak(Habit h) => _streaksOf(h).$2;

  (int, int) _streaksOf(Habit h) => _streaks[h.id] ??= store.streaks(h.id, today, restWeekends: restWeekends);

  @override
  void dispose() {
    _habitTimer?.cancel();
    super.dispose();
  }
}
