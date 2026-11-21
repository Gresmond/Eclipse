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
part 'phone_today.dart';
part 'phone_settings.dart';

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

