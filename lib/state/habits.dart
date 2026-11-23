part of '../app_state.dart';

/// Rituals: each month's list, the sleep schedule, the marks on each day,
/// and streaks.
mixin _Habits on ChangeNotifier {
  Store get store;
  DateTime get today;
  bool canEditDay(DateTime day);
  List<Holiday> get holidays;
  void _removed(String label, List<RowsBefore> before);
  void _invalidateFirstDay();

  int habitsRevision = 0, entriesRevision = 0;
  int get entryNotesRevision;
  set entryNotesRevision(int value);
  final _monthHabits = LruCache<(int, int), List<Habit>>(24);

  /// Unsaved copies shown for months without their own list, until any
  /// list or the day changes.
  final _previewHabits = LruCache<(int, int), ({List<Habit> habits, bool preview})>(24);
  final _entryMonths = LruCache<(int, int), Map<String, ({HabitStatus status, String? note, int? amount})>>(12);
  final _monthScores = LruCache<(int, int), Map<int, (int, int)>>(24);

  void _habitsChanged() {
    _previewHabits.clear();
    _trails.clear();
    habitsRevision++;
    notifyListeners();
  }

  void _entriesChanged(DateTime day, {bool noteChanged = false}) {
    _monthScores.remove((day.year, day.month));
    final sunday = DateTime(day.year, day.month, day.day + 7 - day.weekday);
    _monthScores.remove((sunday.year, sunday.month));
    _invalidateFirstDay();
    entriesRevision++;
    if (noteChanged) entryNotesRevision++;
    notifyListeners();
  }

  /// (current, best) streak by ritual id, until a mark or the day changes.
  final _streaks = LruCache<int, (int, int)>(256);

  /// Past days' streaks, by what they depend on, so an old key is simply
  /// never asked for again.
  final _pastStreaks = LruCache<(int, DateTime, int, int, List<Holiday>), (int, int)>(256);

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
    final index = sleepHabitsFor(year, month).indexWhere((x) => x.id == h.id);
    if (index < 0) return;
    final item = SleepItem.values[index];
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

  /// A month's ritual list. Months not yet saved on disk read cleanly from the
  /// nearest saved month without writing to SQLite during build(); saving
  /// happens only when ticked or edited, or when today's day starts.
  List<Habit> habitsFor(int year, int month) {
    final cached = _monthHabits[(year, month)] ?? _previewHabits[(year, month)]?.habits;
    if (cached != null) return cached;

    if (store.hasMonth(year, month)) {
      return _monthHabits[(year, month)] = store.monthHabits(year, month);
    }
    final source = store.nearestMonthWithHabits(year, month);
    if (source == null) return const [];
    final beforeFirst = source.$1 * 12 + source.$2 > year * 12 + month;
    final preview = beforeFirst || isFutureMonth(year, month);
    final derived = [
      for (final h in store.monthHabits(source.$1, source.$2))
        // Not one added partway through a later month: it didn't exist yet.
        if (!beforeFirst || h.addedOn == null)
          Habit(
            h.id,
            h.name,
            description: h.description,
            weekly: h.weekly,
            target: h.target,
            unit: h.unit,
            days: [if (h.weekdays != everyDay) (null, h.weekdays)],
          ),
    ];
    _previewHabits[(year, month)] = (habits: derived, preview: preview);
    return derived;
  }

  /// Whether [habitsFor] is showing an unsaved copy for this month.
  bool isPreviewMonth(int year, int month) {
    final list = habitsFor(year, month);
    if (list.isEmpty || _monthHabits.containsKey((year, month))) return false;
    return _previewHabits[(year, month)]?.preview ?? false;
  }

  /// The month's saved list, copying the nearest month first if needed.
  List<Habit> _savedList(int year, int month) {
    final cached = _monthHabits[(year, month)];
    if (cached != null) return cached;
    if (store.ensureMonth(year, month)) {
      _previewHabits.clear();
      habitsRevision++;
    } else {
      _previewHabits.remove((year, month));
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
    // A preview month gets its own list first, copied from the one it
    // shows, so the new ritual joins it rather than starting it.
    final list = _savedList(year, month);
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
    list.add(h);
    _habitsChanged();
  }

  void renameHabit(int year, int month, Habit h, String name) {
    if (name.trim().isEmpty) return;
    final saved = _savedList(year, month).where((x) => x.id == h.id).firstOrNull;
    if (saved == null) return;
    saved.name = normaliseNote(name.trim());
    store.renameHabit(year, month, h.id, saved.name);
    _habitsChanged();
  }

  /// This month's note on the ritual; blank removes it.
  void setHabitNote(int year, int month, Habit h, String note) {
    final saved = _savedList(year, month).where((x) => x.id == h.id).firstOrNull;
    if (saved == null) return;
    saved.description = note.trim().isEmpty ? null : normaliseNote(note.trim());
    store.setHabitNote(year, month, h.id, saved.description);
    entryNotesRevision++;
    _habitsChanged();
  }

  void setRitualGoal(int year, int month, Habit habit, {int? weekly, int? target, String? unit}) {
    if (weekly != null && (weekly < 1 || weekly > 7) || target != null && target <= 0) return;
    final saved = _savedList(year, month).where((h) => h.id == habit.id).firstOrNull;
    if (saved == null) return;
    final normalizedUnit = target == null || unit == null || unit.trim().isEmpty
        ? null
        : curlyQuotes(unit.trim());
    store.transaction(() {
      store.raw.execute('UPDATE month_habits SET weekly=?,target=?,unit=? WHERE year=? AND month=? AND habit_id=?', [
        weekly,
        target,
        normalizedUnit,
        year,
        month,
        habit.id,
      ]);
      if (target != null) {
        final from = dateKey(DateTime(year, month));
        final to = dateKey(DateTime(year, month + 1));
        for (final row in store.raw.select(
          'SELECT day, status, amount FROM entries WHERE habit_id=? AND day >= ? AND day < ? AND amount IS NOT NULL AND status IN (0, 1)',
          [habit.id, from, to],
        )) {
          final amount = row['amount'] as int;
          final next = amount >= target ? HabitStatus.done.index : HabitStatus.none.index;
          if (next != row['status'] as int) {
            store.raw.execute('UPDATE entries SET status=? WHERE day=? AND habit_id=?', [
              next,
              row['day'],
              habit.id,
            ]);
          }
        }
      }
    });
    saved.weekly = weekly;
    saved.target = target;
    saved.unit = normalizedUnit;
    _entryMonths.remove((year, month));
    _monthScores.clear();
    _streaks.clear();
    entriesRevision++;
    _habitsChanged();
  }

  int amountOn(DateTime day, Habit habit) =>
      _entriesFor(day)[_cell(day, habit)]?.amount ??
      (statusOf(day, habit) == HabitStatus.done ? habit.target ?? 0 : 0);

  int weeklyDone(DateTime day, Habit habit) {
    final monday = DateTime(day.year, day.month, day.day - day.weekday + 1);
    var count = 0;
    for (var d = monday; !d.isAfter(day); d = DateTime(d.year, d.month, d.day + 1)) {
      if (habit.startedBy(d) && holidayOn(holidays, d) == null && statusOf(d, habit) == HabitStatus.done) count++;
    }
    return count;
  }

  void recordAmount(DateTime day, Habit habit, int amount) {
    if (!canEditDay(day) || amount < 0 || habit.target == null || !habit.onDay(day) || !habit.startedBy(day)) return;
    _savedList(day.year, day.month);
    final previousNote = noteOf(day, habit);
    final previousStatus = statusOf(day, habit);
    if (amount == 0) {
      store.setEntry(dateKey(day), habit.id, HabitStatus.none);
      _entriesFor(day).remove(_cell(day, habit));
    } else {
      final status = amount >= habit.target! ? HabitStatus.done : HabitStatus.none;
      final clearNote = previousStatus == HabitStatus.other;
      store.raw.execute(
        'INSERT INTO entries(day,habit_id,status,amount,note) VALUES(?,?,?,?,NULL) '
        'ON CONFLICT(day,habit_id) DO UPDATE SET status=excluded.status,amount=excluded.amount,'
        'note=CASE WHEN ? THEN NULL ELSE entries.note END',
        [dateKey(day), habit.id, status.index, amount, clearNote ? 1 : 0],
      );
      _entriesFor(day)[_cell(day, habit)] = (
        status: status,
        note: clearNote ? null : previousNote,
        amount: amount,
      );
    }
    _streaks.remove(habit.id);
    _entriesChanged(day, noteChanged: previousStatus == HabitStatus.other && previousNote != null);
  }

  /// The weekdays the ritual is on, as bits (see [weekdayBit]). In the current month
  /// they change from today on, so earlier days keep the ones they had;
  /// any other month changes as a whole.
  void setHabitDays(int year, int month, Habit h, int bits) {
    if (bits & everyDay == 0) return;
    final saved = _savedList(year, month).where((x) => x.id == h.id).firstOrNull;
    if (saved == null) return;
    final from = year == today.year && month == today.month && today.day > 1 ? today : null;
    saved.days = changeDays(saved.days, from, bits);
    store.setHabitDays(year, month, h.id, saved.days);
    _monthScores.remove((year, month));
    _streaks.remove(h.id);
    _habitsChanged();
  }

  void removeHabit(int year, int month, Habit h) {
    saveHabitDrafts();
    final list = _savedList(year, month);
    _removed('Removed “${h.name}” from ${monthNames[month - 1]}', [
      store.rowsBefore(
        'month_habits',
        ['year', 'month', 'habit_id'],
        'year = ? AND month = ? AND habit_id = ?',
        [year, month, h.id],
      ),
    ]);
    list.removeWhere((x) => x.id == h.id);
    store.removeHabit(year, month, h.id);
    _monthScores.remove((year, month));
    _streaks.remove(h.id);
    _habitsChanged();
  }

  void reorderHabit(int year, int month, int from, int to) {
    final list = _savedList(year, month);
    list.insert(to, list.removeAt(from));
    store.reorderHabits(year, month, [for (final h in list) h.id]);
    _habitsChanged();
  }

  // Entries

  Map<String, ({HabitStatus status, String? note, int? amount})> _entriesFor(DateTime day) => _entryMonths.putIfAbsent(
    (day.year, day.month),
    () => {
      for (final e in store.entriesInMonth(day.year, day.month))
        '${e.day}|${e.habitId}': (status: e.status, note: e.note, amount: e.amount),
    },
  );

  HabitStatus statusOf(DateTime day, Habit h) => _entriesFor(day)[_cell(day, h)]?.status ?? HabitStatus.none;

  String? noteOf(DateTime day, Habit h) => _entriesFor(day)[_cell(day, h)]?.note;

  /// Select a mark directly; repeating that mark clears the square.
  HabitStatus selectStatus(DateTime day, Habit h, HabitStatus status) {
    if (dateOnly(day).isAfter(today)) return HabitStatus.none;
    if (status == HabitStatus.none || statusOf(day, h) == status) {
      clear(day, h);
      return HabitStatus.none;
    }
    _savedList(day.year, day.month);
    final key = _cell(day, h);
    final hadNote = _entriesFor(day)[key]?.note != null;
    _entriesFor(day)[key] = (status: status, note: null, amount: null);
    _streaks.remove(h.id);
    store.setEntry(dateKey(day), h.id, status, clearNote: true);
    _entriesChanged(day, noteChanged: hadNote);
    return status;
  }

  /// Back to blank, whatever the mark was.
  void clear(DateTime day, Habit h) {
    if (dateOnly(day).isAfter(today)) return;
    final key = _cell(day, h);
    final removed = _entriesFor(day).remove(key);
    if (removed == null) return;
    _streaks.remove(h.id);
    store.setEntry(dateKey(day), h.id, HabitStatus.none);
    _entriesChanged(day, noteChanged: removed.note != null);
  }

  void setNote(DateTime day, Habit h, String note) {
    if (dateOnly(day).isAfter(today)) return;
    final key = _cell(day, h);
    final trimmed = normaliseNote(note.trim());
    final dayKey = dateKey(day);
    final existing = _entriesFor(day)[key];
    if (existing == null && !store.hasEntry(dayKey, h.id)) return;
    final nextNote = trimmed.isEmpty ? null : trimmed;
    _entriesFor(day)[key] = (status: existing?.status ?? statusOf(day, h), note: nextNote, amount: existing?.amount);
    store.setNote(dayKey, h.id, nextNote);
    _entriesChanged(day, noteChanged: true);
  }

  /// Done among the rituals that are on [day].
  int doneOn(DateTime day, List<Habit> habits) =>
      habits.where((h) => h.onDay(day) && statusOf(day, h) == HabitStatus.done).length;

  (int, int) scoreOf(int year, int month, Habit habit) =>
      _monthScores.putIfAbsent(
        (year, month),
        () => store.monthScores(year, month, asOf: today, holidays: holidays),
      )[habit.id] ??
      (0, 0);

  /// Consecutive done days ending today (or yesterday, if today is still
  /// open). An "other" day, or a blank or missed rest day, is excused: it neither
  /// breaks nor extends a streak.
  int currentStreak(Habit h) => _streaksOf(h).$1;

  int bestStreak(Habit h) => _streaksOf(h).$2;

  /// A ritual's current and best streak as they stood at the end of [day];
  /// on today, as they stand now.
  (int, int) streaksOn(Habit h, DateTime day) => day == today
      ? _streaksOf(h)
      : _pastStreaks[(h.id, day, entriesRevision, habitsRevision, holidays)] ??= store.streaks(
          h.id,
          day,
          holidays: holidays,
          dayOver: true,
        );

  (int, int) _streaksOf(Habit h) =>
      _streaks[h.id] ??= store.streaks(h.id, today, holidays: holidays);

  @override
  void dispose() {
    _habitTimer?.cancel();
    super.dispose();
  }
}
