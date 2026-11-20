import '../widgets/ritual_goal.dart';
import '../widgets/workout_tools.dart';

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../data/app_log.dart';
import '../data/backups.dart';
import '../data/data_folder.dart';
import '../data/google_drive.dart';
import '../data/store.dart';
import '../data/sync_service.dart';
import '../models.dart';
import '../smart_add.dart';
import '../screens/startup_error.dart';
import '../screens/today_view.dart' show JournalCard;
import '../screens/training_view.dart' show AddSessionExercise;
import '../training.dart';
import '../training_log.dart';
import '../widgets/todo_panel.dart' show PhonePlan, TaskDetailsMenu, addTaskAnywhere, confirmRemoveTask;
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_dialog.dart';
import '../widgets/holidays.dart';
import '../widgets/search_glow.dart';
import '../widgets/setting_rows.dart';
import '../widgets/tile.dart';
import 'phone_platform.dart';

part 'phone_tabs.dart';

/// The phone's Eclipse: today's rituals, sleep and tasks, and adding tasks,
/// on the same data as the computers through Drive sync.
Future<void> phoneMain({Future<Directory> Function() supportDirectory = getApplicationSupportDirectory}) async {
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themeNamed(null),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: context.palette.background,
          body: const Center(child: CircularProgressIndicator()),
        ),
      ),
    ),
  );
  await _openPhone(supportDirectory);
}

Future<bool> _backupBeforeUpgrade(Directory home, String directory, String database) => Isolate.run(() {
  AppLog.start(home);
  final backups = Backups(Directory(directory))..beforeUpdating(database);
  return backups.updateCopyFailed;
});

Future<void> _openPhone(Future<Directory> Function() supportDirectory) async {
  Directory? home;
  DataFolder? data;
  Store? opened;
  try {
    final dir = home = await supportDirectory();
    await dir.create(recursive: true);
    AppLog.start(dir);
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      AppLog.failure('Drawing', details.exception, details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      AppLog.failure('Uncaught', error, stack);
      return false;
    };
    final documents = await getApplicationDocumentsDirectory();
    data = DataFolder.load(dir, documents);
    await data.root.create(recursive: true);
    final backups = Backups(data.backups);
    backups.updateCopyFailed = await _backupBeforeUpgrade(dir, backups.dir.path, data.database);
    final store = opened = Store.open(data.database);
    SyncService? sync;
    try {
      sync = SyncService.load(dir, store)..copiesToDrive = true;
    } catch (error) {
      AppLog.failure('Sync couldn’t start', error);
    }
    final state = AppState(store, backups: backups, dataFolder: data, sync: sync);
    state.endTour();
    sync?.start();
    if (sync?.isOn ?? false) unawaited(sync!.run());
    runApp(PhoneApp(state: state, updater: PhoneUpdater()));
    unawaited(
      PhonePlatform.enableBackgroundSync(state).catchError((Object error, StackTrace stack) {
        AppLog.failure('Background sync couldn’t start', error, stack);
      }),
    );
  } catch (error, stack) {
    AppLog.failure('Couldn’t open the data', error, stack);
    unawaited(PhonePlatform.reportStartupError('$error'));
    try {
      opened?.close();
    } catch (_) {}
    String? theme;
    try {
      if (data != null) theme = savedThemeName(data.database);
    } catch (_) {}
    final updater = PhoneUpdater();
    unawaited(updater.check());
    runApp(
      StartupErrorApp(
        error: error,
        phoneUpdater: updater,
        themeName: theme,
        onRetry: () => _openPhone(supportDirectory),
        recovery: data == null || home == null
            ? null
            : StartupRecovery(
                backups: Backups(data.backups),
                database: data.database,
                driveCopies: SyncService.copiesAt(home),
                reopen: () => _openPhone(supportDirectory),
              ),
      ),
    );
  }
}

class PhoneApp extends StatefulWidget {
  const PhoneApp({super.key, required this.state, this.updater, this.schedule = PhonePlatform.schedule});

