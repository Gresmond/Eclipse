import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'data/app_log.dart';
import 'data/backups.dart';
import 'data/data_folder.dart';
import 'data/dev_install.dart';
import 'data/journal_files.dart';
import 'data/night_light.dart';
import 'data/restart.dart';
import 'data/store.dart';
import 'data/sync_service.dart';
import 'data/system_notifications.dart';
import 'data/system_time_zone.dart' if (dart.library.js_interop) 'data/system_time_zone_web.dart';
import 'data/updates.dart';
import 'models.dart';
import 'phone/phone_app.dart';
import 'screens/shell.dart';
import 'screens/startup_error.dart';
import 'theme/app_theme.dart';
import 'web/web_app.dart';
import 'widgets/app_dialog.dart';
import 'widgets/search_dialog.dart';
import 'widgets/todo_panel.dart' show addTaskAnywhere;
import 'widgets/undo_card.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    return webMain(
      app: (state, updater) => EclipseApp(state: state, updater: updater),
      watch: (state) {
        final stopWindow = _watchWindow(state);
        final stopDate = _watchDate(state);
        final stopReminders = _watchReminders(state);
        return () {
          stopWindow();
          stopDate();
          stopReminders();
        };
      },
    );
  }
  if (Platform.isAndroid) return phoneMain();
  SystemTimeZone.instance?.sync();
  // ~/.local/share/dev.nicholas.productivity_app, unless you chose a folder.
  final dir = await getApplicationSupportDirectory();
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
  final version = ReleaseUpdater.readInstalledVersion(Platform.resolvedExecutable);
  AppLog.note('Opened Eclipse ${version ?? '(local build)'}, database format ${Store.schemaVersion}');
  final documents = await getApplicationDocumentsDirectory();
  final AppState state;
  Store? opened;
  try {
    final data = DataFolder.load(dir, documents);
    await data.root.create(recursive: true);
    final backups = Backups(data.backups)..beforeUpdating(data.database);
    final store = opened = Store.open(data.database);
    // Sync is optional: the app runs on its own without it.
    SyncService? sync;
    try {
      sync = SyncService.load(dir, store)..copiesToDrive = true;
    } catch (error) {
      AppLog.failure('Sync couldn’t start', error);
    }
    state = AppState(
      store,
      backups: backups,
      journalFiles: JournalFiles(data.journal),
      dataFolder: data,
      sync: sync,
      notifier: SystemNotifications(),
      clock: SystemTimeZone.now,
    );
  } catch (error, stack) {
    AppLog.failure('Couldn’t open the data', error, stack);
    // Let go of it, as a backup may be put in its place.
    try {
      opened?.close();
    } catch (_) {}
    String? theme;
    DataFolder? data;
    try {
      data = DataFolder.load(dir, documents);
      theme = savedThemeName(data.database);
    } catch (_) {}
    _showStartupError(error, theme: theme, data: data, home: dir);
    return;
  }
  unawaited(refreshInstalledCopy(Store.schemaVersion));
  state.sync?.start();
  if (state.sync?.isOn ?? false) unawaited(state.sync!.run());
  final disposers = <void Function()>[
    _watchWindow(state),
    _watchDate(state),
    _watchNightLight(state),
    _watchReminders(state),
  ];

  // Installed by linux/install.sh: watches its folder for newer commits.
  // Packaged installs ask GitHub for a newer release.
  final updater = Updater.forThisApp(
    onRestart: () async {
      for (final stop in disposers) {
        stop();
      }
      await _shutdown(state);
    },
  );
  if (updater != null) {
    unawaited(updater.check());
    final updateTimer = Timer.periodic(updater.checkEvery, (_) {
      if (!state.closing) updater.check();
    });
    disposers.add(updateTimer.cancel);
  }

  runApp(EclipseApp(state: state, updater: updater));
}

