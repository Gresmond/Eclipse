import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:crypto/crypto.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync_disk.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/phone/phone_app.dart';
import 'package:eclipse/phone/phone_platform.dart';
import 'package:eclipse/screens/startup_error.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/widgets/rolling_number.dart';
import 'package:eclipse/widgets/tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:flutter_test/flutter_test.dart';

void main() {
  (Store, AppState) make() {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 6, 9));
    addTearDown(state.dispose);
    return (store, state);
  }

  Future<void> show(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(PhoneApp(state: state, schedule: (_) async {}));
    await tester.pumpAndSettle();
  }

  testWidgets('phone draws while opening storage and offers retry if storage is unavailable', (tester) async {
    const bgChannel = MethodChannel('eclipse/background');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(bgChannel, (call) async => call.method == 'hasUi' ? true : null);
    addTearDown(() => messenger.setMockMethodCallHandler(bgChannel, null));

    final directory = Completer<Directory>();
    final startup = phoneMain(supportDirectory: () => directory.future);
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    directory.completeError(const FileSystemException('Storage unavailable'));
    await startup;
    await tester.pump();
    expect(tester.widget<StartupErrorApp>(find.byType(StartupErrorApp)).onRetry, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in-app capture previews and saves a timed recurring task', (tester) async {
    final (store, state) = make();
    await show(tester, state);
    await tester.tap(find.byTooltip('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Train every Monday at 8pm at Gym and remind me 20 minutes before');
    await tester.pump();
    expect(find.textContaining('Gym · Every Mon · Remind Mon 9 Nov at 7:40 pm'), findsOneWidget);
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    final series = store.repeats().single;
    expect((series.text, series.start, series.time), ('Train', DateTime(2026, 11, 9), 1200));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('tapping a ritual goes round its marks', (tester) async {
    final (_, state) = make();
    await show(tester, state);
    final read = state.habits.single;
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, read), HabitStatus.done);
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, read), HabitStatus.missed);
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, read), HabitStatus.other);
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, read), HabitStatus.none);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a task is added for tomorrow, and one for today can be ticked', (tester) async {
    final (_, state) = make();
    await show(tester, state);
    await tester.tap(find.byTooltip('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    final added = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Buy milk');

    await tester.dragUntilVisible(find.text('Buy milk'), find.byType(ListView), const Offset(0, -200));
    await tester.tap(find.text('Buy milk'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.singleWhere((t) => t.id == added.id).done, isTrue);

    await tester.tap(find.byTooltip('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Call Sam');
    await tester.tap(find.text('Tomorrow'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.map((t) => t.text), isNot(contains('Call Sam')));
    expect(state.todos.values.expand((list) => list).map((t) => t.text), contains('Call Sam'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Plan, Training and Journal share the desktop records', (tester) async {
    final (store, state) = make();
    state.addTodo(TodoScope.tomorrow, 'Pack gym shoes');
    final exercise = state.training.createExercise('Squat', MuscleGroup.quads, bodyweight: false);
    state.training.addSet(DateTime(2026, 11, 5), exercise, reps: 8, loggedWeight: 62.25);
    state.training.addToDay(state.today, exercise);
    store.setSetting('restSeconds', '0');
    await show(tester, state);
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.text('Pack gym shoes'), findsOneWidget);
    await tester.tap(find.text('Training'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log set'));
    await tester.pumpAndSettle();
    expect(find.text('62.25'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).last, '9');
    await tester.tap(find.widgetWithText(FilledButton, 'Log set'));
    await tester.pumpAndSettle();
    expect(state.training.session(state.today).single.$2.single.reps, 9);
    expect(find.text('PB'), findsOneWidget);
    await tester.tap(find.text('Journal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Added one rep.');
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(state.journalOf(state.today), 'Added one rep.');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('sign-in waits for the phone to come back from the browser', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    var back = false;
    unawaited(whenBackFromBrowser().then((_) => back = true));
    await tester.pump();
    expect(back, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(back, isTrue);
  });

  test('upcoming reminders list what\'s still to go off, soonest first', () {
    final (_, state) = make();
    state.addTodo(
      TodoScope.today,
      'Dentist',
      dueDate: state.today,
      time: 15 * 60,
      reminders: Reminder.hourBefore.bit | Reminder.quarterBefore.bit,
    );
    final upcoming = state.upcomingReminders();
    expect(upcoming.map((r) => r.at), [DateTime(2026, 11, 6, 14), DateTime(2026, 11, 6, 14, 45)]);
    expect(upcoming.first.title, 'Dentist');
    expect(upcoming.first.body, 'In 1 hour, at 3:00 pm');
  });

  testWidgets('off-day and future-added rituals are hidden on phone Today', (tester) async {
    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    // 2026-11-06 is a Friday. Add a Monday-only ritual and one added tomorrow.
    final mondayOnly = store.addHabit(2026, 11, 'Monday sprint');
    store.setHabitDays(2026, 11, mondayOnly.id, [(null, weekdayBit(DateTime.monday))]);
    store.addHabit(2026, 11, 'Starts tomorrow', addedOn: DateTime(2026, 11, 7));
    final state = AppState(store, clock: () => DateTime(2026, 11, 6, 9));
    addTearDown(state.dispose);
    expect(state.habits, hasLength(3));

    await show(tester, state);

    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Monday sprint'), findsNothing);
    expect(find.text('Starts tomorrow'), findsNothing);
    final ritualsHeader = find.ancestor(of: find.text('RITUALS'), matching: find.byType(TileHeader));
    expect(find.descendant(of: ritualsHeader, matching: find.text(' OF 1')), findsOneWidget);
    expect(
      tester.widget<RollingNumber>(find.descendant(of: ritualsHeader, matching: find.byType(RollingNumber))).value,
      0,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('phone tasks show metadata and subtasks, and swipe-to-delete can be undone', (tester) async {
    final (_, state) = make();
    state.addTodo(TodoScope.today, 'Dentist', time: 10 * 60, location: 'Rundle Mall');
    final timed = state.todos[TodoScope.today]!.last;
    state.setTodoSubtasks(TodoScope.today, timed, [const TodoSubtask('Bring card')]);
    state.addRepeat('Vitamins', const RepeatRule.every(1), DateTime(2026, 11, 6));
    await show(tester, state);

    await tester.dragUntilVisible(find.text('Dentist'), find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.text('10:00 am'), findsOneWidget);
    expect(find.text('Rundle Mall'), findsOneWidget);
    expect(find.text('Bring card'), findsOneWidget);
    expect(find.byIcon(Icons.repeat_rounded), findsOneWidget);

    await tester.tap(find.text('Bring card'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.firstWhere((t) => t.id == timed.id).subtasks.single.done, isTrue);

    await tester.drag(find.text('Dentist'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Dentist'), findsNothing);
    expect(find.text('Removed “Dentist”'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Dentist'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('phone settings shows Days controls and opens Holiday dialog without overflow', (tester) async {
    final (_, state) = make();
    await show(tester, state);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('DAYS'), findsOneWidget);
    expect(find.text('Weekends as rest days'), findsNothing);
    expect(find.text('Smart quick-add'), findsNothing);
    expect(find.text('New day starts at'), findsOneWidget);
    expect(find.text('Holidays'), findsOneWidget);
    expect(find.text('Reduce motion'), findsOneWidget);

    await tester.tap(find.text('4am'));
    await tester.pumpAndSettle();
    expect(state.dayStartHour, 4);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Add a holiday'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('phone settings Reduce motion disables animations across PhoneApp', (tester) async {
    final (store, state) = make();
    await show(tester, state);

    expect(state.reduceMotion, isFalse);
    expect(MediaQuery.disableAnimationsOf(tester.element(find.byType(Scaffold).first)), isFalse);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Reduce motion'), 200);
    expect(find.text('Reduce motion'), findsOneWidget);

    await tester.tap(find.text('Reduce motion'));
    await tester.pumpAndSettle();

    expect(state.reduceMotion, isTrue);
    expect(store.setting('reduceMotion'), '1');
    expect(MediaQuery.disableAnimationsOf(tester.element(find.byType(Scaffold).last)), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('repeating task swipe confirms scope, weekly ritual omits streak, and long-press opens action sheet', (
    tester,
  ) async {
    final (store, state) = make();
    final weekly = store.addHabit(2026, 11, 'Long run');
    state.setRitualGoal(2026, 11, weekly, weekly: 3);
    final savedWeekly = state.habits.firstWhere((h) => h.id == weekly.id);
    state.selectStatus(DateTime(2026, 11, 5), savedWeekly, HabitStatus.done);
    state.selectStatus(state.today, savedWeekly, HabitStatus.done);
    state.addRepeat('Daily pills', const RepeatRule.every(1), state.today);
    await show(tester, state);

    expect(find.text('Long run · 2/3 this week'), findsOneWidget);
    expect(find.text('2'), findsNothing);

    await tester.longPress(find.text('Long run · 2/3 this week'));
    await tester.pumpAndSettle();
    expect(find.text('Mark not done'), findsOneWidget);
    await tester.tap(find.text('Mark not done'));
    await tester.pumpAndSettle();
    expect(state.statusOf(state.today, weekly), HabitStatus.missed);

    await tester.ensureVisible(find.text('Daily pills'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Daily pills'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Remove repeating task'), findsOneWidget);
    await tester.tap(find.text('Only this one'));
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.any((t) => t.text == 'Daily pills'), isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Plan uses formatted headings and Workout edits sets, weighted bodyweight, and rest timer', (
    tester,
  ) async {
    final (store, state) = make();
    final laterDay = DateTime(2026, 11, 20);
    state.addTodo(TodoScope.month, 'Haircut', dueDate: laterDay);
    state.addTodo(TodoScope.month, 'Alex birthday', dueDate: laterDay, birthday: true);
    final pullup = state.training.createExercise('Pull-ups', MuscleGroup.back, bodyweight: true);
    state.training.addToDay(state.today, pullup);
    store.setSetting('restSeconds', '60');
    const channel = MethodChannel('eclipse/phone');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final restCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startRest' || call.method == 'cancelRest') restCalls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await show(tester, state);

    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.text('Fri 20 Nov'), findsOneWidget);
    expect(find.text('2026-11-20'), findsNothing);
    expect(find.text('Alex birthday'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide birthdays'));
    await tester.pumpAndSettle();
    expect(find.text('Alex birthday'), findsNothing);
    await tester.tap(find.byTooltip('Show birthdays'));
    await tester.pumpAndSettle();
    expect(find.text('Alex birthday'), findsOneWidget);

    await tester.tap(find.text('Training'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log set'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '10');
    await tester.enterText(find.byType(TextFormField).last, '8');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Log set'));
    await tester.pumpAndSettle();
    expect(find.text('+10 kg × 8 reps'), findsOneWidget);
    expect(find.text('Rest 1:00'), findsOneWidget);
    expect(restCalls.single.method, 'startRest');
    expect(restCalls.single.arguments, isA<int>());

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Rest timer · 1:00'), findsOneWidget);
    expect(restCalls.last.method, 'cancelRest');

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Rest 1:00'), findsOneWidget);
    expect(restCalls.last.method, 'startRest');

    await tester.tap(find.text('+10 kg × 8 reps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('+10 kg × 8 reps'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

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

  test('PhoneUpdater validates URL, SHA-256 checksum, +build, offline retries, .part cleanup, and install permission fallback', () async {
    final dir = makeTemp('eclipse-batch1-upd');
    final updatesDir = Directory(p.join(dir.path, 'updates'));
    final apkBytes = utf8.encode('fake-apk-payload');
    final apkSha = sha256.convert(apkBytes).toString();
    var now = DateTime(2026, 11, 19, 10);

    var call = 0;
    var downloadUrl = 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/Eclipse.apk';
    var releaseDigest = 'sha256:$apkSha';
    var releaseBody = '<!-- eclipse-build: 2 -->';
    var tag = 'v26.11.10';
    var installResult = false;
    var downloadCalls = 0;

    final updater = PhoneUpdater(
      installed: '26.11.10+1',
      fetch: (uri) async {
        call++;
        if (call == 1) return (503, const <int>[]);
        if (uri.path.endsWith('/SHA256SUMS')) {
          return (200, utf8.encode('$apkSha  Eclipse.apk\n'));
        }
        return (
          200,
          utf8.encode(
            jsonEncode({
              'tag_name': tag,
              'body': releaseBody,
              'assets': [
                {
                  'name': 'Eclipse.apk',
                  'browser_download_url': downloadUrl,
                  if (releaseDigest.isNotEmpty) 'digest': releaseDigest,
                },
                {
                  'name': 'SHA256SUMS',
                  'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/SHA256SUMS',
                },
              ],
            }),
          ),
        );
      },
      downloadToFile: (uri, part) async {
        downloadCalls++;
        await part.writeAsBytes(apkBytes, flush: true);
      },
      install: (_) async => installResult,
      updatesDir: () async => updatesDir,
      now: () => now,
    );

    await updater.check();
    expect(updater.available, isNull);
    await updater.check();
    expect(updater.available, '26.11.10', reason: 'same version with newer +build 2 > 1 is offered');

    await updater.update();
    expect(updater.error, contains('Settings'));
    expect(downloadCalls, 1);
    expect(File(p.join(updatesDir.path, 'Eclipse.apk')).existsSync(), isTrue);

    installResult = true;
    await updater.update();
    expect(updater.error, isNull);
    expect(downloadCalls, 1);

    now = now.add(const Duration(hours: 4));
    downloadUrl = 'http://evil.example/Eclipse.apk';
    final badUrlUpdater = PhoneUpdater(
      installed: '26.11.9+1',
      fetch: (_) async => (
        200,
        utf8.encode(
          jsonEncode({
            'tag_name': 'v26.11.10',
            'body': '<!-- eclipse-build: 1 -->',
            'assets': [
              {'name': 'Eclipse.apk', 'browser_download_url': downloadUrl, 'digest': releaseDigest},
            ],
          }),
        ),
      ),
      updatesDir: () async => updatesDir,
    );
    await badUrlUpdater.check();
    expect(badUrlUpdater.available, isNull);

    final mismatchDir = Directory(p.join(dir.path, 'updates2'));
    final mismatchUpdater = PhoneUpdater(
      installed: '26.11.9+1',
      fetch: (_) async => (
        200,
        utf8.encode(
          jsonEncode({
            'tag_name': 'v26.11.10',
            'body': '<!-- eclipse-build: 1 -->',
            'assets': [
              {
                'name': 'Eclipse.apk',
                'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/Eclipse.apk',
                'digest': 'sha256:${'0' * 64}',
              },
            ],
          }),
        ),
      ),
      downloadToFile: (uri, part) async => part.writeAsBytes(apkBytes, flush: true),
      install: (_) async => true,
      updatesDir: () async => mismatchDir,
    );
    await mismatchUpdater.check();
    await mismatchUpdater.update();
    expect(mismatchUpdater.error, contains('checksum'));
    expect(File(p.join(mismatchDir.path, 'Eclipse.apk.part')).existsSync(), isFalse);
    expect(File(p.join(mismatchDir.path, 'Eclipse.apk')).existsSync(), isFalse);

    final sumsDir = Directory(p.join(dir.path, 'updates3'));
    final sumsUpdater = PhoneUpdater(
      installed: '26.11.9+1',
      fetch: (uri) async {
        if (uri.path.endsWith('/SHA256SUMS')) return (200, utf8.encode('$apkSha  Eclipse.apk\n'));
        return (
          200,
          utf8.encode(
            jsonEncode({
              'tag_name': 'v26.11.10',
              'body': '<!-- eclipse-build: 1 -->',
              'assets': [
                {
                  'name': 'Eclipse.apk',
                  'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/Eclipse.apk',
                },
                {
                  'name': 'SHA256SUMS',
                  'browser_download_url': 'https://github.com/Gresmond/Eclipse/releases/download/v26.11.10/SHA256SUMS',
                },
              ],
            }),
          ),
        );
      },
      downloadToFile: (uri, part) async => part.writeAsBytes(apkBytes, flush: true),
      install: (_) async => true,
      updatesDir: () async => sumsDir,
    );
    await sumsUpdater.check();
    await sumsUpdater.update();
    expect(sumsUpdater.error, isNull);
    expect(File(p.join(sumsDir.path, 'Eclipse.apk')).existsSync(), isTrue);
  });

  test('upcomingReminders includes unmaterialized repeats & birthdays up to lookaheadDays with uid & dayStartHour', () {
    final store = Store.memory();
    addTearDown(store.close);
    final state = AppState(store, clock: () => DateTime(2026, 11, 6, 9));
    addTearDown(state.dispose);
    state.setDayStartHour(4);

    state.addRepeat(
      'Late note',
      const RepeatRule.every(1, weeks: true),
      DateTime(2026, 11, 13),
      time: 90,
      reminders: Reminder.quarterBefore.bit,
    );
    state.addRepeat(
      'Sam',
      const RepeatRule.yearly(1),
      DateTime(2026, 11, 20),
      birthday: true,
      reminders: Reminder.onTheDay.bit,
    );
    final upcoming = state.upcomingReminders(limit: 200, lookaheadDays: 60);
    expect(upcoming, isNotEmpty);
    expect(upcoming.every((r) => r.uid.isNotEmpty), isTrue);
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
    final streamedTo = <String>[];
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
    final drive = _PhoneFakeDrive();
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
    final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 6, 9));
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
    final driveA = _PhoneFakeDrive();
    final driveB = _PhoneFakeDrive();
    const acctA = GoogleAccount(email: 'a@example.com', id: 'id-a', refreshToken: 'r-a');
    const acctB = GoogleAccount(email: 'b@example.com', id: 'id-b', refreshToken: 'r-b');

    final currentAcct = acctB;
    final sync = memorySync(
      store,
      connect: (token) => token == 'r-a' ? driveA : driveB,
      signIn: ({cancel}) async => currentAcct,
    );
    await sync.look(acctA);
    await sync.turnOn(acctA, join: false);
    await sync.turnOff();
    expect(sync.hasSynced, isTrue);

    final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 6, 9));
    addTearDown(state.dispose);

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(PhoneApp(state: state, schedule: (_) async {}));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();
    expect(find.text('Move this phone’s data into this account?'), findsOneWidget);

    await tester.tap(find.text('Cancel').hitTestable());
    await tester.pumpAndSettle();
    expect(sync.isOn, isFalse);

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
    final drive = _PhoneFakeDrive();
    const acct = GoogleAccount(email: 'a@example.com', id: 'id-a', refreshToken: 'r-a');
    final sync = memorySync(
      store,
      connect: (_) => drive,
      signIn: ({cancel}) async => acct,
    );
    await sync.look(acct);
    await sync.turnOn(acct, join: false);

    final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 6, 9));
    addTearDown(state.dispose);

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(PhoneApp(state: state, schedule: (_) async {}));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

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
    final state = AppState(store, clock: () => DateTime(2026, 11, 6, 9));
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

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(schedules, 1);

    schedules = 0;
    state.selectStatus(state.today, habit, HabitStatus.done);
    state.setTheme('Lunar Eclipse');
    await tester.pump(const Duration(seconds: 2));
    expect(schedules, 0);

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

  testWidgets('PhoneApp pauses timers and skips empty sync on paused, sends dirty changes, and resumes', (
    tester,
  ) async {
    final store = Store.memory();
    addTearDown(store.close);
    final drive = _PhoneFakeDrive();
    const acct = GoogleAccount(email: 'a@example.com', id: 'id-a', refreshToken: 'r-a');
    final sync = memorySync(
      store,
      connect: (_) => drive,
      signIn: ({cancel}) async => acct,
    );
    await sync.look(acct);
    await sync.turnOn(acct, join: false);
    final initialCalls = drive.listCalls;

    final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 6, 9));
    addTearDown(state.dispose);

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(PhoneApp(state: state, schedule: (_) async {}));
    await tester.pumpAndSettle();

    void setLifecycle(List<AppLifecycleState> states) {
      for (final s in states) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    // Pausing with no local changes does not sync and stops periodic polling.
    setLifecycle([AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    await tester.pump();
    expect(drive.listCalls, initialCalls);

    await tester.pump(const Duration(minutes: 4));
    expect(drive.listCalls, initialCalls);

    // Resuming restarts polling and triggers an immediate sync.
    setLifecycle([AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pump();
    expect(drive.listCalls, greaterThan(initialCalls));
    final afterResume = drive.listCalls;

    // Pausing with unsent local changes triggers sendChanges().
    state.addTodo(TodoScope.today, 'Unsent change');
    setLifecycle([AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    await tester.pump();
    expect(drive.listCalls, greaterThan(afterResume));

    sync.stop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Workout rest timer pauses ticker in background and resyncs deadline on resume', (tester) async {
    final (store, state) = make();
    final squat = state.training.createExercise('Squat', MuscleGroup.quads, bodyweight: false);
    state.training.addToDay(state.today, squat);
    store.setSetting('restSeconds', '60');

    const channel = MethodChannel('eclipse/phone');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    int? storedDeadline;
    var deadlineReads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startRest':
          storedDeadline = call.arguments as int;
        case 'restDeadline':
          deadlineReads++;
          return storedDeadline;
        case 'cancelRest':
          storedDeadline = null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await show(tester, state);
    await tester.tap(find.text('Training'));
    await tester.pumpAndSettle();
    final readsBeforeStart = deadlineReads;

    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(storedDeadline, isNotNull);
    expect(find.textContaining('Rest '), findsOneWidget);

    void setLifecycle(List<AppLifecycleState> states) {
      for (final s in states) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    // Pause stops the local countdown ticker and does not poll restDeadline.
    setLifecycle([AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    await tester.pump(const Duration(seconds: 5));
    expect(deadlineReads, readsBeforeStart);

    // Simulate time passing natively before resuming.
    storedDeadline = DateTime.now().add(const Duration(seconds: 15)).millisecondsSinceEpoch;
    setLifecycle([AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pump();
    await tester.pump();
    expect(deadlineReads, readsBeforeStart + 1);
    expect(find.text('Rest 0:15'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(storedDeadline, isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('headless phoneMain skips UI until attachUi is invoked', (tester) async {
    final oldFlutterError = FlutterError.onError;
    final oldPlatformError = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = oldFlutterError;
      PlatformDispatcher.instance.onError = oldPlatformError;
    });

    final root = makeTemp('eclipse-headless-phone');
    final supportDir = Directory(p.join(root.path, 'support'));
    final docsDir = Directory(p.join(root.path, 'docs'));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const bgChannel = MethodChannel('eclipse/background');
    final bgCalls = <String>[];
    messenger.setMockMethodCallHandler(bgChannel, (call) async {
      bgCalls.add(call.method);
      if (call.method == 'hasUi') return false;
      if (call.method == 'ready') return false;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(bgChannel, null));

    await tester.runAsync(
      () => phoneMain(supportDirectory: () async => supportDir, documentsDirectory: () async => docsDir),
    );
    await tester.pump();

    expect(bgCalls, containsAll(['hasUi', 'ready']));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(PhoneApp), findsNothing);

    await messenger.handlePlatformMessage(
      'eclipse/background',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('attachUi')),
      (_) {},
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(PhoneApp), findsOneWidget);
    final mountedState = tester.widget<PhoneApp>(find.byType(PhoneApp)).state;

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() async {
      await mountedState.backedUp;
      await mountedState.flushFiles();
    });
    mountedState.dispose();
    mountedState.store.close();
  });
}

class _PhoneFakeDrive implements SyncDrive {
  final files = <String, (String, List<int>, int)>{};
  int _seq = 1;
  int listCalls = 0;
  bool failList = false;
  Completer<void>? listGate;

  @override
  Future<List<DriveFile>> list() async {
    listCalls++;
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
