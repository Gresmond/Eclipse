import 'dart:convert';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/today_view.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/theme/oklch.dart' show contrast;
import 'package:eclipse/widgets/rolling_number.dart';
import 'package:eclipse/widgets/status_cell.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:eclipse/widgets/tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('calendar top follows the first checkbox across wrapping, resizing and completion', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    store.addHabit(2026, 10, 'A long first ritual name that wraps when the window is narrow');
    for (var i = 0; i < 6; i++) {
      store.addHabit(2026, 10, 'Ritual $i');
    }
    final state = AppState(store, clock: () => DateTime(2026, 10, 31));
    addTearDown(() {
      state.dispose();
      store.close();
    });
    state.addTodo(TodoScope.month, 'Future task', dueDate: DateTime(2026, 11, 11));
    for (final size in const [Size(1680, 1160), Size(1000, 1040), Size(1440, 900), Size(2550, 1390)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
      final calendar = find.ancestor(of: find.text('NOV'), matching: find.byType(Container)).first;
      expect(
        tester.getTopLeft(calendar).dy,
        closeTo(tester.getTopLeft(find.byType(StatusCell).first).dy, 0.1),
        reason: '$size',
      );
      expect(tester.takeException(), isNull);
    }
    for (final habit in state.habits) {
      state.selectStatus(state.today, habit, HabitStatus.done);
    }
    await tester.pumpAndSettle();
    final calendar = find.ancestor(of: find.text('NOV'), matching: find.byType(Container)).first;
    expect(find.text('Every ritual done. Beautiful.'), findsNothing);
    expect(tester.getTopLeft(calendar).dy, closeTo(tester.getTopLeft(find.byType(StatusCell).first).dy, 0.1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('status pills reuse clock digits, roll counts and ease their width while labels fade', (tester) async {
    Future<void> show(String label, {bool complete = false}) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(sunrisePalette),
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [StatusPill(label: label, complete: complete)],
            ),
          ),
        ),
      ),
    );
    await show('9 OPEN');
    await tester.pumpAndSettle();
    final originalState = tester.state(find.byType(RollingNumber));
    final before = tester.getSize(find.byType(StatusPill)).width;
    await show('10 OPEN');
    await tester.pump();
    expect(tester.state(find.byType(RollingNumber)), same(originalState));
    expect(tester.getSize(find.byType(StatusPill)).width, closeTo(before, 0.01));
    await tester.pump(Motion.morph ~/ 2);
    final during = tester.getSize(find.byType(StatusPill)).width;
    final rolling = find.descendant(of: find.byType(RollingNumber), matching: find.byType(SlideTransition));
    expect(tester.widgetList<SlideTransition>(rolling).any((s) => s.position.value.dy.abs() > 0.01), isTrue);
    await tester.pumpAndSettle();
    final after = tester.getSize(find.byType(StatusPill)).width;
    expect(during, greaterThan(before));
    expect(during, lessThan(after));

    await show('ALL DONE', complete: true);
    await tester.pump();
    final fading = find.ancestor(of: find.text('ALL DONE'), matching: find.byType(FadeTransition)).first;
    expect(tester.widget<FadeTransition>(fading).opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(find.text('ALL DONE'), findsOneWidget);
    expect(find.bySemanticsLabel('10 OPEN'), findsNothing);
    expect(tester.getSize(find.byType(StatusPill)).height, 28);
    expect(tester.takeException(), isNull);
  });

  testWidgets('planned pill grows for double-digit counts and stays beside the heading', (tester) async {
    tester.view.physicalSize = const Size(1680, 1160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 31));
    addTearDown(() {
      state.dispose();
      store.close();
    });
    for (final scope in TodoScope.values) {
      for (final task in [...state.todos[scope]!]) {
        state.removeTodo(scope, task);
      }
    }
    for (var i = 0; i < 9; i++) {
      state.addTodo(TodoScope.month, 'Future task $i', dueDate: DateTime(2026, 11, 11));
    }
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    Finder pill(String label) => find.ancestor(of: find.bySemanticsLabel(label), matching: find.byType(StatusPill));
    final singleWidth = tester.getSize(pill('9 PLANNED')).width;
    for (var i = 9; i < 14; i++) {
      state.addTodo(TodoScope.month, 'Future task $i', dueDate: DateTime(2026, 11, 11));
    }
    await tester.pumpAndSettle();
    final badge = tester.getRect(pill('14 PLANNED'));
    final text = tester.getRect(find.bySemanticsLabel('14 PLANNED'));
    final title = tester.getRect(find.text('Further ahead'));
    expect(badge.width, greaterThan(singleWidth));
    expect(badge.height, 28);
    expect(text.left - badge.left, greaterThanOrEqualTo(10));
    expect(badge.right - text.right, greaterThanOrEqualTo(10));
    expect(badge.center.dy, closeTo(title.center.dy, 0.1));
    expect(badge.left, greaterThan(title.right));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dashboard keeps the approved task typography, pills and date tiles', (tester) async {
    tester.view.physicalSize = const Size(1680, 1160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 31));
    addTearDown(() {
      state.dispose();
      store.close();
    });
    for (final scope in TodoScope.values) {
      for (final task in [...state.todos[scope]!]) {
        state.removeTodo(scope, task);
      }
    }
    state.addTodo(TodoScope.tomorrow, 'Timed task', time: 17 * 60 + 40);
    final task = state.todos[TodoScope.tomorrow]!.single;
    state.setTodoSubtasks(TodoScope.tomorrow, task, const [
      TodoSubtask('One'),
      TodoSubtask('Two'),
      TodoSubtask('Three'),
    ]);
    state.addTodo(TodoScope.month, 'Future task', dueDate: DateTime(2026, 11, 11));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final time = tester.widget<Text>(find.text('5:40 pm'));
    final count = tester.widget<Text>(find.text('0 of 3 subtasks complete'));
    expect(time.style!.fontFamily, Fonts.taskTime);
    expect(count.style!.fontFamily, isNot(Fonts.taskTime));
    expect(time.style!.fontSize, count.style!.fontSize);
    expect(time.style!.color, count.style!.color);
    expect(tester.getTopLeft(find.text('5:40 pm')).dy, lessThan(tester.getTopLeft(find.text('Timed task')).dy));
    expect(find.text('SATURDAY'), findsOneWidget);
    expect(find.text('31 October'), findsOneWidget);
    expect(tester.getTopLeft(find.text('SATURDAY')).dy, lessThan(tester.getTopLeft(find.text('31 October')).dy));
    final tile = find.ancestor(of: find.text('NOV'), matching: find.byType(Container)).first;
    expect(tester.getSize(tile).width, 56);
    final pill = find.ancestor(of: find.bySemanticsLabel('1 PLANNED'), matching: find.byType(StatusPill)).first;
    expect(tester.getSize(pill).height, 28);
    expect(tester.getSize(pill).width, greaterThanOrEqualTo(76));
    final later = find.byType(FurtherAheadCard);
    final week = find.byType(WeekCard);
    final laterWidth = tester.getSize(later).width;
    expect(laterWidth / tester.getSize(week).width, closeTo(17 / 22, 0.001));
    final checkbox = find.byType(StatusCell).first;
    expect(tester.getTopLeft(tile).dy, closeTo(tester.getTopLeft(checkbox).dy, 0.1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('header actions share icon, target, pill and colour in both toggle states', (tester) async {
    tester.view.physicalSize = const Size(1680, 1160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final directory = Directory.systemTemp.createTempSync('eclipse-header-test-');
    final store = Store.memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 31), journalFiles: JournalFiles(directory));
    await state.flushFiles();
    addTearDown(() {
      state.dispose();
      store.close();
      directory.deleteSync(recursive: true);
    });
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    void check() {
      final actions = find.byType(HeaderIconButton);
      final statePalette = actions.first.evaluate().single.palette;
      expect(actions, findsNWidgets(3));
      final colours = <(bool, Color?)>[];
      final insets = <Offset>[];
      final hoverFills = <(bool, Color?)>[];
      for (final element in actions.evaluate()) {
        final action = find.byWidget(element.widget);
        expect(tester.getSize(action), const Size.square(28));
        final bounds = tester.getRect(action);
        final card = tester.getRect(find.ancestor(of: action, matching: find.byType(Tile)).first);
        insets.add(Offset(card.right - bounds.right, bounds.top - card.top));
        final button = tester.widget<IconButton>(find.descendant(of: action, matching: find.byType(IconButton)));
        expect((button.icon as Icon).size, 16);
        expect(button.style!.shape!.resolve({}), isA<CircleBorder>());
        final active = (element.widget as HeaderIconButton).active;
        colours.add((active, button.style!.foregroundColor!.resolve({})));
        hoverFills.add((active, button.style!.backgroundColor!.resolve({WidgetState.hovered})));
      }
      for (final inset in insets.skip(1)) {
        expect(inset.dx, closeTo(insets.first.dx, 0.1));
        expect(inset.dy, closeTo(insets.first.dy, 0.1));
      }
      for (final (active, colour) in colours) {
        expect(colour, active ? statePalette.onDone : statePalette.inkMuted.withValues(alpha: 0.8));
      }
      for (final (active, fill) in hoverFills) {
        expect(fill, active ? statePalette.done : statePalette.empty.withValues(alpha: 0.8));
      }
    }

    check();
    state.toggleWeekEmptyDays();
    state.toggleLaterBirthdays();
    await tester.pumpAndSettle();
    check();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('birthday text and countdown use the same left edge as meetings', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 31));
    addTearDown(() {
      state.dispose();
      store.close();
    });
    state.addTodo(TodoScope.month, 'Meeting with Georgia and Ben', dueDate: DateTime(2026, 11, 11), time: 11 * 60);
    state.addTodo(TodoScope.month, 'Papa Dawe’s Birthday', dueDate: DateTime(2026, 11, 30), birthday: true);
    state.addRepeat('Dad’s Birthday', const RepeatRule.yearly(1), DateTime(2026, 12, 7), birthday: true);
    for (final width in [1440.0, 1680.0, 2550.0]) {
      tester.view.physicalSize = Size(width, 1390);
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
      final x = tester.getTopLeft(find.text('Meeting with Georgia and Ben')).dx;
      for (final label in ['Papa Dawe’s Birthday', 'Dad’s Birthday']) {
        expect(tester.getTopLeft(find.text(label)).dx, closeTo(x, 0.5), reason: '$label at $width');
      }
      for (final label in ['In 30 days', 'In 37 days']) {
        expect(
          tester.getTopLeft(find.text(label)).dx,
          closeTo(x + 20, 0.5),
          reason: 'countdown text follows its 12 px icon and 8 px gap',
        );
      }
      expect(find.text('Birthday'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sleep times use the standard delayed hover tooltip instead of inline text', (tester) async {
    tester.view.physicalSize = const Size(1680, 1160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 31));
    addTearDown(() {
      state.dispose();
      store.close();
    });
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final time = clockLabel(state.sleepHabits.first.minutes!);
    expect(find.text(time), findsNothing);
    expect(find.byTooltip(time), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Rise Early')));
    await tester.pump(const Duration(milliseconds: 599));
    expect(find.text(time), findsNothing);
    await tester.pump(const Duration(milliseconds: 201));
    expect(find.text(time), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  });

  group('consistency and sizing checks', () {
    setUpAll(() async {
      final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final family in manifest.cast<Map<String, dynamic>>()) {
        final loader = FontLoader(family['family'] as String);
        for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
          loader.addFont(rootBundle.load(font['asset'] as String));
        }
        await loader.load();
      }
    });

    testWidgets('narrow dashboard preserves readable columns and task drafts across resizing', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = Store.memory();
      final state = AppState(store, clock: () => DateTime(2026, 10, 31));
      addTearDown(() {
        state.dispose();
        store.close();
      });
      state.addTodo(TodoScope.month, 'A future meeting', dueDate: DateTime(2026, 11, 11));
      tester.view.physicalSize = const Size(1280, 1000);
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
      final referenceWidth = tester.getSize(find.byType(WeekCard)).width;
      final field = find.descendant(of: find.byType(WeekCard), matching: find.byType(TextField)).last;
      await tester.enterText(field, 'Keep this draft');

      for (final width in [800.0, 860.0, 900.0, 1000.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(WeekCard)).width, closeTo(referenceWidth, 0.1));
        expect(tester.widget<TextField>(field).controller!.text, 'Keep this draft');
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        expect(tester.renderObject<RenderParagraph>(find.text('Further ahead')).didExceedMaxLines, isFalse);
        expect(tester.takeException(), isNull);
      }

      tester.view.physicalSize = const Size(800, 1000);
      await tester.pumpAndSettle();
      final horizontal = find.descendant(
        of: find.byType(TodayView),
        matching: find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
      );
      await tester.drag(horizontal, const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(find.text('Further ahead').hitTestable(), findsOneWidget);
      expect(find.text('A future meeting').hitTestable(), findsOneWidget);
      expect(tester.getRect(find.byType(FurtherAheadCard)).right, closeTo(800 - 32, 0.1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('scaled pills keep their text inside and completed pills fit every palette', (tester) async {
      for (final palette in palettes) {
        for (final (label, complete) in [('14 PLANNED', false), ('10 OPEN', false), ('ALL DONE', true)]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(palette),
              home: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Scaffold(
                  body: Center(
                    child: StatusPill(label: label, complete: complete),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final pill = tester.getRect(find.byType(StatusPill));
          final texts = find.descendant(of: find.byType(StatusPill), matching: find.byType(Text));
          for (final element in texts.evaluate()) {
            final text = element.widget as Text;
            if (text.data?.isEmpty ?? true) continue;
            final bounds = tester.getRect(find.byWidget(text));
            expect(bounds.top - pill.top, greaterThanOrEqualTo(4), reason: '${palette.name}: $label');
            expect(pill.bottom - bounds.bottom, greaterThanOrEqualTo(4), reason: '${palette.name}: $label');
          }
          expect(pill.height, greaterThan(28));
          if (complete) {
            final container = tester.widget<AnimatedContainer>(
              find.descendant(of: find.byType(StatusPill), matching: find.byType(AnimatedContainer)),
            );
            final fill = (container.decoration! as BoxDecoration).color!;
            final ink = tester.widget<Text>(find.text('ALL DONE')).style!.color!;
            expect(contrast(ink, fill), greaterThanOrEqualTo(4.5), reason: palette.name);
            expect(contrast(fill, palette.tile), lessThan(2), reason: 'subtle surface in ${palette.name}');
          }
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('Further ahead only says nothing but birthdays when some are hidden', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1680, 1160);
      addTearDown(tester.view.reset);
      final store = Store.memory();
      final state = AppState(store, clock: () => DateTime(2026, 10, 31));
      addTearDown(() {
        state.dispose();
        store.close();
      });
      for (final scope in TodoScope.values) {
        for (final task in [...state.todos[scope]!]) {
          state.removeTodo(scope, task);
        }
      }
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
      expect(find.text('Nothing planned.'), findsOneWidget);
      state.toggleLaterBirthdays();
      await tester.pumpAndSettle();
      expect(find.text('Nothing planned.'), findsOneWidget);
      state.addTodo(TodoScope.month, 'Ana', dueDate: DateTime(2026, 12, 20), birthday: true);
      await tester.pumpAndSettle();
      expect(find.text('Nothing but birthdays.'), findsOneWidget);
      expect(find.text('Nothing planned.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('empty states and task-entry hints stay readable and share typography in every theme', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1680, 1160);
      addTearDown(tester.view.reset);
      final store = Store.memory();
      final state = AppState(store, clock: () => DateTime(2026, 10, 31));
      addTearDown(() {
        state.dispose();
        store.close();
      });
      for (final scope in TodoScope.values) {
        for (final task in [...state.todos[scope]!]) {
          state.removeTodo(scope, task);
        }
      }
      await tester.pumpWidget(EclipseApp(state: state));
      for (final palette in palettes) {
        state.setTheme(palette.name);
        await tester.pumpAndSettle();
        final fields = tester
            .widgetList<TextField>(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Add task'))
            .toList();
        expect(fields.length, greaterThanOrEqualTo(3));
        for (final field in fields) {
          expect(field.style, fields.first.style);
          final hint = field.decoration!.hintStyle!;
          for (final opacity in [0.0, 0.45, 0.65]) {
            final surface = Color.alphaBlend(palette.empty.withValues(alpha: opacity), palette.tile);
            expect(contrast(hint.color!, surface), greaterThanOrEqualTo(4.5), reason: palette.name);
          }
        }
        for (final label in ['Nothing due.', 'Nothing planned.']) {
          final text = tester.widget<Text>(find.text(label));
          expect(text.style!.fontSize, 15);
          expect(contrast(text.style!.color!, palette.tile), greaterThanOrEqualTo(4.5), reason: palette.name);
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('date tile and first ritual checkbox align with enlarged text', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1680, 1160);
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = Store.memory();
      store.addHabit(2026, 10, 'A ritual with a name that can wrap');
      final state = AppState(store, clock: () => DateTime(2026, 10, 31));
      addTearDown(() {
        state.dispose();
        store.close();
      });
      state.addTodo(TodoScope.month, 'A future meeting', dueDate: DateTime(2026, 11, 11));
      for (final scale in [1.0, 1.3, 2.0]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await tester.pumpWidget(EclipseApp(state: state));
        await tester.pumpAndSettle();
        final date = find.ancestor(of: find.text('NOV'), matching: find.byType(Container)).first;
        expect(tester.getTopLeft(date).dy, closeTo(tester.getTopLeft(find.byType(StatusCell).first).dy, 0.1));
        expect(tester.renderObject<RenderParagraph>(find.text('Further ahead')).didExceedMaxLines, isFalse);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a streak waits for the page, both ways, rather than popping in', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = Store.memory();
      final habit = store.addHabit(2026, 11, 'Sketch', addedOn: DateTime(2026, 11, 1));
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 10));
      addTearDown(() {
        state.dispose();
        store.close();
      });
      store.setEntry('2026-11-04', habit.id, HabitStatus.done);
      store.setEntry('2026-11-05', habit.id, HabitStatus.done);
      state.showDay(DateTime(2026, 11, 2));
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
      final flame = find.byIcon(Icons.local_fire_department_rounded);
      expect(flame, findsNothing);
      double shown() => tester
          .widget<FadeTransition>(find.ancestor(of: flame, matching: find.byType(FadeTransition)).first)
          .opacity
          .value;

      state.showToday();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(shown(), 0, reason: 'nothing new shows until the old day has faded');
      await tester.pump(const Duration(milliseconds: 120));
      expect(shown(), inExclusiveRange(0, 1), reason: 'partway through the page fade');
      await tester.pumpAndSettle();
      expect(shown(), 1);

      state.showDay(DateTime(2026, 11, 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(shown(), inExclusiveRange(0, 1), reason: 'still fading out with the page');
      await tester.pumpAndSettle();
      expect(flame, findsNothing);
    });

    test('a past day has the streak it ended with', () {
      final store = Store.memory();
      final state = AppState(store, clock: () => DateTime(2026, 11, 6, 10));
      addTearDown(() {
        state.dispose();
        store.close();
      });
      final habit = store.addHabit(2026, 11, 'Sketch', addedOn: DateTime(2026, 11, 1));
      for (final day in ['01', '02', '04', '05', '06']) {
        store.setEntry('2026-11-$day', habit.id, HabitStatus.done);
      }
      (int, int) on(int day) => state.streaksOn(habit, DateTime(2026, 11, day));
      expect(on(2), (2, 2));
      expect(on(3), (0, 2), reason: 'left blank, so the run ended');
      expect(on(5), (2, 2));
      expect(on(6), (3, 3));
      state.selectStatus(DateTime(2026, 11, 5), habit, HabitStatus.missed);
      expect(on(5), (0, 2), reason: 'follows a correction');
    });

    testWidgets('another day rolls the count in a pill that stays put', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = Store.memory();
      final habit = store.addHabit(2026, 11, 'Sketch', addedOn: DateTime(2026, 11, 1));
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 10));
      addTearDown(() {
        state.dispose();
        store.close();
      });
      for (final day in ['01', '02', '03', '04', '05']) {
        store.setEntry('2026-11-$day', habit.id, HabitStatus.done);
      }
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
      final flame = find.byIcon(Icons.local_fire_department_rounded);
      final number = find.descendant(
        of: find.ancestor(of: flame, matching: find.byType(Row)).first,
        matching: find.byType(RollingNumber),
      );
      final at = tester.getTopLeft(flame);
      final kept = tester.element(number);

      state.showDay(DateTime(2026, 11, 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.element(number), same(kept), reason: 'the same pill, so its number rolls');
      expect(tester.widget<RollingNumber>(number).value, 2);
      final fade = tester.widget<FadeTransition>(find.ancestor(of: flame, matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, 1, reason: 'the pill itself never fades');
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(flame), at);

      state.showToday();
      await tester.pumpAndSettle();
      state.clear(DateTime(2026, 11, 5), habit);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.element(number), same(kept), reason: 'a new count on the same day rolls too');
      expect(tester.widget<RollingNumber>(number).value, 4);
    });

    testWidgets('only the day\'s name or date is in full ink, not its weekday', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = Store.memory();
      final state = AppState(store, clock: () => DateTime(2026, 11, 6, 10));
      addTearDown(() {
        state.dispose();
        store.close();
      });
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
      Map<String, Color?> heading(String ends) {
        final text = tester.widget<RichText>(
          find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().endsWith(ends)).first,
        );
        final colours = <String, Color?>{};
        text.text.visitChildren((span) {
          if (span is TextSpan && span.text != null) colours[span.text!] = span.style?.color;
          return true;
        });
        return colours;
      }

      state.showDay(DateTime(2026, 11, 5));
      await tester.pumpAndSettle();
      final yesterday = heading('Thursday');
      final ink = yesterday['Yesterday'], grey = yesterday['5 Nov'];
      expect(grey, isNot(ink));
      expect(yesterday['Thursday'], grey);
      state.showDay(DateTime(2026, 11, 4));
      await tester.pumpAndSettle();
      expect(heading('Wednesday')['4 Nov'], ink);
      expect(heading('Wednesday')['Wednesday'], grey);
    });
  });
}