/// Shows why the data couldn't be opened, instead of a blank window, and
/// offers the update when an older copy meets data from a newer one.
void _showStartupError(Object error, {String? theme, DataFolder? data, required Directory home}) {
  final updater = error is DatabaseTooNewException ? Updater.forThisApp() : null;
  if (updater != null && updater is! GitUpdater) unawaited(updater.check());
  if (Platform.isLinux) {
    // Nothing was opened, so the tray's Quit has nothing to save.
    const MethodChannel('eclipse/lifecycle').setMethodCallHandler((call) async {
      if (call.method != 'quit') throw MissingPluginException();
    });
  }
  runApp(
    StartupErrorApp(
      error: error,
      updater: updater,
      themeName: theme,
      recovery: data == null
          ? null
          : StartupRecovery(
              backups: Backups(data.backups),
              database: data.database,
              journal: JournalFiles(data.journal),
              driveCopies: SyncService.copiesAt(home),
              reopen: () => restartApplication(beforeRestart: () async {}),
            ),
    ),
  );
}

Future<void>? _shuttingDown;

Future<void> _shutdown(AppState state) => _shuttingDown ??= () async {
  FocusManager.instance.primaryFocus?.unfocus();
  await state.shutdown();
}();

/// Rolls the day over on the stroke of midnight (or whenever the user's day
/// starts). Also looks once a minute,
/// because timers stand still while the computer sleeps and the time zone
/// can change, and whenever the window comes back.
void Function() _watchDate(AppState state) {
  Timer? timer;
  void check() {
    if (state.closing) return;
    SystemTimeZone.instance?.sync();
    state.checkDate();
  }

  void schedule() {
    if (state.closing) return;
    final now = SystemTimeZone.now();
    // Midnight is looked at too, for the "until 4am" in the header.
    final until = [
      DateTime(now.year, now.month, now.day + 1),
      nextDayStart(now, state.dayStartHour),
    ].map((t) => t.difference(now)).reduce((a, b) => a < b ? a : b);
    // Just past the hour, so the clock has certainly turned.
    final wait = until <= Duration.zero
        ? const Duration(milliseconds: 20)
        : until < const Duration(minutes: 1)
        ? until + const Duration(milliseconds: 20)
        : const Duration(minutes: 1);
    timer = Timer(wait, () {
      check();
      schedule();
    });
  }

  schedule();
  final listener = AppLifecycleListener(onResume: check, onShow: check);
  return () {
    timer?.cancel();
    listener.dispose();
  };
}

/// Syncs as the window comes and goes, so switching computers shows the
/// latest: what changed here goes when the window goes to the back or is
/// closed, and the others' changes come in when it comes back. Quitting
/// waits a moment for sync, and saves typing first either way.
void Function() _watchWindow(AppState state) {
  void leaving() {
    if (state.closing) return;
    state.saveDrafts();
    state.store.flushToDisk();
    unawaited(state.persist?.call());
    state.sync?.sendChanges();
  }

  final listener = AppLifecycleListener(
    onResume: () {
      if (!state.closing) state.sync?.refresh();
    },
    onShow: () {
      if (!state.closing) state.sync?.refresh();
    },
    onInactive: leaving,
    onHide: leaving,
    onExitRequested: () async {
      await _shutdown(state);
      return AppExitResponse.exit;
    },
  );
  // The tray's Quit, which saves before the app closes.
  if (!kIsWeb && Platform.isLinux) {
    const MethodChannel('eclipse/lifecycle').setMethodCallHandler((call) async {
      if (call.method != 'quit') throw MissingPluginException();
      await _shutdown(state);
    });
  }
  return () {
    listener.dispose();
    if (!kIsWeb && Platform.isLinux) {
      const MethodChannel('eclipse/lifecycle').setMethodCallHandler(null);
    }
  };
}