  final AppState state;
  final PhoneUpdater? updater;

  /// Sets the reminders as alarms; stands in for the phone in tests.
  final Future<void> Function(AppState) schedule;

  @override
  State<PhoneApp> createState() => _PhoneAppState();
}

class _PhoneAppState extends State<PhoneApp> with WidgetsBindingObserver {
  AppState get _state => widget.state;
  final _home = GlobalKey<_PhoneHomeState>();
  final _navigator = GlobalKey<NavigatorState>();
  Timer? _scheduling, _dateTimer;
  Object? _reminderKey;
  bool _scheduleDirty = false;
  bool _askedNotifications = false;
  bool? _lastSyncOn;
  bool _wasSignedIn = false;

  Object _currentReminderKey() => (
    _state.today,
    _state.todosRevision,
    _state.dayStartHour,
    _state.snoozeRevision,
    _state.sync?.isOn ?? false,
    _state.sync?.email ?? '',
    Object.hashAll(_state.holidays),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastSyncOn = _state.sync?.isOn ?? false;
    _wasSignedIn = _lastSyncOn!;
    _state.addListener(_onStateChanged);
    _reminderKey = _currentReminderKey();
    _scheduleDirty = true;
    _onStateChanged();
    _changed();
    _state.sync?.addListener(_onStateChanged);
    _dateTimer = Timer.periodic(const Duration(seconds: 30), (_) => _state.checkDate());
    unawaited(widget.updater?.check());
    unawaited(PhonePlatform.listenReminders(_openReminder));
  }

