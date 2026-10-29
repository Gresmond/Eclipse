import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'data/backups.dart';
import 'data/data_folder.dart';
import 'data/dev_install.dart';
import 'data/journal_files.dart';
import 'data/night_light.dart';
import 'data/restart.dart';
import 'data/store.dart';
import 'data/sync_service.dart';
import 'data/system_time_zone.dart';
import 'data/updates.dart';
import 'data/windows_night_light.dart';
import 'models.dart';
import 'screens/shell.dart';
import 'screens/startup_error.dart';
import 'theme/app_theme.dart';
import 'widgets/undo_card.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemTimeZone.instance?.sync();
  // ~/.local/share/dev.nicholas.productivity_app, unless you chose a folder.
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final documents = await getApplicationDocumentsDirectory();
  DataFolder.leaveSandbox(dir, documents);
  final data = DataFolder.load(dir, documents);
  final Store store;
  try {
    await data.root.create(recursive: true);
    store = Store.open(data.database);
  } catch (error) {
    _showStartupError(error);
    return;
  }
  unawaited(refreshInstalledCopy(Store.schemaVersion));
  late final AppState state;
  state = AppState(
    store,
    backups: Backups(data.backups),
    journalFiles: JournalFiles(data.journal),
    dataFolder: data,
    sync: SyncService.load(dir, store),
    restart: () => restartApplication(beforeRestart: () => _shutdown(state)),
  );
  state.sync?.start();
  if (state.sync?.isOn ?? false) unawaited(state.sync!.run());
  _watchWindow(state);

  if (state.firstRun) state.startTour();
  _watchDate(state);
  _watchNightLight(state);

  // Installed by linux/install.sh: watches its folder for newer commits.
  // Packaged installs ask GitHub for a newer release.
  final updater = Updater.forThisApp(onRestart: () => _shutdown(state));
  if (updater != null) {
    unawaited(updater.check());
    Timer.periodic(updater.checkEvery, (_) => updater.check());
  }

  runApp(EclipseApp(state: state, updater: updater));
}

/// Shows why the data couldn't be opened, instead of a blank window, and
/// offers the update when an older copy meets data from a newer one.
void _showStartupError(Object error) {
  final updater = Updater.forThisApp();
  if (updater != null && updater is! GitUpdater) unawaited(updater.check());
  if (Platform.isLinux || Platform.isWindows) {
    // Nothing was opened, so the tray's Quit has nothing to save.
    const MethodChannel('eclipse/lifecycle').setMethodCallHandler((call) async {
      if (call.method != 'quit') throw MissingPluginException();
    });
  }
  runApp(StartupErrorApp(error: error, updater: updater));
}

Future<void> _shutdown(AppState state) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await state.shutdown();
}

/// Rolls the day over on the stroke of midnight (or whenever the user's day
/// starts). Also looks once a minute,
/// because timers stand still while the computer sleeps and the time zone
/// can change, and whenever the window comes back.
void _watchDate(AppState state) {
  void check() {
    if (state.closing) return;
    SystemTimeZone.instance?.sync();
    state.checkDate();
  }

  void schedule() {
    if (state.closing) return;
    final now = DateTime.now();
    // Midnight is looked at too, for the "until 4am" in the header.
    final until = [
      DateTime(now.year, now.month, now.day + 1),
      nextDayStart(now, state.dayStartHour),
    ].map((t) => t.difference(now)).reduce((a, b) => a < b ? a : b);
    // Just past the hour, so the clock has certainly turned.
    final wait = until < const Duration(minutes: 1)
        ? until + const Duration(milliseconds: 20)
        : const Duration(minutes: 1);
    Timer(wait, () {
      check();
      schedule();
    });
  }

  schedule();
  AppLifecycleListener(onResume: check, onShow: check);
}

/// Syncs as the window comes and goes, so switching computers shows the
/// latest: what changed here goes when the window goes to the back or is
/// closed, and the others' changes come in when it comes back. Quitting
/// waits a moment for sync, and saves typing first either way.
void _watchWindow(AppState state) {
  void leaving() {
    if (state.closing) return;
    state.saveDrafts();
    state.store.flushToDisk();
    state.sync?.sendChanges();
  }

  AppLifecycleListener(
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
  // The tray's Quit (Linux and Windows), which saves before the app closes.
  if (Platform.isLinux || Platform.isWindows) {
    const MethodChannel('eclipse/lifecycle').setMethodCallHandler((call) async {
      if (call.method != 'quit') throw MissingPluginException();
      await _shutdown(state);
    });
  }
}

/// Mirrors night light into [AppState]: hyprsunset can't announce a
/// change, so it's asked every few seconds and whenever the window comes back.
/// Windows Night light is read from the registry the same way.
/// A Mac has no night light to read (Night Shift has no public API), so
/// there it follows Dark mode, which macOS's Auto appearance turns on at
/// sunset and off at sunrise.
void _watchNightLight(AppState state) {
  if (Platform.isMacOS) {
    state.nightLightAvailable = true;
    WidgetsBinding.instance.addObserver(_DarkModeObserver(state));
    return;
  }
  final isOn = Platform.isWindows ? WindowsNightLight.isOn : NightLight.forSession()?.isOn;
  if (isOn == null) return;
  state.nightLightAvailable = true;
  Future<void> check() async {
    if (state.closing) return;
    final on = await isOn();
    if (on != null && !state.closing) state.nightLightIs(on);
  }

  unawaited(check());
  Timer.periodic(const Duration(seconds: 5), (_) => check());
  AppLifecycleListener(onResume: check, onShow: check);
}

class _DarkModeObserver with WidgetsBindingObserver {
  _DarkModeObserver(this.state) {
    didChangePlatformBrightness();
  }

  final AppState state;

  @override
  void didChangePlatformBrightness() {
    if (!state.closing) {
      state.nightLightIs(WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);
    }
  }
}

class EclipseApp extends StatelessWidget {
  const EclipseApp({super.key, required this.state, this.updater});

  final AppState state;
  final Updater? updater;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ValueListenableBuilder<String?>(
        valueListenable: state.themeNotifier,
        builder: (context, themeName, _) => MaterialApp(
          title: 'Eclipse',
          debugShowCheckedModeBanner: false,
          theme: themeNamed(themeName),
          themeAnimationDuration: Motion.morph,
          themeAnimationCurve: Motion.morphCurve,
          // A line's extra height goes equally above and below it, which
          // centres the fonts' capitals in their line, and so on the tick
          // boxes and tints beside them.
          builder: (context, child) => DefaultTextHeightBehavior(
            textHeightBehavior: const TextHeightBehavior(leadingDistribution: TextLeadingDistribution.even),
            child: UndoLayer(child: child!),
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
