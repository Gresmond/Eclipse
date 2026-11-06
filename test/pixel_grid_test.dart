import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/data/updates.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/screens/shell.dart';
import 'package:eclipse/screens/startup_error.dart';
import 'package:eclipse/training.dart';
import 'package:eclipse/widgets/app_dialog.dart';
import 'package:eclipse/widgets/status_cell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every shape that's drawn, at rest, with an edge part way across a pixel of
/// the screen: positions here are logical, so they're compared at [scale].
List<String> offGrid(double scale) {
  bool off(double logical) {
    final physical = logical * scale;
    return (physical - physical.roundToDouble()).abs() > 0.02;
  }

  final view = RendererBinding.instance.renderViews.first;
  final window = Offset.zero & (RendererBinding.instance.platformDispatcher.views.first.physicalSize / scale);
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
      // A round mark growing under the pointer has no straight edge to blur.
      RenderCustomPaint(:final painter) => painter != null && '${painter.runtimeType}' != '_CheckPainter',
      _ => false,
    };
    // The tour's light, drawn inside its painter, cuts round what it's showing.
    if (o is RenderCustomPaint && '${o.painter.runtimeType}' == '_SpotlightPainter') {
      final hole = (o.painter as dynamic).hole as Rect;
      if (!hole.isEmpty && (off(hole.left) || off(hole.top) || off(hole.right) || off(hole.bottom))) {
        hits.add('Tour light $hole');
      }
    }
    if (paints && o is RenderBox && o.hasSize && !o.size.isEmpty) {
      final r = MatrixUtils.transformRect(o.getTransformTo(null), Offset.zero & o.size);
      if (r.overlaps(window) && (off(r.left) || off(r.top) || off(r.right) || off(r.bottom))) {
        hits.add(
          '${[r.left, r.top, r.right, r.bottom].map((v) => v.toStringAsFixed(3)).join(' ')} ${(o.debugCreator?.toString() ?? '${o.runtimeType}').split(' ← ').take(8).join(' < ')}',
        );
      }
    }
    o.visitChildren(visit);
  }

  visit(view);
  return hits;
}

class _FakeUpdater extends Updater {
  @override
  String get actionLabel => 'Update and restart';
  @override
  Duration get checkEvery => const Duration(days: 1);
  @override
  Future<void> check() async {}
  @override
  Future<void> update() async {}
  @override
  void dismiss() {}
  void show(UpdateStatus s, {String? version, String? problem}) {
    newVersion = version;
    error = problem;
    // ignore: invalid_use_of_protected_member
    set(s);
  }
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

