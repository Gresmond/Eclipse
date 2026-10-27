import 'dart:io';

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

  test("the week trail is a ritual's last 7 days, back across months, and no further than it goes", () {
    final store = Store.memory();
    addTearDown(store.close);
    final habit = store.addHabit(2026, 9, 'Gym', addedOn: DateTime(2026, 9, 14));
    store.setHabitDays(2026, 9, habit.id, [(null, weekdayBit(DateTime.monday))]);
    // October isn't saved yet, so it's on September's days.
    expect(store.pastDays(habit.id, DateTime(2026, 10, 27), 7), [
      DateTime(2026, 10, 26),
      DateTime(2026, 10, 19),
      DateTime(2026, 10, 12),
      DateTime(2026, 10, 5),
      DateTime(2026, 9, 28),
      DateTime(2026, 9, 21),
      DateTime(2026, 9, 14),
    ]);
    // Saved, and on Mondays and Fridays from the 20th: only the day it was added stops it.
    store.copyMonth((2026, 9), (2026, 10));
    store.setHabitDays(
      2026,
      10,
      habit.id,
      changeDays(
        [(null, weekdayBit(DateTime.monday))],
        DateTime(2026, 10, 20),
        weekdayBit(DateTime.monday) | weekdayBit(DateTime.friday),
      ),
    );
    expect(store.pastDays(habit.id, DateTime(2026, 10, 27), 7).take(3), [
      DateTime(2026, 10, 26),
      DateTime(2026, 10, 23),
      DateTime(2026, 10, 19),
    ]);
    expect(store.pastDays(habit.id, DateTime(2026, 9, 22), 7), [DateTime(2026, 9, 21), DateTime(2026, 9, 14)]);
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

  test('saved days from before are reset to every day once', () {
    final dir = Directory.systemTemp.createTempSync('eclipse-ritual-days');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/test.db';
    var store = Store.open(path);
    final gym = store.addHabit(2026, 10, 'Gym');
    store.setHabitDays(2026, 10, gym.id, [(null, mwf)]);
    store.raw.execute('PRAGMA user_version = 19');
    store.close();

    store = Store.open(path);
    expect(store.monthHabits(2026, 10).single.weekdays, everyDay);
    expect(store.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion);
    store.setHabitDays(2026, 10, gym.id, [(null, mwf)]);
    store.close();

    store = Store.open(path);
    addTearDown(store.close);
    expect(store.monthHabits(2026, 10).single.weekdays, mwf, reason: 'days chosen after the reset stay');
  });

  test('a database whose days column was dropped opens with it back', () {
    final dir = Directory.systemTemp.createTempSync('eclipse-ritual-days');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/test.db';
    var store = Store.open(path);
    store.addHabit(2026, 10, 'Gym');
    store.raw.execute('ALTER TABLE month_habits DROP COLUMN days');
    store.raw.execute('PRAGMA user_version = 20');
    store.close();

    store = Store.open(path);
    addTearDown(store.close);
    expect(store.monthHabits(2026, 10).single.weekdays, everyDay);
    expect(store.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion);
  });

  test('days an upgrade reset without sync seeing reach the other computer after the next upgrade', () {
    final dir = Directory.systemTemp.createTempSync('eclipse-ritual-days');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/test.db';
    var store = Store.open(path);
    final gym = store.addHabit(2026, 10, 'Gym');
    store.setEntry('2026-10-24', gym.id, HabitStatus.done);
    store.setHabitDays(2026, 10, gym.id, [(null, mwf)]);
    SyncEngine(store, 'pc').claimAll();
    // As versions 20 and 21 did: the column dropped and added back, so the
    // days are every day here while sync still has Mon/Wed/Fri.
    store.raw.execute('ALTER TABLE month_habits DROP COLUMN days');
    store.raw.execute('ALTER TABLE month_habits ADD COLUMN days TEXT');
    store.raw.execute('PRAGMA user_version = 22');
    store.close();

    store = Store.open(path);
    addTearDown(store.close);
    final pc = SyncEngine(store, 'pc')..flush();
    final laptop = Store.memory();
    addTearDown(laptop.close);
    SyncEngine(laptop, 'laptop')
      ..clearForJoining()
      ..mergeAll([(pc.changesSince(0).values.expand((v) => v).toList(), 'pc')]);
    expect(laptop.monthHabits(2026, 10).single.weekdays, everyDay);
    expect(laptop.monthHabits(2026, 10).single.onDay(DateTime(2026, 10, 24)), isTrue, reason: 'a Saturday');

    // Nothing else changed, so nothing else is sent again.
    store.raw.execute('PRAGMA user_version = 22');
    final before = pc.changesSince(0).values.expand((v) => v).length;
    store.close();
    store = Store.open(path);
    SyncEngine(store, 'pc').flush();
    expect(SyncEngine(store, 'pc').changesSince(0).values.expand((v) => v).length, before);
  });
}