  @override
  void didUpdateWidget(PhoneApp old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      old.state.removeListener(_onStateChanged);
      old.state.sync?.removeListener(_onStateChanged);
      _lastSyncOn = _state.sync?.isOn ?? false;
      _wasSignedIn = _lastSyncOn!;
      _state.sync?.addListener(_onStateChanged);
      _state.addListener(_onStateChanged);
      _reminderKey = _currentReminderKey();
      _scheduleDirty = true;
      _onStateChanged();
      _changed();
    }
  }

  @override
  void dispose() {
    _scheduling?.cancel();
    _dateTimer?.cancel();
    PhonePlatform.stopListeningReminders();
    _state.sync?.removeListener(_onStateChanged);
    _state.removeListener(_onStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _openReminder(String uid) {
    _state.openReminder(uid);
    final inToday = _state.todos[TodoScope.today]!.any((t) => t.uid == uid);
    final occurrenceDay = uid.contains('@') ? DateTime.tryParse(uid.split('@').last) : null;
    final inPlan = !inToday && (_state.store.remindingTodoByUid(uid) != null || occurrenceDay?.isAfter(_state.today) == true);
    _home.currentState?.select(inPlan ? 1 : 0);
    _navigator.currentState?.popUntil((route) => route.isFirst);
  }

  void _onStateChanged() {
    final syncOn = _state.sync?.isOn ?? false;
    if (syncOn != _lastSyncOn) {
      _lastSyncOn = syncOn;
      unawaited(PhonePlatform.setBackgroundSync(syncOn));
    }
    final signedOut = !syncOn && _wasSignedIn;
    if (signedOut) {
      _navigator.currentState?.popUntil((route) => route.isFirst);
    }
    _wasSignedIn = syncOn;
    final key = _currentReminderKey();
    if (key == _reminderKey) return;
    _reminderKey = key;
    _scheduleDirty = true;
    if (syncOn) {
      _changed();
    } else if (signedOut) {
      _flushSchedule();
    }
  }

  /// Puts the alarms right once a burst of changes has settled.
  void _changed() {
    if (!_scheduleDirty) return;
    _scheduling?.cancel();
    _scheduling = Timer(const Duration(seconds: 1), _runSchedule);
  }

  void _runSchedule() {
    _scheduling = null;
    _scheduleDirty = false;
    if (!_askedNotifications && _state.sync?.isOn != false && _state.upcomingReminders().isNotEmpty) {
      _askedNotifications = true;
      unawaited(PhonePlatform.askNotifications());
    }
    unawaited(widget.schedule(_state).catchError((Object _) {}));
  }

  void _flushSchedule() {
    if (_scheduling == null && !_scheduleDirty) return;
    _scheduling?.cancel();
    _runSchedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    final sync = _state.sync;
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        _state.checkDate();
        if (sync != null && sync.isOn) unawaited(sync.run());
        unawaited(widget.updater?.check());
      case AppLifecycleState.paused:
        // What was just ticked reaches the computers before Android stops it.
        _state.saveDrafts();
        _flushSchedule();
        _state.store.flushToDisk();
        if (sync != null && sync.isOn) unawaited(sync.run());
      default:
    }
  }

  @override
  Widget build(BuildContext context) => AppScope(
    state: _state,
    child: ValueListenableBuilder<String?>(
      valueListenable: _state.themeNotifier,
      builder: (context, themeName, _) => MaterialApp(
        title: 'Eclipse',
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        // A finger has no hover, so a touch keeps Material's ripple here.
        theme: themeNamed(themeName).copyWith(splashFactory: InkSparkle.splashFactory),
        themeAnimationDuration:
            (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ? Duration.zero : Motion.morph,
        themeAnimationCurve: Motion.morphCurve,
        builder: (context, child) => DefaultTextHeightBehavior(
          textHeightBehavior: const TextHeightBehavior(leadingDistribution: TextLeadingDistribution.even),
          child: ThemeMorph(target: paletteNamed(themeName), child: child!),
        ),
        home: _state.sync == null
            ? _PhoneHome(key: _home, updater: widget.updater)
            : ListenableBuilder(
                listenable: _state.sync!,
                builder: (context, _) =>
                    _state.sync!.isOn ? _PhoneHome(key: _home, updater: widget.updater) : _SignInPage(sync: _state.sync!),
              ),
      ),
    ),
  );
}

/// Text as on a computer: Regular, at the tasks' line height.
TextStyle _body(Palette p, {double size = 15, Color? colour}) =>
    TextStyle(fontFamily: Fonts.body, fontSize: size, fontWeight: FontWeight.w400, height: 1.35, color: colour ?? p.ink);

/// The big date and page titles, as a computer's header sets them.
TextStyle _title(Palette p, {double size = 38}) => TextStyle(
  fontFamily: Fonts.display,
  fontSize: size,
  fontWeight: FontWeight.w600,
  letterSpacing: -0.6,
  height: 1.05,
  color: p.ink,
);

/// The first thing on a new phone: there's nothing here until it's joined.
class _SignInPage extends StatefulWidget {
  const _SignInPage({required this.sync});

  final SyncService sync;

  @override
  State<_SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<_SignInPage> {
  bool _busy = false;
  String? _error;
  Completer<void>? _cancel;

  @override
  void dispose() {
    if (!(_cancel?.isCompleted ?? true)) _cancel!.complete();
    super.dispose();
  }

  Future<void> _signIn() async {
    final cancel = _cancel = Completer<void>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final sync = widget.sync;
    try {
      final GoogleAccount account = await sync.signIn(cancel: cancel.future);
      if (!mounted || cancel.isCompleted) return;
      unawaited(PhonePlatform.toFront());
      final others = await sync.look(account);
      if (!mounted || cancel.isCompleted) return;
      if (others && !sync.isReturning(account)) {
        if (sync.needsAccountChoice(account) && !await _confirmReplace(account.email)) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        if (!mounted || cancel.isCompleted) return;
        await sync.turnOn(account, join: true);
      } else if (sync.needsAccountChoice(account)) {
        if (!await _confirmTransfer(account.email)) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        if (!mounted || cancel.isCompleted) return;
        await sync.turnOn(account, join: false, transfer: true);
      } else {
        await sync.turnOn(account, join: false);
      }
      if (!mounted || cancel.isCompleted) return;
      unawaited(PhonePlatform.askNotifications());
    } catch (e) {
      if (mounted && !cancel.isCompleted) setState(() => _error = '$e');
    }
    if (mounted && identical(_cancel, cancel)) {
      _cancel = null;
      setState(() => _busy = false);
    }
  }

  void _cancelSignIn() {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    setState(() {
      _busy = false;
      _error = null;
    });
  }

  Future<bool> _confirmReplace(String email) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
          title: 'Use this account’s data?',
          content: Text('What’s on this phone is replaced with what’s in $email.'),
          actions: [
            DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
            DialogConfirm(label: 'Use it', onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      ) ??
      false;

  Future<bool> _confirmTransfer(String email) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
          title: 'Move this phone’s data into this account?',
          content: Text('What’s on this phone will be moved into $email.'),
          actions: [
            DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
            DialogConfirm(label: 'Move', onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text('Eclipse', style: _title(p)),
              const SizedBox(height: 12),
              Text(
                'Sign in with the same Google account as your computers to bring your rituals and tasks here.',
                style: _body(p, colour: p.inkMuted),
              ),
              const SizedBox(height: 24),
              if (_error case final error?) ...[
                Text(error, style: _body(p, size: 14, colour: p.missedInk)),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: _busy ? null : _signIn,
                style: FilledButton.styleFrom(
                  backgroundColor: p.done,
                  foregroundColor: p.onDone,
                  minimumSize: const Size.fromHeight(52),
                ),
                child: Text(_busy ? 'Waiting for Google…' : 'Sign in with Google'),
              ),
              if (_busy) ...[
                const SizedBox(height: 12),
                Center(
                  child: TextButton(onPressed: _cancelSignIn, child: const Text('Cancel')),
                ),
              ],
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _TodayPage extends StatelessWidget {
  const _TodayPage({this.updater});

  final PhoneUpdater? updater;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(
      context,
      (s) => (s.today, s.habitsRevision, s.entriesRevision, s.todosRevision, s.restWeekends, s.holidays),
    );
    final today = state.today;
    final rest = state.isRestDay(today);
    final rituals = [
      for (final h in state.habits)
        if (h.onDay(today) && h.startedBy(today)) h,
    ];
    return SafeArea(
      child: RefreshIndicator(
        color: p.accent,
        onRefresh: () async {
          final sync = state.sync;
          if (sync != null && sync.isOn) await sync.run();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(weekdayNames[today.weekday - 1].toUpperCase(), style: capsLabel(p.inkMuted)),
                      const SizedBox(height: 4),
                      Text('${today.day} ${monthNames[today.month - 1]}', style: _title(p)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Settings',
                  icon: Icon(Icons.settings_rounded, color: p.inkMuted),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => _SettingsPage(updater: updater)),
                  ),
                ),
              ],
            ),
            if (updater case final updater?) _UpdateCard(updater: updater),
            const SizedBox(height: 16),
            _MarksCard(title: 'RITUALS', habits: rituals, rest: rest),
            const SizedBox(height: 12),
            _MarksCard(title: 'SLEEP', habits: state.sleepHabits, rest: rest),
            const SizedBox(height: 12),
            const _TasksCard(),
          ],
        ),
      ),
    );
  }
}

