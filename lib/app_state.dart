import 'dart:async';
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

/// App state backed by [Store]. Keeps habit entries and the current to-do
/// lists in memory and writes every change straight to SQLite.
class AppState extends ChangeNotifier {
  AppState(
    this.store, {
    this.backups,
    this.journalFiles,
    this.dataFolder,
    this.sync,
    this.restart,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
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

  final Store store;
  bool closing = false;
  bool _disposed = false;
  late final Future<void> _initialExport;

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
    _draftTimer?.cancel();
    _habitTimer?.cancel();
    themeNotifier.dispose();
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
  final JournalFiles? journalFiles;

  /// Where everything is kept; null in tests.
  final DataFolder? dataFolder;

  /// Keeps everything the same on your other computers; null in tests.
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
          _monthHabits.remove((month[0], month[1]));
          _previewHabits.clear();
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

  /// Reopens the app; null in tests.
  final Future<void> Function()? restart;

  /// Drive's Eclipse Journals folder is made and kept up to date, so the
  /// files on this computer can be turned off.
  bool get journalInDrive => sync != null && sync!.journalFolderLink != null && !sync!.needsJournalSignIn;

  /// Turned off on this computer only. Back on by itself whenever Drive
  /// doesn't have the journal, so there's always a copy you can read.
  late bool keepsJournalFiles = store.setting('journalFiles') != '0';

  bool get savesJournalFiles => journalFiles != null && (keepsJournalFiles || !journalInDrive);
  late bool _savesFiles;

  void setKeepsJournalFiles(bool keep) {
    saveJournalDraft();
    keepsJournalFiles = keep;
    store.setSetting('journalFiles', keep ? '1' : '0');
    if (!keep) journalFileProblem = null;
    notifyListeners();
    _checkJournalFiles();
  }

  /// Files left behind while they were off are brought up to date once
  /// they're back on.
  void _checkJournalFiles() {
    final saves = savesJournalFiles;
    if (saves == _savesFiles) return;
    _savesFiles = saves;
    if (saves) {
      unawaited(_rewriteStaleJournal());
    } else {
      store.setSetting('journalFilesStale', '1');
    }
    notifyListeners();
  }

  /// Writes every entry out again, and removes the files of days that were
  /// emptied meanwhile.
  Future<void> _rewriteStaleJournal() async {
    final files = journalFiles;
    if (files == null || store.setting('journalFilesStale') != '1') return;
    try {
      final days = <String>{};
      String? after;
      while (true) {
        if (closing || _disposed || !_savesFiles) return;
        final batch = store.journalEntries(after: after, limit: 64).toList();
        if (batch.isEmpty) break;
        for (final e in batch) {
          days.add(e.day);
          await _writeJournalFile(DateTime.parse(e.day), e.text);
        }
        after = batch.last.day;
      }
      for (final day in await files.days()) {
        if (!days.contains(dateKey(day))) await _writeJournalFile(day, '');
      }
      if (_savesFiles) store.setSetting('journalFilesStale', '0');
    } catch (e) {
      debugPrint('Rewriting journal files failed: $e');
    }
  }

  /// Keeps the journal's files in [folder] from now on, on this computer,
  /// and moves the ones already saved there. Throws if some couldn't be
  /// moved; the folder is switched all the same, and those stay put.
  Future<void> useJournalFolder(Directory folder) async {
    final files = journalFiles!;
    saveJournalDraft();
    await flushFiles();
    final old = files.dir;
    dataFolder?.useJournal(folder);
    files.dir = folder;
    journalFileProblem = null;
    notifyListeners();
    await files.moveFrom(old);
  }

  /// Keeps everything in [folder] from now on, copying it there unless the
  /// folder already has data, then reopens the app on it.
  Future<void> useDataFolder(Directory folder) async {
    saveDrafts();
    await flushFiles();
    await sync?.beforeQuit();
    Future<void> copyAndRestart() async {
      saveDrafts();
      await flushFiles();
      dataFolder!.moveTo(folder, store);
      await restart?.call();
    }

    if (sync == null) {
      await copyAndRestart();
    } else {
      await sync!.exclusive(copyAndRestart);
    }
  }

  final DateTime Function() _clock;

  /// The day ticks, to-dos and the journal count towards: the calendar
  /// date, except before [dayStartHour], when it's still the day before.
  late DateTime today;

  /// Past midnight but before [dayStartHour], so [today] is yesterday's date.
  late bool lateNight;

  /// The hour a new day starts: 0 for midnight or 4 for night owls.
  late int dayStartHour = int.tryParse(store.setting('dayStartHour') ?? '') ?? 0;

  void setDayStartHour(int hour) {
    dayStartHour = hour;
    store.setSetting('dayStartHour', '$hour');
    checkDate();
    notifyListeners();
  }

  late int viewYear;

  /// 1-12 when a month tab is open, null for the Today view.
  int? viewMonth;

  /// The year's record is open (with [viewMonth] null).
  bool viewingYear = false;

  /// A past day the Today view is showing, to look at only; null for today.
  DateTime? viewDay;

  /// The day the Today view shows.
  DateTime get shownDay => viewDay ?? today;
  Object get navigation => (viewYear, viewMonth, viewingYear, viewDay, today, lateNight, dayStartHour, firstMonth);

  /// Name of the chosen colour theme; null until one is picked.
  late String? themeName = _savedTheme();
  late final ValueNotifier<String?> themeNotifier = ValueNotifier(themeName);

  /// Brings saved names up to date: version 2 paired the themes light and
  /// dark (the old Sunset was light and is now Sunrise), version 3 dropped
  /// Citrus, version 4 named the Pastels Morning and Evening. Runs once per
  /// database (a restored backup may need it again).
  String? _savedTheme() {
    final saved = store.setting('theme');
    final version = int.tryParse(store.setting('themeNames') ?? '') ?? 1;
    if (saved == null || version >= _themeNames) return saved;
    var name = version >= 2
        ? saved
        : switch (saved) {
            'Main' => 'Solar Eclipse',
            'Dark' || 'Eclipse' => 'Lunar Eclipse',
            'Soft Pastel' => 'Pastel',
            'Sage & Sunset' => 'Citrus',
            'Sunset' => 'Sunrise',
            final name => name,
          };
    name = switch (name) {
      'Citrus' => 'Solar Eclipse',
      'Dark Citrus' => 'Lunar Eclipse',
      'Pastel' => 'Morning Pastel',
      'Dark Pastel' => 'Evening Pastel',
      final name => name,
    };
    store.setSetting('theme', name);
    store.setSetting('themeNames', '$_themeNames');
    return name;
  }

  static const _themeNames = 4;

  void setTheme(String name) {
    themeName = name;
    themeNotifier.value = name;
    store.transaction(() {
      store.setSetting('theme', name);
      store.setSetting('themeNames', '$_themeNames');
    });
    notifyListeners();
  }

  /// True where night light can be read (a Hyprland session, Windows, or a
  /// Mac's Dark mode); the menu hides the switch otherwise.
  bool nightLightAvailable = false;

  /// Switch to the dark partner when night light comes on, and back when it
  /// goes off. A theme picked in between holds until the next change.
  late bool followNightLight = store.setting('followNightLight') != '0';

  /// Night light as last seen, kept across restarts so a change while the
  /// app was closed still switches, but a restart alone doesn't.
  late bool? _nightLight = switch (store.setting('nightLight')) {
    '1' => true,
    '0' => false,
    _ => null,
  };

  void setFollowNightLight(bool follow) {
    followNightLight = follow;
    store.setSetting('followNightLight', follow ? '1' : '0');
    if (follow && _nightLight != null) _matchNightLight(_nightLight!);
    notifyListeners();
  }

  /// Call with each reading of night light.
  void nightLightIs(bool on) {
    if (on == _nightLight) return;
    _nightLight = on;
    // One save for the reading and the theme it switches to.
    store.transaction(() {
      store.setSetting('nightLight', on ? '1' : '0');
      if (followNightLight) _matchNightLight(on);
    });
  }

  void _matchNightLight(bool on) {
    final name = partnerOf(themeName, dark: on).name;
    if (name != themeName) setTheme(name);
  }

  /// Weekends shown greyed as rest days. A blank rest day doesn't break a
  /// streak; a ritual done on one still counts.
  late bool restWeekends = store.setting('restWeekends') == '1';

  void setRestWeekends(bool rest) {
    restWeekends = rest;
    store.setSetting('restWeekends', rest ? '1' : '0');
    _streaks.clear();
    notifyListeners();
  }

  bool isRestDay(DateTime day) => restWeekends && day.weekday >= DateTime.saturday;

  int habitsRevision = 0, entriesRevision = 0, todosRevision = 0, journalRevision = 0;
  final _monthHabits = LruCache<(int, int), List<Habit>>(24);

  /// Unsaved copies shown for months without their own list, until any
  /// list or the day changes.
  final _previewHabits = LruCache<(int, int), List<Habit>>(24);
  final _entryMonths = LruCache<(int, int), Map<String, (HabitStatus, String?)>>(12);
  final _monthScores = LruCache<(int, int), Map<int, (int, int)>>(24);
  final _todoDays = LruCache<String, Map<TodoScope, List<TodoItem>>>(3);
  final _orderedTodos = LruCache<(TodoScope, String?), List<TodoItem>>(16);

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

  void _todosChanged() {
    _repeats = null;
    _todoDays.clear();
    _orderedTodos.clear();
    todosRevision++;
    notifyListeners();
  }

  final Map<TodoScope, List<TodoItem>> todos = {};

  /// (current, best) streak by ritual id, until a mark or the day changes.
  final _streaks = LruCache<int, (int, int)>(256);

  /// The days behind each ritual's week trail, by ritual and day, until its days change.
  final _trails = LruCache<(int, DateTime), List<DateTime>>(256);

  /// The ritual's last 7 days before [day], latest first; fewer when it's new.
  List<DateTime> trailDays(Habit h, DateTime day) =>
      _trails[(h.id, dateOnly(day))] ??= store.pastDays(h.id, dateOnly(day), 7);

  String _cell(DateTime day, Habit h) => '${dateKey(day)}|${h.id}';

  /// Call periodically: when the date has changed, carries unfinished to-dos
  /// into the new day/week/month.
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
    await backups!.restore(store, backup);
    // The journal's files follow: the restored entries written out, and
    // the files of days the copy has no entry for removed.
    final after = {for (final e in store.journalEntries()) e.day: e.text};
    for (final day in {...before, ...after.keys}) {
      _writeJournalFile(DateTime.parse(day), after[day] ?? '');
    }
    await flushFiles();
    _load();
    checkDate(); // the backup may start its days at another hour
    notifyListeners();
  }

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

  // Navigation

  /// Gym training, every exercise's progress; the page under the corner.
  late final training = TrainingLog(store, notifyListeners);

  /// The Training page is turned to, over whichever view was open.
  bool showingTraining = false;

  void toggleTraining() {
    saveDrafts();
    showingTraining = !showingTraining;
    if (!showingTraining) training.day = null;
    notifyListeners();
  }

  void showToday() {
    saveHabitDrafts();
    viewMonth = null;
    viewingYear = false;
    viewDay = null;
    viewYear = today.year;
    notifyListeners();
  }

  /// Opens a past day's card in the Today view.
  void showDay(DateTime day) {
    saveHabitDrafts();
    viewMonth = null;
    viewingYear = false;
    viewDay = day.isBefore(today) ? dateOnly(day) : null;
    viewYear = today.year;
    notifyListeners();
  }

  /// Opens the record of [viewYear]: every month's percentages at once.
  void showYear() {
    saveHabitDrafts();
    viewMonth = null;
    viewDay = null;
    viewingYear = true;
    notifyListeners();
  }

  void showMonth(int month) {
    saveHabitDrafts();
    viewMonth = month;
    viewingYear = false;
    viewDay = null;
    notifyListeners();
  }

  void shiftYear(int delta) {
    saveHabitDrafts();
    viewYear = (viewYear + delta).clamp(firstMonth.$1, today.year);
    if (!viewingYear) {
      final months = shownMonths(viewYear);
      viewMonth = (viewMonth ?? today.month).clamp(months.first, months.last);
    }
    notifyListeners();
  }

  // Ritual lists

  bool isFutureMonth(int year, int month) => year * 12 + month > today.year * 12 + today.month;

  /// Worked out again after each change, as one can log an earlier day.
  DateTime? _firstDay;

  @override
  void notifyListeners() {
    _firstDay = null;
    // Each change is an edit from the moment it's made, not from whenever
    // sync next looks.
    if (!closing && !_disposed) sync?.recordEdits();
    super.notifyListeners();
  }

  /// The month you started using the app, or this month before anything
  /// is logged. No earlier month is shown.
  (int, int) get firstMonth {
    final day = _firstDay ??= store.firstActivity() ?? today;
    return day.isAfter(today) ? (today.year, today.month) : (day.year, day.month);
  }

  /// Whether [month] is between the one you started in and this one.
  bool isShownMonth(int year, int month) {
    final (y, m) = firstMonth;
    return year * 12 + month >= y * 12 + m && !isFutureMonth(year, month);
  }

  /// The months of [year] that are shown, in order.
  List<int> shownMonths(int year) => [
    for (var m = 1; m <= 12; m++)
      if (isShownMonth(year, m)) m,
  ];

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

  void saveDrafts() {
    saveHabitDrafts();
    saveJournalDraft();
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

  // To-dos

  /// Today and the preceding calendar day remain editable.
  bool canEditDay(DateTime day) =>
      !dateOnly(day).isAfter(today) && !dateOnly(day).isBefore(DateTime(today.year, today.month, today.day - 1));

  void _reloadTodos() {
    for (final scope in TodoScope.values) {
      final next = store.todos(scope, scope.period(today));
      final previous = todos[scope]!;
      if (previous.length != next.length ||
          !Iterable.generate(next.length, (i) => previous[i].sameContent(next[i])).every((same) => same)) {
        todos[scope] = next;
      }
    }
  }

  void addTodo(TodoScope scope, String text, {DateTime? day, DateTime? dueDate, int? time, TaskCategory? category}) {
    final target = day ?? today;
    if (text.trim().isEmpty || !canEditDay(target)) return;
    final value = normaliseNote(text.trim());
    if (target == today) {
      final item = store.addTodo(scope, today, value);
      todos[scope] = [...todos[scope]!, item];
      if (dueDate != null || time != null || category != null) {
        store.editTodo(item.id, value, dueDate, today, time: time, category: category);
        store.promoteDueTodos(today, earliest: today);
        store.rollTomorrowToToday(dateKey(today));
        _reloadTodos();
      }
    } else {
      store.editPastTodo(scope, target, text: value, dueDate: dueDate, time: time, category: category);
    }
    _todosChanged();
  }

  List<TodoItem> todosOn(TodoScope scope, DateTime day) =>
      _todoDays.putIfAbsent(dateKey(day), () => store.todoListsOn(day))[scope]!;

  List<TodoItem> orderedTodos(TodoScope scope, {DateTime? day}) => _orderedTodos.putIfAbsent((
    scope,
    day == null ? null : dateKey(day),
  ), () => sortTodos(day == null ? todos[scope]! : todosOn(scope, day)));

  void toggleTodo(TodoItem item, {DateTime? day, TodoScope scope = TodoScope.today}) {
    final target = day ?? today;
    if (!canEditDay(target)) return;
    if (target == today) {
      store.setTodoDone(item.id, !item.done, day: today);
    } else {
      store.setPastTodoDone(scope, target, item, !item.done, today);
    }
    _reloadTodos();
    _todosChanged();
  }

  void setTodoSubtasks(TodoScope scope, TodoItem item, List<TodoSubtask> children, {DateTime? day}) {
    final target = day ?? today;
    if (!canEditDay(target)) return;
    store.setTodoSubtasks(scope, item, children, target, live: target == today);
    _reloadTodos();
    _todosChanged();
  }

  /// Without a [time] or [category], it has none.
  void editTodo(
    TodoScope scope,
    TodoItem item,
    String text,
    DateTime? dueDate, {
    DateTime? day,
    int? time,
    TaskCategory? category,
  }) {
    final target = day ?? today;
    if (!canEditDay(target) || text.trim().isEmpty) return;
    final value = normaliseNote(text.trim());
    if (target == today) {
      store.editTodo(item.id, value, dueDate, today, time: time, category: category);
      store.promoteDueTodos(today, earliest: today);
      store.rollTomorrowToToday(dateKey(today));
      _reloadTodos();
    } else {
      store.editPastTodo(scope, target, item: item, text: value, dueDate: dueDate, time: time, category: category);
    }
    _todosChanged();
  }

  bool nestTodo(TodoScope sourceScope, TodoItem source, TodoScope targetScope, TodoItem target) {
    final from = todos[sourceScope]!.where((item) => item.id == source.id).firstOrNull;
    final into = todos[targetScope]!.where((item) => item.id == target.id).firstOrNull;
    if (from == null || into == null || from.id == into.id || from.done || from.subtasks.isNotEmpty) return false;
    store.nestTodo(targetScope, from, into, today);
    _reloadTodos();
    _todosChanged();
    return true;
  }

  void moveTodo(TodoScope source, TodoItem item, TodoScope destination) {
    if (source == destination) return;
    final current = todos[source]!.where((t) => t.id == item.id).firstOrNull;
    if (current == null || current.done) return;
    store.moveTodo(current.id, destination, today);
    _reloadTodos();
    _todosChanged();
  }

  /// Moves an open task to [day]: Today, Tomorrow, or due that day.
  void moveTodoTo(TodoScope source, TodoItem item, DateTime day) {
    final current = todos[source]!.where((t) => t.id == item.id).firstOrNull;
    if (current == null || current.done || day.isBefore(today)) return;
    final days = DateTime.utc(
      day.year,
      day.month,
      day.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    if (days <= 1) {
      moveTodo(source, current, days == 0 ? TodoScope.today : TodoScope.tomorrow);
      return;
    }
    // Due this week files under This week, anything after under This month.
    final sunday = DateTime(today.year, today.month, today.day + 7 - today.weekday);
    store.moveTodo(current.id, day.isAfter(sunday) ? TodoScope.month : TodoScope.week, today, due: day);
    _reloadTodos();
    _todosChanged();
  }

  void removeTodo(TodoScope scope, TodoItem item, {DateTime? day}) {
    final target = day ?? today;
    if (!canEditDay(target)) return;
    if (target == today) {
      store.deleteTodo(item.id, day: today);
      todos[scope] = [
        for (final task in todos[scope]!)
          if (task.id != item.id) task,
      ];
    } else {
      store.editPastTodo(scope, target, item: item, deleted: true);
    }
    _todosChanged();
  }

  /// The categories Further ahead shows; none picked shows everything.
  late Set<TaskCategory> laterFilter = {
    for (final name in (store.setting('laterFilter') ?? '').split(',')) ?TaskCategory.decode(name),
  };

  void toggleLaterFilter(TaskCategory category) {
    laterFilter = laterFilter.contains(category) ? ({...laterFilter}..remove(category)) : {...laterFilter, category};
    store.setSetting(
      'laterFilter',
      [
        for (final c in TaskCategory.values)
          if (laterFilter.contains(c)) c.name,
      ].join(','),
    );
    notifyListeners();
  }

  // Repeating tasks

  List<Repeat>? _repeats;
  List<Repeat> get repeats => _repeats ??= store.repeats();

  /// The repeat [item] is a time of, while it still repeats.
  Repeat? repeatOf(TodoItem item) {
    final uid = item.repeatUid;
    return uid == null ? null : repeats.where((r) => r.uid == uid).firstOrNull;
  }

  /// The first time [repeat] comes round on or after [from] that wasn't
  /// taken away, made or not and done or not: the one time of it shown.
  /// [kept] has the uids of the to-dos still in a list.
  DateTime? comingOccurrence(Repeat repeat, DateTime from, {Set<String> kept = const {}}) {
    final made = store.madeOccurrences(repeat.uid);
    for (var day = repeat.next(from); day != null; day = repeat.next(DateTime(day.year, day.month, day.day + 1))) {
      final uid = '${repeat.uid}@${dateKey(day)}';
      if (kept.contains(uid) || !made.contains(uid)) return day;
    }
    return null;
  }

  /// [repeat]'s to-do for [day], made now so it can be changed on its own.
  TodoItem occurrence(Repeat repeat, DateTime day) {
    final item = store.makeOccurrence(repeat, day);
    _startDay();
    _todosChanged();
    return item;
  }

  void addRepeat(String text, RepeatRule rule, DateTime start, {DateTime? until, int? time, TaskCategory? category}) {
    if (text.trim().isEmpty) return;
    store.addRepeat(normaliseNote(text.trim()), rule, start, until: until, time: time, category: category);
    _startDay();
    _todosChanged();
  }

  /// Makes [item] repeat from its day (or today) on, in place of it.
  void makeRepeating(
    TodoScope scope,
    TodoItem item,
    String text,
    RepeatRule rule, {
    DateTime? until,
    int? time,
    TaskCategory? category,
  }) {
    final due = item.dueDate;
    final start = due == null || due.isBefore(today) ? today : dateOnly(due);
    store.transaction(() {
      store.addRepeat(normaliseNote(text.trim()), rule, start, until: until, time: time, category: category);
      store.deleteTodo(item.id, day: today);
    });
    _reloadTodos();
    _startDay();
    _todosChanged();
  }

  /// Renames [repeat] from [from] on, and sets its time and category.
  void renameRepeat(Repeat repeat, String text, DateTime from, {int? time, TaskCategory? category}) {
    if (text.trim().isEmpty) return;
    store.renameRepeat(repeat.uid, normaliseNote(text.trim()), from, today, time: time, category: category);
    _repeats = null;
    _reloadTodos();
    _todosChanged();
  }

  /// Stops [repeat] coming round from [from] on.
  void endRepeat(Repeat repeat, DateTime from) {
    store.endRepeat(repeat.uid, from, today);
    _reloadTodos();
    _startDay();
    _todosChanged();
  }

  /// [repeat] from [from] on, as a new repeat by [rule]; or, without one,
  /// no more after [from], whose to-do stays.
  void changeRepeat(
    Repeat repeat,
    DateTime from,
    String text,
    RepeatRule? rule, {
    DateTime? until,
    int? time,
    TaskCategory? category,
  }) {
    if (text.trim().isEmpty) return;
    final value = normaliseNote(text.trim());
    store.transaction(() {
      if (rule == null) {
        store.endRepeat(repeat.uid, DateTime(from.year, from.month, from.day + 1), today);
        if ((value, time, category) != (repeat.text, repeat.time, repeat.category)) {
          store.renameRepeat(repeat.uid, value, from, today, time: time, category: category);
        }
      } else {
        store.endRepeat(repeat.uid, from, today);
        store.addRepeat(value, rule, from.isBefore(today) ? today : from, until: until, time: time, category: category);
      }
    });
    _reloadTodos();
    _startDay();
    _todosChanged();
  }

  // Journal

  /// The journal lives in the database. Its files are a copy for reading
  /// outside the app, so one that's missing or can't be read (a Mac told
  /// no to the Documents folder) never hides an entry.
  String journalOf(DateTime day) => store.journal(dateKey(day));

  Future<void> setJournal(DateTime day, String text) {
    text = normaliseNote(text);
    store.setJournal(dateKey(day), text);
    _journalShown = (day: day, text: store.journal(dateKey(day)));
    journalRevision++;
    notifyListeners();
    return _writeJournalFile(day, text);
  }

  /// The entry the journal's editor has, as stored, by day: what typing
  /// there is on top of.
  ({DateTime day, String text})? _journalShown;

  /// The editor now has [text] as [day]'s stored entry.
  void journalShown(DateTime day, String text) => _journalShown = (day: day, text: text);

  /// Typed but not saved yet: saved a moment after typing stops, rather
  /// than on every keystroke, and at once before sync merges, a restore,
  /// or quitting.
  ({DateTime day, String text})? _draft;
  Timer? _draftTimer;

  void draftJournal(DateTime day, String text) {
    if (_draft != null && _draft!.day != day) saveJournalDraft();
    _draft = (day: day, text: text);
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), saveJournalDraft);
  }

  /// Whether [day] has typing not saved yet.
  bool hasJournalDraft(DateTime day) => _draft?.day == day;

  void saveJournalDraft() {
    _draftTimer?.cancel();
    _draftTimer = null;
    final draft = _draft;
    if (draft == null) return;
    _draft = null;
    final stored = store.journal(dateKey(draft.day));
    final shown = _journalShown?.day == draft.day ? _journalShown!.text : stored;
    // Another computer's text came in as a key was pressed, before the
    // editor showed it: both kept.
    unawaited(setJournal(draft.day, stored == shown ? draft.text : _typedOver(shown, draft.text, stored)));
  }

  /// [typed] on top of [shown], saved where [stored] replaced it meanwhile.
  static String _typedOver(String shown, String typed, String stored) {
    if (shown.trim().isNotEmpty && stored.contains(shown) && !typed.contains(stored) && !stored.contains(typed)) {
      return stored.replaceFirst(shown, typed);
    }
    return Store.keepWriting(typed, stored);
  }

  /// Why the journal's files aren't being saved, for the folder button;
  /// null while they are.
  String? journalFileProblem;

  /// Copies a day's entry to its file. A failure only means the copy is
  /// behind: the database still has it, and the next save tries again.
  Future<void> _writeJournalFile(DateTime day, String text) async {
    final files = journalFiles;
    if (files == null) return;
    if (!savesJournalFiles) {
      store.setSetting('journalFilesStale', '1');
      return;
    }
    String? problem;
    try {
      await files.write(day, text);
    } on FileSystemException catch (e) {
      debugPrint('Saving journal file failed: $e');
      // EPERM: macOS's privacy settings keep Eclipse out of Documents.
      problem = Platform.isMacOS && e.osError?.errorCode == 1
          ? "Eclipse isn’t allowed in your Documents folder, so the journal’s files aren’t being saved. "
                'Allow it in System Settings, Privacy & Security, Files and Folders.'
          : "The journal’s files couldn’t be saved (${e.osError?.message ?? e.message}).";
    }
    problem = problem == null ? null : curlyQuotes(problem);
    if (_disposed || problem == journalFileProblem) return;
    journalFileProblem = problem;
    notifyListeners();
  }

  /// Once: writes entries from before the journal moved to documents out as
  /// files. Never overwrites a file, and never runs again, so deleting a
  /// file in the folder doesn't bring it back.
  Future<void> _exportJournal() async {
    final files = journalFiles;
    if (files == null || !savesJournalFiles || store.setting('journalExported') != null) return;
    try {
      String? after;
      while (true) {
        if (closing || _disposed) return;
        final batch = store.journalEntries(after: after, limit: 64).toList();
        if (batch.isEmpty) break;
        for (final e in batch) {
          if (closing || _disposed) return;
          final day = DateTime.parse(e.day);
          if (!await files.fileFor(day).exists()) await files.write(day, e.text);
        }
        after = batch.last.day;
      }
      store.setSetting('journalExported', '1');
    } catch (e) {
      debugPrint('Exporting journal failed: $e');
    }
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
