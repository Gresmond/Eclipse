import 'dart:convert';

import 'package:eclipse/data/google_drive.dart';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/smart_add.dart';
import 'package:eclipse/training.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/widgets/search_dialog.dart';
import 'package:eclipse/widgets/todo_panel.dart';

void main() {
  final day = DateTime(2026, 11, 19);
  late Store store;
  late AppState state;

  setUp(() {
    store = Store.memory();
    store.addHabit(2026, 11, 'Read');
    state = AppState(store, clock: () => DateTime(2026, 11, 19, 12));
  });
  tearDown(() {
    state.dispose();
    store.close();
  });

  test('Drive changes retain untouched files and follow pagination through deletions', () async {
    final pages = <String>[];
    final drive = AppDataFolder(
      '',
      accessToken: () async => ('token', 3600),
      send: (method, uri, {body, type, bearer}) async {
        pages.add(uri.queryParameters['pageToken']!);
        final reply = pages.length == 1
            ? {
                'changes': [
                  {'fileId': 'old', 'removed': true},
                ],
                'nextPageToken': 'b',
              }
            : {
                'changes': [
                  {
                    'fileId': 'new',
                    'file': {'id': 'new', 'name': 'added', 'modifiedTime': 'v2'},
                  },
                ],
                'newStartPageToken': 'c',
              };
        return (200, Uint8List.fromList(utf8.encode(jsonEncode(reply))));
      },
    );
    final (token, files) = await drive.inventory('a', const [
      DriveFile(id: 'keep', name: 'keep', modified: 'v1'),
      DriveFile(id: 'old', name: 'old', modified: 'v1'),
    ]);
    expect(pages, ['a', 'b']);
    expect(token, 'c');
    expect(files.map((f) => f.id), ['keep', 'new']);
  });

  test('incomplete Drive changes rebuild the inventory before removing local files', () async {
    final drive = AppDataFolder(
      '',
      accessToken: () async => ('token', 3600),
      send: (method, uri, {body, type, bearer}) async {
        final reply = switch (uri.path) {
          '/drive/v3/changes' => {
            'changes': [{'fileId': 'keep'}],
            'newStartPageToken': 'partial',
          },
          '/drive/v3/changes/startPageToken' => {'startPageToken': 'fresh'},
          '/drive/v3/files' => {
            'files': [{'id': 'keep', 'name': 'preserved', 'modifiedTime': 'v1'}],
          },
          _ => throw StateError('Unexpected request to ${uri.path}'),
        };
        return (200, Uint8List.fromList(utf8.encode(jsonEncode(reply))));
      },
    );
    final (token, files) = await drive.inventory('old', const []);
    expect((token, files.single.id), ('fresh', 'keep'));
  });

  testWidgets('a focused command field accepts arrow navigation and Enter', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    state.endTour();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(SearchDialog), matching: find.byType(TextField));
    await tester.enterText(field, 'Show');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(state.viewMonth, day.month);
  });

  test('smart quick add carries weekday, time and location into a task', () {
    final parsed = parseQuickTask('Dentist fri 2:30pm @Clinic', day);
    expect(parsed, (name: 'Dentist', day: DateTime(2026, 11, 20), minutes: 870, location: 'Clinic', repeat: null, until: null, reminders: 0));
  });

  test('a spoken fortnightly task saves its start, time, place and alert', () {
    state.quickAddTodo(TodoScope.today,
        'Put the bins out every second Thursday starting next week at 8pm @Home and remind me 20 minutes before');
    final series = store.repeats().single;
    expect(series.text, 'Put the bins out');
    expect(series.start, DateTime(2026, 11, 26));
    expect(series.rule.on(DateTime(2026, 12, 3), series.start), isFalse);
    expect(series.rule.on(DateTime(2026, 12, 10), series.start), isTrue);
    expect((series.time, series.location, series.reminders), (1200, 'Home', Reminder.twentyBefore.bit));
    expect(Reminder.twentyBefore.at(series.start, series.time), DateTime(2026, 11, 26, 19, 40));
  });

  test('weekday series stops on the inclusive end date after its future start', () {
    state.quickAddTodo(TodoScope.today, 'Check mail every weekday starting next week until Friday at noon');
    final series = store.repeats().single;
    expect((series.text, series.start, series.until), ('Check mail', DateTime(2026, 11, 23), DateTime(2026, 11, 27)));
    expect(series.on(DateTime(2026, 11, 27)), isTrue);
    expect(series.on(DateTime(2026, 11, 30)), isFalse);
    final invalid = 'Check daily starting 25/12/2026 until 24/12/2026';
    expect(parseQuickTask(invalid, day).name, invalid);
  });

  test('spoken places preserve names, addresses and ordinary uses of at or in', () {
    for (final (input, name, place) in [
      ('Get milk at coles tomorrow at noon', 'Get milk', 'coles'),
      ('Dinner at Mum’s place', 'Dinner', 'Mum’s place'),
      ('Meet at 42 King Street at 7pm', 'Meet', '42 King Street'),
      ('Meet at 7pm at North Adelaide Library', 'Meet', 'North Adelaide Library'),
      ('Swim in the pool', 'Swim', 'the pool'),
      ('Look at the school timetable', 'Look at the school timetable', null),
      ('Reply in writing', 'Reply in writing', null),
      ('Buy at least three apples', 'Buy at least three apples', null),
      ('Call in two weeks', 'Call', null),
      ('Call at 7', 'Call at 7', null),
    ]) {
      final result = parseQuickTask(input, day);
      expect((result.name, result.location), (name, place), reason: input);
    }
  });

  test('weekday lists cross weekends and year boundaries', () {
    final parsed = parseQuickTask('Train every Mon, Wed and Fri at noon', DateTime(2027, 12, 31),
        defaultDay: DateTime(2028, 1, 1));
    expect(parsed.name, 'Train');
    expect(parsed.minutes, 720);
    expect(parsed.repeat, const RepeatRule.weekly({1, 3, 5}));
    expect(parsed.day, DateTime(2028, 1, 3));
    expect(parseQuickTask('Check monthly starting on 29 February 2028', day).day, DateTime(2028, 2, 29));
  });

  test('recurrence, time, reminder and multiword place work in every clause order', () {
    Iterable<List<String>> orders(List<String> clauses) sync* {
      if (clauses.isEmpty) yield [];
      for (final clause in clauses) {
        for (final rest in orders(clauses.where((c) => c != clause).toList())) {
          yield [clause, ...rest];
        }
      }
    }
    for (final order in orders(['every two weeks', 'starting in a fortnight', 'at 19:35',
      'in North Adelaide', 'remind me 20 mins before'])) {
      final text = 'Train ${order.join(' ')}';
      final result = parseQuickTask(text, day);
      expect((result.name, result.day, result.minutes, result.location, result.repeat, result.reminders),
          ('Train', DateTime(2026, 12, 3), 1175, 'North Adelaide', const RepeatRule.every(2, weeks: true), 16),
          reason: text);
    }
  });

  test('invalid dates and unsupported instructions keep the full title', () {
    for (final text in [
      'Check due on 31/2 at noon',
      'Call the second Thursday of every month',
      'Call every 0 days',
      'Call tomorrow @Home and remind me 7 minutes before',
      'Call tomorrow and remind me 15 minutes before',
      'Email sam@example.com',
    ]) {
      final parsed = parseQuickTask(text, day);
      expect(parsed.name, text);
      expect(parsed.repeat, isNull);
      expect(parsed.reminders, 0);
    }
  });

  test('quick add consumes connectors and matches both parts of Friday 13th', () {
    final friday = DateTime(2027, 8, 13);
    for (final input in [
      'Call Marge Simpson due on Friday 13th at 7:35 pm',
      'Call Marge Simpson at 7:35 pm on Friday the 13th',
      'Call Marge Simpson on 13 August 2027 at 19:35',
      'Call Marge Simpson at 7:35 p.m. due 13/8/2027',
    ]) {
      expect(parseQuickTask(input, day), (name: 'Call Marge Simpson', day: friday, minutes: 1175, location: null, repeat: null, until: null, reminders: 0));
    }
    expect(parseQuickTask('Meet at home', day).location, 'home');
    expect(parseQuickTask('Review due on 31/2', day).day, isNull);
    expect(parseQuickTask('Ring tomorrow at midnight', day).minutes, 0);
  });

  testWidgets('both planning footers accept a spoken date on Enter', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    state.endTour();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    for (final card in [WeekCard, FurtherAheadCard]) {
      final field = find.descendant(of: find.byType(card), matching: find.widgetWithText(TextField, 'Add task')).last;
      await tester.enterText(field, 'Call Marge from $card due on Friday 13th at 7:35 pm');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final task = state.todos[TodoScope.month]!.singleWhere((t) => t.text == 'Call Marge from $card');
      expect((task.dueDate, task.dueTime), (DateTime(2027, 8, 13), 1175));
      expect(find.byTooltip('Next month').hitTestable(), findsNothing);
    }
  });

  test('numeric progress survives reload and only reaching the goal counts for the week', () {
    final habit = state.habits.single;
    state.setRitualGoal(2026, 11, habit, weekly: 3, target: 10, unit: 'pages');
    state.recordAmount(day, habit, 6);
    expect(state.amountOn(day, habit), 6);
    expect(state.weeklyDone(day, habit), 0);
    state.recordAmount(day, habit, 12);
    expect(state.statusOf(day, habit), HabitStatus.done);
    expect(state.weeklyDone(day, habit), 1);
    expect(store.raw.select('SELECT target,unit FROM month_habits').single['unit'], 'pages');
  });

  test('routine reapplication preserves performed sets and does not duplicate planned sets', () {
    final log = state.training;
    final exercise = log.createExercise('Weighted chin-ups', MuscleGroup.back, bodyweight: true);
    log.addSet(day, exercise, reps: 5);
    final performed = log.session(day).single.$2.single;
    log.setDetails(performed, 'Strict', 8, addedWeight: 10);
    log.weighIn(day, 80);
    expect(log.weeklyVolume(day)[MuscleGroup.back], (1, 450.0));
    log.saveRoutine('Pull', day);
    final next = DateTime(2026, 11, 20);
    final uid = log.routines.single.$1;
    log.applyRoutine(uid, next);
    log.applyRoutine(uid, next);
    final row = log.session(next).single.$2.single;
    expect(row.weight, 10);
    expect(row.reps, 0);
    expect(log.session(day).single.$2.single.note, 'Strict');
  });
}
