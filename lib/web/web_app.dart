import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../data/app_log.dart';
import '../data/browser_store.dart';
import '../data/google_drive.dart';
import '../data/http_request.dart' if (dart.library.js_interop) '../data/http_request_web.dart';
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
  required void Function(AppState state) watch,
}) async {
  // Right-click is Eclipse's own, as on the desktop: it marks things missed.
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(BrowserContextMenu.disableContextMenu());
  runApp(const WebNotice(title: 'Eclipse', busy: true));

  // What it takes to let go of the data, as far as it's got.
  Future<void> Function() close = () async {};
  late final DataLock lock;
  Future<void> handOver() async {
    await close();
    runApp(
      const WebNotice(
        title: 'Eclipse is open in another tab',
        text: 'Only one tab can use your data at a time.',
        actions: [WebNoticeAction('Use it here', reloadPage)],
      ),
    );
    lock.release();
  }

  lock = await DataLock.take(onAsked: handOver);
  final data = await BrowserData.open();
  close = () async {
    data.store.close();
    await data.close();
  };

  void show(AppState state) {
    close = () async {
      await state.shutdown();
      await data.close();
    };
    watch(state);
    if (state.firstRun) state.startTour();
    final updater = WebUpdater();
    unawaited(updater.check());
    Timer.periodic(updater.checkEvery, (_) => updater.check());
    runApp(app(state, updater));
  }

  if (_localOnly) return show(AppState(data.store, notifier: BrowserNotifications()));

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
    await data.persist();
    remember(_hereKey, null);
    goTo(_welcome);
    return;
  }
  if (answer == _Answer.offline && !sync.isOn) {
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
    state = AppState(data.store, sync: sync, notifier: BrowserNotifications());
  } catch (e, stack) {
    AppLog.failure('Couldn’t open the data', e, stack);
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
  state.signOut = ({bool force = false}) => _signOut(state, data, lock, force: force);
  show(state);

  // Sign-in taken back while open: nothing here is lost, it just waits.
  sync.addListener(() async {
    if (sync.isOn || state.closing || turnOn != null) return;
    state.saveDrafts();
    await data.persist();
    remember(_hereKey, null);
    goTo('$_welcome?expired=1');
  });

  if (turnOn case final first?) {
    await first();
    turnOn = null;
  }
  sync.start();
  if (sync.isOn) unawaited(sync.run());
}

/// Signed in with another account than this browser's copy belongs to.
void _chooseAccount(String? had, GoogleAccount now, Future<void> Function() close) {
  Future<void> signOutFirst() async {
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
Future<String?> _signOut(AppState state, BrowserData data, DataLock lock, {required bool force}) async {
  final sync = state.sync!;
  state.saveDrafts();
  await sync.run();
  if (sync.error != null && !force) return sync.error;
  await state.shutdown();
  try {
    await sendHttpRequest('POST', Uri.base.resolve('/api/signout'), body: const [], type: 'text/plain');
  } catch (_) {
    // Offline: the sign-in lingers, but there's nothing left here to read.
  }
  await data.close();
  remember(_hereKey, null);
  await BrowserData.erase();
  lock.release();
  goTo(_welcome);
  return null;
}

/// Asks the site what version it's on. A newer one is there as soon as the
/// page reloads.
class WebUpdater extends Updater {
  static const _running = String.fromEnvironment('FLUTTER_BUILD_NAME');
  String? _dismissed;

  @override
  String get actionLabel => 'Reload';

  @override
  Duration get checkEvery => const Duration(minutes: 30);

  @override
  Future<void> check() async {
    try {
      final (status, body) = await sendHttpRequest('GET', Uri.base.resolve('/version.json'));
      if (status != 200) return;
      final version = (jsonDecode(utf8.decode(body)) as Map)['version'] as String?;
      if (version == null || version == _running || version == _dismissed) return;
      newVersion = version;
      set(UpdateStatus.available);
    } catch (_) {
      // Offline: there's nothing to tell.
    }
  }

  @override
  Future<void> update() async => reloadPage();

  @override
  void dismiss() {
    _dismissed = newVersion;
    set(UpdateStatus.none);
  }
}
