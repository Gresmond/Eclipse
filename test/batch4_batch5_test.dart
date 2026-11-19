import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/http_request.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync_disk.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/data/system_time_zone.dart';
import 'package:eclipse/data/updates.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/phone/phone_app.dart';
import 'package:eclipse/phone/phone_platform.dart';
import 'package:eclipse/screens/startup_error.dart';
import 'package:eclipse/screens/year_heatmap.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/web/web_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

class _FakeSyncDrive implements SyncDrive {
  final files = <String, (String, List<int>, int)>{};
  int _seq = 1;
  bool failList = false;
  Completer<void>? listGate;

  @override
  Future<List<DriveFile>> list() async {
    if (listGate != null) await listGate!.future;
    if (failList) throw const DriveError('Offline', unreachable: true);
    return [
      for (final e in files.entries) DriveFile(id: e.key, name: e.value.$1, modified: '${e.value.$3}'),
    ];
  }

  @override
  Future<List<int>> download(String id) async => files[id]!.$2;

  @override
  Future<DriveFile> upload(String name, List<int> bytes, {String? id}) async {
    final key = id ?? 'f${_seq++}';
    final ver = _seq++;
    files[key] = (name, bytes, ver);
    return DriveFile(id: key, name: name, modified: '$ver');
  }
}

Uint8List _buildTzifV2({
  required List<int> transitionsSeconds,
  required List<int> typeIndices,
  required List<int> utcOffsetsSeconds,
}) {
  final builder = BytesBuilder();
  void writeHeader(int timeCount, int typeCount) {
    builder.add(ascii.encode('TZif2'));
    builder.add(List<int>.filled(15, 0));
    final bd = ByteData(24)
      ..setUint32(0, 0) // ttisutcnt
      ..setUint32(4, 0) // ttisstdcnt
      ..setUint32(8, 0) // leapcnt
      ..setUint32(12, timeCount)
      ..setUint32(16, typeCount)
      ..setUint32(20, 1); // charcnt
    builder.add(bd.buffer.asUint8List());
  }

  // Minimal v1 block (0 transitions, 1 type, 1 char).
  writeHeader(0, 1);
  builder.add(Uint8List(6));
  builder.addByte(0);

  // v2 block with 64-bit timestamps.
  writeHeader(transitionsSeconds.length, utcOffsetsSeconds.length);
  for (final ts in transitionsSeconds) {
    final bd = ByteData(8)..setInt64(0, ts);
    builder.add(bd.buffer.asUint8List());
  }
  builder.add(typeIndices);
  for (final offset in utcOffsetsSeconds) {
    final bd = ByteData(6)..setInt32(0, offset);
    builder.add(bd.buffer.asUint8List());
  }
  builder.addByte(0);
  return builder.takeBytes();
}