class _PhoneUndoBanner extends StatefulWidget {
  const _PhoneUndoBanner({
    this.removal,
    this.canRedo = false,
    required this.onUndo,
    this.onRedo,
    required this.onHide,
  });

  final Removal? removal;
  final bool canRedo;
  final VoidCallback onUndo;
  final VoidCallback? onRedo;
  final VoidCallback onHide;

  @override
  State<_PhoneUndoBanner> createState() => _PhoneUndoBannerState();
}

class _PhoneUndoBannerState extends State<_PhoneUndoBanner> {
  Timer? _timer;

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), widget.onHide);
  }

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(_PhoneUndoBanner old) {
    super.didUpdateWidget(old);
    if (!identical(widget.removal, old.removal) || widget.canRedo != old.canRedo) _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final removal = widget.removal;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              removal?.label ?? 'Undone',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _body(p, size: 14),
            ),
          ),
          if (removal != null) TextButton(onPressed: widget.onUndo, child: const Text('Undo')),
          if (widget.canRedo && widget.onRedo != null) TextButton(onPressed: widget.onRedo, child: const Text('Redo')),
        ],
      ),
    );
  }
}

class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.updater});

  final PhoneUpdater updater;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final version = updater.available;
        if (version == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Tile(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(child: Text(updater.error ?? 'Eclipse $version is out', style: _body(p, size: 14))),
                TextButton(
                  onPressed: updater.updating ? null : updater.update,
                  child: Text(updater.updating ? 'Downloading…' : 'Update'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Rituals or the sleep schedule: each a row with its mark for today.
class _MarksCard extends StatelessWidget {
  const _MarksCard({required this.title, required this.habits, required this.rest});

  final String title;
  final List<Habit> habits;
  final bool rest;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.today, s.entriesRevision));
    if (habits.isEmpty) return const SizedBox.shrink();
    final done = habits.where((h) => state.statusOf(state.today, h) == HabitStatus.done).length;
    return Tile(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TileHeader(
            title: title,
            titleStyle: capsLabel(context.palette.inkMuted),
            caption: rest ? 'Rest day' : '$done of ${habits.length}',
          ),
          const SizedBox(height: 8),
          for (final h in habits) _MarkRow(habit: h),
        ],
      ),
    );
  }
}

