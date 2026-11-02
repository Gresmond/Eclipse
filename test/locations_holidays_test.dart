import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/search.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<List<Object?>> _sent(SyncEngine e) => e.changesSince(0).values.expand((v) => v).toList();

void main() {
  Store memory() {
    final store = Store.memory();
    addTearDown(store.close);
    return store;
  }

  test('a task keeps its location through edits, repeats, search and sync', () {
    final store = memory();
    store.addHabit(2026, 11, 'Read');
    var now = DateTime(2026, 11, 2, 9);
    final state = AppState(store, clock: () => now);
    addTearDown(state.dispose);
    state.addTodo(TodoScope.today, 'Dentist', time: 10 * 60, location: '  Rundle Mall ');
    var item = state.todos[TodoScope.today]!.single;
    expect(item.location, 'Rundle Mall');
    expect(SearchIndex(store).search('rundle').single.text, 'Dentist');

    state.editTodo(TodoScope.today, item, 'Dentist', null, time: 10 * 60);
    expect(state.todos[TodoScope.today]!.single.location, isNull, reason: 'cleared in the editor');

    item = state.todos[TodoScope.today]!.single;
    state.makeRepeating(TodoScope.today, item, 'Gym', const RepeatRule.every(1), location: 'Pulteney St');
    expect(state.todos[TodoScope.today]!.single.location, 'Pulteney St');
    now = DateTime(2026, 11, 3, 9);
    state.checkDate();
    expect(state.todos[TodoScope.today]!.map((t) => t.location).toSet(), {'Pulteney St'});

    final sender = SyncEngine(store, 'a')..claimAll();
    final other = memory();
    SyncEngine(other, 'b')
      ..clearForJoining()
      ..mergeAll([(_sent(sender), 'a')]);
    expect(other.repeats().single.location, 'Pulteney St');
    expect(other.todos(TodoScope.today, '2026-11-03').map((t) => t.location).toSet(), {'Pulteney St'});
  });

  test('a past day keeps the location it was edited to', () {
    final store = memory();
    store.addHabit(2026, 11, 'Read');
    var now = DateTime(2026, 11, 1, 9);
    final state = AppState(store, clock: () => now);
    addTearDown(state.dispose);
    state.addTodo(TodoScope.today, 'Swim');
    now = DateTime(2026, 11, 2, 9);
    state.checkDate();
    final yesterday = DateTime(2026, 11, 1);
    final item = state.todosOn(TodoScope.today, yesterday).single;
    state.editTodo(TodoScope.today, item, 'Swim', null, day: yesterday, location: 'Aquatic Centre');
    expect(state.todosOn(TodoScope.today, yesterday).single.location, 'Aquatic Centre');
  });

  test('holidays rest every day in them, join when they touch, and sync', () {
    final store = memory();
    store.addHabit(2026, 11, 'Read');
    final now = DateTime(2026, 11, 12, 9);
    final state = AppState(store, clock: () => now);
    addTearDown(state.dispose);
    final read = state.habitsFor(2026, 11).single;
    for (final d in [2, 3, 4]) {
      state.selectStatus(DateTime(2026, 11, d), read, HabitStatus.done);
    }
    // Blank 5th to 9th, then done again.
    for (final d in [10, 11, 12]) {
      state.selectStatus(DateTime(2026, 11, d), read, HabitStatus.done);
    }
    expect(state.currentStreak(read), 3);

    state.addHoliday(DateTime(2026, 11, 5), DateTime(2026, 11, 7));
    state.addHoliday(DateTime(2026, 11, 8), DateTime(2026, 11, 9));
    expect(state.holidays, [(start: DateTime(2026, 11, 5), end: DateTime(2026, 11, 9))]);
    expect(state.isRestDay(DateTime(2026, 11, 6)), isTrue);
    expect(state.isRestDay(DateTime(2026, 11, 10)), isFalse);
    expect(state.currentStreak(read), 6, reason: 'blank holiday days no longer break it');

    final sender = SyncEngine(store, 'a')..claimAll();
    final other = memory();
    SyncEngine(other, 'b')
      ..clearForJoining()
      ..mergeAll([(_sent(sender), 'a')]);
    expect(decodeHolidays(other.setting('holidays')), state.holidays);

    state.removeHoliday(state.holidays.single);
    expect(state.isRestDay(DateTime(2026, 11, 6)), isFalse);
    expect(state.currentStreak(read), 3);
  });

  test('the Today panel in Week ahead cross-fades between a theme pair', () {
    final light = themeNamed('Sunrise').extension<Palette>()!, dark = themeNamed('Sunset').extension<Palette>()!;
    expect(light.todayPanel, const Color(0xFFFCF0F2));
    // No jump at the halfway mark, where the palette's name switches.
    final before = light.lerp(dark, 0.49).todayPanel, after = light.lerp(dark, 0.51).todayPanel;
    expect((before.r - after.r).abs(), lessThan(0.02));
    expect((before.a - after.a).abs(), lessThan(0.02));
  });

  testWidgets('a task shows its time and location on the line over its name', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = memory();
    store.addHabit(2026, 11, 'Read');
    final state = AppState(store, clock: () => DateTime(2026, 11, 2, 9));
    addTearDown(state.dispose);
    state.addTodo(TodoScope.today, 'Dentist', time: 10 * 60, location: 'Rundle Mall');
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final place = find.text('Rundle Mall');
    expect(place, findsOneWidget);
    expect(tester.getTopLeft(place).dy, lessThan(tester.getTopLeft(find.text('Dentist')).dy));
    // On the time's line, after it, with its pin between.
    expect(tester.getCenter(place).dy, closeTo(tester.getCenter(find.text('10:00 am')).dy, 1));
    expect(tester.getTopLeft(place).dx, greaterThan(tester.getTopLeft(find.byIcon(Icons.place_rounded)).dx));
    expect(
      tester.getTopLeft(find.byIcon(Icons.place_rounded)).dx,
      greaterThan(tester.getTopLeft(find.text('10:00 am')).dx),
    );
  });
}