void main() {
  Directory makeTemp(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  SyncService memorySync(
    Store store, {
    required SyncDrive Function(String refreshToken) connect,
    required Future<GoogleAccount> Function({Future<void>? cancel}) signIn,
  }) {
    final syncDb = sqlite3.openInMemory();
    addTearDown(syncDb.close);
    final sync = SyncService.loadFrom(
      DatabaseSettings(syncDb),
      DatabaseDisk(syncDb),
      store,
      connect: connect,
      signIn: signIn,
    );
    addTearDown(sync.dispose);
    return sync;
  }

  group('Android & Phone reliability (Batch 4)', () {
    test('upcomingReminders includes unmaterialized repeats & birthdays up to lookaheadDays with uid & dayStartHour', () {
      final store = Store.memory();
      addTearDown(store.close);
      final state = AppState(store, clock: () => DateTime(2026, 11, 6, 9));
      addTearDown(state.dispose);
      state.setDayStartHour(4);

      // Weekly repeat at 1:30 am (after midnight with dayStartHour == 4 -> shifts to calendar day Nov 14).
      state.addRepeat(
        'Late note',
        const RepeatRule.every(1, weeks: true),
        DateTime(2026, 11, 13),
        time: 90,
        reminders: Reminder.quarterBefore.bit,
      );
      // Birthday 14 days ahead.
      state.addRepeat(
        'Sam',
        const RepeatRule.yearly(1),
        DateTime(2026, 11, 20),
        birthday: true,
        reminders: Reminder.onTheDay.bit,
      );
      // Weekly repeat inside and beyond 60-day boundary (80 days out).
      final upcoming = state.upcomingReminders(limit: 200, lookaheadDays: 60);
      expect(upcoming, isNotEmpty);
      expect(upcoming.every((r) => r.uid.isNotEmpty), isTrue);
      // The first unmaterialized occurrence on Nov 13 with dayStartHour=4, time=1:30am fires on Nov 14 at 01:15.
      expect(
        upcoming.any((r) => r.title == 'Late note' && r.at == DateTime(2026, 11, 14, 1, 15)),
        isTrue,
      );
      expect(
        upcoming.any((r) => r.title == 'Sam' && r.at.year == 2026 && r.at.month == 11 && r.at.day == 20),
        isTrue,
      );
      expect(upcoming.any((r) => r.at.isAfter(DateTime(2027, 1, 6))), isFalse);

      final wider = state.upcomingReminders(limit: 200, lookaheadDays: 90);
      expect(wider.any((r) => r.at.isAfter(DateTime(2027, 1, 6))), isTrue);
    });

    test('PhoneUpdater streams APK to part file, verifies SHA-256, and surfaces installer permission retry', () async {
      final dir = makeTemp('eclipse_phone_upd');
      final apkBytes = utf8.encode('fake-apk-payload');
      final digest = sha256.convert(apkBytes).toString();
      var streamedTo = <String>[];
      var installed = false;
      var allowInstall = false;

      final updater = PhoneUpdater(
        installed: '1.0.0',
        installedBuild: 1,
        updatesDir: () async => dir,
        fetch: (uri) async => (
          200,
          utf8.encode(
            jsonEncode({
              'tag_name': 'v1.2.0',
              'body': '<!-- eclipse-build: 2 -->',
              'assets': [
                {
                  'name': 'Eclipse.apk',
                  'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v1.2.0/Eclipse.apk',
                  'digest': 'sha256:$digest',
                },
              ],
            }),
          ),
        ),
        downloadToFile: (uri, partFile) async {
          streamedTo.add(partFile.path);
          await partFile.writeAsBytes(apkBytes, flush: true);
        },
        install: (path) async {
          installed = File(path).existsSync();
          return allowInstall;
        },
      );

      await updater.check();
      expect(updater.available, '1.2.0');

      await updater.update();
      expect(streamedTo.single, endsWith('.part'));
      expect(installed, isTrue);
      expect(updater.error, contains('Settings'));

      allowInstall = true;
      await updater.update();
      expect(updater.error, isNull);
    });

    testWidgets('PhoneApp sign-in Cancel resets busy wait cleanly', (tester) async {
      final store = Store.memory();
      addTearDown(store.close);
      final drive = _FakeSyncDrive();
      late Completer<void> cancelObserved;
      final signInHold = Completer<GoogleAccount>();

      final sync = memorySync(
        store,
        connect: (_) => drive,
        signIn: ({cancel}) {
          cancelObserved = Completer<void>();
          cancel?.then((_) {
            if (!cancelObserved.isCompleted) cancelObserved.complete();
          });
          return signInHold.future;
        },
      );
      final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 6, 9))..endTour();
      addTearDown(state.dispose);

      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(PhoneApp(state: state, schedule: (_) async {}));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();
      expect(find.text('Waiting for Google…'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await cancelObserved.future;
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(sync.isOn, isFalse);

      sync.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('PhoneApp asks to move phone data into an empty different Google account', (tester) async {
      final store = Store.memory();
      addTearDown(store.close);
      store.setJournal('2026-11-06', 'Entry to transfer');
      final driveA = _FakeSyncDrive();
      final driveB = _FakeSyncDrive();
      const acctA = GoogleAccount(email: 'a@example.com', id: 'id-a', refreshToken: 'r-a');
      const acctB = GoogleAccount(email: 'b@example.com', id: 'id-b', refreshToken: 'r-b');

      var currentAcct = acctB;
      final sync = memorySync(
        store,
        connect: (token) => token == 'r-a' ? driveA : driveB,
        signIn: ({cancel}) async => currentAcct,
      );
      await sync.look(acctA);
      await sync.turnOn(acctA, join: false);
      await sync.turnOff();
      expect(sync.hasSynced, isTrue);

      final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 6, 9))..endTour();
      addTearDown(state.dispose);

      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(PhoneApp(state: state, schedule: (_) async {}));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();
      expect(find.text('Move this phone’s data into this account?'), findsOneWidget);

      // Cancelling leaves sync off.
      await tester.tap(find.text('Cancel').hitTestable());
      await tester.pumpAndSettle();
      expect(sync.isOn, isFalse);

      // Approving "Move" transfers cleanly into account B.
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move'));
      await tester.pumpAndSettle();
      expect(sync.isOn, isTrue);
      expect(sync.email, 'b@example.com');

      sync.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('PhoneApp disables Sync now while busy and warns before offline sign-out', (tester) async {
      final store = Store.memory();
      addTearDown(store.close);
      final drive = _FakeSyncDrive();
      const acct = GoogleAccount(email: 'a@example.com', id: 'id-a', refreshToken: 'r-a');
      final sync = memorySync(
        store,
        connect: (_) => drive,
        signIn: ({cancel}) async => acct,
      );
      await sync.look(acct);
      await sync.turnOn(acct, join: false);

      final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 6, 9))..endTour();
      addTearDown(state.dispose);

      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(PhoneApp(state: state, schedule: (_) async {}));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      // Pause Sync now while busy and verify button is disabled.
      final gate = Completer<void>();
      drive.listGate = gate;
      await tester.tap(find.text('Sync now'));
      await tester.pump();
      expect(find.text('Syncing…'), findsOneWidget);
      final busyBtn = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Syncing…'));
      expect(busyBtn.onPressed, isNull);
      drive.listGate = null;
      gate.complete();
      await tester.pumpAndSettle();

      // Make sync fail on sign-out, check Cancel vs Sign out anyway.
      drive.failList = true;
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out without syncing?'), findsOneWidget);
      expect(find.text('Sign out anyway'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sync.isOn, isTrue);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out anyway'));
      await tester.pumpAndSettle();
      expect(sync.isOn, isFalse);
      expect(find.text('Sign in with Google'), findsOneWidget);

      sync.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('PhoneApp flushes alarms on paused, skips reschedule on habit/theme edits, and opens tapped reminders', (
      tester,
    ) async {
      final store = Store.memory();
      addTearDown(store.close);
      final habit = store.addHabit(2026, 11, 'Read');
      final state = AppState(store, clock: () => DateTime(2026, 11, 6, 9))..endTour();
      addTearDown(state.dispose);
      state.addTodo(
        TodoScope.today,
        'Call dentist',
        time: 14 * 60,
        reminders: Reminder.quarterBefore.bit,
      );
      final uid = state.todos[TodoScope.today]!.single.uid!;

      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      var schedules = 0;
      await tester.pumpWidget(
        PhoneApp(
          state: state,
          schedule: (_) async {
            schedules++;
          },
        ),
      );
      await tester.pump();
      expect(schedules, 0, reason: 'debounced on init');

      // Pausing flushes the pending alarm schedule immediately without waiting 1s.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(schedules, 1);

      // Unrelated habit status and theme changes must not trigger rescheduling.
      schedules = 0;
      state.selectStatus(state.today, habit, HabitStatus.done);
      state.setTheme('Lunar Eclipse');
      await tester.pump(const Duration(seconds: 2));
      expect(schedules, 0);

      // Navigating to another tab then receiving openReminder switches back to Today and highlights task.
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'eclipse/phone',
        const StandardMethodCodec().encodeMethodCall(MethodCall('openReminder', uid)),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(state.found?.target, uid);
      expect(find.text('RITUALS'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('StartupErrorApp renders retry and phone update prompt when database is too new', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      var retried = false;
      await tester.pumpWidget(
        StartupErrorApp(
          error: StateError('disk issue'),
          phoneUpdater: PhoneUpdater(installed: '1.0.0'),
          onRetry: () => retried = true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retried, isTrue);

      final updater = PhoneUpdater(
        installed: '1.0.0',
        installedBuild: 1,
        fetch: (_) async => (
          200,
          utf8.encode(
            jsonEncode({
              'tag_name': 'v1.1.0',
              'body': '<!-- eclipse-build: 1 -->',
              'assets': [
                {
                  'name': 'Eclipse.apk',
                  'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v1.1.0/Eclipse.apk',
                  'digest': 'sha256:${sha256.convert([1]).toString()}',
                },
              ],
            }),
          ),
        ),
      );
      await updater.check();
      await tester.pumpWidget(
        StartupErrorApp(
          error: const DatabaseTooNewException(),
          phoneUpdater: updater,
          onRetry: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1.1.0'), findsOneWidget);
    });
  });

  group('Linux & Web reliability (Batch 4)', () {
    test('TzifZone parses transitions and SystemTimeZone detects symlink zone switches', () {
      final dir = makeTemp('eclipse_tzif');
      final utcTransition = DateTime.utc(2026, 4, 5, 1, 0).millisecondsSinceEpoch ~/ 1000;
      final zoneA = File('${dir.path}/zoneA')
        ..writeAsBytesSync(
          _buildTzifV2(
            transitionsSeconds: [utcTransition],
            typeIndices: [1],
            utcOffsetsSeconds: [10 * 3600, 9 * 3600],
          ),
        );
      final zoneB = File('${dir.path}/zoneB')
        ..writeAsBytesSync(
          _buildTzifV2(
            transitionsSeconds: const [],
            typeIndices: const [],
            utcOffsetsSeconds: [-5 * 3600],
          ),
        );

      final parsedA = TzifZone.parse(zoneA.readAsBytesSync())!;
      expect(parsedA.offsetAt(DateTime.utc(2026, 4, 5, 0, 59)), const Duration(hours: 10));
      expect(parsedA.offsetAt(DateTime.utc(2026, 4, 5, 1, 0)), const Duration(hours: 9));
      expect(TzifZone.parse(Uint8List.fromList([1, 2, 3])), isNull);

      final link = Link('${dir.path}/localtime')..createSync(zoneA.path);
      final sys = SystemTimeZone.forPath(link.path)..sync();
      final sampleUtc = DateTime.utc(2026, 5, 1, 12, 0);
      expect(sys.currentTime(utcNow: () => sampleUtc), DateTime(2026, 5, 1, 21, 0));

      link.deleteSync();
      link.createSync(zoneB.path);
      sys.sync();
      expect(sys.currentTime(utcNow: () => sampleUtc), DateTime(2026, 5, 1, 7, 0));
    });

    test('signInWithGoogle starts listening before openUrl runs and respects cancel', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        late String callbackStatus;
        await expectLater(
          () => signInWithGoogle(
            openUrl: (url) async {
              final authUri = Uri.parse(url);
              final redirect = Uri.parse(authUri.queryParameters['redirect_uri']!);
              final stateParam = authUri.queryParameters['state']!;
              final callbackUri = redirect.replace(queryParameters: {'error': 'access_denied', 'state': stateParam});
              final client = HttpClient();
              try {
                final req = await client.getUrl(callbackUri);
                final res = await req.close();
                await res.drain<void>();
                callbackStatus = '${res.statusCode}';
              } finally {
                client.close(force: true);
              }
            },
          ),
          throwsA(isA<DriveError>().having((e) => e.message, 'message', contains('cancelled'))),
        );
        expect(callbackStatus, '200');

        final cancel = Completer<void>();
        await expectLater(
          () => signInWithGoogle(
            cancel: cancel.future,
            openUrl: (_) async {
              cancel.complete();
            },
          ),
          throwsA(isA<DriveError>().having((e) => e.message, 'message', 'Sign-in cancelled.')),
        );
      }, _LoopbackHttpOverrides());
    });

    test('WebUpdater uses isNewer for update detection and reloads on update', () async {
      var reloaded = false;
      String? offered = '1.2.0';
      final updater = WebUpdater(
        running: '1.2.0',
        fetch: (_) async => (200, utf8.encode(jsonEncode({'version': offered}))),
        onReload: () => reloaded = true,
      );

      await updater.check();
      expect(updater.status, UpdateStatus.none);

      offered = '1.1.9';
      await updater.check();
      expect(updater.status, UpdateStatus.none);

      offered = '1.10.0';
      await updater.check();
      expect(updater.status, UpdateStatus.available);
      expect(updater.newVersion, '1.10.0');
      await updater.update();
      expect(reloaded, isTrue);
    });

    test('static reliability guards exist in web/sw.js and Linux install/runner scripts', () {
      final sw = File('web/sw.js').readAsStringSync();
      expect(sw, contains('__ECLIPSE_VERSION__'));
      expect(sw, contains('caches.delete'));
      expect(sw, contains('AbortController'));
      expect(sw, contains('skipWaiting'));

      final buildWeb = File('tool/build_web.sh').readAsStringSync();
      expect(buildWeb, isNot(contains('--no-tree-shake-icons')));

      final install = File('linux/install.sh').readAsStringSync();
      expect(install, contains('mktemp'));
      expect(install, matches(RegExp(r'^Exec="\$[a-zA-Z_][a-zA-Z0-9_]*"$', multiLine: true)));

      final installRelease = File('linux/install-release.sh').readAsStringSync();
      expect(installRelease, contains('ldconfig'));
      expect(installRelease, contains(r'libsqlite3\.so'));

      final appCc = File('linux/runner/my_application.cc').readAsStringSync();
      expect(appCc, contains('gtk_window_set_decorated(window, FALSE)'));
      expect(appCc, contains('g_application_get_is_remote'));
    });
  });

  group('Performance & state notification cleanup (Batch 5)', () {
    test('sendHttpRequest reuses pooled HttpClient across calls and downloadFile streams & guards redirects', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final payload = utf8.encode('streamed-content-1234567890');
      server.listen((req) async {
        req.response.persistentConnection = false;
        if (req.uri.path == '/ok') {
          req.response.write('ok');
          await req.response.close();
        } else if (req.uri.path == '/slow') {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          try {
            req.response.write('late');
            await req.response.close();
          } catch (_) {}
        } else if (req.uri.path == '/file') {
          req.response.add(payload);
          await req.response.close();
        } else if (req.uri.path == '/redir') {
          req.response.statusCode = HttpStatus.found;
          req.response.headers.set(HttpHeaders.locationHeader, '/file');
          await req.response.close();
        }
      });

      await HttpOverrides.runWithHttpOverrides(() async {
        final base = Uri.parse('http://127.0.0.1:${server.port}');
        final startClients = debugHttpClientsCreated;

        for (var i = 0; i < 3; i++) {
          final (status, body) = await sendHttpRequest('GET', base.resolve('/ok'));
          expect(status, 200);
          expect(utf8.decode(body), 'ok');
        }
        expect(debugHttpClientsCreated - startClients, 1);

        await expectLater(
          () => sendHttpRequest('GET', base.resolve('/slow'), timeout: const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()),
        );
        // Pool was not closed by timeout.
        final (statusAfter, _) = await sendHttpRequest('GET', base.resolve('/ok'));
        expect(statusAfter, 200);
        expect(debugHttpClientsCreated - startClients, 1);

        final dir = makeTemp('eclipse_dl');
        final dest = File('${dir.path}/out.bin');
        final dlStatus = await downloadFile(
          base.resolve('/redir'),
          dest,
          httpsOnlyRedirects: false,
        );
        expect(dlStatus, 200);
        expect(dest.readAsBytesSync(), payload);

        final blocked = File('${dir.path}/blocked.bin');
        await expectLater(
          () => downloadFile(base.resolve('/redir'), blocked, httpsOnlyRedirects: true),
          throwsA(isA<FormatException>()),
        );
      }, _LoopbackHttpOverrides());
    });

    testWidgets('YearHeatmap memoizes SQLite aggregation across theme cross-fades', (tester) async {
      final store = Store.memory();
      addTearDown(store.close);
      final h = store.addHabit(2026, 11, 'Read');
      final state = AppState(store, clock: () => DateTime(2026, 11, 6, 9))..endTour();
      addTearDown(state.dispose);

      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      YearHeatmap.debugComputes = 0;
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: ValueListenableBuilder<String?>(
            valueListenable: state.themeNotifier,
            builder: (context, themeName, _) => MaterialApp(
              theme: buildTheme(paletteNamed(themeName)),
              home: ThemeMorph(
                target: paletteNamed(themeName),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: SizedBox(
                      width: 1100,
                      child: YearHeatmap(year: 2026, rituals: {11: {h.id}}),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(YearHeatmap.debugComputes, 1);

      state.setTheme('Lunar Eclipse');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(YearHeatmap.debugComputes, 1);

      state.selectStatus(state.today, h, HabitStatus.done);
      await tester.pumpAndSettle();
      expect(YearHeatmap.debugComputes, 2);
    });

    test('AppState caches firstMonth, emits single post-write notifications, keeps habitsFor read-only, and isolates UI state', () {
      final store = Store.memory();
      addTearDown(store.close);
      store.addHabit(2026, 10, 'Read');
      final state = AppState(store, clock: () => DateTime(2026, 10, 23))..endTour();
      addTearDown(state.dispose);

      // firstMonth cache stays warm across unrelated notifications and invalidates on date-bearing writes.
      expect(state.firstMonth, (2026, 10));
      final lookupsBefore = state.debugFirstMonthLookups;
      state.setTheme('Lunar Eclipse');
      state.endTour();
      state.setRestWeekends(true);
      expect(state.firstMonth, (2026, 10));
      expect(state.debugFirstMonthLookups, lookupsBefore);

      state.setJournal(DateTime(2026, 9, 5), 'Earlier day');
      expect(state.firstMonth, (2026, 9));
      expect(state.debugFirstMonthLookups, lookupsBefore + 1);

      // Read-only habitsFor preview leaves SQLite tables untouched.
      final monthsBefore = store.raw.select('SELECT year, month FROM habit_months').length;
      final preview = state.habitsFor(2026, 8);
      expect(preview.map((h) => h.name), ['Read']);
      expect(state.isPreviewMonth(2026, 8), isTrue);
      expect(store.raw.select('SELECT year, month FROM habit_months').length, monthsBefore);

      // Single post-write notifications on settings setters.
      var notifications = 0;
      late int seenHour;
      late String? seenTheme;
      late bool seenFollow;
      late bool seenJournalFiles;
      state.addListener(() {
        notifications++;
        seenHour = state.dayStartHour;
        seenTheme = state.themeName;
        seenFollow = state.followNightLight;
        seenJournalFiles = state.keepsJournalFiles;
      });

      notifications = 0;
      state.setDayStartHour(4);
      expect(notifications, 1);
      expect(seenHour, 4);

      notifications = 0;
      state.setTheme('Sunrise');
      expect(notifications, 1);
      expect(seenTheme, 'Sunrise');

      notifications = 0;
      state.setFollowNightLight(false);
      expect(notifications, 1);
      expect(seenFollow, isFalse);

      notifications = 0;
      state.setKeepsJournalFiles(false);
      expect(notifications, 1);
      expect(seenJournalFiles, isFalse);

      // Per-AppState task UI state isolation (no global statics).
      final store2 = Store.memory();
      addTearDown(store2.close);
      final other = AppState(store2, clock: () => DateTime(2026, 10, 23));
      addTearDown(other.dispose);
      state.openedTasks.add((TodoScope.today, 42));
      state.draggingTask.value = true;
      expect(other.openedTasks, isEmpty);
      expect(other.draggingTask.value, isFalse);
    });
  });
}

class _LoopbackHttpOverrides extends HttpOverrides {}
