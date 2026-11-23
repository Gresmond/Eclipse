import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/year_heatmap.dart';
import 'package:eclipse/screens/year_insights.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Store.yearTaskStats', () {
    test('reconstructs fresh and carried task stats while excluding today, birthdays and deleted tasks', () {
      final store = Store.memory();
      addTearDown(store.close);
      final today = DateTime(2026, 10, 10);

      // Task 1: added Oct 1, carried Oct 2, carried Oct 3 and ticked Oct 3.
      final carriedTask = store.addTodo(TodoScope.today, DateTime(2026, 10, 1), 'Write report');
      store.carryForward(TodoScope.today, '2026-10-02', day: DateTime(2026, 10, 2));
      store.carryForward(TodoScope.today, '2026-10-03', day: DateTime(2026, 10, 3));
      store.setTodoDone(carriedTask.id, true, day: DateTime(2026, 10, 3));

      // Task 2: added & completed on Oct 1 (fresh done).
      store.addTodo(TodoScope.today, DateTime(2026, 10, 1), 'Buy coffee', done: true);

      // Birthday on Oct 1: must be excluded from task counts.
      store.editPastTodo(
        TodoScope.today,
        DateTime(2026, 10, 1),
        text: 'Sam',
        done: false,
        birthday: true,
      );

      // Deleted snapshot on Oct 2: must be excluded from Oct 2 onwards.
      final deleted = store.addTodo(TodoScope.today, DateTime(2026, 10, 2), 'Mistake');
      store.deleteTodo(deleted.id, day: DateTime(2026, 10, 2));

      // Task added on today (Oct 10): must not appear in past year stats.
      store.addTodo(TodoScope.today, today, 'Still in progress today');

      final stats = store.yearTaskStats(2026, today);
      expect(stats['2026-10-01'], (
        planned: 2,
        done: 1,
        unfinished: 1,
        freshPlanned: 2,
        freshDone: 1,
        carriedPlanned: 0,
        carriedDone: 0,
      ));
      expect(stats['2026-10-02'], (
        planned: 1,
        done: 0,
        unfinished: 1,
        freshPlanned: 0,
        freshDone: 0,
        carriedPlanned: 1,
        carriedDone: 0,
      ));
      expect(stats['2026-10-03'], (
        planned: 1,
        done: 1,
        unfinished: 0,
        freshPlanned: 0,
        freshDone: 0,
        carriedPlanned: 1,
        carriedDone: 1,
      ));
      expect(stats[dateKey(today)], isNull);
    });
  });

  group('YearView full-width heatmap and cross-app PATTERNS card', () {
    testWidgets('YearHeatmap spans full card width, caps square height on wide screens and shows no slip sidebar', (
      tester,
    ) async {
      final store = Store.memory();
      addTearDown(store.close);
      store.addHabit(2026, 10, 'Read', addedOn: DateTime(2026, 10, 1));
      final state = AppState(store, clock: () => DateTime(2026, 11, 2, 10));
      addTearDown(state.dispose);
      state.showYear();

      for (final size in [const Size(1440, 900), const Size(1920, 1080), const Size(2560, 1440)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(EclipseApp(state: state));
        await tester.pumpAndSettle();

        expect(find.text('WHERE THINGS SLIP'), findsNothing);
        expect(find.text('PATTERNS'), findsOneWidget);

        final tileWidth = tester.getSize(find.byType(YearHeatmap)).width;
        final gridPaint = find.descendant(
          of: find.byType(YearHeatmap),
          matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null && w.size.width > 300),
        );
        final gridSize = tester.getSize(gridPaint);
        expect(gridSize.width, greaterThan(tileWidth - 110));
        // Capped at cell <= 20px: max height = 7 * 20 + 6 * 3 = 158px.
        expect(gridSize.height, lessThanOrEqualTo(158.0));

        // Top three cards still sit cleanly above PATTERNS on initial viewport before scrolling.
        final sleepTop = tester.getTopLeft(find.textContaining('SLEEP SCHEDULE')).dy;
        final patternsTop = tester.getTopLeft(find.text('PATTERNS')).dy;
        expect(sleepTop, lessThan(size.height));
        expect(patternsTop, greaterThan(sleepTop));
      }
    });

    testWidgets('PATTERNS empty state renders cleanly below Sleep schedule', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final store = Store.memory();
      addTearDown(store.close);
      store.addHabit(2026, 10, 'Read');
      final state = AppState(store, clock: () => DateTime(2026, 10, 15, 10));
      addTearDown(state.dispose);
      state.showYear();

      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();

      expect(find.text('PATTERNS'), findsOneWidget);
      expect(
        find.text('Patterns across rituals, sleep and tasks will appear here once there’s enough logged data.'),
        findsOneWidget,
      );
    });

    test('detects cross-app wins and slips across sleep, rituals and tasks while ignoring rest days', () {
      final store = Store.memory();
      addTearDown(store.close);

      // Start on Oct 5 (Mon) through Nov 13 (Fri): 6 weeks = 30 Mon-Fri workdays, 10 weekend days.
      final read = store.addHabit(2026, 10, 'Read', addedOn: DateTime(2026, 10, 1));
      final stretch = store.addHabit(2026, 10, 'Stretch', addedOn: DateTime(2026, 10, 1));
      final octSleep = store.sleepHabits(2026, 10);
      final novSleep = store.sleepHabits(2026, 11);
      final riseOct = octSleep[SleepItem.riseEarly.index];
      final earlyOct = octSleep[SleepItem.sleepEarly.index];
      final riseNov = novSleep[SleepItem.riseEarly.index];
      final earlyNov = novSleep[SleepItem.sleepEarly.index];
      expect(riseNov.id, riseOct.id);
      expect(earlyNov.id, earlyOct.id);

      final workdays = <DateTime>[];
      for (var d = DateTime(2026, 10, 5); !d.isAfter(DateTime(2026, 11, 13)); d = DateTime(d.year, d.month, d.day + 1)) {
        final key = dateKey(d);
        if (d.weekday >= DateTime.saturday) {
          // Rest weekends: even if marked missed, must never drive slip findings.
          store.setEntry(key, read.id, HabitStatus.missed);
          store.setEntry(key, stretch.id, HabitStatus.missed);
          continue;
        }
        workdays.add(d);
      }

      // Pattern design across the 30 Mon-Fri workdays:
      // - Heavy task days happen on index % 3 == 0 (5 tasks each, finishing only 2/5 -> 40%, and Read missed -> 0%!).
      //   Light task days (2 tasks each, finishing 2/2 -> 100%, Read done).
      // - Previous workday Sleep Early was done on Mon & Tue (good sleep -> next day Rise Early = done, Stretch = done, tasks = 100%);
      //   missed on Wed & Thu (poor sleep -> next day Rise Early = missed, Stretch = missed).
      // - Carried-over tasks: 12 carried instances left unfinished vs fresh tasks mostly finished.
      for (var i = 0; i < workdays.length; i++) {
        final d = workdays[i];
        final key = dateKey(d);
        final sleptEarlyYesterday = i > 0 && d.weekday != DateTime.monday && workdays[i - 1].weekday <= DateTime.tuesday;

        // Sleep on d: Mon & Tue hit Sleep Early; Wed-Fri miss Sleep Early.
        store.setEntry(key, earlyOct.id, d.weekday <= DateTime.tuesday ? HabitStatus.done : HabitStatus.missed);
        // Morning Rise Early follows night-before Sleep Early.
        final goodMorning = i == 0 || workdays[i - 1].weekday <= DateTime.tuesday;
        store.setEntry(key, riseOct.id, goodMorning ? HabitStatus.done : HabitStatus.missed);

        // Stretch succeeds when yesterday had Sleep Early (or Rise Early today), misses on Fri completely.
        final stretchDone = d.weekday != DateTime.friday && (sleptEarlyYesterday || d.weekday == DateTime.monday);
        store.setEntry(key, stretch.id, stretchDone ? HabitStatus.done : HabitStatus.missed);

        // Heavy task days on i % 3 == 0 squeeze Read & leave tasks undone.
        final isHeavy = i % 3 == 0;
        store.setEntry(key, read.id, isHeavy ? HabitStatus.missed : HabitStatus.done);

        final count = isHeavy ? 5 : 2;
        final doneCount = isHeavy ? 1 : 2;
        for (var t = 0; t < count; t++) {
          final task = store.addTodo(TodoScope.today, d, 'Task $i-$t', done: t < doneCount);
          if (isHeavy && t >= doneCount && i + 1 < workdays.length && t == doneCount) {
            // Carry one unfinished task onto next workday and leave it unfinished again so carried rate drops.
            store.carryForward(TodoScope.today, dateKey(workdays[i + 1]), day: workdays[i + 1]);
            store.editPastTodo(TodoScope.today, workdays[i + 1], item: task, done: false);
          }
        }
      }

      final state = AppState(store, clock: () => DateTime(2026, 11, 14, 10));
      addTearDown(state.dispose);
      final ritualsByMonth = <int, Set<int>>{
        10: {read.id, stretch.id},
        11: {read.id, stretch.id},
      };

      final insights = computeYearInsights(state, 2026, ritualsByMonth);
      final leads = insights.map((i) => i.lead).toList();
      expect(insights.any((i) => i.tone == InsightTone.win), isTrue, reason: 'Expected wins in $leads');
      expect(insights.any((i) => i.tone == InsightTone.slip), isTrue, reason: 'Expected slips in $leads');
      expect(insights.length, lessThanOrEqualTo(8));
      expect(leads.join('\n'), isNot(contains('Saturdays')));
      expect(leads.join('\n'), isNot(contains('Sundays')));

      // Verify specific cross-app links are detected in the candidate set / top insights.
      expect(
        leads.any(
          (l) =>
              l.contains('Sleep Early') ||
              l.contains('Rise Early') ||
              l.contains('Heavy task days') ||
              l.contains('Overpacked days') ||
              l.contains('Clearing your tasks') ||
              l.contains('Carried-over'),
        ),
        isTrue,
        reason: 'Expected cross-app link in $leads',
      );
    });

    testWidgets('YearInsightsCard mixes wins and slips on screen and memoizes recomputes', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final store = Store.memory();
      addTearDown(store.close);
      final stretch = store.addHabit(2026, 10, 'Stretch', addedOn: DateTime(2026, 10, 1));
      final early = store.sleepHabits(2026, 10)[SleepItem.sleepEarly.index];

      // 4 full weeks Mon-Fri (20 days): Sleep Early done Mon-Tue lifts next day's Stretch (Tue-Wed);
      // misses Wed-Thu and next day's Stretch misses (Thu-Fri).
      for (var d = 5; d <= 30; d++) {
        final day = DateTime(2026, 10, d);
        if (day.weekday >= DateTime.saturday) continue;
        final key = dateKey(day);
        final slept = day.weekday <= DateTime.tuesday;
        store.setEntry(key, early.id, slept ? HabitStatus.done : HabitStatus.missed);
        final goodNextDay = day.weekday >= DateTime.tuesday && day.weekday <= DateTime.wednesday;
        store.setEntry(key, stretch.id, goodNextDay ? HabitStatus.done : HabitStatus.missed);
      }

      final state = AppState(store, clock: () => DateTime(2026, 11, 2, 10));
      addTearDown(state.dispose);
      state.showYear();
      YearInsightsCard.debugComputes = 0;

      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();

      expect(YearInsightsCard.debugComputes, 1);
      expect(find.text('PATTERNS'), findsOneWidget);
      expect(find.text('Works'), findsOneWidget);
      expect(find.text('Slips'), findsOneWidget);
      expect(find.textContaining('Sleep Early lifts next-day rituals', findRichText: true), findsOneWidget);
      expect(find.textContaining('Stretch slips on', findRichText: true), findsOneWidget);

      // Theme change should NOT recompute YearInsightsCard SQLite aggregation.
      state.setTheme('Lunar Eclipse');
      await tester.pumpAndSettle();
      expect(YearInsightsCard.debugComputes, 1);

      // Adding a Today task increments todosRevision and refreshes insights once.
      state.addTodo(TodoScope.today, 'New task');
      await tester.pump();
      expect(YearInsightsCard.debugComputes, 2);
    });
  });
}
