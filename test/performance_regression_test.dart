import 'dart:convert';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/updates.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/util/lru_cache.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:eclipse/widgets/lazy_motion.dart';
import 'package:eclipse/screens/month_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Store store;
  late AppState state;
  setUp(() {
    store = Store.memory();
    store.addHabit(2026, 10, 'Review habit');
    state = AppState(store, clock: () => DateTime(2026, 10, 26));
  });
  tearDown(() {
    state.dispose();
    store.close();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
  }

  testWidgets('task edits rebuild zero month cells, and a mark rebuilds just its cell', (tester) async {
    for (var i = 1; i < 20; i++) {
      state.addHabit(2026, 10, 'Review habit $i');
    }
    state.showMonth(10);
    await show(tester);
    var cells = 0;
    debugOnRebuildDirtyWidget = (element, built) {
      if (element.widget.runtimeType.toString() == 'StatusCell') cells++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    state.addTodo(TodoScope.today, 'Unrelated task');
    await tester.pump();
    expect(cells, 0);
    state.selectStatus(state.today, state.habits.first, HabitStatus.done);
    await tester.pump();
    expect(cells, 1);
    await tester.pumpAndSettle();
    cells = 0;
    state.setTheme('Lunar Eclipse');
    await tester.pumpAndSettle();
    expect(cells, 0, reason: 'theme frames repaint the grid without rebuilding its cells');
  });

  testWidgets('a long week builds only the rows on screen', (tester) async {
    for (var i = 0; i < 200; i++) {
      state.addTodo(TodoScope.today, 'Review task $i');
    }
    state.addTodo(TodoScope.week, 'Untouched planner', dueDate: DateTime(2026, 10, 29));
    await show(tester);
    // Task names are rich text, a time going before them.
    final labels = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('Review task '));
    expect(labels.evaluate().length, allOf(greaterThan(0), lessThan(40)));
    var rows = 0;
    debugOnRebuildDirtyWidget = (element, built) {
      if (element.widget.runtimeType.toString() == '_TodoRow') rows++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    state.toggleTodo(state.todos[TodoScope.today]!.first);
    await tester.pump();
    expect(rows, lessThan(40));
    await tester.pumpAndSettle();
    debugOnRebuildDirtyWidget = null;
    final scroll = find.descendant(of: find.byType(WeekCard), matching: find.byType(Scrollable));
    tester.state<ScrollableState>(scroll.first).position.jumpTo(700);
    await tester.pumpAndSettle();
    expect(labels.evaluate().length, lessThan(40));
    expect(find.text('Review task 1'), findsNothing);
  });

  testWidgets('rapid navigation does not build an invisible month grid', (tester) async {
    await show(tester);
    state.showMonth(10);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(MonthView), findsNothing);
    expect(find.text('Daily rituals'), findsOneWidget, reason: 'the visible outgoing page is retained');
    state.showToday();
    await tester.pumpAndSettle();
    expect(find.byType(MonthView), findsNothing);
    state.showMonth(10);
    await tester.pumpAndSettle();
    expect(find.byType(MonthView), findsOneWidget);
  });

  testWidgets('lazy motion settles, releases its ticker and supports another interaction', (tester) async {
    Future<void> showValue(double value) => tester.pumpWidget(
      LazyMotion(
        value: value,
        duration: const Duration(milliseconds: 100),
        curve: Curves.linear,
        transition: (animation, child) => FadeTransition(opacity: animation, child: child),
        child: const SizedBox(width: 20, height: 20),
      ),
    );
    double opacity() => tester.widget<FadeTransition>(find.byType(FadeTransition)).opacity.value;
    await showValue(1);
    await showValue(0.5);
    await tester.pump(const Duration(milliseconds: 25));
    expect(opacity(), allOf(greaterThan(0.5), lessThan(1)));
    await showValue(1);
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    expect(tester.binding.transientCallbackCount, 0);
    await showValue(0.6);
    await tester.pumpAndSettle();
    expect(opacity(), 0.6);
    expect(tester.binding.transientCallbackCount, 0);
  });

  test('historical lists share a day load and invalidate after a correction', () {
    final yesterday = DateTime(2026, 10, 25);
    state.addTodo(TodoScope.today, 'Yesterday task', day: yesterday);
    final before = state.todosOn(TodoScope.today, yesterday);
    state.todosOn(TodoScope.week, yesterday);
    expect(state.todosOn(TodoScope.today, yesterday), same(before));
    state.editTodo(TodoScope.today, before.single, 'Corrected', null, day: yesterday);
    final after = state.todosOn(TodoScope.today, yesterday);
    expect(after, same(state.todosOn(TodoScope.today, yesterday)));
    expect(after.single.text, 'Corrected');
    expect(after, isNot(same(before)));
  });

  test('sparse streak computation preserves weekend and other-day semantics', () {
    final habit = state.habits.first;
    store.setEntry('2010-01-01', habit.id, HabitStatus.done);
    store.setEntry('2026-10-22', habit.id, HabitStatus.done);
    store.setEntry('2026-10-23', habit.id, HabitStatus.other);
    expect(store.streaks(habit.id, DateTime(2026, 10, 26), restWeekends: true), (1, 1));
    expect(store.streaks(habit.id, DateTime(2026, 10, 26), restWeekends: false), (0, 1));
    store.setEntry('2026-10-26', habit.id, HabitStatus.done);
    expect(store.streaks(habit.id, DateTime(2026, 10, 26), restWeekends: true), (2, 2));
  });

  test('LRU eviction and clearing release resources exactly once', () {
    final disposed = <String>[];
    final cache = LruCache<int, String>(2, onEvict: disposed.add);
    cache[1] = 'first';
    cache[2] = 'second';
    expect(cache[1], 'first');
    cache[3] = 'third';
    expect(cache.keys, orderedEquals([1, 3]));
    expect(disposed, ['second']);
    cache.clear();
    expect(disposed, ['second', 'first', 'third']);
    expect(cache, isEmpty);
  });

  for (final extension in ['.exe', '.dmg']) {
    test('desktop $extension updates compare version and build', () async {
      Future<ReleaseUpdater> updater(int installed, int available) async {
        final value = ReleaseUpdater(
          '26.10.1',
          installedRelease: installed,
          assetExtension: extension,
          fetch: (_) async => (
            200,
            utf8.encode(
              jsonEncode({
                'tag_name': 'v26.10.1',
                'body': '<!-- eclipse-build: $available -->',
                'assets': [
                  {'name': 'Eclipse$extension', 'browser_download_url': 'https://example.com/download'},
                ],
              }),
            ),
          ),
        );
        await value.check();
        return value;
      }

      final newer = await updater(43, 44);
      expect(newer.status, UpdateStatus.available);
      newer.dispose();
      final same = await updater(44, 44);
      expect(same.status, UpdateStatus.none);
      same.dispose();
      final older = await updater(44, 43);
      expect(older.status, UpdateStatus.none);
      older.dispose();
    });
  }

  test('journal saves are ordered and shutdown flushes the final draft', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse_journal_queue_');
    final disk = Store.memory();
    final files = JournalFiles(dir);
    final local = AppState(disk, journalFiles: files, clock: () => DateTime(2026, 10, 26));
    addTearDown(() {
      local.dispose();
      dir.deleteSync(recursive: true);
    });
    final day = local.today;
    final first = local.setJournal(day, 'First');
    final second = local.setJournal(day, 'Second');
    expect(local.journalOf(day), 'Second', reason: 'SQLite is written immediately');
    await Future.wait([first, second]);
    expect(files.fileFor(day).readAsStringSync(), contains('Second'));
    local.draftJournal(day, 'Final draft');
    await local.shutdown();
    expect(files.fileFor(day).readAsStringSync(), contains('Final draft'));
  });

  test('journal edits during a folder move cannot be overwritten by the copy', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse_journal_move_');
    final disk = Store.memory();
    final files = JournalFiles(Directory('${dir.path}/old'));
    final local = AppState(disk, journalFiles: files, clock: () => DateTime(2026, 10, 26));
    addTearDown(() {
      local.dispose();
      disk.close();
      dir.deleteSync(recursive: true);
    });
    await local.setJournal(local.today, 'Before');
    final moving = local.useJournalFolder(Directory('${dir.path}/new'));
    await Future<void>.delayed(Duration.zero);
    final writing = local.setJournal(local.today, 'After');
    await moving;
    await writing;
    await local.flushFiles();
    expect(files.fileFor(local.today).readAsStringSync(), contains('After'));
  });

  test('async sync preparation saves intervening drafts immediately before merge', () async {
    final dir = Directory.systemTemp.createTempSync('eclipse_sync_prepare_');
    final remote = Store.memory();
    addTearDown(() {
      remote.close();
      dir.deleteSync(recursive: true);
    });
    final theirs = SyncEngine(remote, 'remote');
    final ours = SyncEngine(store, 'local');
    remote.setJournal('2026-10-26', 'Original');
    theirs.claimAll();
    ours.mergeAll([(theirs.changesSince(0).values.expand((rows) => rows), 'Remote')]);
    remote.setJournal('2026-10-26', 'Remote edit');
    theirs.flush();
    await SyncFolder(dir, 'remote', 'Remote').write(theirs, 0);
    var saves = 0;
    final folder = SyncFolder(dir, 'local', 'Local');
    await folder.readAsync(
      ours,
      beforeMerge: () {
        saves++;
        store.setJournal('2026-10-26', 'Local draft');
      },
    );
    expect(saves, 1);
    expect(store.journal('2026-10-26'), contains('Local draft'));
    expect(store.journal('2026-10-26'), contains('Remote edit'));
    await folder.readAsync(ours, canMerge: () => false, beforeMerge: () => fail('stopped sync must not merge'));
  });

  test('Windows packaged metadata supplies the installed build', () {
    final dir = Directory.systemTemp.createTempSync('eclipse_metadata_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/version').writeAsStringSync('26.10.1');
    File('${dir.path}/package-release').writeAsStringSync('44');
    final updater = ReleaseUpdater.forWindows('${dir.path}/eclipse.exe')!;
    expect(updater.installedRelease, 44);
    updater.dispose();
  });
}