/// Tapping goes round as on a computer: blank, done, not done, other.
class _MarkRow extends StatelessWidget {
  const _MarkRow({required this.habit});

  final Habit habit;

  static const _next = {
    HabitStatus.none: HabitStatus.done,
    HabitStatus.done: HabitStatus.missed,
    HabitStatus.missed: HabitStatus.other,
    HabitStatus.other: HabitStatus.none,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(
      context,
      (s) => (s.today, s.entriesRevision, s.habitsRevision, s.restWeekends, s.holidays),
    );
    final today = state.today;
    final status = state.statusOf(today, habit);
    final streak = state.currentStreak(habit);
    final (fill, ink, icon) = switch (status) {
      HabitStatus.done => (p.done, p.onAccent, Icons.check_rounded),
      HabitStatus.missed => (p.missed, p.onAccent, Icons.close_rounded),
      HabitStatus.other => (p.other, p.onAccent, Icons.remove_rounded),
      HabitStatus.none => (p.empty, p.inkMuted, null),
    };
    final showStreak = habit.weekly == null && streak > 1;
    final canEditGoal = state.habits.any((h) => h.id == habit.id);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onLongPress: () => _showMenu(context, state, today, habit, canEditGoal: canEditGoal),
      onTap: () => habit.target != null
          ? enterRitualAmount(context, today, habit)
          : state.selectStatus(today, habit, _next[status]!),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            Expanded(
              child: Text(
                ritualProgress(state, today, habit),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _body(p),
              ),
            ),
            if (habit.weekly != null) ...[
              Icon(Icons.event_repeat_rounded, size: 16, color: p.inkMuted),
              const SizedBox(width: 8),
            ],
            if (showStreak) ...[
              Text('$streak', style: _body(p, size: 12, colour: p.inkMuted)),
              const SizedBox(width: 12),
            ],
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(12)),
              child: icon == null ? null : Icon(icon, size: 22, color: ink),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMenu(
    BuildContext context,
    AppState state,
    DateTime day,
    Habit habit, {
    required bool canEditGoal,
  }) async {
    final p = context.palette;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.tile,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.check_rounded, size: 18, color: p.done),
              title: Text('Mark done', style: _body(p)),
              onTap: () {
                Navigator.pop(sheet);
                state.selectStatus(day, habit, HabitStatus.done);
              },
            ),
            if (habit.target != null)
              ListTile(
                leading: Icon(Icons.edit_rounded, size: 18, color: p.accent),
                title: Text('Log progress', style: _body(p)),
                onTap: () {
                  Navigator.pop(sheet);
                  enterRitualAmount(context, day, habit);
                },
              ),
            ListTile(
              leading: Icon(Icons.close_rounded, size: 18, color: p.missed),
              title: Text('Mark not done', style: _body(p)),
              onTap: () {
                Navigator.pop(sheet);
                state.selectStatus(day, habit, HabitStatus.missed);
              },
            ),
            ListTile(
              leading: Icon(Icons.remove_rounded, size: 18, color: p.other),
              title: Text('Mark other', style: _body(p)),
              onTap: () {
                Navigator.pop(sheet);
                state.selectStatus(day, habit, HabitStatus.other);
              },
            ),
            ListTile(
              leading: Icon(Icons.clear_all_rounded, size: 18, color: p.inkMuted),
              title: Text('Clear mark', style: _body(p)),
              onTap: () {
                Navigator.pop(sheet);
                state.selectStatus(day, habit, HabitStatus.none);
              },
            ),
            if (canEditGoal)
              ListTile(
                leading: Icon(Icons.tune_rounded, size: 18, color: p.inkMuted),
                title: Text('Edit goal', style: _body(p)),
                onTap: () {
                  Navigator.pop(sheet);
                  editRitualGoal(context, habit, day.year, day.month);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _TasksCard extends StatelessWidget {
  const _TasksCard();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision));
    final tasks = state.orderedTodos(TodoScope.today);
    return Tile(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TileHeader(
            title: 'TODAY',
            titleStyle: capsLabel(p.inkMuted),
            caption: switch (tasks.where((t) => !t.done).length) {
              0 => null,
              final open => '$open to do',
            },
          ),
          const SizedBox(height: 8),
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('Nothing planned', style: _body(p, colour: p.inkMuted)),
            ),
          for (final task in tasks)
            Dismissible(
              key: ValueKey('dismiss-${task.id}'),
              direction: DismissDirection.endToStart,
              confirmDismiss: task.repeatUid == null
                  ? null
                  : (_) async {
                      await confirmRemoveTask(context, TodoScope.today, task, day: state.today);
                      return false;
                    },
              onDismissed: (_) => state.removeTodo(TodoScope.today, task),
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                decoration: BoxDecoration(color: p.missed, borderRadius: BorderRadius.circular(12)),
                child: Icon(Icons.delete_rounded, size: 18, color: p.onAccent),
              ),
              child: SearchGlow(
                target: task.uid,
                radius: 12,
                child: _TaskRow(key: ValueKey(task.id), task: task),
              ),
            ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({super.key, required this.task});

  final TodoItem task;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final hasMeta = task.dueTime != null || task.location != null || task.repeatUid != null || task.birthday;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => state.toggleTodo(task),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: task.done ? p.done : Colors.transparent,
                    border: task.done ? null : Border.all(color: p.inkMuted, width: 1.5),
                  ),
                  child: task.done ? Icon(Icons.check_rounded, size: 18, color: p.onDone) : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hasMeta)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(
                              children: [
                                if (task.dueTime case final time?)
                                  Text(
                                    clockLabel(time),
                                    style: TextStyle(fontFamily: Fonts.taskTime, fontSize: 12, color: p.inkMuted),
                                  ),
                                if (task.location case final loc?) ...[
                                  if (task.dueTime != null) const SizedBox(width: 8),
                                  Icon(Icons.place_rounded, size: 12, color: p.inkMuted),
                                  const SizedBox(width: 2),
                                  Flexible(
                                    child: Text(
                                      loc,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _body(p, size: 12, colour: p.inkMuted),
                                    ),
                                  ),
                                ],
                                if (task.birthday || task.repeatUid != null) ...[
                                  if (task.dueTime != null || task.location != null) const SizedBox(width: 8),
                                  Icon(
                                    task.birthday ? Icons.cake_rounded : Icons.repeat_rounded,
                                    size: 12,
                                    color: p.inkMuted,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        Text(
                          task.text,
                          style: _body(p, colour: task.done ? p.inkMuted : p.ink).copyWith(
                            decoration: task.done ? TextDecoration.lineThrough : null,
                            decorationColor: p.inkMuted.withValues(alpha: 0.45),
                          ),
                        ),
                        if (task.note case final note?)
                          Text(
                            note,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: _body(p, size: 12, colour: p.inkMuted),
                          ),
                      ],
                    ),
                  ),
                ),
                TaskDetailsMenu(scope: TodoScope.today, item: task),
              ],
            ),
          ),
        ),
        for (final (i, sub) in task.subtasks.indexed)
          Padding(
            padding: const EdgeInsets.only(left: 38),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                HapticFeedback.selectionClick();
                state.setTodoSubtasks(TodoScope.today, task, [
                  for (final (j, s) in task.subtasks.indexed)
                    if (j == i) TodoSubtask(s.text, done: !s.done, note: s.note, numbered: s.numbered) else s,
                ]);
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Row(
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: sub.done ? p.done : Colors.transparent,
                        border: sub.done ? null : Border.all(color: p.inkMuted, width: 1.5),
                      ),
                      child: sub.done ? Icon(Icons.check_rounded, size: 12, color: p.onDone) : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          sub.text,
                          style: _body(p, size: 14, colour: sub.done ? p.inkMuted : p.ink).copyWith(
                            decoration: sub.done ? TextDecoration.lineThrough : null,
                            decorationColor: p.inkMuted.withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A task's name and day: today, tomorrow or one picked.
Future<void> _addTask(BuildContext context) async {
  final state = AppScope.read(context);
  final p = context.palette;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.tile,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => AppScope(state: state, child: const _AddTaskSheet()),
  );
}

class _AddTaskSheet extends StatefulWidget {
  const _AddTaskSheet();

  @override
  State<_AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<_AddTaskSheet> {
  final _name = TextEditingController();
  late DateTime _day = AppScope.read(context).today;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final text = _name.text.trim();
    if (text.isEmpty) return;
    final state = AppScope.read(context);
    final (scope, due) = scopeForDay(state.today, _day);
    state.quickAddTodo(scope, text, dueDate: due);
    Navigator.pop(context);
  }

  Future<void> _pick() async {
    final today = AppScope.read(context).today;
    final picked = await showDatePicker(
      context: context,
      firstDate: today,
      lastDate: DateTime(today.year + 5),
      initialDate: _day.isBefore(today) ? today : _day,
    );
    if (picked != null && mounted) setState(() => _day = picked);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final today = AppScope.read(context).today;
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final picked = _day != today && _day != tomorrow;
    Widget chip(String label, bool on, VoidCallback onTap) => ChoiceChip(
      label: Text(label, style: _body(p, size: 14, colour: on ? p.onDone : p.ink)),
      selected: on,
      showCheckmark: false,
      selectedColor: p.done,
      backgroundColor: p.empty,
      side: BorderSide.none,
      onSelected: (_) => onTap(),
    );
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              cursorColor: p.ink,
              style: _body(p, size: 16),
              decoration: InputDecoration(
                hintText: 'New task',
                hintStyle: _body(p, size: 16, colour: p.inkMuted),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _save(),
            ),
            if (AppScope.read(context).smartAdd)
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _name,
                builder: (context, value, _) {
                  final parsed = parseQuickTask(value.text, today, defaultDay: _day);
                  if (parsed.name == value.text.trim()) return const SizedBox.shrink();
                  final day = parsed.day ?? _day;
                  final time = parsed.minutes;
                  final actualDay = afterMidnight(time, AppScope.read(context).dayStartHour)
                      ? DateTime(day.year, day.month, day.day + 1)
                      : day;
                  final details = [
                    shortDay(actualDay, today: today),
                    if (time != null) clockLabel(time),
                    ?parsed.location,
                    if (parsed.repeat case final rule?) rule.label,
                    if (parsed.until case final end?) 'Until ${shortDay(end, today: today)}',
                    for (final at in Reminder.of(parsed.reminders).map((r) => r.at(actualDay, time)))
                      'Remind ${shortDay(at, today: today)} at ${clockLabel(at.hour * 60 + at.minute)}',
                  ];
                  return Text(details.join(' · '), style: _body(p, size: 12, colour: p.inkMuted));
                },
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    children: [
                      chip('Today', _day == today, () => setState(() => _day = today)),
                      chip('Tomorrow', _day == tomorrow, () => setState(() => _day = tomorrow)),
                      chip(picked ? shortDay(_day, today: today) : 'Pick a day', picked, _pick),
                    ],
                  ),
                ),
                IconButton.filled(
                  tooltip: 'Add',
                  style: IconButton.styleFrom(backgroundColor: p.done, foregroundColor: p.onDone),
                  onPressed: _save,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({this.updater});

  final PhoneUpdater? updater;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  bool _signingOut = false;

  Future<void> _signOut(AppState state, SyncService sync) async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      state.saveDrafts();
      await sync.run();
      if (!mounted) return;
      if (sync.error != null) {
        final proceed =
            await showDialog<bool>(
              context: context,
              builder: (context) => AppAlertDialog(
                title: 'Sign out without syncing?',
                content: Text(
                  'Eclipse couldn’t sync first, so unsynced changes on this phone would be lost (${sync.error}).',
                ),
                actions: [
                  DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
                  DialogConfirm(label: 'Sign out anyway', onPressed: () => Navigator.pop(context, true)),
                ],
              ),
            ) ??
            false;
        if (!proceed || !mounted) return;
      }
      await sync.turnOff();
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.themeName, s.restWeekends, s.dayStartHour, s.smartAdd));
    final sync = state.sync;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.background,
        foregroundColor: p.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('Settings', style: _title(p, size: 22)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (sync != null) ...[
            ListenableBuilder(
              listenable: sync,
              builder: (context, _) => Tile(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('SYNC', style: capsLabel(p.inkMuted)),
                    const SizedBox(height: 12),
                    Text(sync.email ?? 'Not signed in', style: _body(p)),
                    if (sync.error case final error?) ...[
                      const SizedBox(height: 6),
                      Text(error, style: _body(p, size: 14, colour: p.missedInk)),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: sync.busy || _signingOut ? null : sync.run,
                          child: Text(sync.busy ? 'Syncing…' : 'Sync now'),
                        ),
                        TextButton(
                          onPressed: _signingOut ? null : () => _signOut(state, sync),
                          child: Text(_signingOut ? 'Signing out…' : 'Sign out'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Tile(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('DAYS', style: capsLabel(p.inkMuted)),
                ),
                SwitchListTile(title: const Text('Smart quick-add'), value: state.smartAdd, onChanged: state.setSmartAdd),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => state.setRestWeekends(!state.restWeekends),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Weekends as rest days', style: _body(p)),
                              const SizedBox(height: 2),
                              Text('Saturdays and Sundays don’t count against streaks.', style: _body(p, size: 14, colour: p.inkMuted)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        SettingToggle(on: state.restWeekends),
                      ],
                    ),
                  ),
                ),
                const DayStartPicker(),
                const HolidaysRow(),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Tile(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('THEME', style: capsLabel(p.inkMuted)),
                const SizedBox(height: 8),
                for (final theme in palettes)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => state.setTheme(theme.name),
                    child: SizedBox(
                      height: 48,
                      child: Row(
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.background,
                              border: Border.all(color: theme.tileBorder),
                            ),
                            child: const SizedBox(width: 18, height: 18),
                          ),
                          const SizedBox(width: 8),
                          for (final colour in [theme.done, theme.missed, theme.other, theme.today])
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: DecoratedBox(
                                decoration: BoxDecoration(shape: BoxShape.circle, color: colour),
                                child: const SizedBox(width: 12, height: 12),
                              ),
                            ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(theme.name, style: _body(p))),
                          if (theme.name == p.name) Icon(Icons.check_rounded, size: 18, color: p.accent),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (widget.updater?.installed case final version?)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Eclipse $version', style: _body(p, size: 12, colour: p.inkMuted)),
            ),
        ],
      ),
    );
  }
}
