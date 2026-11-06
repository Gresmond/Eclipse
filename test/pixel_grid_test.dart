import 'dart:async';
import 'dart:convert';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/shell.dart';
import 'package:eclipse/widgets/app_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every shape that's drawn, at rest, whose edge isn't on a whole pixel.
List<String> offGrid([RenderObject? root]) {
  bool off(double v) => (v - v.roundToDouble()).abs() > 0.02;
  final view = RendererBinding.instance.renderViews.first;
  final hits = <String>[];
  void visit(RenderObject o) {
    if (o is RenderAnimatedOpacity && o.opacity.value == 0) return;
    if (o is RenderOpacity && o.opacity == 0) return;
    final paints = switch (o) {
      RenderDecoratedBox(:final decoration) =>
        decoration is! BoxDecoration ||
            (decoration.color?.a ?? 0) > 0 ||
            decoration.gradient != null ||
            decoration.border != null,
      RenderPhysicalShape() || RenderPhysicalModel() || RenderClipRRect() || RenderImage() => true,
      RenderCustomPaint(:final painter) => painter != null,
      _ => false,
    };
    if (paints && o is RenderBox && o.hasSize && !o.size.isEmpty) {
      final r = MatrixUtils.transformRect(o.getTransformTo(null), Offset.zero & o.size);
      if (r.overlaps(Offset.zero & view.size) && (off(r.left) || off(r.top) || off(r.right) || off(r.bottom))) {
        hits.add('$r ${(o.debugCreator?.toString() ?? '${o.runtimeType}').split(' ← ').take(8).join(' < ')}');
      }
    }
    o.visitChildren(visit);
  }

  visit(root ?? view);
  return hits;
}

void main() {
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

  // Odd and even, as a plain centre lands on half a pixel in an odd space.
  for (final size in const [Size(1265, 1380), Size(1266, 1381), Size(1401, 903), Size(1877, 1001)]) {
    testWidgets('everything at rest is on whole pixels at $size', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);

      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 400));
        }
      }

      RenderObject dialog() => t.renderObject(find.byType(Dialog).last);
      void close() => Navigator.of(appNavigator.currentContext!).pop();

      final store = Store.memory();
      for (final name in [
        'Sketch',
        'Read',
        'Walk',
        'Stretch',
        'Water',
        'Piano',
        'Letters',
        'A much longer ritual name that wraps on to a second line in the card',
        'Another',
      ]) {
        store.addHabit(2026, 11, name, addedOn: DateTime(2026, 11, 1));
      }
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 10));
      state.addTodo(TodoScope.today, 'A task with words');
      state.addTodo(TodoScope.week, 'Big project');
      state.setTodoSubtasks(TodoScope.week, state.todos[TodoScope.week]!.single, [
        const TodoSubtask('One', numbered: true),
        const TodoSubtask('Two', numbered: true),
      ]);
      state.addTodo(TodoScope.tomorrow, 'Something for tomorrow with a title long enough to wrap on to a second line');

      await t.pumpWidget(EclipseApp(state: state));
      await settle();
      expect(offGrid(), isEmpty, reason: 'Today');

      await t.tap(find.text('Nov').hitTestable());
      await settle();
      expect(offGrid(), isEmpty, reason: 'Month');

      unawaited(openSettings(appNavigator.currentContext!));
      await settle();
      expect(offGrid(dialog()), isEmpty, reason: 'Settings');
      await t.tap(find.text('Data').hitTestable());
      await settle();
      expect(offGrid(dialog()), isEmpty, reason: 'Settings, Data');
      close();
      await settle();

      await t.tap(find.text('Year').hitTestable());
      await settle();
      expect(offGrid(), isEmpty, reason: 'Year');

      state.toggleTraining();
      await settle();
      expect(offGrid(), isEmpty, reason: 'Training');
      state.toggleTraining();
      await settle();

      state.showToday();
      await settle();
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(find.text('A task with words').first));
      await settle();
      await t.tap(find.byTooltip('Add subtask').first, warnIfMissed: false);
      await settle();
      expect(offGrid(dialog()), isEmpty, reason: 'Subtask dialog');
      close();
      await settle();
      await t.tap(find.byTooltip('Edit task').first, warnIfMissed: false);
      await settle();
      expect(offGrid(dialog()), isEmpty, reason: 'Task editor');
      close();
      await settle();

      unawaited(
        showAppDialog<void>(
          context: appNavigator.currentContext!,
          builder: (_) => const AppAlertDialog(
            title: 'Hello',
            content: Text('Two words'),
            actions: [DialogConfirm(label: 'Save', onPressed: null)],
          ),
        ),
      );
      await settle();
      expect(offGrid(dialog()), isEmpty, reason: 'Alert');
      close();

      await mouse.removePointer();
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
      state.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
