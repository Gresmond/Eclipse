import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/smart_add.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:eclipse/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        birthday: false,
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
          birthday: false,
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

    test('parses this weekday, start/middle clauses, everyday phrasing, durations and venues', () {
      // "this Friday" / "this coming Monday" without leaving stray "this"
      final thisFri = parseQuickTask('Dentist this Friday', day); // Thu Nov 19
      expect((thisFri.name, thisFri.day), ('Dentist', DateTime(2026, 11, 20)));
      final thisMon = parseQuickTask('Gym this coming Monday', day);
      expect((thisMon.name, thisMon.day), ('Gym', DateTime(2026, 11, 23)));
      final onFri = parseQuickTask('Dentist on Friday', day);
      expect((onFri.name, onFri.day, onFri.repeat), ('Dentist', DateTime(2026, 11, 20), null));

      // Start & middle clause extraction + capitalization preservation
      final startTime = parseQuickTask('Tomorrow at 3pm call dentist', day);
      expect((startTime.name, startTime.day, startTime.minutes), ('Call dentist', DateTime(2026, 11, 20), 15 * 60));

      final midDate = parseQuickTask('Call Mum tomorrow about dinner', day);
      expect((midDate.name, midDate.day), ('Call Mum about dinner', DateTime(2026, 11, 20)));

      final startDay = parseQuickTask('On Friday buy groceries', day);
      expect((startDay.name, startDay.day), ('Buy groceries', DateTime(2026, 11, 20)));

      final startColon = parseQuickTask('Friday: pay rent', day);
      expect((startColon.name, startColon.day), ('Pay rent', DateTime(2026, 11, 20)));

      final startPlace = parseQuickTask('@Home fix shelf tomorrow', day);
      expect((startPlace.name, startPlace.location, startPlace.day), ('Fix shelf', 'Home', DateTime(2026, 11, 20)));

      final startRepeatUntil = parseQuickTask('Every Monday until 15 Dec take out bins', day);
      expect(
        (startRepeatUntil.name, startRepeatUntil.repeat, startRepeatUntil.day, startRepeatUntil.until),
        ('Take out bins', const RepeatRule.weekly({DateTime.monday}), DateTime(2026, 11, 23), DateTime(2026, 12, 15)),
      );

      final midSlash = parseQuickTask('Gym every Mon/Wed/Fri before work', day);
      expect(
        (midSlash.name, midSlash.repeat),
        ('Gym before work', const RepeatRule.weekly({DateTime.monday, DateTime.wednesday, DateTime.friday})),
      );

      // Everyday relative dates, parts of day, dot times & number words
      expect(parseQuickTask('Clean shed this weekend', day).day, DateTime(2026, 11, 21));
      expect(parseQuickTask('Clean shed on the weekend', day).day, DateTime(2026, 11, 21));
      expect(parseQuickTask('Visit Nan next weekend', day).day, DateTime(2026, 11, 28));
      expect(parseQuickTask('Pay rego next month', day).day, DateTime(2026, 12, 1));
      expect(parseQuickTask('Review in a month', day).day, DateTime(2026, 12, 19));
      expect(parseQuickTask('Dentist in 3 months', day).day, DateTime(2027, 2, 19));
      expect(parseQuickTask('Follow up in six days', day).day, DateTime(2026, 11, 25));
      expect(parseQuickTask('Check in in a couple of weeks', day).day, DateTime(2026, 12, 3));

      expect(parseQuickTask('Eat tomorrow at midday', day).minutes, 12 * 60);
      final tomMorn = parseQuickTask('Call Mum tomorrow morning', day);
      expect((tomMorn.name, tomMorn.day, tomMorn.minutes), ('Call Mum', DateTime(2026, 11, 20), 9 * 60));
      final friAft = parseQuickTask('Dentist Friday afternoon', day);
      expect((friAft.name, friAft.day, friAft.minutes), ('Dentist', DateTime(2026, 11, 20), 14 * 60));
      final thisEve = parseQuickTask('Stretch this evening', day);
      expect((thisEve.name, thisEve.day, thisEve.minutes), ('Stretch', day, 18 * 60));
      final tonight = parseQuickTask('Cook dinner tonight', day);
      expect((tonight.name, tonight.day, tonight.minutes), ('Cook dinner', day, 19 * 60));
      // Explicit clock time overrides vague part of day
      final tonight8 = parseQuickTask('Cook dinner tonight at 8pm', day);
      expect((tonight8.name, tonight8.day, tonight8.minutes), ('Cook dinner', day, 20 * 60));

      expect(parseQuickTask('Dinner 7.30pm', day).minutes, 19 * 60 + 30);
      expect(parseQuickTask('Training at 19.30', day).minutes, 19 * 60 + 30);

      // Everyday repeats & durations
      expect(
        parseQuickTask('Water plants every weekend', day).repeat,
        const RepeatRule.weekly({DateTime.saturday, DateTime.sunday}),
      );
      expect(
        parseQuickTask('Parkrun on weekends', day).repeat,
        const RepeatRule.weekly({DateTime.saturday, DateTime.sunday}),
      );
      expect(
        parseQuickTask('Medicate dog on weekdays', day).repeat,
        const RepeatRule.weekly({1, 2, 3, 4, 5}),
      );
      expect(
        parseQuickTask('Spin on Mon/Wed/Fri', day).repeat,
        const RepeatRule.weekly({1, 3, 5}),
      );
      expect(
        parseQuickTask('Team sync on Fridays', day).repeat,
        const RepeatRule.weekly({DateTime.friday}),
      );
      final every2ndFri = parseQuickTask('Payday every 2nd Friday', day);
      expect((every2ndFri.repeat, every2ndFri.day), (const RepeatRule.every(2, weeks: true), DateTime(2026, 11, 20)));
      expect(parseQuickTask('Audit every 3rd week', day).repeat, const RepeatRule.every(3, weeks: true));

      final every15th = parseQuickTask('Pay rent every 15th', day);
      expect((every15th.name, every15th.repeat, every15th.day), ('Pay rent', const RepeatRule.monthly(15), DateTime(2026, 12, 15)));
      final on15thEveryMonth = parseQuickTask('Pay rent on the 15th of every month', day);
      expect((on15thEveryMonth.name, on15thEveryMonth.repeat), ('Pay rent', const RepeatRule.monthly(15)));

      final for7Days = parseQuickTask('Take antibiotics every day for 7 days', day);
      expect(
        (for7Days.name, for7Days.repeat, for7Days.day, for7Days.until),
        ('Take antibiotics', const RepeatRule.every(1), day, DateTime(2026, 11, 25)),
      );
      final for4Weeks = parseQuickTask('Physio every Monday for 4 weeks', day);
      expect(
        (for4Weeks.name, for4Weeks.repeat, for4Weeks.day, for4Weeks.until),
        ('Physio', const RepeatRule.weekly({DateTime.monday}), DateTime(2026, 11, 23), DateTime(2026, 12, 20)),
      );

      // Lowercase common venues
      expect(parseQuickTask('Checkup at the dentist tomorrow', day).location, 'the dentist');
      expect(parseQuickTask('Send parcel at the post office tomorrow', day).location, 'the post office');
      expect(parseQuickTask('Take Bella at the vet tomorrow', day).location, 'the vet');
      expect(parseQuickTask('Meet Sam at the pub Friday', day).location, 'the pub');
    });

    test('auto-detects birthdays, shorter and combined reminders, and preserves literal safety', () {
      // Birthdays
      final mum = parseQuickTask("Mum's birthday 15 March", day);
      expect(
        (mum.name, mum.birthday, mum.repeat, mum.day, mum.minutes),
        ("Mum's birthday", true, const RepeatRule.yearly(1), DateTime(2027, 3, 15), null),
      );
      final alex = parseQuickTask('Alex birthday on 12/4', day);
      expect(
        (alex.name, alex.birthday, alex.repeat, alex.day),
        ('Alex birthday', true, const RepeatRule.yearly(1), DateTime(2027, 4, 12)),
      );
      final samLead = parseQuickTask('Birthday: Sam 5 June', day);
      expect(
        (samLead.name, samLead.birthday, samLead.repeat, samLead.day),
        ('Sam', true, const RepeatRule.yearly(1), DateTime(2027, 6, 5)),
      );
      final anaPlace = parseQuickTask("Ana's birthday 20 Nov @Rundle Mall", day);
      expect((anaPlace.birthday, anaPlace.location, anaPlace.day), (true, 'Rundle Mall', DateTime(2026, 11, 20)));
      final mumNoDate = parseQuickTask("Mum's birthday", day);
      expect((mumNoDate.name, mumNoDate.birthday, mumNoDate.day, mumNoDate.repeat), ("Mum's birthday", true, null, null));

      // Birthday reminders without needing a clock time
      final bdayRem = parseQuickTask("Mum's birthday 15 March remind me a day before and on the day", day);
      expect(bdayRem.birthday, isTrue);
      expect(bdayRem.reminders, Reminder.dayBefore.bit | Reminder.onTheDay.bit);
      expect(bdayRem.name, "Mum's birthday");

      // Invalid timed reminder on a birthday keeps full literal
      final bdayBadRem = parseQuickTask("Mum's birthday 15 March remind me 15m before", day);
      expect(bdayBadRem.name, "Mum's birthday 15 March remind me 15m before");
      expect(bdayBadRem.birthday, isFalse);

      // Birthday negative guards
      for (final text in [
        'Buy birthday cake tomorrow at 3pm',
        "Wrap Sam's birthday present Friday",
        "Alex's birthday dinner at 7pm",
      ]) {
        expect(parseQuickTask(text, day).birthday, isFalse, reason: text);
      }

      // Shorter & combined reminders
      expect(parseQuickTask('Dentist tomorrow at 3pm remind me 15m before', day).reminders, Reminder.quarterBefore.bit);
      expect(parseQuickTask('Dentist tomorrow at 3pm remind me 20m before', day).reminders, Reminder.twentyBefore.bit);
      expect(parseQuickTask('Dentist tomorrow at 3pm remind me 1h before', day).reminders, Reminder.hourBefore.bit);
      expect(parseQuickTask('Dentist tomorrow at 3pm remind me 1hr before', day).reminders, Reminder.hourBefore.bit);
      expect(parseQuickTask('Dentist tomorrow at 3pm remind me 24h before', day).reminders, Reminder.dayBefore.bit);
      expect(parseQuickTask('Dentist tomorrow at 3pm remind me 1d before', day).reminders, Reminder.dayBefore.bit);
      expect(
        parseQuickTask('Dentist tomorrow at 3pm remind me a day and an hour before', day).reminders,
        Reminder.dayBefore.bit | Reminder.hourBefore.bit,
      );
      expect(
        parseQuickTask('Dentist tomorrow at 3pm remind me 1d and 15m before', day).reminders,
        Reminder.dayBefore.bit | Reminder.quarterBefore.bit,
      );
      expect(
        parseQuickTask('Dentist tomorrow at 3pm remind me 1h, 20m and 15m before', day).reminders,
        Reminder.hourBefore.bit | Reminder.twentyBefore.bit | Reminder.quarterBefore.bit,
      );

      // Negative reminder guards stay literal
      for (final literalCase in [
        'Call at 3pm remind me 7m before',
        'Call tomorrow and remind me 15m before',
      ]) {
        expect(parseQuickTask(literalCase, day).name, literalCase, reason: literalCase);
      }

      // Literal safety cases
      expect(parseQuickTask('Morning walk tomorrow', day).minutes, isNull);
      expect(parseQuickTask('Morning walk tomorrow', day).name, 'Morning walk');
      expect(parseQuickTask('Evening stretch Friday', day).minutes, isNull);
      expect(parseQuickTask('Evening stretch Friday', day).name, 'Evening stretch');
      expect(parseQuickTask('Submit weekly report', day).repeat, isNull);
      expect(parseQuickTask('Submit weekly report', day).name, 'Submit weekly report');
      final hotel = parseQuickTask('Book hotel tomorrow for 3 days', day);
      expect((hotel.name, hotel.day, hotel.until, hotel.repeat), ('Book hotel for 3 days', DateTime(2026, 11, 20), null, null));
      for (final literalText in [
        'Install v2.10',
        'Buy 1.5L milk',
        'Sat nav repair',
        'Buy sun cream',
        'Prepare tomorrow breakfast',
      ]) {
        final p = parseQuickTask(literalText, day);
        expect((p.name, p.day, p.minutes, p.repeat), (literalText, null, null, null), reason: literalText);
      }
    });

    testWidgets('_DatedAdd pre-fills dialog details on Enter when date is missing and saves clean title', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();

      final further = find.byType(FurtherAheadCard);
      final field = find.descendant(of: further, matching: find.widgetWithText(TextField, 'Add task')).last;
      await tester.enterText(field, 'Dentist at 3pm @Clinic');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Dialog opens pre-filled with 3:00 pm and Clinic.
      expect(find.descendant(of: find.byType(Dialog), matching: find.text('3:00 pm')), findsOneWidget);
      expect(find.descendant(of: find.byType(Dialog), matching: find.text('Clinic')), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final firstFurther = DateTime(day.year, day.month, day.day + WeekCard.span + 1);
      final saved = state.todos[TodoScope.week]!.singleWhere((t) => t.text == 'Dentist');
      expect((saved.dueDate, saved.dueTime, saved.location), (firstFurther, 15 * 60, 'Clinic'));
    });

    testWidgets('Ctrl+N merges calendar-picked date with typed time, place and reminder + detailed preview', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      // Pick November 25 on the calendar first, then type natural language details.
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('25')));
      await tester.pumpAndSettle();

      final input = find.widgetWithText(TextField, 'Task name');
      await tester.enterText(input, 'Dentist at 3pm @Clinic remind me 1h before');
      await tester.pump();
      expect(find.text('3:00 pm'), findsWidgets);
      expect(find.text('Clinic'), findsWidgets);
      expect(find.text('Notify 1 hour before'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final saved = state.todos[TodoScope.week]!.singleWhere((t) => t.text == 'Dentist');
      expect(
        (saved.dueDate, saved.dueTime, saved.location, saved.reminders),
        (DateTime(2026, 11, 25), 15 * 60, 'Clinic', Reminder.hourBefore.bit),
      );
    });

    testWidgets('live preview shows Birthday badge and specific reminder wording', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();

      final further = find.byType(FurtherAheadCard);
      final field = find.descendant(of: further, matching: find.widgetWithText(TextField, 'Add task')).last;
      await tester.enterText(field, "Mum's birthday 15 March remind me on the day");
      await tester.pump();

      expect(find.descendant(of: further, matching: find.text('Birthday')), findsOneWidget);
      expect(find.descendant(of: further, matching: find.text('Notify on the day, at 9 am')), findsOneWidget);
      expect(find.descendant(of: further, matching: find.text('Reminder')), findsNothing);
    });
  });
}
