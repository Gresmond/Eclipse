import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/progress_ring.dart';
import 'package:eclipse/widgets/rolling_number.dart';
import 'package:eclipse/widgets/status_cell.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:eclipse/widgets/tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
    expect(find.text('Every ritual done. Beautiful.'), findsOneWidget);
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
    expect(time.style!.fontFamily, Fonts.time);
    expect(time.style!.fontSize, count.style!.fontSize);
    expect(time.style!.color, count.style!.color);
    expect(tester.getTopLeft(find.text('5:40 pm')).dy, lessThan(tester.getTopLeft(find.text('Timed task')).dy));
    expect(find.byType(ProgressRing), findsNothing);
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
      expect(actions, findsNWidgets(3));
      final colours = <Color?>[];
      final insets = <Offset>[];
      final hoverFills = <Color?>[];
      for (final element in actions.evaluate()) {
        final action = find.byWidget(element.widget);
        expect(tester.getSize(action), const Size.square(28));
        final bounds = tester.getRect(action);
        final card = tester.getRect(find.ancestor(of: action, matching: find.byType(Tile)).first);
        insets.add(Offset(card.right - bounds.right, bounds.top - card.top));
        final button = tester.widget<IconButton>(find.descendant(of: action, matching: find.byType(IconButton)));
        expect((button.icon as Icon).size, 16);
        expect(button.style!.shape!.resolve({}), isA<CircleBorder>());
        colours.add(button.style!.foregroundColor!.resolve({}));
        hoverFills.add(button.style!.backgroundColor!.resolve({WidgetState.hovered}));
      }
      for (final inset in insets.skip(1)) {
        expect(inset.dx, closeTo(insets.first.dx, 0.1));
        expect(inset.dy, closeTo(insets.first.dy, 0.1));
      }
      expect(colours.toSet().length, 1);
      expect(hoverFills.toSet().length, 1);
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
}