  // Odd and even, as a plain centre lands on half a pixel in an odd space;
  // a lighter and a darker theme; on screens of one and two pixels per unit.
  for (final (size, scale, theme) in const [
    (Size(1265, 1380), 1.0, 'Solar Eclipse'),
    (Size(1266, 1381), 1.0, 'Lunar Eclipse'),
    (Size(1401, 903), 1.0, 'Lunar Eclipse'),
    (Size(1877, 1001), 1.0, 'Solar Eclipse'),
    (Size(1265, 1380), 2.0, 'Lunar Eclipse'),
    (Size(1401, 903), 2.0, 'Solar Eclipse'),
    (Size(1400.5, 902.5), 2.0, 'Lunar Eclipse'),
  ]) {
    testWidgets('everything at rest is on whole pixels at $size x$scale in $theme', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      t.view.physicalSize = size * scale;
      t.view.devicePixelRatio = scale;
      addTearDown(t.view.reset);

      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 400));
        }
      }

      final problems = <String>[];
      final seen = <String>{};

      /// What's on screen, once [open] has run and it has settled.
      Future<void> scene(String name, Future<void> Function() open, {Pattern? shows}) async {
        try {
          await open();
          await settle();
          if (shows != null && find.textContaining(shows).evaluate().isEmpty) throw 'it isn\'t showing $shows';
          // Flutter's own can't be on whole pixels: see PixelTooltip.
          if (find.byWidgetPredicate((w) => w.runtimeType == Tooltip).evaluate().isNotEmpty) throw 'a plain Tooltip';
        } catch (e) {
          problems.add('[$name] did not open: ${e.toString().split('\n').take(3).join(' ')}');
          return;
        }
        for (final hit in offGrid(scale)) {
          if (seen.add(hit)) problems.add('[$name] $hit');
        }
      }

      void close() {
        final navigator = Navigator.of(appNavigator.currentContext!);
        if (navigator.canPop()) navigator.pop();
      }

      Future<void> tap(Finder f, {int buttons = kPrimaryButton}) =>
          t.tap(f.hitTestable().first, buttons: buttons, warnIfMissed: false);

      final home = Directory.systemTemp.createTempSync('eclipse-pixels');
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
      final sync = SyncService.load(home, store);
      final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 5, 10));
      state.setTheme(theme);
      state.addTodo(TodoScope.today, 'A task with words');
      state.addTodo(TodoScope.today, 'Remove me later');
      state.addTodo(TodoScope.week, 'Big project');
      state.setTodoSubtasks(TodoScope.week, state.todos[TodoScope.week]!.single, [
        const TodoSubtask('One', numbered: true),
        const TodoSubtask('Two', numbered: true),
      ]);
      state.addTodo(TodoScope.tomorrow, 'Something for tomorrow with a title long enough to wrap on to a second line');
      state.addRepeat('Bins', const RepeatRule.every(1), DateTime(2026, 11, 5), time: 9 * 60);
      for (var w = 6; w >= 0; w--) {
        final day = DateTime(2026, 11, 5).subtract(Duration(days: w * 7));
        for (final (name, group) in [
          ('Pec deck', MuscleGroup.chest),
          ('Calf raises with a long name', MuscleGroup.calves),
        ]) {
          final log = state.training;
          final e =
              log.exercises.where((x) => x.name == name).firstOrNull ??
              log.createExercise(name, group, bodyweight: false);
          log.addToDay(day, e);
          log.updateSet(
            log.session(day).firstWhere((s) => s.$1.uid == e.uid).$2.first,
            reps: 8,
            weight: 100.0 + w * 2.5,
          );
        }
      }
      final updater = _FakeUpdater();

      await t.pumpWidget(EclipseApp(state: state, updater: updater));
      await scene('Today', () async {});

      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(find.text('A task with words').first));
      await scene('Today, hovered row', () async {});

      await scene('Subtask dialog', () => tap(find.byTooltip('Add subtask')), shows: 'Number the subtasks');
      close();
      await settle();
      await scene('Task editor', () => tap(find.byTooltip('Edit task')), shows: 'Doesn’t repeat');
      await scene('Task editor, time', () => tap(find.text('Add a time')), shows: 'am');
      await t.tapAt(const Offset(2, 2));
      await settle();
      await scene('Task editor, repeat', () => tap(find.text('Doesn’t repeat')), shows: 'Monthly');
      close();
      await settle();

      await mouse.moveTo(t.getCenter(find.text('Bins').first));
      await settle();
      await scene('Ask which', () async {
        await tap(find.byTooltip('Edit task'));
        await settle();
        await t.enterText(
          find.descendant(of: find.byType(Dialog), matching: find.byType(EditableText)).first,
          'Bins out',
        );
        await settle();
        await tap(find.text('Save'));
      }, shows: 'This and future ones');
      close();
      await settle();
      if (find.byType(Dialog).evaluate().isNotEmpty) close();
      await settle();

      await scene('Due date dialog', () => tap(find.byTooltip('Pick a day')), shows: 'Add a time');
      close();
      await settle();

      for (final (name, version) in [('available', '26.11.1'), ('no version', null)]) {
        await scene('Update card, $name', () async => updater.show(UpdateStatus.available, version: version));
      }
      await scene('Update card, updating', () async => updater.show(UpdateStatus.updating));
      await scene(
        'Update card, failed',
        () async => updater.show(
          UpdateStatus.failed,
          problem: 'make: *** [all] Error 1 and some more text that goes on a while',
        ),
      );
      await scene('Update card, restarting', () async => updater.show(UpdateStatus.restarting));
      updater.show(UpdateStatus.none);
      await settle();

      await scene('Backup card', () async {
        state.backupProblem = BackupProblem.damaged;
        state.notifyListeners();
      });
      state.backupProblem = null;
      state.notifyListeners();
      await settle();

      await scene('Sync card, incoming', () async {
        sync.lastIncoming = Incoming({('journal', '2026-10-24'), ('journal', '2026-10-25')}, {'Remote laptop'});
        sync.incomingCount++;
        // ignore: invalid_use_of_protected_member
        sync.notifyListeners();
      });

      await scene('Undo card', () async {
        state.removeTodo(TodoScope.today, state.todos[TodoScope.today]!.firstWhere((x) => x.text == 'Remove me later'));
      });
      await settle();

      await scene('Sync card, waiting', () async {
        sync.newerFrom = {'Remote laptop'};
        sync.unreadFrom = {'Another computer with a long name'};
        sync.lastIncoming = null;
        // ignore: invalid_use_of_protected_member
        sync.notifyListeners();
        await t.pump(const Duration(seconds: 30));
      });

      sync.newerFrom = {};
      sync.unreadFrom = {};
      // ignore: invalid_use_of_protected_member
      sync.notifyListeners();
      await settle();

      await scene(
        'Note dialog',
        () => tap(find.byType(StatusCell), buttons: kMiddleMouseButton),
        shows: 'What happened?',
      );
      close();
      await settle();

      await scene('Appearance menu', () => tap(find.byTooltip('Appearance')), shows: 'Orchard Dawn');
      await t.tapAt(const Offset(2, 2));
      await settle();

      await scene('Tooltips', () async {
        await mouse.moveTo(t.getCenter(find.byTooltip('Settings').first));
        await t.pump(const Duration(seconds: 2));
      }, shows: 'Settings');
      await scene('Tooltips, odd width', () async {
        await mouse.moveTo(t.getCenter(find.byTooltip('Look back at another day').first));
        await t.pump(const Duration(seconds: 2));
      }, shows: 'Look back at another day');
      await mouse.moveTo(const Offset(2, 2));
      await settle();

      await scene('Reminder card', () async {
        state.reminderCards.add(
          ReminderAlert(
            uid: 'pixels',
            text: 'Dentist on the far side of town',
            day: DateTime(2026, 11, 5),
            time: 15 * 60,
            birthday: false,
            reminder: Reminder.quarterBefore,
          ),
        );
        state.notifyListeners();
      });
      state.reminderCards.clear();
      state.notifyListeners();
      await settle();

      await scene('Week card, drop dialog', () async {
        final drag = await t.startGesture(t.getCenter(find.text('Big project').first), kind: PointerDeviceKind.mouse);
        await drag.moveBy(const Offset(0, 20));
        await t.pump();
        await drag.moveTo(t.getCenter(find.text('Further ahead').first));
        await t.pump();
        await drag.up();
      });
      close();
      await settle();

      await scene('Tour', () async => state.startTour(), shows: 'Show me around');
      await scene('Tour step 2', () => tap(find.text('Show me around')), shows: 'Next');
      var steps = 2;
      while (find.text('Next').evaluate().isNotEmpty && steps < 20) {
        await scene('Tour step ${++steps}', () => t.tap(find.text('Next').first, warnIfMissed: false));
      }
      if (steps < 8) problems.add('the tour stopped at step $steps');
      state.endTour();
      await settle();

      await scene('Past day', () async => state.showDay(DateTime(2026, 11, 3)));
      state.showToday();
      await settle();

      await scene('Month', () => tap(find.text('Nov')));
      await scene('Ritual editor', () => tap(find.text('Edit rituals')));
      await tap(find.text('Done'));
      await settle();
      await scene('Sleep editor', () => tap(find.textContaining('Edit').last));
      await settle();

      unawaited(openSettings(appNavigator.currentContext!));
      await scene('Settings', () async {});
      await scene('Settings, appearance', () async {
        if (find.text('Holidays').evaluate().isNotEmpty) await t.ensureVisible(find.text('Holidays').first);
      });
      await scene('Holiday dialog', () async {
        await t.ensureVisible(find.text('Add').first);
        await settle();
        await tap(find.text('Add'));
      }, shows: 'Cancel');
      close();
      await settle();
      await scene('Settings, Data', () => tap(find.text('Data')));
      close();
      await settle();
      await scene('Search', () => tap(find.byTooltip('Search')));
      await scene('Search, results', () async {
        await t.enterText(find.byType(EditableText).first, 'theme');
      });
      await scene('Search, cleared', () async {
        await t.enterText(find.byType(EditableText).first, '');
      });
      close();
      await settle();

      await scene('Year', () => tap(find.text('Year')));
      await scene('Calendar', () async => state.toggleCalendar(), shows: 'MON');
      await scene('Training', () async => state.toggleTraining());
      await scene('Training, group menu', () {
        return tap(find.byWidgetPredicate((w) => '${w.runtimeType}' == '_GroupPill'));
      }, shows: 'CALVES');
      await t.tapAt(const Offset(2, 2));
      await settle();
      await scene('Training, day menu', () => tap(find.text('Another day')), shows: 'November');
      await t.tapAt(const Offset(2, 2));
      await settle();
      await scene('Training, add exercise', () async {
        await t.enterText(find.byType(EditableText).last, 'squat');
      }, shows: 'SHOULDERS');
      await t.tapAt(const Offset(2, 2));
      state.toggleTraining();
      await settle();

      // Too short for what's in it, where the rows stand as tall as their names
      // and the page scrolls.
      t.view.physicalSize = const Size(1100, 700) * scale;
      await scene('Year, short window', () async {});
      await scene('Today, short window', () async => state.showToday());
      await scene('Month, short window', () => tap(find.text('Nov')));
      t.view.physicalSize = size * scale;
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
      await scene('Alert', () async {});
      close();

      await mouse.removePointer();
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
      sync.dispose();
      state.dispose();
      home.deleteSync(recursive: true);
      debugDefaultTargetPlatformOverride = null;
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  // Fractional scales aren't held to whole pixels, as every fixed spacing would
  // have to round too, but rounding mustn't overflow anything.
  for (final scale in const [1.25, 1.5]) {
    testWidgets('nothing overflows at x$scale', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      t.view.physicalSize = const Size(1401, 903) * scale;
      t.view.devicePixelRatio = scale;
      addTearDown(t.view.reset);
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 400));
        }
      }

      final store = Store.memory();
      for (final name in ['Sketch', 'Read', 'A much longer ritual name that wraps on to a second line in the card']) {
        store.addHabit(2026, 11, name, addedOn: DateTime(2026, 11, 1));
      }
      final state = AppState(store, clock: () => DateTime(2026, 11, 5, 10));
      state.addTodo(TodoScope.today, 'A task with words');
      await t.pumpWidget(EclipseApp(state: state));
      await settle();
      await t.tap(find.text('Nov').hitTestable());
      await settle();
      unawaited(openSettings(appNavigator.currentContext!));
      await settle();
      Navigator.of(appNavigator.currentContext!).pop();
      await settle();
      await t.tap(find.text('Year').hitTestable());
      await settle();
      state.toggleTraining();
      await settle();
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
      state.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final (size, scale) in const [(Size(1401, 903), 1.0), (Size(1266, 1381), 1.0), (Size(1401, 903), 2.0)]) {
    testWidgets('the startup error and saved copies are on whole pixels at $size x$scale', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      t.view.physicalSize = size * scale;
      t.view.devicePixelRatio = scale;
      addTearDown(t.view.reset);
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 400));
        }
      }

      await t.pumpWidget(StartupErrorApp(error: const FileSystemException('Disk is full')));
      await settle();
      final hits = {'Startup error': offGrid(scale)};
      await t.pumpWidget(const SizedBox());
      await settle();

      final home = Directory.systemTemp.createTempSync('eclipse-pixels');
      final store = Store.memory();
      final backups = Backups(Directory('${home.path}/backups'));
      await t.runAsync(() async {
        backups.dir.createSync(recursive: true);
        store.saveCopy('${backups.dir.path}/productivity-2026-11-04.db');
      });
      final state = AppState(store, backups: backups, clock: () => DateTime(2026, 11, 5, 10));
      await t.pumpWidget(EclipseApp(state: state));
      await settle();
      unawaited(openSettings(appNavigator.currentContext!, ribbon: 1));
      await settle();
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await settle();
      hits['Saved copies'] = offGrid(scale);
      expect(find.text('Restore'), findsWidgets);
      await t.tap(find.text('Restore').first);
      await settle();
      hits['Restore, asking'] = offGrid(scale);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
      state.dispose();
      home.deleteSync(recursive: true);
      debugDefaultTargetPlatformOverride = null;
      hits.removeWhere((_, list) => list.isEmpty);
      expect(hits, isEmpty);
    });
  }

  testWidgets('sync\'s other cards are on whole pixels', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    t.view.physicalSize = const Size(1401, 903);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final home = Directory.systemTemp.createTempSync('eclipse-pixels');
    File('${home.path}/sync.json').writeAsStringSync(
      '{"refresh": "old", "email": "me@example.com", "stopped": "Eclipse stopped syncing on its own for a while."}',
    );
    final store = Store.memory();
    final sync = SyncService.load(home, store);
    final state = AppState(store, sync: sync, clock: () => DateTime(2026, 11, 5, 10));
    await t.pumpWidget(EclipseApp(state: state));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 400));
    }
    final hits = offGrid(1);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
    sync.dispose();
    state.dispose();
    home.deleteSync(recursive: true);
    debugDefaultTargetPlatformOverride = null;
    expect(hits, isEmpty);
  });
}
