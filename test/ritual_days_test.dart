import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final mwf = weekdayBit(DateTime.monday) | weekdayBit(DateTime.wednesday) | weekdayBit(DateTime.friday);

  test('a change of days partway through a month leaves earlier days alone', () {
    final from = DateTime(2026, 10, 27);
    var days = changeDays([], from, mwf);
    expect(isOnDay(days, DateTime(2026, 10, 20)), isTrue, reason: 'a Tuesday before the change');
    expect(isOnDay(days, DateTime(2026, 10, 27)), isFalse, reason: 'a Tuesday from the change on');
    expect(isOnDay(days, DateTime(2026, 10, 28, 9)), isTrue);

    // Changed again the same day: replaces that day's change.
    days = changeDays(days, from, mwf | weekdayBit(DateTime.tuesday));
    expect(days, hasLength(1));
    expect(changeDays(days, from, everyDay), isEmpty, reason: 'back to every day');

    // A whole-month change replaces everything.
    expect(changeDays(days, null, mwf), [(null, mwf)]);
    expect(decodeDays(encodeDays(days)), days);
  });

  test('off days count for nothing: not in the score and not breaking a streak', () {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 10, 'Gym');
    store.setHabitDays(2026, 10, habit.id, [(null, mwf)]);
    expect(store.monthHabits(2026, 10).single.weekdays, mwf);

    // Mon 19, Wed 21, Fri 23, Mon 26 done; Tue 20 logged missed before the
    // schedule was set.
    for (final day in ['2026-10-19', '2026-10-21', '2026-10-23', '2026-10-26']) {
      store.setEntry(day, habit.id, HabitStatus.done);
    }
    store.setEntry('2026-10-20', habit.id, HabitStatus.missed);
    expect(store.monthScores(2026, 10)[habit.id], (4, 4));
    expect(store.streaks(habit.id, DateTime(2026, 10, 27), restWeekends: false), (4, 4));
    // Wednesday left blank breaks it once Thursday comes.
    expect(store.streaks(habit.id, DateTime(2026, 10, 29), restWeekends: false), (0, 4));
  });

  test('a new month starts on the latest days, and days sync', () {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 10, 'Gym');
    store.setHabitDays(2026, 10, habit.id, changeDays([], DateTime(2026, 10, 27), mwf));
    store.copyMonth((2026, 10), (2026, 11));
    expect(store.monthHabits(2026, 11).single.days, [(null, mwf)]);

    final other = Store.memory();
    addTearDown(other.close);
    final sender = SyncEngine(store, 'a')..claimAll();
    final receiver = SyncEngine(other, 'b')..clearForJoining();
    receiver.mergeAll([(sender.changesSince(0).values.expand((v) => v).toList(), 'a')]);
    expect(other.monthHabits(2026, 10).single.days, store.monthHabits(2026, 10).single.days);
  });
}
