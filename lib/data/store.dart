import 'dart:convert';
import 'dart:math';

import 'copy_database.dart';
import 'sqlite.dart';

import '../models.dart';
import '../training.dart';
import 'safe_write.dart';

part 'store_todos.dart';
part 'store_todo_history.dart';
part 'store_repeats.dart';
part 'store_undo.dart';
part 'store_backups.dart';
part 'store_migrations.dart';

/// How sync hears of writes the app makes by itself rather than for an
/// edit: [before] sends the edits made until then, and [after] what the
/// write changed, as [Store.local] or [Store.weak] says.
abstract interface class AutomaticWrites {
  /// [day]: the day a [Store.local] write moves things on to.
  void before({required bool local, String? day});
  void after({required bool local});
  void reset();
}

/// SQLite persistence. Every method writes straight through; AppState keeps
/// an in-memory copy for drawing.
class Store {
  static const schemaVersion = 38;
  Store._(this._db) {
    _db.execute('PRAGMA busy_timeout = 5000');
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    // A save no longer waits for the disk (about 6 ms each on btrfs, on the
    // UI thread). The database still can't be corrupted, and a crash of the
    // app loses nothing; [flushToDisk] covers a power cut at the moments
    // that matter.
    _db.execute('PRAGMA synchronous = NORMAL');
    _migrate();
  }

