import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adelaide's clocks go back on 4 April 2027 and forward on 3 October 2027.
/// CI runs this file a second time with TZ=Australia/Adelaide to cover them.
final _clocksChange = DateTime(2027, 4, 3, 12).timeZoneOffset != DateTime(2027, 4, 5, 12).timeZoneOffset;

void main() {
  late DateTime now;

  (Store, AppState) open(DateTime at, {int dayStart = 0}) {
    now = at;
    final store = Store.memory();
    addTearDown(store.close);
    if (dayStart != 0) store.setSetting('dayStartHour', '$dayStart');
    store.addHabit(at.year, at.month, 'Read');
    final state = AppState(store, clock: () => now);
    addTearDown(state.dispose);
    return (store, state);
  }

  group('New Year', () {
    test('the day, the year on show and January all turn over', () {
      final (_, state) = open(DateTime(2026, 12, 31, 23, 59));
      expect(state.today, DateTime(2026, 12, 31));
      expect(state.viewYear, 2026);
      now = DateTime(2027, 1, 1, 0, 0, 1);
      state.checkDate();
      expect(state.today, DateTime(2027, 1, 1));
      expect(state.viewYear, 2027);
      expect(state.habits.map((h) => h.name), ['Read']);
    });

    test('with a 4am start the year turns at 4am, not midnight', () {
      final (_, state) = open(DateTime(2026, 12, 31, 23, 59), dayStart: 4);
      now = DateTime(2027, 1, 1, 3, 59);
      state.checkDate();
      expect(state.today, DateTime(2026, 12, 31));
      expect(state.viewYear, 2026);
      expect(state.lateNight, isTrue);
      now = DateTime(2027, 1, 1, 4);
      state.checkDate();
      expect(state.today, DateTime(2027, 1, 1));
      expect(state.viewYear, 2027);
      expect(state.lateNight, isFalse);
    });

    test('a year on show from before stays on show', () {
      final (_, state) = open(DateTime(2026, 12, 31, 23, 59));
      state.viewYear = 2025;
      now = DateTime(2027, 1, 1);
      state.checkDate();
      expect(state.viewYear, 2025);
    });

    test('a streak carries from December into January', () {
      final (_, state) = open(DateTime(2026, 12, 30, 12));
      final read = state.habits.single;
      state.selectStatus(state.today, read, HabitStatus.done);
      now = DateTime(2026, 12, 31, 12);
      state.checkDate();
      state.selectStatus(state.today, state.habits.single, HabitStatus.done);
      now = DateTime(2027, 1, 1, 12);
      state.checkDate();
      state.selectStatus(state.today, state.habits.single, HabitStatus.done);
      expect(state.currentStreak(state.habits.single), 3);
      expect(state.bestStreak(state.habits.single), 3);
    });

    test('an unfinished task carries into the new year and keeps its first day', () {
      final (_, state) = open(DateTime(2026, 12, 31, 12));
      state.addTodo(TodoScope.today, 'Pay rent');
      now = DateTime(2027, 1, 1, 12);
      state.checkDate();
      final carried = state.todosOn(TodoScope.today, state.today).where((t) => t.text == 'Pay rent');
      expect(carried, hasLength(1));
      expect(carried.single.since, DateTime(2026, 12, 31));
    });

    test('a task due in January stays on its day from December', () {
      final (_, state) = open(DateTime(2026, 12, 28, 12));
      state.addTodo(TodoScope.today, 'Dentist', dueDate: DateTime(2027, 1, 2));
      expect(state.todosOn(TodoScope.today, DateTime(2027, 1, 2)).map((t) => t.text), contains('Dentist'));
      now = DateTime(2027, 1, 2, 12);
      state.checkDate();
      expect(state.todosOn(TodoScope.today, state.today).map((t) => t.text), contains('Dentist'));
    });

    test('repeats and birthdays come round across the year', () {
      final start = DateTime(2026, 12, 29);
      final weekly = Repeat(uid: 'w', text: 'Bins', rule: RepeatRule.weekly({DateTime.friday}), start: start);
      expect(weekly.next(DateTime(2026, 12, 30)), DateTime(2027, 1, 1));
      final fortnight = Repeat(uid: 'f', text: 'Mow', rule: const RepeatRule.every(2, weeks: true), start: start);
      expect(fortnight.next(DateTime(2027, 1, 1)), DateTime(2027, 1, 12));
      final daily = Repeat(uid: 'd', text: 'Water', rule: const RepeatRule.every(3), start: start);
      expect(daily.next(DateTime(2027, 1, 1)), DateTime(2027, 1, 1));
    });

    test('2028 has a 29 February and days count through it', () {
      expect(daysBetween(DateTime(2028, 2, 28), DateTime(2028, 3, 1)), 2);
      final (_, state) = open(DateTime(2028, 2, 28, 23, 59));
      now = DateTime(2028, 2, 29, 0, 0, 1);
      state.checkDate();
      expect(state.today, DateTime(2028, 2, 29));
      now = DateTime(2028, 3, 1, 0, 0, 1);
      state.checkDate();
      expect(state.today, DateTime(2028, 3, 1));
    });
  });

  group('clock changes', skip: _clocksChange ? false : 'needs TZ=Australia/Adelaide', () {
    /// Every 15 minutes from [from] to [to], counted in real time.
    List<DateTime> dayStartsWalking(AppState state, DateTime from, DateTime to) {
      final days = <DateTime>[state.today];
      for (var t = from; t.isBefore(to); t = t.add(const Duration(minutes: 15))) {
        now = t;
        state.checkDate();
        if (state.today != days.last) days.add(state.today);
      }
      return days;
    }

    for (final (name, changes) in [('going back', DateTime(2027, 4, 4)), ('going forward', DateTime(2027, 10, 3))]) {
      for (final dayStart in [0, 4]) {
        test('$name, each day comes once with a ${dayStart}am start', () {
          final from = DateTime(changes.year, changes.month, changes.day - 1, 12);
          final (_, state) = open(from, dayStart: dayStart);
          final days = dayStartsWalking(state, from, DateTime(changes.year, changes.month, changes.day + 2, 12));
          expect(days, [
            DateTime(changes.year, changes.month, changes.day - 1),
            changes,
            DateTime(changes.year, changes.month, changes.day + 1),
            DateTime(changes.year, changes.month, changes.day + 2),
          ]);
        });
      }

      test('$name, the next day begins on the hour and days count whole', () {
        expect(nextDayStart(changes, 0), DateTime(changes.year, changes.month, changes.day + 1));
        expect(nextDayStart(changes, 4), DateTime(changes.year, changes.month, changes.day, 4));
        expect(daysBetween(changes, DateTime(changes.year, changes.month, changes.day + 1)), 1);
      });

      test('$name, a daily repeat lands on every date', () {
        final start = DateTime(changes.year, changes.month, changes.day - 3);
        final daily = Repeat(uid: 'd', text: 'Water', rule: const RepeatRule.every(1), start: start);
        for (var i = 0; i < 7; i++) {
          final day = DateTime(start.year, start.month, start.day + i);
          expect(daily.next(day), day);
        }
      });

      test('$name, a streak isn\'t broken', () {
        final from = DateTime(changes.year, changes.month, changes.day - 1, 12);
        final (_, state) = open(from);
        for (var i = 0; i < 3; i++) {
          now = DateTime(from.year, from.month, from.day + i, 12);
          state.checkDate();
          state.selectStatus(state.today, state.habits.single, HabitStatus.done);
        }
        expect(state.currentStreak(state.habits.single), 3);
      });
    }

    test('a reminder an hour before is a real hour early, even over the change', () {
      for (final (day, time) in [(DateTime(2027, 4, 4), 4 * 60 + 30), (DateTime(2027, 10, 3), 3 * 60 + 30)]) {
        final due = Reminder.onTheDay.at(day, time);
        expect(due.difference(Reminder.hourBefore.at(day, time)), const Duration(hours: 1));
        expect(due.difference(Reminder.quarterBefore.at(day, time)), const Duration(minutes: 15));
      }
    });
  });
}
