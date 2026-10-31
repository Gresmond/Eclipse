import 'dart:convert';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/today_view.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/theme/oklch.dart' show contrast;
import 'package:eclipse/widgets/status_cell.dart';
import 'package:eclipse/widgets/tile.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
      for (final label in ['Nothing due', 'Nothing more than a week away']) {
        final text = tester.widget<Text>(find.text(label));
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
}
