import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/smart_add.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:eclipse/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('smart add parses tricky places and times while leaving ratios, bible verses, and plain words literal', () {
    final today = DateTime(2026, 11, 20); // Friday
    final oval = parseQuickTask('Training at North Adelaide Oval at 19:35', today);
    expect(oval.name, 'Training');
    expect(oval.location, 'North Adelaide Oval');
    expect(oval.minutes, 19 * 60 + 35);

    final fraction = parseQuickTask('Use 1/2 cup oats', today);
    expect(fraction.day, isNull);
    expect(fraction.name, 'Use 1/2 cup oats');

    final sunblock = parseQuickTask('Buy sunblock', today);
    expect(sunblock.day, isNull);
    expect(sunblock.name, 'Buy sunblock');

    final satchel = parseQuickTask('Fix sat nav', today);
    expect(satchel.day, isNull);
    expect(satchel.name, 'Fix sat nav');

    final nextMon = parseQuickTask('Dentist next Monday', DateTime(2026, 11, 16));
    expect(nextMon.day, DateTime(2026, 11, 23));

    final range = parseQuickTask('Deep work between 3pm and 5pm', today);
    expect(range.name, 'Deep work');
    expect(range.minutes, 15 * 60);

    expect(parseQuickTask('Meeting from 3pm to 4pm', today).minutes, 900);
    expect(parseQuickTask('Dentist next Monday', today).day, DateTime(2026, 11, 23));
    expect(parseQuickTask('Buy milk 1/2', today).day, isNull);
    expect(parseQuickTask('Buy milk on 1/2', today).day, DateTime(2027, 2, 1));

    final verse = parseQuickTask('Read John 3:16', today);
    expect(verse.minutes, isNull);
    expect(verse.name, 'Read John 3:16');

    final ratio = parseQuickTask('Mix 2:1 epoxy', today);
    expect(ratio.minutes, isNull);
    expect(ratio.name, 'Mix 2:1 epoxy');
  });

  group('spoken quick add', () {
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

    test('smart quick add carries weekday, time and location into a task', () {
      final parsed = parseQuickTask('Dentist fri 2:30pm @Clinic', day);
      expect(parsed, (
        name: 'Dentist',
        day: DateTime(2026, 11, 20),
        minutes: 870,
        location: 'Clinic',
        repeat: null,
        until: null,
        reminders: 0,
      ));
    });

    test('a spoken fortnightly task saves its start, time, place and alert', () {
      state.quickAddTodo(
        TodoScope.today,
        'Put the bins out every second Thursday starting next week at 8pm @Home and remind me 20 minutes before',
      );
      final series = store.repeats().single;
      expect(series.text, 'Put the bins out');
      expect(series.start, DateTime(2026, 11, 26));
      expect(series.rule.on(DateTime(2026, 12, 3), series.start), isFalse);
      expect(series.rule.on(DateTime(2026, 12, 10), series.start), isTrue);
      expect((series.time, series.location, series.reminders), (1200, 'Home', Reminder.twentyBefore.bit));
      expect(Reminder.twentyBefore.at(series.start, series.time), DateTime(2026, 11, 26, 19, 40));
    });

    test('weekday series stops on the inclusive end date after its future start', () {
      state.quickAddTodo(TodoScope.today, 'Check mail every weekday starting next week until Friday at noon');
      final series = store.repeats().single;
      expect((series.text, series.start, series.until), ('Check mail', DateTime(2026, 11, 23), DateTime(2026, 11, 27)));
      expect(series.on(DateTime(2026, 11, 27)), isTrue);
      expect(series.on(DateTime(2026, 11, 30)), isFalse);
      const invalid = 'Check daily starting 25/12/2026 until 24/12/2026';
      expect(parseQuickTask(invalid, day).name, invalid);
    });

    test('spoken places preserve names, addresses and ordinary uses of at or in', () {
      for (final (input, name, place) in [
        ('Get milk at coles tomorrow at noon', 'Get milk', 'coles'),
        ('Dinner at Mum’s place', 'Dinner', 'Mum’s place'),
        ('Meet at 42 King Street at 7pm', 'Meet', '42 King Street'),
        ('Meet at 7pm at North Adelaide Library', 'Meet', 'North Adelaide Library'),
        ('Swim in the pool', 'Swim', 'the pool'),
        ('Look at the school timetable', 'Look at the school timetable', null),
        ('Reply in writing', 'Reply in writing', null),
        ('Buy at least three apples', 'Buy at least three apples', null),
        ('Call in two weeks', 'Call', null),
        ('Call at 7', 'Call at 7', null),
      ]) {
        final result = parseQuickTask(input, day);
        expect((result.name, result.location), (name, place), reason: input);
      }
    });

    test('weekday lists cross weekends and year boundaries', () {
      final parsed = parseQuickTask(
        'Train every Mon, Wed and Fri at noon',
        DateTime(2027, 12, 31),
        defaultDay: DateTime(2028, 1, 1),
      );
      expect(parsed.name, 'Train');
      expect(parsed.minutes, 720);
      expect(parsed.repeat, const RepeatRule.weekly({1, 3, 5}));
      expect(parsed.day, DateTime(2028, 1, 3));
      expect(parseQuickTask('Check monthly starting on 29 February 2028', day).day, DateTime(2028, 2, 29));
    });

    test('recurrence, time, reminder and multiword place work in every clause order', () {
      Iterable<List<String>> orders(List<String> clauses) sync* {
        if (clauses.isEmpty) yield [];
        for (final clause in clauses) {
          for (final rest in orders(clauses.where((c) => c != clause).toList())) {
            yield [clause, ...rest];
          }
        }
      }

      for (final order in orders([
        'every two weeks',
        'starting in a fortnight',
        'at 19:35',
        'in North Adelaide',
        'remind me 20 mins before',
      ])) {
        final text = 'Train ${order.join(' ')}';
        final result = parseQuickTask(text, day);
        expect(
          (result.name, result.day, result.minutes, result.location, result.repeat, result.reminders),
          ('Train', DateTime(2026, 12, 3), 1175, 'North Adelaide', const RepeatRule.every(2, weeks: true), 16),
          reason: text,
        );
      }
    });

    test('invalid dates and unsupported instructions keep the full title', () {
      for (final text in [
        'Check due on 31/2 at noon',
        'Call the second Thursday of every month',
        'Call every 0 days',
        'Call tomorrow @Home and remind me 7 minutes before',
        'Call tomorrow and remind me 15 minutes before',
        'Email sam@example.com',
      ]) {
        final parsed = parseQuickTask(text, day);
        expect(parsed.name, text);
        expect(parsed.repeat, isNull);
        expect(parsed.reminders, 0);
      }
    });

    test('quick add consumes connectors and matches both parts of Friday 13th', () {
      final friday = DateTime(2027, 8, 13);
      for (final input in [
        'Call Marge Simpson due on Friday 13th at 7:35 pm',
        'Call Marge Simpson at 7:35 pm on Friday the 13th',
        'Call Marge Simpson on 13 August 2027 at 19:35',
        'Call Marge Simpson at 7:35 p.m. due 13/8/2027',
      ]) {
        expect(parseQuickTask(input, day), (
          name: 'Call Marge Simpson',
          day: friday,
          minutes: 1175,
          location: null,
          repeat: null,
          until: null,
          reminders: 0,
        ));
      }
      expect(parseQuickTask('Meet at home', day).location, 'home');
      expect(parseQuickTask('Review due on 31/2', day).day, isNull);
      expect(parseQuickTask('Ring tomorrow at midnight', day).minutes, 0);
    });

    testWidgets('both planning footers accept a spoken date on Enter', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
  });
}