/// Mirrors night light into [AppState]: hyprsunset can't announce a
/// change, so it's asked every few seconds and whenever the window comes back.
void Function() _watchNightLight(AppState state) {
  final isOn = NightLight.forSession()?.isOn;
  if (isOn == null) return () {};
  state.nightLightAvailable = true;
  Future<void> check({bool force = false}) async {
    if (state.closing || !state.followNightLight || (!force && !state.windowOpen)) return;
    final on = await isOn();
    if (on != null && !state.closing) state.nightLightIs(on);
  }

  var wasFollowing = state.followNightLight;
  void onState() {
    if (state.followNightLight && !wasFollowing) unawaited(check(force: true));
    wasFollowing = state.followNightLight;
  }

  state.addListener(onState);
  unawaited(check(force: true));
  final timer = Timer.periodic(const Duration(seconds: 5), (_) => check());
  final listener = AppLifecycleListener(onResume: () => check(force: true), onShow: () => check(force: true));
  return () {
    state.removeListener(onState);
    timer.cancel();
    listener.dispose();
  };
}

/// Sends tasks' reminders as they come due: looked for every few seconds,
/// since timers stand still while the computer sleeps, and whenever the
/// window comes back. Cards show only while the window is open. On starting
/// or waking they wait for a sync, for times changed on another computer.
void Function() _watchReminders(AppState state) {
  void check() {
    if (state.closing) return;
    SystemTimeZone.instance?.sync();
    state.checkDate();
    state.checkReminders();
  }

  void syncFirst() {
    final sync = state.sync;
    if (sync != null && sync.isOn) state.holdReminders(sync.run());
  }

  syncFirst();
  var last = DateTime.now();
  final timer = Timer.periodic(const Duration(seconds: 10), (_) {
    final now = DateTime.now();
    if (now.difference(last) > const Duration(seconds: 30)) syncFirst();
    last = now;
    check();
  });
  final listener = AppLifecycleListener(
    onShow: () {
      state.windowOpen = true;
      check();
    },
    onHide: () => state.windowOpen = false,
    onResume: check,
  );
  // Started hidden (at login), it shows nothing in the window yet.
  state.windowOpen = WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden;
  WidgetsBinding.instance.addPostFrameCallback((_) => check());
  check();
  return () {
    timer.cancel();
    listener.dispose();
  };
}

class EclipseApp extends StatelessWidget {
  const EclipseApp({super.key, required this.state, this.updater});

  final AppState state;
  final Updater? updater;

  void _search() {
    final navigator = appNavigator.currentState;
    if (navigator == null || navigator.canPop() || state.closing) return;
    showAppDialog<void>(context: navigator.context, builder: (_) => const SearchDialog());
  }

  /// Ctrl+N, unless a dialog is open.
  void _newTask() {
    final navigator = appNavigator.currentState;
    if (navigator == null || navigator.canPop() || state.closing) return;
    addTaskAnywhere(navigator.context);
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ValueListenableBuilder<String?>(
        valueListenable: state.themeNotifier,
        builder: (context, themeName, _) => MaterialApp(
          title: 'Eclipse',
          navigatorKey: appNavigator,
          debugShowCheckedModeBanner: false,
          theme: themeNamed(themeName),
          themeAnimationDuration: (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ? Duration.zero : Motion.morph,
          themeAnimationCurve: Motion.morphCurve,
          // A line's extra height goes equally above and below it, which
          // centres the fonts' capitals in their line, and so on the tick
          // boxes and tints beside them.
          builder: (context, child) => DefaultTextHeightBehavior(
            textHeightBehavior: const TextHeightBehavior(leadingDistribution: TextLeadingDistribution.even),
            child: ThemeMorph(
              target: paletteNamed(themeName),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search,
                  const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _search,
                  const SingleActivator(LogicalKeyboardKey.keyF, control: true): _search,
                  const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _search,
                  const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newTask,
                  const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _newTask,
                },
                child: UndoLayer(cards: CornerCards(updater: updater), child: child!),
              ),
            ),
          ),
          home: Builder(
            builder: (context) => AbsorbPointer(
              absorbing: AppScope.watch(context, (s) => s.closing).closing,
              child: Shell(updater: updater),
            ),
          ),
        ),
      ),
    );
  }
}
