import 'dart:convert';

import 'package:eclipse/data/google_drive.dart';

import 'package:archive/archive.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/personal_export.dart';
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
    expect(parsed, (name: 'Dentist', day: DateTime(2026, 11, 20), minutes: 870, location: 'Clinic'));
  });

  test('quick add consumes connectors and matches both parts of Friday 13th', () {
    final friday = DateTime(2027, 8, 13);
    for (final input in [
      'Call Marge Simpson due on Friday 13th at 7:35 pm',
      'Call Marge Simpson at 7:35 pm on Friday the 13th',
      'Call Marge Simpson on 13 August 2027 at 19:35',
      'Call Marge Simpson at 7:35 p.m. due 13/8/2027',
    ]) {
      expect(parseQuickTask(input, day), (name: 'Call Marge Simpson', day: friday, minutes: 1175, location: null));
    }
    expect(parseQuickTask('Meet at home', day).name, 'Meet at home');
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

  test('export round-trips journal Unicode and includes timed calendar events', () {
    const note = '今日, read "Eclipse"';
    store.raw.execute('INSERT INTO journal(day,text) VALUES(?,?)', [dateKey(day), note]);
    store.raw.execute(
      "INSERT INTO todos(uid,scope,period,text,since,due_date,due_time) VALUES('d','today','','Dentist, check','2026-11-19','2026-11-20','14:30')",
    );
    final archive = ZipDecoder().decodeBytes(exportBundle(store, day, generated: day));
    String contents(String path) => utf8.decode(archive.findFile(path)!.content as List<int>);
    expect(contents('journal/2026-11-19.md'), note);
    expect(jsonDecode(contents('eclipse.json'))['tables']['journal'].single['text'], note);
    expect(contents('csv/journal.csv'), contains('""Eclipse""'));
    expect(contents('calendar.ics'), contains('DTSTART:20261120T143000\r\nSUMMARY:Dentist\\, check'));
  });
}
