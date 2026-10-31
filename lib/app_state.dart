import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'data/backups.dart';
import 'data/data_folder.dart';
import 'data/journal_files.dart';
import 'data/store.dart';
import 'data/sync.dart';
import 'data/sync_service.dart';
import 'models.dart';
import 'theme/app_theme.dart';
import 'training_log.dart';
import 'util/lru_cache.dart';

part 'app_scope.dart';
part 'state/habits.dart';
part 'state/journal.dart';
part 'state/navigation.dart';
part 'state/reminders.dart';
part 'state/settings.dart';
part 'state/todos.dart';
part 'state/undo.dart';

/// App state backed by [Store]. Keeps habit entries and the current to-do
/// lists in memory and writes every change straight to SQLite.
///
/// Each area's state and edits are in a part of their own, in state/.
class AppState extends ChangeNotifier with _Settings, _Navigation, _Habits, _Todos, _Journal, _Undo, _Reminders {
  AppState(
    this.store, {
    this.backups,
    this.journalFiles,
    this.dataFolder,
    this.sync,
    this.notifier,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    notifier?.onOpen = openReminder;
    sync?.onIncoming = _takeIncoming;
    sync?.beforeMerge = saveDrafts;
    sync?.beforeJoin = () => backups?.beforeJoining(store);
    sync?.addListener(_checkJournalFiles);
    sync?.onClear = (days) {
      for (final day in days) {
        _writeJournalFile(DateTime.parse(day), '');
      }
      _load();
    };
    today = dayOf(_clock(), dayStartHour);
    lateNight = dateOnly(_clock()) != today;
    viewYear = today.year;
    // Signed in already, an empty store fills from sync: no examples are
    // added to your history.
    firstRun = store.isEmpty && !(sync?.isOn ?? false);
    if (firstRun) _seed();
    _backUp();
    _savesFiles = savesJournalFiles;
    _initialExport = _exportJournal().then((_) => _savesFiles ? _rewriteStaleJournal() : null);
    _load();
  }

  @override
  final Store store;

  /// Null where nothing is shown outside the app (tests).
  @override
  final ReminderNotifier? notifier;
  @override
  bool closing = false;
  @override
  bool _disposed = false;
  late final Future<void> _initialExport;

  @override
  Future<void> flushFiles() async {
    await _initialExport;
    await journalFiles?.pending;
  }

  Future<void>? _shutdown;

  /// All quit/restart paths use the same save, sync, stop, close order.
  Future<void> shutdown() => _shutdown ??= _close().catchError((Object error, StackTrace stack) {
    _shutdown = null;
    closing = false;
    notifyListeners();
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _close() async {
    saveDrafts();
    closing = true;
    notifyListeners();
    await sync?.beforeQuit();
    saveDrafts();
    await flushFiles();
    sync?.stop();
    store.flushToDisk();
    store.close();
  }

  @override
  void dispose() {
    _disposed = true;
    sync?.removeListener(_checkJournalFiles);
    super.dispose();
  }

  /// The store was empty and sync off: a new install, or a new, empty data
  /// folder.
  late final bool firstRun;

  /// The welcome tour is showing.
  bool touring = false;

  /// Opens the welcome tour, on the Today view it walks through.
  void startTour() {
    touring = true;
    showToday();
  }

  void endTour() {
    touring = false;
    notifyListeners();
  }

  /// Null where nothing should be written to disk (tests).
  final Backups? backups;

  /// Where the journal lives as documents; null keeps it in the database
  /// only (tests).
  @override
  final JournalFiles? journalFiles;

  /// Where everything is kept; null in tests.
  @override
  final DataFolder? dataFolder;

  /// Keeps everything the same on your other computers; null in tests.
  @override
  final SyncService? sync;

  /// Brings in what sync merged from another computer.
  void _takeIncoming(Incoming incoming) {
    if (incoming.journalDays.isNotEmpty) journalRevision++;
    for (final day in incoming.journalDays) {
      _writeJournalFile(DateTime.parse(day), store.journal(day));
    }
    final entryDays = <String>{};
    var reloadTodos = false;
    for (final (kind, key) in incoming.rows) {
      switch (kind) {
        case 'entry':
          entryDays.add(key.split('/').first);
        case 'month_habit' || 'habit_month':
          final month = key.split('/').first.split('-').map(int.parse).toList();
          // Its rituals' days may have changed, and with them what counts.
          _monthHabits.remove((month[0], month[1]));
          _monthScores.remove((month[0], month[1]));
          _previewHabits.clear();
          _trails.clear();
          _streaks.clear();
          habitsRevision++;
        case 'sleep_note':
          _monthSleep.clear();
          habitsRevision++;
        case 'todo' || 'todo_history' || 'todo_repeat':
          reloadTodos = true;
        case 'exercise' || 'training_set':
          training.reload();
        case 'setting':
          restWeekends = store.setting('restWeekends') == '1';
          dayStartHour = int.tryParse(store.setting('dayStartHour') ?? '') ?? 0;
          _streaks.clear();
      }
    }
    if (entryDays.isNotEmpty) {
      for (final key in entryDays) {
        final day = DateTime.parse(key);
        _entryMonths.remove((day.year, day.month));
        _monthScores.remove((day.year, day.month));
      }
      entriesRevision++;
      _streaks.clear();
    }
    if (reloadTodos) _startDay();
    checkDate();
    notifyListeners();
  }

  @override
  final DateTime Function() _clock;

  /// The day ticks, to-dos and the journal count towards: the calendar
  /// date, except before [dayStartHour], when it's still the day before.
  @override
  late DateTime today;

  /// Past midnight but before [dayStartHour], so [today] is yesterday's date.
  @override
  late bool lateNight;

  /// Call periodically: when the date has changed, carries unfinished to-dos
  /// into the new day/week/month.
  @override
  void checkDate() {
    final clock = _clock();
    final now = dayOf(clock, dayStartHour);
    final late = dateOnly(clock) != now;
    if (now == today) {
      if (late != lateNight) {
        lateNight = late;
        notifyListeners();
      }
      return;
    }
    lateNight = late;
    if (viewYear == today.year) viewYear = now.year;
    if (viewDay == now) viewDay = null;
    today = now;
    _forgetRemovals();
    _previewHabits.clear();
    _streaks.clear();
    _backUp();
    _startDay();
    notifyListeners();
  }

  /// Today's copy, taken before anything changes today. A failed backup
  /// must never stop the app opening.
  void _backUp() {
    try {
      backups?.daily(store, today);
    } catch (e) {
      debugPrint('Backup failed: $e');
    }
  }

  /// Reloads settings and live tasks; history is loaded into bounded caches.
  void _load() {
    _monthHabits.clear();
    _previewHabits.clear();
    _trails.clear();
    _entryMonths.clear();
    _monthScores.clear();
    habitsRevision++;
    entriesRevision++;
    journalRevision++;
    themeName = _savedTheme();
    themeNotifier.value = themeName;
    restWeekends = store.setting('restWeekends') == '1';
    followNightLight = store.setting('followNightLight') != '0';
    dayStartHour = int.tryParse(store.setting('dayStartHour') ?? '') ?? 0;
    laterBirthdays = store.setting('laterBirthdays') != 'hidden';
    weekEmptyDays = store.setting('weekEmptyDays') == 'shown';
    _monthSleep.clear();
    _streaks.clear();
    _startDay();
  }

  /// Replaces all data with [backup]. What was there before is kept as a
  /// backup of its own.
  Future<void> restore(Backup backup) async {
    if (sync != null) {
      await sync!.exclusive(() => _restore(backup));
    } else {
      await _restore(backup);
    }
  }

  Future<void> _restore(Backup backup) async {
    saveDrafts(); // so it's in the before-restore copy
    await flushFiles();
    final before = {for (final e in store.journalEntries()) e.day};
    try {
      // Loaded before its files are written, so a copy the app can't open
      // goes back untouched.
      await backups!.restore(
        store,
        backup,
        check: () {
          _load();
          checkDate(); // the backup may start its days at another hour
        },
      );
    } catch (_) {
      _load();
      notifyListeners();
      rethrow;
    }
    // The journal's files follow: the restored entries written out, and
    // the files of days the copy has no entry for removed.
    final after = {for (final e in store.journalEntries()) e.day: e.text};
    for (final day in {...before, ...after.keys}) {
      _writeJournalFile(DateTime.parse(day), after[day] ?? '');
    }
    await flushFiles();
    notifyListeners();
  }

  @override
  void _removed(String label, List<RowsBefore> before) => _undoable(label, before);

  @override
  void _quietReminders(bool Function(String uid) which) => _settleReminders(which);

  @override
  void _reloadAfterUndo() {
    _monthHabits.clear();
    _monthScores.clear();
    _previewHabits.clear();
    _trails.clear();
    _streaks.clear();
    habitsRevision++;
    _startDay();
    _todosChanged();
  }

  @override
  void _startDay() {
    _repeats = null;
    _todoDays.clear();
    _orderedTodos.clear();
    todosRevision++;
    store.dateUndatedTodos(today);
    store.makeRepeats(today);
    todos.addAll(store.startDay(today));
    habitsFor(today.year, today.month);
  }

  @override
  void notifyListeners() {
    _firstDay = null;
    // Each change is an edit from the moment it's made, not from whenever
    // sync next looks.
    if (!closing && !_disposed) sync?.recordEdits();
    super.notifyListeners();
  }

  @override
  void saveDrafts() {
    saveHabitDrafts();
    saveJournalDraft();
  }

  /// A new install's starting point: a few gentle rituals for this month,
  /// and to-dos that teach the app by being done.
  void _seed() {
    for (final name in [
      'Drink water on waking',
      'Make the bed',
      'Move for 20 minutes',
      'Read 10 pages',
      'Tidy for 10 minutes',
    ]) {
      store.addHabit(today.year, today.month, name);
    }
    for (final (scope, text) in [
      (TodoScope.today, 'Tick this off to try it'),
      (TodoScope.today, 'Add a task of your own'),
      (TodoScope.week, 'Edit rituals to make them yours'),
      (TodoScope.month, 'Pick a theme you love'),
    ]) {
      store.addTodo(scope, today, text);
    }
  }
}
