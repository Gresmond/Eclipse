import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../data/app_log.dart';
import '../data/browser_store.dart';
import '../data/google_drive.dart';
import '../data/http_request.dart' if (dart.library.js_interop) '../data/http_request_web.dart';
import '../data/store.dart' show DatabaseTooNewException;
import '../data/sync_service.dart';
import '../data/updates.dart';
import 'browser.dart';
import 'web_screens.dart';

/// Built with no Eclipse server behind it, to look at locally: data stays in
/// the browser, with no sign-in or sync.
const _localOnly = bool.fromEnvironment('ECLIPSE_LOCAL');

const _welcome = '/welcome.html';
const _signIn = '/api/auth/start';

/// Said to index.html: a person is signed in here, so it needn't ask the
/// server before loading the app.
const _hereKey = 'eclipse-here';

/// The Google account the server holds a sign-in for.
enum _Answer { signedIn, signedOut, offline }

Future<(_Answer, Map<String, dynamic>?)> _session() async {
  try {
    final (status, body) = await sendHttpRequest('GET', Uri.base.resolve('/api/session'));
    if (status == 200) return (_Answer.signedIn, jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
    return (status == 401 ? _Answer.signedOut : _Answer.offline, null);
  } catch (_) {
    return (_Answer.offline, null);
  }
}

/// Access to Drive from the sign-in the server holds, which never reaches
/// this page.
Future<(String, int)> _accessToken() async {
  final int status;
  final Uint8List body;
  try {
    (status, body) = await sendHttpRequest('POST', Uri.base.resolve('/api/token'), body: const [], type: 'text/plain');
  } catch (_) {
    throw const DriveError('Can’t reach Eclipse. Are you online?', unreachable: true);
  }
  if (status == 401) throw const DriveError('Google signed Eclipse out. Sign in again.', signedOut: true);
  if (status != 200) throw DriveError('Eclipse’s sign-in said: error $status');
  final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
  return (json['access_token'] as String, (json['expires_in'] as num?)?.toInt() ?? 3600);
}

/// Running in a browser: opens this browser's copy once the sign-in is settled,
/// then hands over to the app. Everything that can't work without a server
/// or another tab's say-so happens first, on plain pages.
Future<void> webMain({
  required Widget Function(AppState state, Updater? updater) app,
  required void Function() Function(AppState state) watch,
}) async {
  // Right-click is Eclipse's own, as on the desktop: it marks things missed.
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(BrowserContextMenu.disableContextMenu());
  runApp(const WebNotice(title: 'Eclipse', busy: true));

  // What it takes to let go of the data, as far as it's got.
  Future<void> Function() close = () async {};
  late final DataLock lock;
  var handingOver = false;
  Future<void> handOver() async {
    if (handingOver) return;
    handingOver = true;
    try {
      await close();
      runApp(
        const WebNotice(
          title: 'Eclipse is open in another tab',
          text: 'Only one tab can use your data at a time.',
          actions: [WebNoticeAction('Use it here', reloadPage)],
        ),
      );
    } finally {
      lock.release();
    }
  }

  lock = await DataLock.take(onAsked: handOver);
  final BrowserData data;
  try {
    data = await BrowserData.open();
  } catch (e, stack) {
    AppLog.failure('Couldn’t open browser storage', e, stack);
    lock.release();
    final tooNew = e is DatabaseTooNewException;
    runApp(
      WebNotice(
        title: tooNew ? 'This copy of Eclipse is older than your data' : 'Eclipse couldn’t open this browser’s storage',
        text: tooNew
            ? 'Reload this tab to open the latest version of Eclipse. Nothing has been lost.'
            : 'Private browsing or blocked browser storage can stop Eclipse saving here. ($e)',
        actions: const [WebNoticeAction('Try again', reloadPage)],
      ),
    );
    return;
  }
  close = () async {
    await data.persist();
    data.store.close();
    await data.close();
  };

  void show(AppState state) {
    final stopPreferences = browserPreferences(state);
    final stopWatching = watch(state);
    final stopPageLeave = onPageLeave(() {
      if (state.closing) return;
      state.saveDrafts();
      state.store.flushToDisk();
      unawaited(data.persist());
      state.sync?.sendChanges();
    });
    if (state.firstRun) state.startTour();
    final updater = WebUpdater();
    unawaited(updater.check());
    final updateTimer = Timer.periodic(updater.checkEvery, (_) => updater.check());
    close = () async {
      stopPreferences();
      stopPageLeave();
      updateTimer.cancel();
      stopWatching();
      await state.shutdown();
      await data.close();
    };
    runApp(app(state, updater));
  }

  if (_localOnly) {
    return show(AppState(data.store, persist: data.persist, notifier: BrowserNotifications()));
  }

  final (answer, session) = await _session();
  final sync =
      SyncService.loadFrom(
          data.settings,
          data.disk,
          data.store,
          connect: (_) => AppDataFolder('', accessToken: _accessToken),
          signIn: ({Future<void>? cancel}) {
            goTo(_signIn);
            return Completer<GoogleAccount>().future; // The page is on its way out.
          },
        )
        ..persist = data.persist
        ..copiesToDrive = true;

  if (answer == _Answer.signedOut) {
    await close();
    lock.release();
    remember(_hereKey, null);
    goTo(_welcome);
    return;
  }
  if (answer == _Answer.offline && !sync.isOn) {
    await close();
    lock.release();
    runApp(
      const WebNotice(
        title: 'You’re offline',
        text: 'Eclipse needs a connection the first time you sign in on this browser.',
        actions: [WebNoticeAction('Try again', reloadPage)],
      ),
    );
    return;
  }

  // Turning sync on, when that's to wait until the app has its examples in.
  Future<void> Function()? turnOn;
  if (answer == _Answer.signedIn) {
    final account = GoogleAccount(
      email: session!['email'] as String,
      id: session['id'] as String?,
      refreshToken: 'held-by-server',
      journalAccess: session['journalAccess'] == true,
    );
    if (sync.needsAccountChoice(account)) {
      _chooseAccount(sync.accountEmail, account, () async {
        await close();
        lock.release();
      });
      return;
    }
    if (sync.isOn) {
      await sync.updateAccess(journalAccess: account.journalAccess);
    } else {
      runApp(const WebNotice(title: 'Bringing your data here', busy: true));
      try {
        final others = await sync.look(account);
        if (others && !sync.hasSynced) {
          await sync.turnOn(account, join: true);
        } else {
          turnOn = () => sync.turnOn(account, join: false);
        }
      } on DriveError catch (e) {
        await close();
        lock.release();
        runApp(
          WebNotice(
            title: 'Couldn’t reach your Drive',
            text: e.message,
            actions: const [WebNoticeAction('Try again', reloadPage)],
          ),
        );
        return;
      }
    }
  }

  final AppState state;
  try {
    state = AppState(data.store, sync: sync, persist: data.persist, notifier: BrowserNotifications());
  } catch (e, stack) {
    AppLog.failure('Couldn’t open the data', e, stack);
    await close();
    lock.release();
    runApp(
      WebNotice(
        title: 'Eclipse couldn’t open your data',
        text: '$e',
        actions: const [WebNoticeAction('Try again', reloadPage)],
      ),
    );
    return;
  }
  remember(_hereKey, '1');
  var signingOut = false;
  var signOutPending = false;
  state.signOut = ({bool force = false}) => _signOut(
    state,
    data,
    lock,
    force: force,
    onStart: () {
      signingOut = true;
      signOutPending = false;
    },
    onPending: () {
      signingOut = false;
      signOutPending = true;
    },
  );
  show(state);

  // Sign-in taken back while open: nothing here is lost, it just waits.
  var wasOn = sync.isOn;
  var handlingExpiry = false;
  sync.addListener(() async {
    if (sync.isOn) {
      wasOn = true;
      return;
    }
    if (!wasOn || handlingExpiry || state.closing || signingOut || signOutPending || turnOn != null) return;
    handlingExpiry = true;
    state.saveDrafts();
    await data.persist();
    await close();
    lock.release();
    remember(_hereKey, null);
    goTo('$_welcome?expired=1');
  });

  if (turnOn case final first?) {
    try {
      await first();
      wasOn = sync.isOn;
    } on Object catch (e, stack) {
      AppLog.failure('Couldn’t finish turning on sync', e, stack);
      turnOn = null;
      await close();
      lock.release();
      runApp(
        WebNotice(
          title: 'Couldn’t reach your Drive',
          text: '$e',
          actions: const [WebNoticeAction('Try again', reloadPage)],
        ),
      );
      return;
    } finally {
      turnOn = null;
    }
  }
  sync.start();
  if (sync.isOn) unawaited(sync.run());
}

/// Signed in with another account than this browser's copy belongs to.
void _chooseAccount(String? had, GoogleAccount now, Future<void> Function() close) {
  Future<void> signOutFirst() async {
    await close();
    await sendHttpRequest('POST', Uri.base.resolve('/api/signout'), body: const [], type: 'text/plain');
    goTo(_welcome);
  }

  Future<void> erase() async {
    await close();
    await BrowserData.erase();
    reloadPage();
  }

  runApp(
    WebNotice(
      title: 'This browser holds another account’s data',
      text:
          'You’re signed in as ${now.email}, but this browser has the copy of '
          '${had ?? 'another account'}. Sign in with that account to use it, or erase the copy here '
          'to use ${now.email}. Anything it hasn’t synced yet would be lost.',
      actions: [
        WebNoticeAction('Sign in with the other account', signOutFirst),
        WebNoticeAction('Erase this browser’s copy', erase),
      ],
    ),
  );
}

/// Sends what's here, says if that failed unless [force], then ends the
/// sign-in and erases this browser's copy.
Future<String?> _signOut(
  AppState state,
  BrowserData data,
  DataLock lock, {
  required bool force,
  required void Function() onStart,
  required void Function() onPending,
}) async {
  onStart();
  final sync = state.sync!;
  state.saveDrafts();
  if (!force && sync.isOn) await sync.run();
  if (sync.error != null && !force) {
    onPending();
    return sync.error;
  }
  await state.shutdown();
  var serverCleared = false;
  try {
    final (status, _) = await sendHttpRequest(
      'POST',
      Uri.base.resolve('/api/signout'),
      body: const [],
      type: 'text/plain',
      timeout: const Duration(seconds: 10),
    );
    serverCleared = status >= 200 && status < 300;
  } catch (_) {
    // Offline: the browser's copy is still erased below.
  }
  var erased = false;
  try {
    await data.close().timeout(const Duration(seconds: 10));
    remember(_hereKey, null);
    await BrowserData.erase().timeout(const Duration(seconds: 10));
    erased = true;
  } catch (e, stack) {
    AppLog.failure('Couldn’t erase browser data', e, stack);
    remember(_hereKey, null);
  } finally {
    lock.release();
    goTo(
      !erased
          ? '$_welcome?error=erase'
          : !serverCleared
          ? '$_welcome?offline_signout=1'
          : _welcome,
    );
  }
  return null;
}

typedef WebFetch = Future<(int, Uint8List)> Function(Uri uri);

/// Asks the site what version it's on. A newer one is there as soon as the
/// page reloads.
class WebUpdater extends Updater {
  WebUpdater({
    @visibleForTesting String? running,
    @visibleForTesting WebFetch? fetch,
    @visibleForTesting VoidCallback? onReload,
  }) : _running = running ?? const String.fromEnvironment('FLUTTER_BUILD_NAME'),
       _fetch = fetch ?? ((uri) => sendHttpRequest('GET', uri)),
       _onReload = onReload ?? reloadPage;

  final String _running;
  final WebFetch _fetch;
  final VoidCallback _onReload;
  String? _dismissed;

  static final _versionFormat = RegExp(r'^\d+\.\d+\.\d+$');

  @override
  String get actionLabel => 'Reload';

  @override
  Duration get checkEvery => const Duration(minutes: 30);

  @override
  Future<void> check() async {
    if (_running.isEmpty || !_versionFormat.hasMatch(_running)) return;
    try {
      final (status, body) = await _fetch(Uri.base.resolve('/version.json'));
      if (status != 200) return;
      final version = (jsonDecode(utf8.decode(body)) as Map)['version'] as String?;
      if (version == null ||
          !_versionFormat.hasMatch(version) ||
          !isNewer(version, _running) ||
          version == _dismissed) {
        return;
      }
      newVersion = version;
      set(UpdateStatus.available);
    } catch (_) {
      // Offline: there's nothing to tell.
    }
  }

  @override
  Future<void> update() async => _onReload();

  @override
  void dismiss() {
    _dismissed = newVersion;
    set(UpdateStatus.none);
  }
}
