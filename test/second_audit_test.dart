// What the 10 Nov 2026 audit found: each test holds the behaviour the rest
// of the app, or the spec, implies.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/sqlite.dart' show Database, OpenMode, checkedCopyOf, offThread, sqlite3;
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_disk.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/widgets/backup_row.dart';
import 'package:eclipse/widgets/todo_panel.dart';

void main() {
  late Store store;
  late AppState state;
  late DateTime now;
  var opened = false;

  void open(DateTime at) {
    opened = true;
    now = at;
    store = Store.memory();
    state = AppState(store, clock: () => now);
    for (final scope in TodoScope.values) {
      for (final task in [...state.todos[scope]!]) {
        state.removeTodo(scope, task);
      }
    }
    state.hideUndoCard(state.shownRemoval ?? (throw StateError('no removal')));
  }

  tearDown(() {
    if (!opened) return;
    opened = false;
    state.dispose();
    store.close();
  });

  Future<void> show(WidgetTester tester) async {
    collapseAllTasks();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  Future<TestGesture> mouse(WidgetTester tester) async {
    final m = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await m.addPointer(location: Offset.zero);
    addTearDown(m.removePointer);
    return m;
  }

  /// A monthly repeat with a checklist, next due on the 20th: beyond the
  /// week, so Further ahead shows its time before it's made.
  void packEveryMonth() {
    state.addTodo(TodoScope.today, 'Pack');
    state.setTodoSubtasks(TodoScope.today, state.todos[TodoScope.today]!.single, [
      const TodoSubtask('Passport'),
      const TodoSubtask('Tickets'),
    ]);
    state.makeRepeating(
      TodoScope.today,
      state.todos[TodoScope.today]!.single,
      'Pack',
      const RepeatRule.monthly(20),
      start: DateTime(2026, 11, 20),
    );
  }

  testWidgets('ticking a step of a repeat’s time in Further ahead, not made yet, ticks it', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    packEveryMonth();
    expect(state.todos[TodoScope.month], isEmpty, reason: 'its time on the 20th isn’t made yet');
    await show(tester);

    final row = find.ancestor(of: find.text('Pack'), matching: find.byType(TaskRow)).first;
    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Expand subtasks')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Passport'));
    await tester.pumpAndSettle();

    final made = state.todos[TodoScope.month]!.single;
    expect(made.uid, endsWith('@2026-11-20'));
    expect({for (final s in made.subtasks) s.text: s.done}, {'Passport': true, 'Tickets': false});
    expect(state.repeats.single.subtasks.every((s) => !s.done), isTrue, reason: 'the times after start unticked');
  });

  testWidgets('stopping a repeat and moving its time in one edit does both', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    state.addRepeat('Water the plants', const RepeatRule.every(1), DateTime(2026, 11, 3));
    await show(tester);

    final row = find.ancestor(of: find.text('Water the plants'), matching: find.byType(TaskRow)).first;
    final m = await mouse(tester);
    await m.moveTo(tester.getCenter(find.descendant(of: row, matching: find.text('Water the plants'))));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Edit task')));
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    await tester.tap(find.descendant(of: dialog, matching: find.byTooltip('Stop repeating')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: dialog, matching: find.text('5')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: dialog, matching: find.text('Save')));
    await tester.pumpAndSettle();

    final left = [
      for (final scope in TodoScope.values)
        for (final item in state.todos[scope]!)
          if (item.text == 'Water the plants') item,
    ];
    expect(left.map((t) => t.dueDate), [DateTime(2026, 11, 5)], reason: 'the one time left, on its new day');
    // Ended, it makes no more times.
    now = DateTime(2026, 11, 12, 10);
    state.checkDate();
    expect([
      for (final scope in TodoScope.values)
        for (final item in state.todos[scope]!)
          if (item.text == 'Water the plants') item,
    ], hasLength(1));
  });

  testWidgets('looking back, Further ahead counts its days from the day shown', (tester) async {
    open(DateTime(2026, 11, 3, 10));
    state.addTodo(TodoScope.month, 'Dentist', dueDate: DateTime(2026, 11, 20));
    now = DateTime(2026, 11, 25, 10);
    state.checkDate();
    await show(tester);
    state.showDay(DateTime(2026, 11, 3));
    await tester.pumpAndSettle();

    expect(find.text('Dentist'), findsOneWidget, reason: 'as the 3rd had it');
    expect(find.text('In 17 days'), findsOneWidget);
    expect(find.textContaining('In -'), findsNothing);
  });

  test('a set logged on an earlier day keeps the days and the chart in order', () {
    open(DateTime(2026, 11, 10, 10));
    final log = state.training;
    final bench = log.createExercise('Bench press', MuscleGroup.chest, bodyweight: false);
    void lift(DateTime day, double kg) {
      log.addToDay(day, bench);
      log.updateSet(log.session(day).single.$2.single, weight: kg, reps: 5);
    }

    lift(DateTime(2026, 11, 8), 60);
    lift(DateTime(2026, 11, 10), 70);
    // Remembered late: a day between the two.
    lift(DateTime(2026, 11, 9), 65);

    expect(log.loggedDays, ['2026-11-10', '2026-11-09', '2026-11-08']);
    expect(log.points().values.single.map((p) => p.day.day), [
      8,
      9,
      10,
    ], reason: 'oldest first, as the chart draws them');
    // The next set starts from the latest day's weight, not the last one typed.
    log.addToDay(DateTime(2026, 11, 11), bench);
    expect(log.session(DateTime(2026, 11, 11)).single.$2.single.weight, 70);
  });

  test('a holiday set on another computer reaches what’s planned here', () {
    opened = true;
    now = DateTime(2026, 11, 3, 10);
    store = Store.memory();
    final settings = sqlite3.openInMemory();
    addTearDown(settings.close);
    final sync = SyncService.loadFrom(DatabaseSettings(settings), DatabaseDisk(settings), store);
    final engine = sync.engine..claimAll();
    state = AppState(store, sync: sync, clock: () => now);
    state.addRepeat('Gym', const RepeatRule.every(1), DateTime(2026, 11, 3));
    final repeat = state.repeats.single;
    final from = DateTime(2026, 11, 11);
    expect(state.comingOccurrence(repeat, from), from);
    final planned = state.todosRevision;

    // The laptop, in step with this one, books a fortnight off.
    final laptop = Store.memory();
    addTearDown(laptop.close);
    final there = SyncEngine(laptop, 'laptop');
    engine.flush();
    there.mergeAll([(engine.changesSince(0).values.expand((d) => d).toList(), 'pc')]);
    laptop.setSetting('holidays', encodeHolidays([(start: DateTime(2026, 11, 11), end: DateTime(2026, 11, 24))]));
    there.flush();
    final sent = [
      for (final r in there.changesSince(0).values.expand((d) => d))
        if (r[0] == 'holiday' || r[0] == 'setting') r,
    ];
    final incoming = engine.mergeAll([(sent, 'laptop')]);
    expect(incoming.rows.map((r) => r.$1).toSet(), {'holiday', 'setting'}, reason: 'no task was touched');
    // What each round does with what it brought in.
    sync.onIncoming!(incoming);

    expect(state.holidays, hasLength(1));
    expect(state.todosRevision, greaterThan(planned), reason: 'the lists are worked out again');
    expect(state.comingOccurrence(repeat, from), DateTime(2026, 11, 25), reason: 'paused through the holiday');
  });

  test('saved copies and the last sync give the time as the rest of the app does', () {
    final saved = DriveBackup(
      id: 'x',
      name: 'backup_pc_before-restore.db',
      day: null,
      saved: DateTime(2026, 11, 9, 14, 5),
      from: 'this computer',
    );
    expect(BackupRow.describe(saved, DateTime(2026, 11, 10)).$2, 'Saved 9 November, 2:05 pm, in Google Drive');
    expect(BackupRow.describe(saved, DateTime(2026, 11, 10)).$2, isNot(contains('14:05')));
    // The same clock a task's time reads on.
    expect(clockLabel(14 * 60 + 5), '2:05 pm');
  });

  test('the daily copy and the copy for Drive are made away from the UI', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse-off-thread');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/app.db');
    addTearDown(store.close);
    store.setJournal('2026-11-10', 'Written today');
    _here = true;
    expect(await offThread(store.raw, _onThisIsolate), isFalse, reason: 'a file is read on an isolate of its own');
    expect(await offThread(Store.memory().raw, _onThisIsolate), isTrue, reason: 'one in memory has no file to open');

    final copy = File('${dir.path}/copy.db')..writeAsBytesSync((await offThread(store.raw, checkedCopyOf))!);
    final saved = sqlite3.open(copy.path, mode: OpenMode.readOnly);
    addTearDown(saved.close);
    expect(saved.select('SELECT text FROM journal').single['text'], 'Written today');

    final backups = Backups(Directory('${dir.path}/backups'));
    await backups.daily(store, DateTime(2026, 11, 10));
    expect(Backups.isHealthy(backups.list().single.file), isTrue);
  });

  testWidgets('YearHeatmap ignores entries before addedOn and on unscheduled weekdays', (tester) async {
    // 2026-11-10 is Tuesday.
    open(DateTime(2026, 11, 10, 10));
    state.dispose();
    for (final h in store.monthHabits(2026, 11)) {
      store.removeHabit(2026, 11, h.id);
    }
    final mondayHabit = store.addHabit(2026, 11, 'Monday review', addedOn: DateTime(2026, 11, 9));
    // Scheduled only on Mondays (2026-11-09 is Monday).
    store.setHabitDays(2026, 11, mondayHabit.id, [(null, weekdayBit(DateTime.monday))]);
    // Entry before addedOn (2026-11-02 is Monday, before Nov 9).
    store.setEntry('2026-11-02', mondayHabit.id, HabitStatus.missed);
    // Entry on an unscheduled weekday (2026-11-10 is Tuesday).
    store.setEntry('2026-11-10', mondayHabit.id, HabitStatus.missed);
    // Valid scheduled entry on addedOn Monday.
    store.setEntry('2026-11-09', mondayHabit.id, HabitStatus.done);
    state = AppState(store, clock: () => now)..endTour();
    state.showYear();
    await show(tester);

    expect(find.text('THE YEAR  ·  100% OF RITUALS DONE'), findsOneWidget);
  });
}

/// Set on the test's isolate only; another isolate starts with it unset.
var _here = false;

bool _onThisIsolate(Database _) => _here;
