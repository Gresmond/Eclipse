import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/system_time_zone.dart';
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

  test('Repeat.on/next normalize non-midnight dates and RepeatRule.decode bounds every', () {
    final r = Repeat(
      uid: 'r1',
      text: 'Daily',
      rule: const RepeatRule.every(2),
      start: DateTime(2026, 11, 1, 15, 30),
      until: DateTime(2026, 11, 5, 8, 0),
    );
    expect(r.on(DateTime(2026, 11, 5, 23, 59)), isTrue);
    expect(r.next(DateTime(2026, 11, 1, 20, 0)), DateTime(2026, 11, 1));
    expect(RepeatRule.decode('days:1001'), isNull);
    expect(RepeatRule.decode('days:1000'), const RepeatRule.every(1000));
  });

  test('parseClock and dayStartHour validate ranges and setDayStartHour bumps todosRevision', () {
    expect(parseClock('25:00'), isNull);
    expect(parseClock('12:60'), isNull);
    expect(parseClock('13:00 pm'), isNull);
    expect(parseClock('08:30'), 510);
    expect(parseDayStartHour('24'), 0);
    expect(parseDayStartHour('-1'), 0);
    expect(parseDayStartHour('4'), 4);

    final store = Store.memory();
    addTearDown(store.close);
    store.addHabit(2026, 11, 'Read');
    store.setSetting('dayStartHour', '99');
    final state = AppState(store, clock: () => DateTime(2026, 11, 5, 2));
    addTearDown(state.dispose);
    expect(state.dayStartHour, 0);

    final rev = state.todosRevision;
    state.setDayStartHour(99);
    expect(state.dayStartHour, 0);
    state.setDayStartHour(4);
    expect(state.dayStartHour, 4);
    expect(state.todosRevision, greaterThan(rev));
    expect(state.today, DateTime(2026, 11, 4));
  });

  test('TzifZone parses transitions and SystemTimeZone detects symlink zone switches', () {
    final dir = Directory.systemTemp.createTempSync('eclipse_tzif');
    addTearDown(() => dir.deleteSync(recursive: true));
    final utcTransition = DateTime.utc(2026, 4, 5, 1, 0).millisecondsSinceEpoch ~/ 1000;
    final zoneA = File('${dir.path}/zoneA')
      ..writeAsBytesSync(
        _buildTzifV2(
          transitionsSeconds: [utcTransition],
          typeIndices: [1],
          utcOffsetsSeconds: [10 * 3600, 9 * 3600],
        ),
      );
    final zoneB = File('${dir.path}/zoneB')
      ..writeAsBytesSync(
        _buildTzifV2(
          transitionsSeconds: const [],
          typeIndices: const [],
          utcOffsetsSeconds: [-5 * 3600],
        ),
      );

    final parsedA = TzifZone.parse(zoneA.readAsBytesSync())!;
    expect(parsedA.offsetAt(DateTime.utc(2026, 4, 5, 0, 59)), const Duration(hours: 10));
    expect(parsedA.offsetAt(DateTime.utc(2026, 4, 5, 1, 0)), const Duration(hours: 9));
    expect(TzifZone.parse(Uint8List.fromList([1, 2, 3])), isNull);

    final link = Link('${dir.path}/localtime')..createSync(zoneA.path);
    final sys = SystemTimeZone.forPath(link.path)..sync();
    final sampleUtc = DateTime.utc(2026, 5, 1, 12, 0);
    expect(sys.currentTime(utcNow: () => sampleUtc), DateTime(2026, 5, 1, 21, 0));

    link.deleteSync();
    link.createSync(zoneB.path);
    sys.sync();
    expect(sys.currentTime(utcNow: () => sampleUtc), DateTime(2026, 5, 1, 7, 0));
  });
}

Uint8List _buildTzifV2({
  required List<int> transitionsSeconds,
  required List<int> typeIndices,
  required List<int> utcOffsetsSeconds,
}) {
  final builder = BytesBuilder();
  void writeHeader(int timeCount, int typeCount) {
    builder.add(ascii.encode('TZif2'));
    builder.add(List<int>.filled(15, 0));
    final bd = ByteData(24)
      ..setUint32(0, 0)
      ..setUint32(4, 0)
      ..setUint32(8, 0)
      ..setUint32(12, timeCount)
      ..setUint32(16, typeCount)
      ..setUint32(20, 1);
    builder.add(bd.buffer.asUint8List());
  }

  writeHeader(0, 1);
  builder.add(Uint8List(6));
  builder.addByte(0);

  writeHeader(transitionsSeconds.length, utcOffsetsSeconds.length);
  for (final ts in transitionsSeconds) {
    final bd = ByteData(8)..setInt64(0, ts);
    builder.add(bd.buffer.asUint8List());
  }
  builder.add(typeIndices);
  for (final offset in utcOffsetsSeconds) {
    final bd = ByteData(6)..setInt32(0, offset);
    builder.add(bd.buffer.asUint8List());
  }
  builder.addByte(0);
  return builder.takeBytes();
}
