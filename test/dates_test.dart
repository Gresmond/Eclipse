import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/system_time_zone.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/smart_add.dart';
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

  group('New Year, dayStartHour & leap day', () {
    test('day, year, 4am day start, streaks, carried tasks and leap day roll over cleanly', () {
      final (_, state) = open(DateTime(2026, 12, 31, 23, 59));
      state.addTodo(TodoScope.today, 'Pay rent');
      state.addTodo(TodoScope.today, 'Dentist', dueDate: DateTime(2027, 1, 2));
      state.selectStatus(state.today, state.habits.single, HabitStatus.done);
      now = DateTime(2027, 1, 1, 0, 0, 1);
      state.checkDate();
      expect((state.today, state.viewYear), (DateTime(2027, 1, 1), 2027));
      state.selectStatus(state.today, state.habits.single, HabitStatus.done);
      expect(state.currentStreak(state.habits.single), 2);
      final carried = state.todosOn(TodoScope.today, state.today).singleWhere((t) => t.text == 'Pay rent');
      expect(carried.since, DateTime(2026, 12, 31));
      now = DateTime(2027, 1, 2, 12);
      state.checkDate();
      expect(state.todosOn(TodoScope.today, state.today).map((t) => t.text), contains('Dentist'));

      final (_, early) = open(DateTime(2026, 12, 31, 23, 59), dayStart: 4);
      now = DateTime(2027, 1, 1, 3, 59);
      early.checkDate();
      expect((early.today, early.lateNight), (DateTime(2026, 12, 31), true));
      now = DateTime(2027, 1, 1, 4);
      early.checkDate();
      expect((early.today, early.lateNight), (DateTime(2027, 1, 1), false));

      expect(daysBetween(DateTime(2028, 2, 28), DateTime(2028, 3, 1)), 2);
    });

    test('parseClock and dayStartHour validate ranges', () {
      expect(parseClock('25:00'), isNull);
      expect(parseClock('12:60'), isNull);
      expect(parseClock('08:30'), 510);
      expect(parseDayStartHour('24'), 0);
      expect(parseDayStartHour('4'), 4);
    });

    test('TzifZone parses transitions and SystemTimeZone detects symlink zone switches', () {
      final dir = Directory.systemTemp.createTempSync('eclipse_tzif');
      addTearDown(() => dir.deleteSync(recursive: true));
      final utcTransition = DateTime.utc(2026, 4, 5, 1, 0).millisecondsSinceEpoch ~/ 1000;
      final zoneA = File('${dir.path}/zoneA')
        ..writeAsBytesSync(
          _buildTzifV2(transitionsSeconds: [utcTransition], typeIndices: [1], utcOffsetsSeconds: [10 * 3600, 9 * 3600]),
        );
      final zoneB = File('${dir.path}/zoneB')
        ..writeAsBytesSync(_buildTzifV2(transitionsSeconds: const [], typeIndices: const [], utcOffsetsSeconds: [-5 * 3600]));

      final parsed = TzifZone.parse(zoneA.readAsBytesSync())!;
      expect(parsed.offsetAt(DateTime.utc(2026, 4, 5, 0, 59)), const Duration(hours: 10));
      expect(parsed.offsetAt(DateTime.utc(2026, 4, 5, 1, 0)), const Duration(hours: 9));

      final link = Link('${dir.path}/localtime')..createSync(zoneA.path);
      final sys = SystemTimeZone.forPath(link.path)..sync();
      final sampleUtc = DateTime.utc(2026, 5, 1, 12, 0);
      expect(sys.currentTime(utcNow: () => sampleUtc), DateTime(2026, 5, 1, 21, 0));
      link.deleteSync();
      link.createSync(zoneB.path);
      sys.sync();
      expect(sys.currentTime(utcNow: () => sampleUtc), DateTime(2026, 5, 1, 7, 0));
    });
  });

  group('clock changes', skip: _clocksChange ? false : 'needs TZ=Australia/Adelaide', () {
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
          expect(dayStartsWalking(state, from, DateTime(changes.year, changes.month, changes.day + 2, 12)), [
            DateTime(changes.year, changes.month, changes.day - 1),
            changes,
            DateTime(changes.year, changes.month, changes.day + 1),
            DateTime(changes.year, changes.month, changes.day + 2),
          ]);
        });
      }

      test('$name, nextDayStart, daysBetween, streaks and daily repeats stay accurate', () {
        expect(nextDayStart(changes, 4), DateTime(changes.year, changes.month, changes.day, 4));
        expect(daysBetween(changes, DateTime(changes.year, changes.month, changes.day + 1)), 1);
        final start = DateTime(changes.year, changes.month, changes.day - 3);
        final daily = Repeat(uid: 'd', text: 'Water', rule: const RepeatRule.every(1), start: start);
        for (var i = 0; i < 7; i++) {
          final day = DateTime(start.year, start.month, start.day + i);
          expect(daily.next(day), day);
        }
        final due = Reminder.onTheDay.at(changes, 4 * 60 + 30);
        expect(due.difference(Reminder.hourBefore.at(changes, 4 * 60 + 30)), const Duration(hours: 1));
      });
    }
  });

  group('repeats & smart quick-add', () {
    test('RepeatRule matches schedules, bounds decode, and Repeat.next finds future dates', () {
      final start = DateTime(2026, 10, 28);
      final weekly = RepeatRule.weekly({1, 3, 5});
      expect(weekly.on(DateTime(2026, 10, 28), start), isTrue);
      expect(weekly.on(DateTime(2026, 10, 29), start), isFalse);
      expect(const RepeatRule.monthly(31).on(DateTime(2026, 11, 30), start), isTrue);
      expect(RepeatRule.decode('days:1001'), isNull);

      final repeat = Repeat(
        uid: 'r',
        text: 'Renew',
        rule: const RepeatRule.every(2, weeks: true),
        start: DateTime(2026, 10, 31),
        until: DateTime(2026, 12, 1),
      );
      expect(repeat.next(DateTime(2026, 11, 1)), DateTime(2026, 11, 14));
      expect(repeat.next(DateTime(2026, 12, 2)), isNull);
    });

    test('makeRepeating preserves subtasks unticked on future occurrences', () {
      final (store, state) = open(DateTime(2026, 10, 31, 9));
      state.addTodo(TodoScope.today, 'Pack');
      var item = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Pack');
      state.setTodoSubtasks(TodoScope.today, item, [
        const TodoSubtask('Passport', done: true),
        const TodoSubtask('Tickets'),
      ]);
      item = state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Pack');
      state.makeRepeating(TodoScope.today, item, item.text, const RepeatRule.every(1));
      final made = state.todos.values.expand((l) => l).where((t) => t.text == 'Pack').toList()
        ..sort((a, b) => a.repeatDay!.compareTo(b.repeatDay!));
      expect(made.first.subtasks.map((s) => s.done), [true, false]);
      expect(made[1].subtasks.map((s) => s.done), [false, false]);
    });

    test('smart quick-add extracts schedule, place and reminders while keeping plain ratios literal', () {
      final friday = DateTime(2026, 11, 20);
      final parsed = parseQuickTask('Dentist fri 2:30pm @Clinic', DateTime(2026, 11, 19));
      expect((parsed.name, parsed.day, parsed.minutes, parsed.location), ('Dentist', friday, 870, 'Clinic'));

      expect(parseQuickTask('Use 1/2 cup oats', friday).name, 'Use 1/2 cup oats');
      expect(parseQuickTask('Read John 3:16', friday).minutes, isNull);
      expect(parseQuickTask('Mix 2:1 epoxy', friday).minutes, isNull);

      final (_, state) = open(DateTime(2026, 11, 19, 12));
      state.quickAddTodo(
        TodoScope.today,
        'Put bins out every second Thursday starting next week at 8pm @Home and remind me 20 minutes before',
      );
      final series = state.store.repeats().single;
      expect((series.text, series.start, series.time, series.location), ('Put bins out', DateTime(2026, 11, 26), 1200, 'Home'));
      expect(series.reminders, Reminder.twentyBefore.bit);
    });
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
    builder.add((ByteData(8)..setInt64(0, ts)).buffer.asUint8List());
  }
  builder.add(typeIndices);
  for (final offset in utcOffsetsSeconds) {
    builder.add((ByteData(6)..setInt32(0, offset)).buffer.asUint8List());
  }
  builder.addByte(0);
  return builder.takeBytes();
}