  factory Store.open(String path) {
    final db = sqlite3.open(path);
    try {
      return Store._(db);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  Store.memory() : this._(sqlite3.openInMemory());

  /// The time in milliseconds, in SQL, for sync's triggers.
  static const _now = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

  final Database _db;

  /// The database itself, for the sync engine, which works below the
  /// level of rituals and to-dos.
  Database get raw => _db;

  /// True while running temp-table work (e.g. search FTS5 indexing) so
  /// browser snapshot listeners do not rewrite OPFS on read-only operations.
  bool inTempWork = false;

  /// Set by sync; null while nothing syncs.
  AutomaticWrites? automatic;

  /// The version this database was upgraded from when it opened, for sync
  /// to take in what the older version couldn't keep; null if it wasn't.
  int? upgradedFrom;

  /// [body] moves things on by itself, as a day starting does. Sync never
  /// sends what it changes: each computer does it itself, from what it has,
  /// so one that's behind can't undo an edit it hasn't heard of.
  T local<T>(T Function() body, {String? day}) => _automatic(body, local: true, day: day);

  /// [body] fills something in for you, as a new month's list copied from
  /// the month before. Sync sends it, but any edit it hadn't heard of wins.
  T weak<T>(T Function() body) => _automatic(body, local: false);

  var _automaticDepth = 0;

  T _automatic<T>(T Function() body, {required bool local, String? day}) => transaction(() {
    // Inside another, it's part of that one.
    if (_automaticDepth > 0) return body();
    _automaticDepth++;
    try {
      automatic?.before(local: local, day: day);
      final result = body();
      automatic?.after(local: local);
      return result;
    } finally {
      _automaticDepth--;
    }
  });

  /// Between two texts of a day's journal kept together.
  static const journalBreak = '\n\n---\n\n';

  /// Both texts, unless one already holds the other: so neither's writing
  /// is lost.
  static String keepWriting(String first, String second) {
    if (second.trim().isEmpty || first.contains(second)) return first;
    if (first.trim().isEmpty || second.contains(first)) return second;
    return '$first$journalBreak$second';
  }

  void close() => _db.close();

  /// Puts every save so far safely on the disk, so a power cut can't take
  /// it: when the window goes to the back, after sync, and before quitting.
  bool flushToDisk() {
    bool checkpointedAll(String mode) {
      final rows = _db.select('PRAGMA wal_checkpoint($mode)');
      if (rows.isEmpty) return true;
      final row = rows.first;
      final busy = row.columnAt(0) as int? ?? 0;
      final log = row.columnAt(1) as int? ?? 0;
      final checkpointed = row.columnAt(2) as int? ?? 0;
      return busy == 0 && (log <= 0 || checkpointed >= log);
    }

    try {
      return checkpointedAll('FULL') || checkpointedAll('PASSIVE');
    } on SqliteException {
      return false;
    }
  }

  /// Settings that are the same on every computer. The theme isn't: each
  /// follows its own night light.
  static const syncedSettings = ['dayStartHour', 'restWeekends', 'holidays'];

  /// Marks every row as changed, for sync to compare with what it knows.
  void markAllChanged() {
    _db.execute('''
      INSERT OR IGNORE INTO sync_dirty SELECT *, $_now FROM (
        SELECT 'month_habit', year || '-' || month || '/' || h.uid FROM month_habits JOIN habits h ON h.id = habit_id
        UNION ALL SELECT 'habit_month', year || '-' || month FROM habit_months
        UNION ALL SELECT 'todo_history', day || '/' || uid FROM todo_history
        UNION ALL SELECT 'entry', day || '/' || h.uid FROM entries JOIN habits h ON h.id = habit_id
        UNION ALL SELECT 'todo', uid FROM todos
        UNION ALL SELECT 'journal', day FROM journal
        UNION ALL SELECT 'sleep_note', year || '-' || month || '/' || item FROM sleep_notes
        UNION ALL SELECT 'routine', uid FROM routines
        UNION ALL SELECT 'weigh_in', uid FROM weigh_ins
        UNION ALL SELECT 'exercise', uid FROM exercises
        UNION ALL SELECT 'training_set', uid FROM training_sets
        UNION ALL SELECT 'todo_repeat', uid FROM todo_repeats
        UNION ALL SELECT 'setting', key FROM settings WHERE key IN (${syncedSettings.map((k) => "'$k'").join(', ')})
      )
    ''');
  }

  /// The earliest day anything was ticked, written or logged; null before
  /// the first. Months only opened to look at don't count.
  DateTime? firstActivity() {
    final day =
        _db
                .select('''
      SELECT MIN(day) FROM (
        SELECT MIN(day) AS day FROM entries
        UNION ALL SELECT MIN(day) FROM journal WHERE text != ''
        UNION ALL SELECT MIN(since) FROM todos
        UNION ALL SELECT MIN(day) FROM todo_history
        UNION ALL SELECT MIN(day) FROM training_sets
        UNION ALL SELECT MIN(uid) FROM weigh_ins
      )
    ''')
                .first
                .columnAt(0)
            as String?;
    return day == null ? null : DateTime.parse(day);
  }

  // Habits

  bool hasMonth(int year, int month) =>
      _db.select('SELECT 1 FROM habit_months WHERE year = ? AND month = ?', [year, month]).isNotEmpty;

  void initializeMonth(int year, int month) =>
      _db.execute('INSERT INTO habit_months VALUES (?, ?) ON CONFLICT DO NOTHING', [year, month]);

  /// No ritual has ever been added (the sleep schedule doesn't count).
  bool get isEmpty =>
      _db.select('SELECT 1 FROM habit_months LIMIT 1').isEmpty &&
      _db.select('SELECT 1 FROM habits WHERE id NOT IN (SELECT habit_id FROM sleep_habits) LIMIT 1').isEmpty;

  /// The sleep schedule as it reads in a month: each item's time is the
  /// one set for that month, or the nearest month before with its own, or
  /// the original time.
  List<Habit> sleepHabits(int year, int month) {
    final ids = {
      for (final r in _db.select('SELECT item, habit_id FROM sleep_habits')) r['item'] as String: r['habit_id'] as int,
    };
    return [
      for (final item in SleepItem.values)
        Habit(
          ids[item.name]!,
          item.label,
          minutes: switch (sleepNote(year, month, item)) {
            null => item.minutes,
            final note => parseClock(note),
          },
        ),
    ];
  }

  /// The time saved for [item] in force in this month ("21:00", empty for
  /// none, or a note from before times were picked); null if never set.
  /// With [own], only what was set for this very month.
  String? sleepNote(int year, int month, SleepItem item, {bool own = false}) {
    final r = _db.select(
      'SELECT note FROM sleep_notes WHERE item = ? AND year * 12 + month ${own ? '=' : '<='} ? '
      'ORDER BY year * 12 + month DESC LIMIT 1',
      [item.name, year * 12 + month],
    );
    return r.isEmpty ? null : curlyQuotes(r.first['note'] as String);
  }

  void setSleepNote(int year, int month, SleepItem item, String note) {
    _db.execute(
      'INSERT INTO sleep_notes (year, month, item, note) VALUES (?, ?, ?, ?) '
      'ON CONFLICT (year, month, item) DO UPDATE SET note = excluded.note',
      [year, month, item.name, note],
    );
  }

  // Format prose on read as well as during input: imports and older sync
  // clients can introduce straight quotes after the one-time migration.
  List<Habit> monthHabits(int year, int month) => [
    // Rituals reordered on two computers at once can share a place: they
    // sort the same on both.
    for (final r in _db.select(
      'SELECT habit_id, name, note, added_on, days,weekly,target,unit FROM month_habits JOIN habits h ON h.id = habit_id '
      'WHERE year = ? AND month = ? ORDER BY position, h.uid',
      [year, month],
    ))
      Habit(
        r['habit_id'] as int,
        curlyQuotes(r['name'] as String),
        description: r['note'] == null ? null : curlyQuotes(r['note'] as String),
        addedOn: DateTime.tryParse(r['added_on'] as String? ?? ''),
        days: decodeDays(r['days'] as String?), weekly: r['weekly'] as int?, target: r['target'] as int?, unit: r['unit'] as String?,
      ),
  ];

  /// The closest month that has a ritual list, preferring earlier months.
  (int, int)? nearestMonthWithHabits(int year, int month) {
    final index = year * 12 + month;
    for (final (cmp, order) in [('<', 'DESC'), ('>', 'ASC')]) {
      final r = _db.select(
        'SELECT year, month FROM habit_months WHERE year * 12 + month $cmp ? '
        'ORDER BY year * 12 + month $order LIMIT 1',
        [index],
      );
      if (r.isNotEmpty) return (r.first['year'] as int, r.first['month'] as int);
    }
    return null;
  }

  /// Saves the month's list as a copy of the nearest month's, unless it
  /// has its own. Returns whether it saved one. Filled in, not an edit: an
  /// edit made to the month on another computer that this one hasn't heard
  /// of yet wins over it.
  bool ensureMonth(int year, int month) => weak(() {
    if (hasMonth(year, month)) return false;
    final source = nearestMonthWithHabits(year, month);
    if (source != null) copyMonth(source, (year, month));
    initializeMonth(year, month);
    return true;
  });

  /// Whether the ritual was on any month's list before [year].
  bool habitBeforeYear(int habitId, int year) =>
      _db.select('SELECT 1 FROM month_habits WHERE habit_id = ? AND year < ? LIMIT 1', [habitId, year]).isNotEmpty;

  void copyMonth((int, int) from, (int, int) to) {
    initializeMonth(to.$1, to.$2);
    // Copied back to an earlier month, a ritual added partway through the
    // later one stays out: it didn't exist yet.
    final earlier = to.$1 * 12 + to.$2 < from.$1 * 12 + from.$2;
    _db.execute(
      'INSERT INTO month_habits (year, month, habit_id, name, position, note,weekly,target,unit) '
      'SELECT ?, ?, habit_id, name, position, note,weekly,target,unit FROM month_habits WHERE year = ? AND month = ?'
      '${earlier ? ' AND added_on IS NULL' : ''}',
      [to.$1, to.$2, from.$1, from.$2],
    );
    // The new month starts on the days each ritual was on last.
    for (final h in monthHabits(from.$1, from.$2)) {
      if (h.weekdays != everyDay) setHabitDays(to.$1, to.$2, h.id, [(null, h.weekdays)]);
    }
  }

  Habit addHabit(int year, int month, String name, {DateTime? addedOn}) => transaction(() {
    initializeMonth(year, month);
    _db.execute('INSERT INTO habits (uid) VALUES (lower(hex(randomblob(8))))');
    final id = _db.lastInsertRowId;
    _db.execute(
      'INSERT INTO month_habits (year, month, habit_id, name, position, added_on) VALUES (?, ?, ?, ?, '
      '(SELECT COALESCE(MAX(position) + 1, 0) FROM month_habits WHERE year = ? AND month = ?), ?)',
      [year, month, id, name, year, month, addedOn == null ? null : dateKey(addedOn)],
    );
    return Habit(id, name, addedOn: addedOn);
  });

  void renameHabit(int year, int month, int habitId, String name) {
    _db.execute('UPDATE month_habits SET name = ? WHERE year = ? AND month = ? AND habit_id = ?', [
      name,
      year,
      month,
      habitId,
    ]);
  }

  void setHabitDays(int year, int month, int habitId, List<(DateTime?, int)> days) {
    _db.execute('UPDATE month_habits SET days = ? WHERE year = ? AND month = ? AND habit_id = ?', [
      encodeDays(days),
      year,
      month,
      habitId,
    ]);
  }

  void setHabitNote(int year, int month, int habitId, String? note) {
    _db.execute('UPDATE month_habits SET note = ? WHERE year = ? AND month = ? AND habit_id = ?', [
      note,
      year,
      month,
      habitId,
    ]);
  }

  void removeHabit(int year, int month, int habitId) {
    _db.execute('DELETE FROM month_habits WHERE year = ? AND month = ? AND habit_id = ?', [year, month, habitId]);
  }

  void reorderHabits(int year, int month, List<int> habitIds) {
    transaction(() {
      for (final (i, id) in habitIds.indexed) {
        _db.execute('UPDATE month_habits SET position = ? WHERE year = ? AND month = ? AND habit_id = ?', [
          i,
          year,
          month,
          id,
        ]);
      }
    });
  }

  // Entries

  Map<int, (int, int)> monthScores(int year, int month, {DateTime? asOf, List<Holiday> holidays = const []}) {
    final habits = {for (final h in monthHabits(year, month)) h.id: h};
    final scores = <int, (int, int)>{};
    for (final r in _db.select(
      'SELECT habit_id, day, status FROM entries WHERE day >= ? AND day < ? AND status IN (1, 2)',
      [dateKey(DateTime(year, month)), dateKey(DateTime(year, month + 1))],
    )) {
      final id = r['habit_id'] as int, day = DateTime.parse(r['day'] as String);
      // Days before a ritual was added that month, or that aren't one of its
      // days, don't count towards it.
      if (holidayOn(holidays, day) != null) continue;
      if (habits[id] case final h? when h.weekly != null || !h.startedBy(day) || !h.onDay(day)) continue;
      final (done, logged) = scores[id] ?? (0, 0);
      scores[id] = (done + (r['status'] == HabitStatus.done.index ? 1 : 0), logged + 1);
    }
    // Assign a week to the month containing its Sunday. The current
    // unfinished week appears provisionally in the month being viewed.
    final now = dateOnly(asOf ?? DateTime.now());
    final weekly = habits.values.where((h) => h.weekly != null);
    if (weekly.isEmpty) return scores;
    final first = DateTime(year, month), last = DateTime(year, month + 1, 0);
    final marks = {
      for (final row in _db.select(
        'SELECT habit_id, day, status FROM entries WHERE day BETWEEN ? AND ? AND status IN (1, 3)',
        [dateKey(DateTime(year, month, 2 - first.weekday)), dateKey(last)],
      ))
        (row['habit_id'] as int, row['day'] as String): HabitStatus.values[row['status'] as int],
    };
    for (final h in weekly) {
      var done = 0, possible = 0;
      for (
        var sunday = DateTime(year, month, 1 + (7 - first.weekday) % 7);
        !sunday.isAfter(DateTime(year, month, last.day + 6));
        sunday = DateTime(sunday.year, sunday.month, sunday.day + 7)
      ) {
        final monday = DateTime(sunday.year, sunday.month, sunday.day - 6);
        if (monday.isAfter(now) || (h.addedOn != null && sunday.isBefore(h.addedOn!))) continue;
        if (sunday.month != month && !(now.year == year && now.month == month && !now.isBefore(monday))) continue;
        final end = sunday.isBefore(now) ? sunday : now;
        final start = h.addedOn != null && monday.isBefore(h.addedOn!) ? h.addedOn! : monday;
        if (start.isAfter(end)) continue;
        var available = 0, completed = 0, remaining = 0;
        for (var d = start; !d.isAfter(sunday); d = DateTime(d.year, d.month, d.day + 1)) {
          if (holidayOn(holidays, d) != null) continue;
          final mark = d.isAfter(now) ? null : marks[(h.id, dateKey(d))];
          if (mark == HabitStatus.other) continue;
          available++;
          if (d.isAfter(now) || (dateKey(d) == dateKey(now) && mark == null)) remaining++;
          if (mark == HabitStatus.done) completed++;
        }
        final target = min(h.weekly!, available);
        final weekDone = min(target, completed);
        final weekPossible = weekDone == 0 && sunday.isAfter(now) ? max(0, target - remaining) : target;
        possible += weekPossible;
        done += weekDone;
      }
      scores[h.id] = (done, possible);
    }
    return scores;
  }

  Iterable<({String day, int habitId, HabitStatus status, String? note, int? amount})> entriesInMonth(
    int year,
    int month,
  ) => _db
      .select('SELECT day, habit_id, status, note, amount FROM entries WHERE day >= ? AND day < ?', [
        dateKey(DateTime(year, month)),
        dateKey(DateTime(year, month + 1)),
      ])
      .map(
        (r) => (
          day: r['day'] as String,
          habitId: r['habit_id'] as int,
          status: HabitStatus.values[r['status'] as int],
          note: r['note'] == null ? null : curlyQuotes(r['note'] as String),
          amount: r['amount'] as int?,
        ),
      );

  /// Work proportional to logged entries, rather than every calendar day.
  ///
  /// The run as of [today], which isn't held against it while blank, unless
  /// [dayOver]: then it's a past day's, and blank breaks the run as it does
  /// for any other day.
  (int, int) streaks(
    int habitId,
    DateTime today, {
    required bool restWeekends,
    List<Holiday> holidays = const [],
    bool dayOver = false,
  }) {
    // Each month's days for the ritual; a day that isn't one of them is
    // passed over, whatever was logged on it. Weekly rituals are active daily.
    final months = {
      for (final r in _db.select(
        'SELECT year, month, days, weekly FROM month_habits WHERE habit_id = ? AND (days IS NOT NULL OR weekly IS NOT NULL)',
        [habitId],
      ))
        (r['year'] as int, r['month'] as int): r['weekly'] != null ? const <(DateTime?, int)>[] : decodeDays(r['days'] as String?),
    };
    bool off(DateTime day) => !isOnDay(months[(day.year, day.month)] ?? const [], day);
    bool rest(DateTime day) => restsOn(day, restWeekends: restWeekends, holidays: holidays);
    bool excused(DateTime day) => off(day) || rest(day);

    bool gapBreaks(DateTime from, DateTime until) {
      final gap = daysBetween(from, until) - 1;
      if (gap <= 0) return false;
      if (!restWeekends && holidays.isEmpty && months.isEmpty) return true;
      for (var i = 1; i <= gap; i++) {
        if (!excused(DateTime(from.year, from.month, from.day + i))) return true;
      }
      return false;
    }

    var run = 0, best = 0;
    DateTime? previous;
    for (final r in _db.select('SELECT day, status FROM entries WHERE habit_id = ? AND day <= ? ORDER BY day', [
      habitId,
      dateKey(today),
    ])) {
      final day = _parseDay(r['day'] as String);
      final status = HabitStatus.values[r['status'] as int];
      if (!dayOver && day == today && status == HabitStatus.none || off(day)) continue;
      if (previous != null && gapBreaks(previous, day)) run = 0;
      // An "other" day, or a rest day left blank or missed, neither breaks
      // nor extends it.
      if (status == HabitStatus.done) {
        run++;
        if (run > best) best = run;
      } else if (status != HabitStatus.other && !rest(day)) {
        run = 0;
      }
      previous = day;
    }
    final until = dayOver ? DateTime(today.year, today.month, today.day + 1) : today;
    if (previous != null && gapBreaks(previous, until)) run = 0;
    return (run, best);
  }

  /// A day's key ('2026-11-03') read without DateTime.parse's general
  /// pattern, which over years of marks is most of a streak's work.
  static DateTime _parseDay(String key) {
    if (key.length != 10) return DateTime.parse(key);
    int digits(int from, int to) {
      var n = 0;
      for (var i = from; i < to; i++) {
        n = n * 10 + key.codeUnitAt(i) - 0x30;
      }
      return n;
    }

    return DateTime(digits(0, 4), digits(5, 7), digits(8, 10));
  }

  /// Up to [count] of the ritual's days before [day], latest first: each
  /// month's own days for it, back to where it was added. A month not saved
  /// yet is on the days of the month it would be copied from.
  List<DateTime> pastDays(int habitId, DateTime day, int count) {
    if (_db.select('SELECT 1 FROM sleep_habits WHERE habit_id = ?', [habitId]).isNotEmpty) {
      return [for (var i = 1; i <= count; i++) DateTime(day.year, day.month, day.day - i)];
    }
    final months = {
      for (final r in _db.select('SELECT year, month, days, weekly, added_on FROM month_habits WHERE habit_id = ?', [
        habitId,
      ]))
        (r['year'] as int, r['month'] as int): (
          r['weekly'] != null ? const <(DateTime?, int)>[] : decodeDays(r['days'] as String?),
          DateTime.tryParse(r['added_on'] as String? ?? ''),
          r['weekly'] != null,
        ),
    };
    if (months.isEmpty) return [];
    final first = months.keys.map((m) => m.$1 * 12 + m.$2).reduce(min);
    final saved = {
      for (final r in _db.select('SELECT year, month FROM habit_months')) (r['year'] as int, r['month'] as int),
    };

    // A month's days for the ritual, or null when it wasn't in that month.
    final resolved = <(int, int), (List<(DateTime?, int)>, DateTime?)?>{};
    (List<(DateTime?, int)>, DateTime?)? daysIn(int year, int month) => resolved.putIfAbsent((year, month), () {
      if (months[(year, month)] case final own?) return (own.$1, own.$2);
      if (saved.contains((year, month))) return null;
      // Copied from the nearest saved month before it, as it stood at the end.
      for (var i = year * 12 + month - 1; i >= first; i--) {
        final m = ((i - 1) ~/ 12, (i - 1) % 12 + 1);
        if (!saved.contains(m)) continue;
        final source = months[m];
        if (source == null) return null;
        if (source.$3) return (const [], null);
        final bits = source.$1.isEmpty ? everyDay : source.$1.last.$2;
        return ([if (bits != everyDay) (null, bits)], null);
      }
      return null;
    });

    final found = <DateTime>[];
    for (
      var d = DateTime(day.year, day.month, day.day - 1);
      found.length < count;
      d = DateTime(d.year, d.month, d.day - 1)
    ) {
      if (d.year * 12 + d.month < first) break;
      final days = daysIn(d.year, d.month);
      if (days == null) break;
      if (days.$2 != null && d.isBefore(days.$2!)) break;
      if (isOnDay(days.$1, d)) found.add(d);
    }
    return found;
  }

  void setEntry(String day, int habitId, HabitStatus status, {bool clearNote = false}) {
    if (status == HabitStatus.none) {
      _db.execute('DELETE FROM entries WHERE day = ? AND habit_id = ?', [day, habitId]);
      return;
    }
    _db.execute(
      'INSERT INTO entries (day, habit_id, status) VALUES (?, ?, ?) '
      'ON CONFLICT (day, habit_id) DO UPDATE SET status = excluded.status, '
      'amount=NULL, note = CASE WHEN ? THEN NULL ELSE entries.note END',
      [day, habitId, status.index, clearNote ? 1 : 0],
    );
  }

  void setNote(String day, int habitId, String? note) {
    _db.execute('UPDATE entries SET note = ? WHERE day = ? AND habit_id = ?', [note, day, habitId]);
  }

  /// Whether an entry row currently exists in SQLite for [day] and [habitId].
  bool hasEntry(String day, int habitId) =>
      _db.select('SELECT 1 FROM entries WHERE day = ? AND habit_id = ? LIMIT 1', [day, habitId]).isNotEmpty;

  // Settings

  String? setting(String key) {
    final r = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void setSetting(String key, String value) {
    _db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  // Journal

  Iterable<({String day, String text})> journalEntries({String? after, int? limit}) => _db
      .select('SELECT day, text FROM journal WHERE day > ? ORDER BY day LIMIT ?', [after ?? '', limit ?? -1])
      .map((r) => (day: r['day'] as String, text: curlyQuotes(r['text'] as String)));

  /// Every task kept, ticked or not, on the day it's on, for search.
  Iterable<
    ({String uid, String day, String text, bool done, List<TodoSubtask> subtasks, String? location, String? note})
  >
  searchableTodos() => _db
      .select('SELECT uid, scope, period, text, done, due_date, since, subtasks, location, note FROM todos')
      .expand((r) {
        final period = r['period'] as String;
        final day = switch (r['scope']) {
          'today' => DateTime.tryParse(period),
          'tomorrow' => switch (DateTime.tryParse(period)) {
            final d? => DateTime(d.year, d.month, d.day + 1),
            null => null,
          },
          _ => DateTime.tryParse((r['due_date'] as String?) ?? (r['since'] as String)),
        };
        // One whose day can't be read (from a damaged copy) isn't found.
        if (day == null) return const <Never>[];
        return [
          (
            uid: r['uid'] as String,
            day: dateKey(day),
            text: curlyQuotes(r['text'] as String),
            done: r['done'] == 1,
            subtasks: TodoSubtask.decode(r['subtasks'] as String?),
            location: r['location'] as String?,
            note: cleanNote(r['note']),
          ),
        ];
      });

  String journal(String day) {
    final r = _db.select('SELECT text FROM journal WHERE day = ?', [day]);
    return r.isEmpty ? '' : curlyQuotes(r.first['text'] as String);
  }

  void setJournal(String day, String text) {
    if (text.trim().isEmpty) {
      _db.execute('DELETE FROM journal WHERE day = ?', [day]);
    } else {
      _db.execute(
        'INSERT INTO journal (day, text) VALUES (?, ?) '
        'ON CONFLICT (day) DO UPDATE SET text = excluded.text',
        [day, text],
      );
    }
  }

  // Training

  String _newUid() => _db.select('SELECT lower(hex(randomblob(8)))').first.columnAt(0) as String;

  List<Exercise> exercises() => [
    for (final r in _db.select('SELECT * FROM exercises ORDER BY name COLLATE NOCASE, uid'))
      Exercise(
        uid: r['uid'] as String,
        name: curlyQuotes(r['name'] as String),
        group: MuscleGroup.named(r['muscle'] as String) ?? MuscleGroup.chest,
        bodyweight: r['bodyweight'] == 1,
      ),
  ];

  Exercise addExercise(String name, MuscleGroup group, {required bool bodyweight}) {
    final e = Exercise(uid: _newUid(), name: curlyQuotes(name), group: group, bodyweight: bodyweight);
    saveExercise(e);
    return e;
  }

  void saveExercise(Exercise e) => _db.execute(
    'INSERT INTO exercises (uid, name, muscle, bodyweight) VALUES (?, ?, ?, ?) '
    'ON CONFLICT (uid) DO UPDATE SET name = excluded.name, muscle = excluded.muscle, bodyweight = excluded.bodyweight',
    [e.uid, e.name, e.group.name, e.bodyweight ? 1 : 0],
  );

  void deleteExercise(String uid) => _db.execute('DELETE FROM exercises WHERE uid = ?', [uid]);

  /// Every set logged, oldest day first, in order within each day.
  List<TrainingSet> trainingSets() => [
    for (final r in _db.select('SELECT * FROM training_sets ORDER BY day, position, uid'))
      TrainingSet(
        uid: r['uid'] as String,
        day: r['day'] as String,
        exercise: r['exercise'] as String,
        position: r['position'] as int,
        weight: (r['weight'] as num?)?.toDouble(),
        reps: r['reps'] as int, note:r['note'] as String?, rpe:(r['rpe'] as num?)?.toDouble(),
      ),
  ];

  TrainingSet addTrainingSet(String day, String exercise, {required int position, double? weight, int reps = 0}) {
    final s = TrainingSet(uid: _newUid(), day: day, exercise: exercise, position: position, weight: weight, reps: reps);
    saveTrainingSet(s);
    return s;
  }

  void saveTrainingSet(TrainingSet s) => _db.execute(
    'INSERT INTO training_sets (uid, day, exercise, position, weight, reps, note, rpe) VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
    'ON CONFLICT (uid) DO UPDATE SET day = excluded.day, exercise = excluded.exercise, '
    'position = excluded.position, weight = excluded.weight, reps = excluded.reps, note=excluded.note,rpe=excluded.rpe',
    [s.uid, s.day, s.exercise, s.position, s.weight, s.reps,s.note,s.rpe],
  );

  void deleteTrainingSet(String uid) => _db.execute('DELETE FROM training_sets WHERE uid = ?', [uid]);

  /// Runs [body] atomically; nested calls are part of the outer one.
  T transaction<T>(T Function() body) {
    _db.execute('SAVEPOINT store_write');
    try {
      final result = body();
      _db.execute('RELEASE store_write');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK TO store_write');
      _db.execute('RELEASE store_write');
      rethrow;
    }
  }
}
