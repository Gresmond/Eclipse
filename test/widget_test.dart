import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as path;
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/data_folder.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/night_light.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/data/updates.dart';
import 'package:eclipse/data/windows_night_light.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/screens/today_view.dart';
import 'package:eclipse/screens/month_view.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/theme/oklch.dart';
import 'package:eclipse/widgets/status_cell.dart';
import 'package:eclipse/widgets/tile.dart';
import 'package:eclipse/widgets/day_picker.dart';
import 'package:eclipse/widgets/todo_panel.dart';
import 'package:eclipse/widgets/time_wheel.dart';

/// Pass --dart-define=SCREENSHOT_DIR=/some/dir to save PNGs of each view.
const _shotDir = String.fromEnvironment('SCREENSHOT_DIR');

var _fontsLoaded = false;

/// Loads every font registered in pubspec.yaml (tests otherwise render
/// placeholder boxes). Fonts stay registered for the rest of the file.
Future<void> _loadFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
}

/// Takes a database back to before sync (version 7): its triggers, tables
/// and the ids that mean the same on every computer.
void _undoSync(Database db) {
  for (final r in db.select("SELECT name FROM sqlite_master WHERE type = 'trigger'")) {
    db.execute('DROP TRIGGER ${r['name']}');
  }
  db.execute('''
    ALTER TABLE month_habits DROP COLUMN added_on; ALTER TABLE month_habits DROP COLUMN days;
    DROP TABLE habit_months; DROP TABLE todo_history;
    DROP INDEX entries_habit_day; DROP INDEX sleep_notes_item_month;
    DROP TABLE sync_reg; DROP TABLE sync_dirty; DROP TABLE sync_seen;
    DROP INDEX habits_uid; ALTER TABLE habits DROP COLUMN uid;
    DROP INDEX todos_uid; ALTER TABLE todos DROP COLUMN uid;
  ''');
}

/// A store with eight synthetic rituals for persistence and widget tests.
Store _testStore() => _fillTestStore(Store.memory());

/// Adds synthetic fixtures, unless [store] has rituals already.
Store _fillTestStore(Store store) {
  if (!store.isEmpty) return store;
  const names = [
    'Sort cards',
    'Label folders',
    'Check labels',
    'Sort stamps',
    'Review sample checklist',
    'File notes',
    'Sort sample cards, labels, folders, and spare supplies',
    'Sketch',
  ];
  // Alternating statuses are generated test data, not an imported daily record.
  for (final (i, name) in names.indexed) {
    final h = store.addHabit(2026, 10, name);
    store.setEntry('2026-10-01', h.id, i.isEven ? HabitStatus.done : HabitStatus.missed);
  }
  return store;
}

Future<void> _shoot(WidgetTester tester, String name) async {
  if (_shotDir.isEmpty) return;
  // The root layer, so popups and dialogs in the overlay are included.
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(Offset.zero & view.size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_shotDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  group('persistence', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('productivity_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('habits, notes, to-dos and journal survive a reopen', () async {
      final path = '${dir.path}/test.db';
      final day = DateTime(2026, 10, 23);

      var store = _fillTestStore(Store.open(path));
      var state = AppState(store, clock: () => day);
      final meditate = state.habits.firstWhere((h) => h.name == 'Sketch');
      state.selectStatus(day, meditate, HabitStatus.done);
      state.selectStatus(day, meditate, HabitStatus.missed);
      state.selectStatus(day, meditate, HabitStatus.other);
      state.setNote(day, meditate, 'Sick');
      state.addTodo(TodoScope.week, 'Book dentist', dueDate: DateTime(day.year, day.month, day.day + 5));
      await state.setJournal(day, 'A good day.');
      state.setTheme('Sunset');
      store.close();

      store = Store.open(path);
      state = AppState(store, clock: () => day);
      final again = state.habits.firstWhere((h) => h.name == 'Sketch');
      expect(state.habits, hasLength(8), reason: 'seed runs only once');
      expect(state.sleepHabits.map((h) => h.name), ['Rise Early', 'Unwind', 'Screen Curfew', 'Sleep Early']);
      expect(state.statusOf(day, again), HabitStatus.other);
      expect(state.noteOf(day, again), 'Sick');
      expect(state.statusOf(DateTime(2026, 10, 1), state.habits[1]), HabitStatus.missed);
      expect(state.todos[TodoScope.week]!.map((t) => t.text), ['Book dentist']);
      expect(state.journalOf(day), 'A good day.');
      expect(state.themeName, 'Sunset');
      store.close();
    });
  });

  group('themes', () {
    test('old theme names move to the new ones once', () {
      for (final (old, now) in [
        ('Main', 'Solar Eclipse'),
        ('Dark', 'Lunar Eclipse'),
        ('Eclipse', 'Lunar Eclipse'),
        ('Soft Pastel', 'Morning Pastel'),
        ('Sage & Sunset', 'Solar Eclipse'),
        ('Sunset', 'Sunrise'),
        ('Citrus', 'Solar Eclipse'),
        ('Pastel', 'Morning Pastel'),
      ]) {
        final store = _testStore()..setSetting('theme', old);
        expect(AppState(store).themeName, now, reason: old);
        // The new dark Sunset is kept once the names are current.
        store.setSetting('theme', 'Sunset');
        expect(AppState(store).themeName, 'Sunset');
        store.close();
      }
    });

    test('every theme has a partner of the other brightness', () {
      expect(palettes.map((p) => p.name), [
        'Solar Eclipse',
        'Lunar Eclipse',
        'Summer Solstice',
        'Winter Solstice',
        'Morning Pastel',
        'Evening Pastel',
        'Sunrise',
        'Sunset',
        'Orchard Dawn',
        'Orchard Dusk',
        'Pluto’s Heartbreak',
        'Pluto’s Revenge',
      ]);
      for (final p in palettes) {
        expect(partnerOf(p.name, dark: true).brightness, Brightness.dark);
        expect(partnerOf(p.name, dark: false).brightness, Brightness.light);
      }
      expect(partnerOf('Sunrise', dark: true).name, 'Sunset');
      expect(partnerOf('Evening Pastel', dark: false).name, 'Morning Pastel');
      expect(partnerOf('Orchard Dawn', dark: true).name, 'Orchard Dusk');
      expect(partnerOf('Pluto’s Heartbreak', dark: true).name, 'Pluto’s Revenge');
      expect(partnerOf('Pluto’s Revenge', dark: false).name, 'Pluto’s Heartbreak');
    });

    test('pastel status colours exchange their exact shades', () {
      for (final (p, lightness, chroma) in [(morningPastelPalette, 0.78, 0.095), (eveningPastelPalette, 0.76, 0.09)]) {
        expect(p.done, Oklch(lightness, chroma, 145).toColor());
        expect(p.other, Oklch(lightness + 0.06, chroma, 265).toColor());
      }
    });

    test('OKLCH round-trips, and keeps out-of-gamut colours in sRGB', () {
      for (final c in [const Color(0xFF3B66F5), const Color(0xFFE85372), const Color(0xFF808080)]) {
        final back = Oklch.of(c).toColor();
        expect(deltaE(c, back), lessThan(1e-4));
      }
      final clipped = Oklch.of(const Oklch(0.7, 0.4, 145).toColor());
      expect(clipped.l, closeTo(0.7, 0.002), reason: 'lightness is kept, chroma gives way');
      expect(clipped.h, closeTo(145, 2));
    });

    test('every theme meets contrast and status separation checks', () {
      for (final p in palettes) {
        final statuses = [p.done, p.missed, p.other];
        expect(contrast(p.ink, p.tile), greaterThanOrEqualTo(7), reason: '${p.name} text');
        expect(contrast(p.inkMuted, p.tile), greaterThanOrEqualTo(4.5), reason: '${p.name} muted text');
        expect(contrast(p.accent, p.tile), greaterThanOrEqualTo(4.5), reason: '${p.name} accent text');
        expect(contrast(p.onToday, p.today), greaterThanOrEqualTo(4.5), reason: "${p.name} today's number");
        for (final c in statuses) {
          expect(contrast(p.onAccent, c), greaterThanOrEqualTo(3), reason: '${p.name} marks on statuses');
        }
        // The requested exact pastel swap brings green and red closer under
        // red/green colour blindness; their check/cross marks also distinguish them.
        final pastel = p == morningPastelPalette || p == eveningPastelPalette;
        for (final type in ColourBlindness.values) {
          expect(
            deltaE(simulate(p.done, type), simulate(p.missed, type)),
            greaterThanOrEqualTo(pastel ? 0.05 : 0.08),
            reason: '${p.name} done vs missed, ${type.name}',
          );
        }
      }
    });

    test('follows night light, and a manual pick holds until it changes', () {
      final store = _testStore();
      var state = AppState(store)..setTheme('Morning Pastel');
      state.nightLightIs(true);
      expect(state.themeName, 'Evening Pastel');
      state.nightLightIs(true);
      state.setTheme('Sunrise');
      state.nightLightIs(true);
      expect(state.themeName, 'Sunrise', reason: 'held until night light changes');
      state.nightLightIs(false);
      expect(state.themeName, 'Sunrise');

      // A restart alone doesn't switch; a change while closed does.
      state = AppState(store)..nightLightIs(false);
      expect(state.themeName, 'Sunrise');
      state = AppState(store)..nightLightIs(true);
      expect(state.themeName, 'Sunset');

      state.setFollowNightLight(false);
      state.nightLightIs(false);
      expect(state.themeName, 'Sunset');
      state.setFollowNightLight(true);
      expect(state.themeName, 'Sunrise', reason: 'turning it on matches night light now');
      expect(AppState(store).followNightLight, isTrue);
      store.close();
    });

    test('reads night light from the hyprsunset socket', () async {
      final dir = Directory.systemTemp.createTempSync('night_light');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/.hyprsunset.sock';
      var temperature = '2371';
      final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
      addTearDown(server.close);
      server.listen((client) {
        client.listen((request) {
          expect(utf8.decode(request), 'temperature');
          client
            ..write(temperature)
            ..close();
        });
      });

      final nightLight = NightLight(path);
      expect(await nightLight.isOn(), isTrue);
      temperature = '6000';
      expect(await nightLight.isOn(), isFalse);
      expect(await NightLight('${dir.path}/missing.sock').isOn(), isNull);
    }, skip: Platform.isWindows);

    test('Windows Night light is read from its registry record', () {
      Uint8List blob(List<int> inner) => Uint8List.fromList([
        ...[0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06, 0xF0, 0x9B, 0xC5, 0xC1, 0x06, 0x2A, 0x2B, 0x0E],
        inner.length + 4,
        ...[0x43, 0x42, 0x01, 0x00],
        ...inner,
      ]);
      const settings = [0xD0, 0x0A, 0x02, 0xC6, 0x14, 0xB8, 0x8E, 0x9D, 0xD4, 0xE4, 0xDE, 0xCC, 0xED, 0x01, 0x00, 0x00];
      expect(WindowsNightLight.parse(blob([0x10, 0x00, ...settings])), isTrue);
      expect(WindowsNightLight.parse(blob(settings)), isFalse);
      expect(WindowsNightLight.parse(null), isNull);
      expect(WindowsNightLight.parse(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])), isNull);
    });
  });

  group('journal files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('productivity_journal'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('entries are Markdown files, and old ones are exported once', () async {
      final store = Store.open('${dir.path}/app.db');
      store.setJournal('2026-10-01', 'Written before files.');
      final files = JournalFiles(Directory('${dir.path}/Eclipse Journal'));
      final day = DateTime(2026, 10, 23);
      var state = AppState(store, journalFiles: files, clock: () => day);

      await state.flushFiles();
      final old = File('${dir.path}/Eclipse Journal/2026/2026-10-01.md');
      expect(old.readAsStringSync(), '# Thursday 1 October 2026\n\nWritten before files.\n');

      await state.setJournal(day, 'Line one\n\nLine two');
      final file = File('${dir.path}/Eclipse Journal/2026/2026-10-23.md');
      expect(file.readAsStringSync(), '# Friday 23 October 2026\n\nLine one\n\nLine two\n');
      expect(state.journalOf(day), 'Line one\n\nLine two');
      expect(store.journal('2026-10-23'), 'Line one\n\nLine two', reason: 'kept in the database for backups');

      // The files are a copy: edits to them aren't read back, and the
      // next save replaces them.
      file.writeAsStringSync('# Friday 23 October 2026\n\nEdited in a text editor\n');
      expect(state.journalOf(day), 'Line one\n\nLine two');

      // A deleted file stays deleted, but the entry is still there.
      old.deleteSync();
      state = AppState(store, journalFiles: files, clock: () => day);
      expect(old.existsSync(), isFalse);
      expect(state.journalOf(DateTime(2026, 10, 1)), 'Written before files.');

      await state.setJournal(day, '  ');
      expect(file.existsSync(), isFalse, reason: 'an emptied entry leaves no file');
      store.close();
    });

    test("files that can't be saved don't lose the entry, and say why", () async {
      final store = Store.open('${dir.path}/app.db');
      // A file where the year's folder should be: nothing can go in it.
      final blocked = File('${dir.path}/Eclipse Journal/2026')..createSync(recursive: true);
      final day = DateTime(2026, 10, 23);
      final state = AppState(
        store,
        journalFiles: JournalFiles(Directory('${dir.path}/Eclipse Journal')),
        clock: () => day,
      );

      await state.setJournal(day, 'Still kept');
      expect(state.journalOf(day), 'Still kept');
      expect(state.journalFileProblem, contains('couldn’t be saved'));

      blocked.deleteSync();
      await state.setJournal(day, 'Kept, and saved');
      expect(state.journalFileProblem, isNull);
      expect(File('${dir.path}/Eclipse Journal/2026/2026-10-23.md').readAsStringSync(), contains('Kept, and saved'));
      store.close();
    });

    test('restoring a backup brings the files in line with it', () async {
      final store = Store.open('${dir.path}/app.db');
      final files = JournalFiles(Directory('${dir.path}/Eclipse Journal'));
      final backups = Backups(Directory('${dir.path}/backups'));
      var now = DateTime(2026, 10, 22);
      final state = AppState(store, journalFiles: files, backups: backups, clock: () => now);
      await state.setJournal(now, 'The 22nd, as first written');

      now = DateTime(2026, 10, 23);
      state.checkDate(); // the 23rd's copy has the 22nd's entry
      await state.setJournal(DateTime(2026, 10, 22), 'The 22nd, rewritten');
      await state.setJournal(now, 'The 23rd');

      await state.restore(backups.list().firstWhere((b) => b.day == now));
      final the22nd = files.fileFor(DateTime(2026, 10, 22)).readAsStringSync();
      expect(the22nd, allOf(contains('The 22nd, as first written'), contains('The 22nd, rewritten')));
      expect(files.fileFor(now).readAsStringSync(), contains('The 23rd'), reason: 'a restore never removes writing');
      store.close();
    });
  });

  test('versions compare by number, across months and years', () {
    expect(isNewer('1.10.2', '1.10.1'), isTrue);
    expect(isNewer('1.11.1', '1.10.12'), isTrue);
    expect(isNewer('2.1.1', '1.12.9'), isTrue);
    expect(isNewer('1.10.1', '1.10.1'), isFalse);
    expect(isNewer('1.9.5', '1.10.1'), isFalse);
    expect(pubspecVersion('name: eclipse\nversion: 1.10.1+2\n'), '1.10.1');
  });

  group('updates', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('productivity_updates'));
    tearDown(() => dir.deleteSync(recursive: true));

    String git(List<String> args) {
      final r = Process.runSync('git', [
        '-C',
        dir.path,
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.com',
        ...args, //
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return (r.stdout as String).trim();
    }

    test('offers newer commits from the folder the app was built from', () async {
      git(['init', '-q']);
      Directory('${dir.path}/linux').createSync();
      File('${dir.path}/linux/install.sh')
          .writeAsStringSync('echo "Building"\necho "Error: no space left" >&2\nexit 1\n');
      git(['add', '-A']);
      git(['commit', '-qm', 'First']);
      final built = git(['rev-parse', 'HEAD']);

      final app = Directory('${dir.path}/installed')..createSync();
      expect(
        GitUpdater.forExecutable('${app.path}/eclipse'),
        isNull,
        reason: 'no build-info: not installed by the script',
      );
      File('${app.path}/build-info').writeAsStringSync('repo=${dir.path}\ncommit=$built\n');
      final updater = GitUpdater.forExecutable('${app.path}/eclipse')!;

      await updater.check();
      expect(updater.status, UpdateStatus.none, reason: 'up to date');

      git(['commit', '-q', '--allow-empty', '-m', 'Second']);
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: eclipse\nversion: 1.10.2+3\n');
      git(['add', '-A']);
      git(['commit', '-qm', 'Add an update banner']);
      await updater.check();
      expect(updater.status, UpdateStatus.available);
      expect(updater.newCommits, 2);
      expect(updater.newVersion, '1.10.2');

      updater.dismiss();
      await updater.check();
      expect(updater.status, UpdateStatus.none, reason: 'Later hides it until there is something newer');
      git(['commit', '-q', '--allow-empty', '-m', 'Third']);
      await updater.check();
      expect(updater.status, UpdateStatus.available);

      await updater.update();
      expect(updater.status, UpdateStatus.failed);
      expect(updater.error, 'Error: no space left');
      await updater.check();
      expect(updater.status, UpdateStatus.failed, reason: 'the error stays until there is something new');
    });
  }, skip: Platform.isWindows);

  test('the journal folders Eclipse named are renamed Eclipse Journals, with what was in them', () {
    final tmp = Directory.systemTemp.createTempSync('productivity_rename');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final home = Directory('${tmp.path}/home')..createSync();
    final docs = Directory('${tmp.path}/docs')..createSync();
    File('${docs.path}/Eclipse Journal/2026/2026-10-24.md').createSync(recursive: true);
    expect(DataFolder.load(home, docs).journal.path, path.join(docs.path, 'Eclipse Journals'));
    expect(File('${docs.path}/Eclipse Journals/2026/2026-10-24.md').existsSync(), isTrue);
    expect(Directory('${docs.path}/Eclipse Journal').existsSync(), isFalse);

    final chosen = Directory('${tmp.path}/Synced')..createSync();
    File('${home.path}/data-folder').writeAsStringSync(chosen.path);
    File('${chosen.path}/Journal/2026/2026-10-24.md').createSync(recursive: true);
    expect(DataFolder.load(home, docs).journal.path, path.join(chosen.path, 'Eclipse Journals'));
    expect(File('${chosen.path}/Eclipse Journals/2026/2026-10-24.md').existsSync(), isTrue);

    // A folder you picked yourself stays as it is.
    final picked = Directory('${tmp.path}/Mine/Eclipse Journal')..createSync(recursive: true);
    File('${home.path}/journal-folder').writeAsStringSync(picked.path);
    expect(DataFolder.load(home, docs).journal.path, picked.path);
  });

  test('moving to a data folder copies everything there and uses it next time', () async {
    final tmp = Directory.systemTemp.createTempSync('productivity_folder');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final home = Directory('${tmp.path}/home')..createSync();
    final docs = Directory('${tmp.path}/docs')..createSync();

    var data = DataFolder.load(home, docs);
    expect(data.chosen, isNull);
    expect(data.journal.path, path.join(docs.path, 'Eclipse Journals'));
    final store = Store.open(data.database);
    final state = AppState(
      store,
      backups: Backups(data.backups),
      journalFiles: JournalFiles(data.journal),
      clock: () => DateTime(2026, 10, 24),
    );
    await state.setJournal(DateTime(2026, 10, 24), 'Written before the move.');

    final drive = Directory('${tmp.path}/Google Drive/Eclipse');
    data.moveTo(drive, store);
    store.close();

    data = DataFolder.load(home, docs);
    expect(data.root.path, drive.path);
    expect(File(data.database).existsSync(), isTrue);
    expect(data.backups.listSync(), isNotEmpty);
    expect(
      JournalFiles(data.journal).fileFor(DateTime(2026, 10, 24)).readAsStringSync(),
      contains('Written before the move.'),
    );
    final moved = Store.open(data.database);
    expect(moved.journal('2026-10-24'), 'Written before the move.');

    // A second computer pointing at the same folder uses what's there.
    final other = DataFolder.load(Directory('${tmp.path}/home2')..createSync(), docs);
    final fresh = _testStore();
    other.moveTo(drive, fresh);
    final second = Store.open(DataFolder.load(Directory('${tmp.path}/home2'), docs).database);
    expect(second.journal('2026-10-24'), 'Written before the move.', reason: 'not overwritten');
    moved.close();
    second.close();
    fresh.close();
  });

  test('choosing a journal folder moves the entries there, on this computer only', () async {
    final tmp = Directory.systemTemp.createTempSync('productivity_journal');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final home = Directory('${tmp.path}/home')..createSync();
    final docs = Directory('${tmp.path}/docs')..createSync();
    final data = DataFolder.load(home, docs);
    final old = data.journal;
    final state = AppState(
      Store.memory(),
      journalFiles: JournalFiles(old),
      dataFolder: data,
      clock: () => DateTime(2026, 10, 24),
    );
    await state.setJournal(DateTime(2026, 10, 23), 'Friday.');
    await state.setJournal(DateTime(2026, 10, 24), 'Saturday.');
    File('${old.path}/notes.txt').writeAsStringSync('mine');

    final chosen = Directory('${tmp.path}/Notes/Journal');
    await state.useJournalFolder(chosen);
    expect(File('${chosen.path}/2026/2026-10-23.md').readAsStringSync(), contains('Friday.'));
    expect(File('${old.path}/2026').existsSync(), isFalse, reason: 'moved, not copied');
    expect(File('${old.path}/notes.txt').readAsStringSync(), 'mine', reason: 'other files stay put');

    await state.setJournal(DateTime(2026, 10, 25), 'Sunday.');
    expect(File('${chosen.path}/2026/2026-10-25.md').existsSync(), isTrue);
    expect(DataFolder.load(home, docs).journal.path, chosen.path, reason: 'remembered for next time');
    expect(
      DataFolder.load(Directory('${tmp.path}/home2')..createSync(), docs).journal.path,
      old.path,
      reason: 'another computer keeps its own',
    );
  });

  group('carry-forward', () {
    test('unfinished to-dos roll into the new day, week and month', () {
      var now = DateTime(2026, 10, 23, 22); // Friday
      final state = AppState(_testStore(), clock: () => now);
      state.todos[TodoScope.today]!.toList().forEach((t) => state.removeTodo(TodoScope.today, t));

      state.addTodo(TodoScope.today, 'Unfinished');
      state.addTodo(TodoScope.today, 'Finished');
      state.toggleTodo(state.todos[TodoScope.today]!.last);
      state.addTodo(TodoScope.week, 'Weekly', dueDate: DateTime(2026, 12, 20));
      state.addTodo(TodoScope.month, 'Monthly', dueDate: DateTime(2026, 12, 30));

      now = DateTime(2026, 10, 24, 0, 1); // Saturday
      state.checkDate();
      expect(state.todos[TodoScope.today]!.map((t) => (t.text, t.carried)), [('Unfinished', 1)]);
      expect(state.todos[TodoScope.week]!.single.carried, 0, reason: 'same week');

      now = DateTime(2026, 10, 26); // Monday
      state.checkDate();
      expect(state.todos[TodoScope.today]!.single.carried, 2);
      expect(state.todos[TodoScope.week]!.map((t) => (t.text, t.carried)), [('Weekly', 1)]);
      expect(state.todos[TodoScope.month]!.single.carried, 0, reason: 'same month');

      now = DateTime(2026, 11, 2);
      state.checkDate();
      expect(state.todos[TodoScope.month]!.map((t) => (t.text, t.carried)), [('Monthly', 1)]);
    });

    test('a past day keeps its list as it stood, ticked and unticked', () {
      var now = DateTime(2026, 10, 22, 12); // Thursday
      final state = AppState(_testStore(), clock: () => now);
      state.todos[TodoScope.today]!.toList().forEach((t) => state.removeTodo(TodoScope.today, t));
      state.addTodo(TodoScope.today, 'collect prescription');
      state.addTodo(TodoScope.today, 'Finished');
      state.toggleTodo(state.todos[TodoScope.today]!.last);
      expect(state.todos[TodoScope.today]!.first.text, 'Collect prescription', reason: 'capitalised');

      now = DateTime(2026, 10, 24, 9); // Saturday: carried twice
      state.checkDate();
      state.toggleTodo(state.todos[TodoScope.today]!.single);

      String list(DateTime day) =>
          state.todosOn(TodoScope.today, day).map((t) => '${t.text}${t.done ? ' ✓' : ''}').join(', ');
      expect(list(DateTime(2026, 10, 22)), 'Collect prescription, Finished ✓');
      expect(list(DateTime(2026, 10, 23)), 'Collect prescription', reason: 'carried through, still open then');
      expect(list(DateTime(2026, 10, 24)), 'Collect prescription ✓');
      expect(state.todos[TodoScope.today]!.single.since, DateTime(2026, 10, 22));
    });

    test('older to-dos get a since date one period back per carry', () {
      final path = '${Directory.systemTemp.createTempSync('productivity_since').path}/old.db';
      Store.open(path).close();
      final db = sqlite3.open(path);
      _undoSync(db);
      db.execute('''
        DROP TABLE sleep_notes; ALTER TABLE todos DROP COLUMN since; PRAGMA user_version = 5;
        INSERT INTO todos (scope, period, text, carried) VALUES
          ('today', '2026-10-24', 'Day', 2), ('week', '2026-10-19', 'Week', 1), ('month', '2026-10', 'Month', 1);
      ''');
      db.close();
      final store = Store.open(path);
      expect(store.todos(TodoScope.today, '2026-10-24').single.since, DateTime(2026, 10, 22));
      expect(store.todos(TodoScope.week, '2026-10-19').single.since, DateTime(2026, 10, 12));
      expect(store.todos(TodoScope.month, '2026-10').single.since, DateTime(2026, 9, 1));
      store.close();
    });

    test('nothing vanishes when the clock goes back over midnight', () {
      var now = DateTime(2026, 10, 24, 0, 30); // flew in from further east
      final state = AppState(_testStore(), clock: () => now);
      state.todos[TodoScope.today]!.toList().forEach((t) => state.removeTodo(TodoScope.today, t));
      state.addTodo(TodoScope.today, 'Unpack');

      now = DateTime(2026, 10, 23, 23); // landed, an hour and a half behind
      state.checkDate();
      expect(state.today, DateTime(2026, 10, 23));
      expect(state.todos[TodoScope.today]!.map((t) => (t.text, t.carried)), [('Unpack', 0)]);

      now = DateTime(2026, 10, 24, 0, 1);
      state.checkDate();
      expect(state.todos[TodoScope.today]!.map((t) => (t.text, t.carried)), [('Unpack', 1)]);
    });

    test('unfinished to-dos in tomorrow roll into today on the new day', () {
      var now = DateTime(2026, 10, 23, 20); // Friday
      final state = AppState(_testStore(), clock: () => now);
      state.todos[TodoScope.today]!.toList().forEach((t) => state.removeTodo(TodoScope.today, t));
      state.todos[TodoScope.tomorrow]!.toList().forEach((t) => state.removeTodo(TodoScope.tomorrow, t));

      state.addTodo(TodoScope.today, 'Today task');
      state.addTodo(TodoScope.tomorrow, 'Call doctor tomorrow');
      state.addTodo(TodoScope.tomorrow, 'Done tomorrow early');
      state.toggleTodo(state.todos[TodoScope.tomorrow]!.last);

      expect(state.todos[TodoScope.tomorrow]!.map((t) => t.text), ['Call doctor tomorrow']);
      expect(state.todos[TodoScope.today]!.last.done, isTrue);

      now = DateTime(2026, 10, 24, 0, 1); // Saturday
      state.checkDate();

      expect(state.todos[TodoScope.today]!.map((t) => (t.text, t.carried)), [
        ('Today task', 1),
        ('Call doctor tomorrow', 0),
      ]);
      expect(state.todos[TodoScope.tomorrow]!, isEmpty);
    });
  });

  group('day start', () {
    test('a day can run on past midnight', () {
      expect(dayOf(DateTime(2026, 10, 24, 1, 30), 4), DateTime(2026, 10, 23));
      expect(dayOf(DateTime(2026, 10, 24, 4), 4), DateTime(2026, 10, 24));
      expect(dayOf(DateTime(2026, 10, 24, 1, 30), 0), DateTime(2026, 10, 24));
      expect(dayOf(DateTime(2026, 11, 1, 2), 3), DateTime(2026, 10, 31), reason: 'across a month');
      expect(nextDayStart(DateTime(2026, 10, 24, 1, 30), 4), DateTime(2026, 10, 24, 4));
      expect(nextDayStart(DateTime(2026, 10, 24, 22), 4), DateTime(2026, 10, 25, 4));
      expect(nextDayStart(DateTime(2026, 10, 24, 22), 0), DateTime(2026, 10, 25));
    });

    test('late-night ticks count for the day before', () {
      final store = _testStore();
      var now = DateTime(2026, 10, 23, 23); // Friday night
      var state = AppState(store, clock: () => now);
      state.setDayStartHour(4);
      state.todos[TodoScope.today]!.toList().forEach((t) => state.removeTodo(TodoScope.today, t));
      state.addTodo(TodoScope.today, 'Unfinished');

      now = DateTime(2026, 10, 24, 1, 30);
      state.checkDate();
      expect(state.today, DateTime(2026, 10, 23));
      expect(state.lateNight, isTrue);
      final journal = state.sleepHabits.firstWhere((h) => h.name == 'Unwind');
      state.selectStatus(state.today, journal, HabitStatus.done);
      expect(state.statusOf(DateTime(2026, 10, 23), journal), HabitStatus.done);
      expect(state.todos[TodoScope.today]!.single.carried, 0, reason: 'still Friday');

      now = DateTime(2026, 10, 24, 4, 0, 1);
      state.checkDate();
      expect(state.today, DateTime(2026, 10, 24));
      expect(state.lateNight, isFalse);
      expect(state.todos[TodoScope.today]!.single.carried, 1);

      state = AppState(store, clock: () => now);
      expect(state.dayStartHour, 4, reason: 'remembered');
    });

    test('changing it after midnight moves today back, losing nothing', () {
      var now = DateTime(2026, 10, 24, 1); // Saturday, 1am, days start at midnight
      final state = AppState(_testStore(), clock: () => now);
      state.todos[TodoScope.today]!.toList().forEach((t) => state.removeTodo(TodoScope.today, t));
      state.addTodo(TodoScope.today, 'Added just after midnight');

      state.setDayStartHour(4);
      expect(state.today, DateTime(2026, 10, 23));
      expect(state.todos[TodoScope.today]!.map((t) => t.text), ['Added just after midnight']);

      state.setDayStartHour(0);
      expect(state.today, DateTime(2026, 10, 24));
      expect(state.lateNight, isFalse);
    });
  });

  group('streaks', () {
    // Daylight saving starts on 4 October 2026 in south-east Australia, making
    // it 23 hours long. Run with TZ=Australia/Sydney to check stepping over it.
    test('step by calendar day over a clock change', () {
      final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 6));
      final h = state.habits.first;
      for (final d in [3, 5, 6]) {
        state.selectStatus(DateTime(2026, 10, d), h, HabitStatus.done);
      }
      expect(state.currentStreak(h), 2, reason: 'the blank 4th breaks it');
      expect(state.bestStreak(h), 2);
    });

    test('a blank weekend is excused only when weekends are rest days', () {
      final store = _testStore();
      var state = AppState(store, clock: () => DateTime(2026, 10, 27)); // Tuesday
      final h = state.habits.first;
      for (final d in [22, 23, 26, 27]) {
        state.selectStatus(DateTime(2026, 10, d), h, HabitStatus.done); // Thu, Fri, then Mon, Tue
      }
      expect(state.currentStreak(h), 2);
      expect(state.isRestDay(DateTime(2026, 10, 24)), isFalse);

      state.setRestWeekends(true);
      expect(state.isRestDay(DateTime(2026, 10, 24)), isTrue);
      expect(state.isRestDay(DateTime(2026, 10, 23)), isFalse);
      expect(state.currentStreak(h), 4, reason: 'Saturday and Sunday neither break nor add');
      expect(state.bestStreak(h), 4);

      state.selectStatus(DateTime(2026, 10, 25), h, HabitStatus.done);
      expect(state.currentStreak(h), 5, reason: 'a ritual done on a rest day still counts');
      state.selectStatus(DateTime(2026, 10, 25), h, HabitStatus.missed);
      expect(state.currentStreak(h), 2, reason: 'marked not done, it breaks the streak');

      state = AppState(store, clock: () => DateTime(2026, 10, 27));
      expect(state.restWeekends, isTrue, reason: 'remembered');
    });
  });

  group('sleep schedule', () {
    test('an older database folds its sleep rituals in, keeping their history', () {
      final path = '${Directory.systemTemp.createTempSync('productivity_sleep').path}/old.db';
      Store.open(path).close();
      // Back to how a database looked before the sleep schedule.
      final db = sqlite3.open(path);
      _undoSync(db);
      db.execute('''
        DELETE FROM sleep_habits; DELETE FROM habits; DROP TABLE sleep_habits;
        ALTER TABLE month_habits DROP COLUMN note; DROP TABLE sleep_notes; ALTER TABLE todos DROP COLUMN since; PRAGMA user_version = 2;
      ''');
      final ids = <String, int>{};
      for (final (i, name) in [
        'Get up at 8:30 am',
        'Sort stamps',
        'Wind down at 8:45',
        'Journal',
        'Meditate', //
        'Screens, shower finished by 9:30 pm', 'Sketch', 'Bed by 10:30 pm',
      ].indexed) {
        db.execute('INSERT INTO habits DEFAULT VALUES');
        ids[name] = db.lastInsertRowId;
        db.execute('INSERT INTO month_habits VALUES (2026, 10, ?, ?, ?)', [ids[name], name, i]);
      }
      db.execute("INSERT INTO entries (day, habit_id, status) VALUES ('2026-10-01', ?, 1)", [ids['Get up at 8:30 am']]);
      db.close();

      final store = Store.open(path);
      final state = AppState(store, clock: () => DateTime(2026, 10, 23));
      expect(state.habits.map((h) => h.name), ['Sort stamps', 'Sketch']);
      final sleep = state.sleepHabits;
      expect(sleep.map((h) => h.name), ['Rise Early', 'Unwind', 'Screen Curfew', 'Sleep Early']);
      expect(sleep.first.minutes, 8 * 60 + 30);
      expect(sleep.first.id, ids['Get up at 8:30 am']);
      expect(sleep[1].id, isNot(ids['Wind down at 8:45']), reason: 'Unwind starts fresh');
      expect(sleep[2].id, ids['Screens, shower finished by 9:30 pm']);
      expect(sleep[3].id, ids['Bed by 10:30 pm']);
      expect(state.statusOf(DateTime(2026, 10, 1), sleep.first), HabitStatus.done);
      expect(state.habitsFor(2025, 3).map((h) => h.name), ['Sort stamps', 'Sketch'], reason: 'every month');
    });
  });

  group('per-month rituals', () {
    test('a new month copies the last one, and edits stay in their month', () {
      var now = DateTime(2026, 10, 31);
      final state = AppState(_testStore(), clock: () => now);

      // Future months preview the latest list without saving it.
      expect(state.habitsFor(2026, 12), hasLength(8));
      state.addHabit(2026, 10, 'Stretch');
      expect(state.habitsFor(2026, 12), hasLength(9));

      now = DateTime(2026, 11, 1);
      state.checkDate();
      final nov = state.habitsFor(2026, 11);
      expect(nov.map((h) => h.name), state.habitsFor(2026, 10).map((h) => h.name));
      expect(state.habits, same(nov));

      state.renameHabit(2026, 11, nov.first, 'Tidy room');
      state.removeHabit(2026, 11, nov.last);
      state.reorderHabit(2026, 11, 0, 2); // move first to third place
      expect(nov.take(3).map((h) => h.name), ['Label folders', 'Check labels', 'Tidy room']);
      expect(nov, hasLength(8));

      final oct = state.store.monthHabits(2026, 10);
      expect(oct.first.name, 'Sort cards');
      expect(oct, hasLength(9));

      // Same ritual id across months keeps streaks going.
      final getUp = oct.first;
      state.selectStatus(DateTime(2026, 10, 31), getUp, HabitStatus.done);
      state.selectStatus(DateTime(2026, 11, 1), nov[2], HabitStatus.done);
      expect(state.currentStreak(nov[2]), 2);
    });
  });

  test('sleep times belong to their month, and a new month starts with the last', () {
    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 24));
    int? time(int month) => state.sleepHabitsFor(2026, month).first.minutes;
    expect(time(10), 8 * 60 + 30);

    state.setSleepTime(2026, 10, state.sleepHabitsFor(2026, 10).first, 8 * 60);
    expect(time(10), 8 * 60);
    expect(time(9), 8 * 60 + 30, reason: 'earlier months keep theirs');
    expect(time(11), 8 * 60, reason: 'a new month copies the last');

    state.setSleepTime(2026, 9, state.sleepHabitsFor(2026, 9).first, null);
    expect(time(9), isNull, reason: 'cleared shows just the name');
    expect(time(10), 8 * 60, reason: 'a change stays in its month');

    state.setSleepTime(2026, 8, state.sleepHabitsFor(2026, 8).first, 7 * 60 + 45);
    expect(time(9), isNull);
    expect(time(10), 8 * 60);
    expect(state.sleepHabitsFor(2026, 10)[1].minutes, 21 * 60, reason: 'others untouched');
  });

  test('times are read from notes written before times were picked', () {
    expect(parseClock('Awaken at 8:30 am'), 8 * 60 + 30);
    expect(parseClock('Complete daily tasks, journal, shower, brush teeth, and meditate at 9 pm'), 21 * 60);
    expect(parseClock('Lights out by 11'), isNull);
    expect(parseClock('12 am'), 0);
    expect(parseClock('12:15 PM'), 12 * 60 + 15);
    expect(parseClock('22:00'), 22 * 60);
    expect(parseClock(''), isNull);
    expect(clockLabel(8 * 60 + 30), '8:30 am');
    expect(clockLabel(21 * 60), '9:00 pm');
    expect(clockLabel(0), '12:00 am');
    expect(clockLabel(12 * 60 + 5), '12:05 pm');

    final store = Store.memory();
    final state = AppState(store, clock: () => DateTime(2026, 10, 24));
    store.setSleepNote(2026, 10, SleepItem.unwind, 'Wind down at 9:15 pm');
    expect(state.sleepHabitsFor(2026, 10)[1].minutes, 21 * 60 + 15);
  });

  group('ritual notes', () {
    test("a note belongs to its month: copied into a new one, then edited apart", () {
      final dir = Directory.systemTemp.createTempSync('productivity_notes');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/app.db';
      var now = DateTime(2026, 10, 31);
      var state = AppState(_fillTestStore(Store.open(path)), clock: () => now);
      final read = state.habits.firstWhere((h) => h.name == 'Sketch');
      state.setHabitNote(2026, 10, read, '  20 pages before bed ');
      expect(state.habits.firstWhere((h) => h.name == 'Sketch').description, '20 pages before bed');

      now = DateTime(2026, 11, 1);
      state.checkDate();
      final nov = state.habits.firstWhere((h) => h.name == 'Sketch');
      expect(nov.description, '20 pages before bed', reason: 'a new month copies the one before');

      state.setHabitNote(2026, 11, nov, '30 pages');
      expect(state.habitsFor(2026, 10).firstWhere((h) => h.name == 'Sketch').description, '20 pages before bed');
      state.store.close();

      state = AppState(Store.open(path), clock: () => now);
      expect(state.habits.firstWhere((h) => h.name == 'Sketch').description, '30 pages');
      expect(state.habitsFor(2026, 10).firstWhere((h) => h.name == 'Sketch').description, '20 pages before bed');
      state.setHabitNote(2026, 11, state.habits.firstWhere((h) => h.name == 'Sketch'), '  ');
      expect(state.habits.firstWhere((h) => h.name == 'Sketch').description, isNull, reason: 'blank removes it');
      state.store.close();
    });

    test('notes from when they followed a ritual everywhere stay in every month it is in', () {
      final path = '${Directory.systemTemp.createTempSync('productivity_notes_v4').path}/old.db';
      Store.open(path).close();
      final db = sqlite3.open(path);
      _undoSync(db);
      db.execute('''
        ALTER TABLE month_habits DROP COLUMN note; ALTER TABLE habits ADD COLUMN note TEXT;
        INSERT INTO habits (note) VALUES ('Home gym');
        DROP TABLE sleep_notes; ALTER TABLE todos DROP COLUMN since; PRAGMA user_version = 4;
      ''');
      final id = db.lastInsertRowId;
      db.execute("INSERT INTO month_habits VALUES (2026, 9, ?, 'Gym', 0), (2026, 10, ?, 'Gym', 0)", [id, id]);
      db.close();

      final store = Store.open(path);
      expect(store.monthHabits(2026, 9).single.description, 'Home gym');
      expect(store.monthHabits(2026, 10).single.description, 'Home gym');
      store.close();
    });
  });

  group('preview months', () {
    test('months before the first list are saved only when ticked or edited', () {
      final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));

      // Browsing back a year shows October's rituals but saves nothing.
      final preview = state.habitsFor(2025, 10);
      expect(preview, hasLength(8));
      expect(state.isPreviewMonth(2025, 10), isTrue);
      expect(state.store.monthHabits(2025, 10), isEmpty);

      // Ticking a ritual saves the month.
      state.selectStatus(DateTime(2025, 10, 5), preview.first, HabitStatus.done);
      expect(state.store.monthHabits(2025, 10), hasLength(8));
      expect(state.isPreviewMonth(2025, 10), isFalse);
      expect(state.statusOf(DateTime(2025, 10, 5), state.habitsFor(2025, 10).first), HabitStatus.done);

      // Editing (with a habit from the preview list) saves it too, and
      // leaves the months it was copied from alone.
      final sep = state.habitsFor(2026, 9);
      expect(state.isPreviewMonth(2026, 9), isFalse, reason: 'between first list and today');
      final aug = state.habitsFor(2025, 8);
      expect(state.isPreviewMonth(2025, 8), isTrue);
      state.renameHabit(2025, 8, aug.first, 'Get up at 9');
      expect(state.store.monthHabits(2025, 8).first.name, 'Get up at 9');
      expect(state.habitsFor(2025, 8).first.name, 'Get up at 9');
      expect(sep.first.name, 'Sort cards');
    });

    test('adding a ritual works in a database with no lists at all', () {
      final store = _testStore();
      final state = AppState(store, clock: () => DateTime(2026, 10, 23));
      for (final h in state.habits.toList()) {
        state.removeHabit(2026, 10, h);
      }
      expect(state.habitsFor(2026, 11), isEmpty);
      state.addHabit(2026, 10, 'Stretch');
      expect(state.habits.map((h) => h.name), ['Stretch']);
    });
  });

  group('backups', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('productivity_backups'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('one copy a day, the newest 30 kept', () {
      final backups = Backups(Directory('${dir.path}/backups'));
      var now = DateTime(2026, 10, 23);
      final state = AppState(_fillTestStore(Store.open('${dir.path}/app.db')), backups: backups, clock: () => now);
      expect(backups.list().map((b) => b.day), [DateTime(2026, 10, 23)]);

      state.checkDate(); // same day: nothing new
      expect(backups.list(), hasLength(1));

      for (var i = 1; i <= 40; i++) {
        now = DateTime(2026, 10, 23 + i); // crosses into November and over the clock change
        state.checkDate();
      }
      final days = backups.list().map((b) => b.day!).toList();
      expect(days, hasLength(30));
      expect(days.first, DateTime(2026, 12, 2));
      expect(days.last, DateTime(2026, 11, 3));
      state.store.close();
    });

    test('restore brings back old data and can itself be undone', () async {
      final backups = Backups(Directory('${dir.path}/backups'));
      var now = DateTime(2026, 10, 23);
      final state = AppState(_fillTestStore(Store.open('${dir.path}/app.db')), backups: backups, clock: () => now);
      final weights = state.habits.firstWhere((h) => h.name == 'File notes');
      state.selectStatus(now, weights, HabitStatus.done); // after the 23rd's copy was taken
      state.setTheme('Sunset');

      now = DateTime(2026, 10, 24);
      state.checkDate(); // the 24th's copy has File notes done
      state.selectStatus(DateTime(2026, 10, 23), weights, HabitStatus.missed);
      state.addTodo(TodoScope.today, 'After the backup');

      final oct24 = backups.list().firstWhere((b) => b.day == DateTime(2026, 10, 24));
      await state.restore(oct24);
      expect(state.statusOf(DateTime(2026, 10, 23), weights), HabitStatus.done);
      expect(state.todos[TodoScope.today]!.map((t) => t.text), isNot(contains('After the backup')));
      expect(state.themeName, 'Sunset');

      final before = backups.list().first;
      expect(before.isBeforeRestore, isTrue);
      await state.restore(before); // undo
      expect(state.statusOf(DateTime(2026, 10, 23), weights), HabitStatus.missed);
      expect(state.todos[TodoScope.today]!.map((t) => t.text), contains('After the backup'));

      // Undoing again swaps back: the before-restore copy is never lost.
      await state.restore(backups.list().first);
      expect(state.statusOf(DateTime(2026, 10, 23), weights), HabitStatus.done);
      state.store.close();
    });

    test('a damaged copy is refused and changes nothing', () async {
      final backups = Backups(Directory('${dir.path}/backups'));
      final day = DateTime(2026, 10, 23);
      final state = AppState(_fillTestStore(Store.open('${dir.path}/app.db')), backups: backups, clock: () => day);
      final copy = backups.list().single;
      copy.file.writeAsStringSync('not a database');
      final weights = state.habits.firstWhere((h) => h.name == 'File notes');
      state.selectStatus(day, weights, HabitStatus.done);

      await expectLater(state.restore(copy), throwsA(anything));
      expect(state.statusOf(day, weights), HabitStatus.done);
      expect(state.store.monthHabits(2026, 10), hasLength(8));
      state.store.close();
    });
  });

  testWidgets('backups dialog restores after asking', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('productivity_backups');
    addTearDown(() => dir.deleteSync(recursive: true));
    final backups = Backups(Directory('${dir.path}/backups'));
    var now = DateTime(2026, 10, 20);
    late AppState state;
    await tester.runAsync(() async {
      final store = _fillTestStore(Store.open('${dir.path}/app.db'));
      state = AppState(
        store,
        backups: backups,
        dataFolder: DataFolder.load(dir, dir),
        sync: SyncService.load(dir, store),
        clock: () => now,
      );
      for (var d = 21; d <= 23; d++) {
        now = DateTime(2026, 10, d);
        state.checkDate();
      }
    });
    final weights = state.habits.firstWhere((h) => h.name == 'File notes');
    state.selectStatus(now, weights, HabitStatus.done);
    await state.setJournal(now, 'Written after the backup');

    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Weekends as rest days'), findsOneWidget, reason: 'Settings opens on General');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Weekends as rest days'), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Data').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Friday 23 October'), findsOneWidget);
    expect(find.text('Yesterday'), findsWidgets);
    await _shoot(tester, 'backups');

    await tester.tap(find.text('Restore').at(1)); // Thursday 22 October
    await tester.pumpAndSettle();
    expect(find.text('Replaces everything you have now, except journal writing.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Replaces everything you have now, except journal writing.'), findsOneWidget);
    await _shoot(tester, 'backups_confirm');
    expect(state.statusOf(now, weights), HabitStatus.done, reason: 'nothing happens before confirming');

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(state.statusOf(now, weights), HabitStatus.none);
    expect(find.text('Written after the backup'), findsOneWidget, reason: 'a restore never removes writing');
    expect(find.textContaining('Restored 22 October'), findsOneWidget);
    await _shoot(tester, 'backups_restored');
    state.store.close();
  });

  testWidgets('Today view, month grid and ritual editor', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = _testStore();
    final todos = {for (var i = 0; i < 10; i++) 'Sample task $i': i.isEven};
    todos.forEach((text, done) => store.addTodo(TodoScope.today, DateTime(2026, 10, 23), text, done: done));
    final state = AppState(store, clock: () => DateTime(2026, 10, 23));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    expect(find.text('Daily rituals'), findsOneWidget);
    expect(find.text('Sleep schedule'), findsOneWidget);
    expect(find.text('Screen Curfew'), findsOneWidget);
    expect(find.text('Sample task 7'), findsOneWidget);

    final weights = state.habits.firstWhere((h) => h.name == 'File notes');
    state.selectStatus(state.today, weights, HabitStatus.done);
    expect(state.currentStreak(weights), 1);
    await tester.pumpAndSettle();
    await _shoot(tester, 'today');

    // Sleep items show their times beside their names, and no tooltip.
    expect(find.text('11:00 pm'), findsOneWidget);
    final name = tester.getRect(find.text('Sleep Early'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(Offset(name.center.dx, name.top - 8));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Sleep Early'), findsOneWidget, reason: 'no tooltip repeats the name');
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Oct').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('31'), findsNWidgets(2), reason: 'rituals and sleep schedule each have the days');
    expect(find.text('SLEEP SCHEDULE  ·  4'), findsOneWidget);
    expect(
      find.text('0%'),
      findsOneWidget,
      reason: 'the sleep schedule shows its percentage before anything is marked',
    );
    await _shoot(tester, 'month');

    await tester.tap(find.text('Edit rituals'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Add a note').first, 'Make the bed too');
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.habits.first.description, 'Make the bed too');
    await tester.enterText(find.byType(TextField).last, 'Stretch');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(state.habits.last.name, 'Stretch');
    await _shoot(tester, 'month_edit');

    await tester.ensureVisible(find.text('Done'));
    await tester.tap(find.widgetWithText(TextField, 'Make the bed too'));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Edit rituals'), findsOneWidget, reason: 'Enter in a ritual description finishes editing');
    expect(state.habits.first.description, 'Make the bed too');
    expect(find.text('Stretch'), findsOneWidget);

    expect(find.text('11:00 pm'), findsOneWidget, reason: 'times show beside the sleep items');
    await tester.ensureVisible(find.text('Edit times'));
    await tester.tap(find.text('Edit times'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TimePill).last);
    await tester.pumpAndSettle();
    await _shoot(tester, 'sleep_wheel');
    // Clicking a minute on the wheel turns it there.
    await tester.tap(find.text('05').hitTestable().first);
    await tester.pumpAndSettle();
    expect(state.sleepHabits.last.minutes, 23 * 60, reason: 'the time is set once it is saved');
    // Dragging it up a row moves on five minutes.
    await tester.drag(find.text('05').hitTestable().first, const Offset(0, -38.0 - kDragSlopDefault));
    await tester.pumpAndSettle();
    expect(state.sleepHabits.last.minutes, 23 * 60, reason: 'only Save sets it');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(state.sleepHabits.last.minutes, 23 * 60 + 10);
    await tester.tap(find.byType(TimePill).last);
    await tester.pumpAndSettle();
    // The hand stays while the mouse drags the wheel round.
    await mouse.moveTo(tester.getCenter(find.text('15').hitTestable().first));
    await mouse.down(tester.getCenter(find.text('15').hitTestable().first));
    for (var i = 0; i < 6; i++) {
      await mouse.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 16));
      expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click);
    }
    await mouse.up();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(state.sleepHabits.last.minutes, 23 * 60 + 10, reason: 'Escape leaves it as it was');
    await tester.ensureVisible(find.text('Done'));
    await _shoot(tester, 'sleep_edit');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Edit times'), findsOneWidget);
  });

  testWidgets('the journal shows what syncs in where you are, and never over unsaved typing', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = _testStore();
    final state = AppState(store, clock: () => DateTime(2026, 10, 23));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final journal = find.byWidgetPredicate((w) => w is TextField && w.expands);
    TextEditingController field() => tester.widget<TextField>(journal).controller!;

    await tester.enterText(journal, 'Mine');
    expect(store.journal('2026-10-23'), '', reason: 'saved once typing stops');

    // A sync round: typing saved before the merge, the merge's text shown.
    state.saveJournalDraft();
    store.setJournal('2026-10-23', 'Theirs\n\n---\n\nMine');
    state.notifyListeners();
    await tester.pump();
    expect(field().text, 'Theirs\n\n---\n\nMine');
    expect(field().selection, const TextSelection.collapsed(offset: 17), reason: 'still after what you wrote');
    expect(tester.widget<EditableText>(find.byType(EditableText).last).focusNode.hasFocus, isTrue);

    // Typing not saved yet stays where you are; what came in underneath it
    // is kept too, once it's saved.
    await tester.enterText(journal, 'Typing');
    store.setJournal('2026-10-23', 'From the laptop');
    state.notifyListeners();
    await tester.pump();
    expect(field().text, 'Typing');
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.journal('2026-10-23'), normaliseNote('Typing${Store.journalBreak}From the laptop'));
  });

  testWidgets('the month view fits rituals and sleep schedule without scrolling', (tester) async {
    await _loadFonts();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    state.addHabit(2026, 10, 'A ritual with a name long enough to need two lines here');
    // Cover large desktop and narrow tiled-window layouts.
    for (final size in const [Size(2500, 1380), Size(1440, 900), Size(1920, 1080), Size(960, 1040)]) {
      tester.view.physicalSize = size;
      state.showMonth(10);
      await tester.pumpWidget(EclipseApp(state: state));
      await tester.pumpAndSettle();
      final scroll = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .singleWhere((s) => s.position.axis == Axis.vertical);
      await _shoot(tester, 'month_fit_${size.width.round()}x${size.height.round()}');
      expect(scroll.position.maxScrollExtent, 0, reason: '$size');
    }
  });

  testWidgets('a long ritual wraps onto more lines, its row growing to fit', (tester) async {
    await _loadFonts();
    // A tiled window; the rituals' column is the narrower middle one.
    tester.view.physicalSize = const Size(1000, 1040);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 24));
    state.setRestWeekends(true);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final longLabel = tester.renderObject<RenderParagraph>(
      find.text('Sort sample cards, labels, folders, and spare supplies'),
    );
    final weights = tester.renderObject<RenderParagraph>(find.text('File notes'));
    expect(longLabel.didExceedMaxLines, isFalse);
    expect(longLabel.size.height, greaterThan(weights.size.height * 1.5));
    expect(find.text('Rest day. Nothing you have to do.'), findsNWidgets(2), reason: 'the sleep schedule rests too');
    await _shoot(tester, 'today_narrow_weekend');
  });

  testWidgets('choosing when the day starts, and the header after midnight', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 24, 1, 30));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('SATURDAY'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4am'));
    await tester.pumpAndSettle();
    expect(state.dayStartHour, 4);
    expect(find.text('New day starts at'), findsOneWidget, reason: 'Settings stays open');
    await _shoot(tester, 'day_start_settings');

    await tester.tapAt(const Offset(20, 880)); // closes Settings
    await tester.pumpAndSettle();
    expect(state.today, DateTime(2026, 10, 23));
    expect(find.text('SATURDAY'), findsNothing);
    expect(find.text('FRIDAY  ·  UNTIL 4AM'), findsOneWidget);
    await _shoot(tester, 'day_start_header');
  });

  testWidgets('date pill keeps resizing when entering and leaving Today', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 25));
    state.showMonth(10);
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    Finder pillFor(String title) => find.ancestor(of: find.text(title), matching: find.byType(AnimatedSize)).first;
    final originalState = tester.state(pillFor('October'));
    final monthWidth = tester.getSize(pillFor('October')).width;

    await tester.tap(find.text('Today').hitTestable());
    await tester.pump();
    expect(tester.state(pillFor('25 October')), same(originalState));
    expect(tester.getSize(pillFor('25 October')).width, closeTo(monthWidth, 0.01));
    await tester.pump(const Duration(milliseconds: 210));
    final growingWidth = tester.getSize(pillFor('25 October')).width;
    await tester.pumpAndSettle();
    final todayWidth = tester.getSize(pillFor('25 October')).width;
    expect(growingWidth, greaterThan(monthWidth));
    expect(growingWidth, lessThan(todayWidth));

    await tester.tap(find.text('Oct').hitTestable());
    await tester.pump();
    expect(tester.state(pillFor('October')), same(originalState));
    await tester.pump(const Duration(milliseconds: 210));
    final shrinkingWidth = tester.getSize(pillFor('October')).width;
    expect(shrinkingWidth, greaterThan(monthWidth));
    expect(shrinkingWidth, lessThan(todayWidth));
    await tester.pumpAndSettle();
    expect(tester.getSize(pillFor('October')).width, closeTo(monthWidth, 0.01));
  });

  testWidgets('switching views and months never shows two at once', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Logged since January, so every month up to October has a tab.
    final state = AppState(_testStore()..setJournal('2026-01-02', 'New year.'), clock: () => DateTime(2026, 10, 23));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    // How visible a widget is, through every fade above it.
    double opacityOf(Finder f) {
      var o = 1.0;
      tester.element(f).visitAncestorElements((e) {
        final w = e.widget;
        if (w is FadeTransition) o *= w.opacity.value;
        return true;
      });
      return o;
    }

    // Steps through a transition, failing if both sides show at any real
    // strength in one frame, or if either side jumps rather than eases.
    Future<void> expectFadeThrough(Finder from, Finder to, String name) async {
      await tester.pump();
      Finder pageOf(Finder label) => find.ancestor(
        of: label,
        matching: find.byWidgetPredicate((widget) => widget is TodayView || widget is MonthView),
      );
      final fromElement = find.ancestor(of: pageOf(from), matching: find.byType(FadeTransition)).evaluate().first;
      final fromView = find.byElementPredicate((element) => identical(element, fromElement));
      Finder? toView;
      final fromBounds = tester.getRect(fromView);
      Rect? toBounds;
      var (lastA, lastB) = (1.0, 0.0);
      for (var i = 1; i <= 18; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (fromView.evaluate().isNotEmpty) {
          expect(tester.getRect(fromView), fromBounds, reason: '$name outgoing page stays put at frame $i');
        }
        if (toView == null && to.evaluate().isNotEmpty) {
          final element = find.ancestor(of: pageOf(to), matching: find.byType(FadeTransition)).evaluate().first;
          toView = find.byElementPredicate((candidate) => identical(candidate, element));
          toBounds = tester.getRect(toView);
        }
        if (toView != null) {
          expect(tester.getRect(toView), toBounds, reason: '$name incoming page stays put at frame $i');
        }
        final a = fromView.evaluate().isEmpty ? 0.0 : tester.widget<FadeTransition>(fromView).opacity.value;
        final b = toView == null ? 0.0 : tester.widget<FadeTransition>(toView).opacity.value;
        expect(a < 0.05 || b < 0.05, isTrue, reason: '$name frame $i: $a and $b');
        expect(
          lastA - a < 0.25 && b - lastB < 0.25,
          isTrue,
          reason: '$name frame $i jumps: $lastA -> $a, $lastB -> $b',
        );
        (lastA, lastB) = (a, b);
        if (i == 5 || i == 12) await _shoot(tester, '${name}_$i');
      }
      await tester.pumpAndSettle();
    }

    state.showMonth(10);
    await expectFadeThrough(find.text('Daily rituals'), find.text('31'), 'today_to_month');

    // Between months the grid stays and morphs: September has 30 days, so
    // October's 31st column closes up while everything else stays visible.
    state.showMonth(9);
    await tester.pump();
    final card = tester.getRect(find.text('Edit rituals'));
    final first = find.text('1').first;
    var lastX = tester.getRect(find.text('30').first).left;
    for (var i = 1; i <= 18; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(opacityOf(first), 1, reason: 'the grid never fades between months');
      final x = tester.getRect(find.text('30').first).left;
      expect(x >= lastX && x - lastX < 6, isTrue, reason: 'columns spread smoothly: $lastX -> $x');
      lastX = x;
      if (i == 8) await _shoot(tester, 'oct_to_sep_8');
    }
    await tester.pumpAndSettle();
    expect(find.text('31'), findsNothing);
    expect(tester.getRect(find.text('Edit rituals')), card, reason: 'the card stays put');

    state.showToday();
    await expectFadeThrough(find.text('Edit rituals'), find.text('Daily rituals'), 'month_to_today');
    for (var month = 1; month <= 10; month++) {
      await tester.tap(find.text(monthNames[month - 1].substring(0, 3)).hitTestable());
      await expectFadeThrough(find.text('Daily rituals'), find.text('Edit rituals'), 'today_to_month_$month');
      await tester.tap(find.text('Today').hitTestable());
      await expectFadeThrough(find.text('Edit rituals'), find.text('Daily rituals'), 'month_${month}_to_today');
    }
  });

  testWidgets('repeating right-click clears not done, and the hover only covers squares', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    await tester.pumpWidget(EclipseApp(state: state));
    state.showMonth(10);
    await tester.pumpAndSettle();

    final weights = state.habits.firstWhere((h) => h.name == 'File notes');
    final day = DateTime(2026, 10, 5);
    state.selectStatus(day, weights, HabitStatus.done);
    state.selectStatus(day, weights, HabitStatus.missed);
    state.setNote(day, weights, 'Rest day');
    await tester.pumpAndSettle();

    final square = find.byWidgetPredicate((w) => w is StatusCell && w.day == day && w.habit.id == weights.id);
    await tester.tap(square, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(state.statusOf(day, weights), HabitStatus.none);
    expect(state.noteOf(day, weights), isNull);

    // Right-clicking a blank square marks not done; future squares stay disabled.
    await tester.tap(square, buttons: kSecondaryButton);
    final future = find.byWidgetPredicate((w) => w is StatusCell && w.day == DateTime(2026, 10, 30));
    await tester.tap(future.first, buttons: kSecondaryButton, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(state.statusOf(day, weights), HabitStatus.missed);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(square));
    await tester.pumpAndSettle();
    await _shoot(tester, 'row_hover');
    await gesture.removePointer();
  });

  testWidgets('a ticked to-do glides down to the bottom', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    for (final t in [...state.todos[TodoScope.today]!]) {
      state.removeTodo(TodoScope.today, t);
    }
    for (final t in ['Alpha', 'Bravo', 'Charlie']) {
      state.addTodo(TodoScope.today, t);
    }
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    final (alpha, charlie) = (top('Alpha'), top('Charlie'));

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(state.todos[TodoScope.today]!.first.done, isTrue);
    // Movement overlaps the tick, without a serial wait.
    await tester.pump(Motion.reorder ~/ 2);
    expect(top('Alpha'), allOf(lessThan(charlie), greaterThan(alpha)), reason: 'still on its way down');

    await tester.pumpAndSettle();
    expect(top('Alpha'), moreOrLessEquals(charlie));
    expect(top('Charlie'), lessThan(top('Alpha')));
  });

  testWidgets('the week ahead, rituals and further ahead fill the columns', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    state.addTodo(TodoScope.month, 'Book flights', dueDate: DateTime(2026, 11, 20));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final week = find.byType(WeekCard), later = find.byType(FurtherAheadCard);
    Rect card(String title) => tester.getRect(find.ancestor(of: find.text(title), matching: find.byType(Tile)).first);
    final weekRect = tester.getRect(week);
    final laterRect = tester.getRect(later);
    final ritualsRect = card('Daily rituals');
    final sleepRect = card('Sleep schedule');
    final journalRect = card('Journal');

    expect(weekRect.right, lessThan(ritualsRect.left));
    expect(weekRect.width, greaterThan(ritualsRect.width), reason: 'the week keeps the widest column');
    expect(laterRect.left, greaterThan(ritualsRect.right));
    expect(laterRect.width, closeTo(ritualsRect.width, 0.5));
    expect(laterRect.bottom, closeTo(ritualsRect.bottom, 0.5));
    expect(journalRect.top, closeTo(sleepRect.top, 0.5));
    expect(journalRect.height, closeTo(sleepRect.height, 0.5));
    expect(weekRect.bottom, closeTo(journalRect.bottom, 0.5));

    // Seven days, today first, and only days with something due; anything
    // later is further ahead, under its day.
    expect(find.descendant(of: week, matching: find.textContaining('Oct 23')), findsOneWidget);
    expect(find.descendant(of: week, matching: find.text('Nothing due')), findsOneWidget);
    expect(find.descendant(of: week, matching: find.textContaining('Tomorrow')), findsNothing);
    // Days with nothing due show on request, and end at day 7.
    await tester.tap(find.byTooltip('Show days with no tasks'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: week, matching: find.textContaining('Oct 29', findRichText: true)),
      findsOneWidget,
      reason: 'the week ends at day 7',
    );
    expect(find.descendant(of: week, matching: find.textContaining('Oct 30', findRichText: true)), findsNothing);
    await tester.tap(find.byTooltip('Hide days with no tasks'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: week, matching: find.textContaining('Oct 29', findRichText: true)), findsNothing);
    expect(find.descendant(of: later, matching: find.text('Book flights')), findsOneWidget);
    expect(find.descendant(of: later, matching: find.textContaining('Nov 20')), findsOneWidget);

    // Adding for tomorrow from the box at the foot, its day picked first.
    await tester.enterText(find.descendant(of: week, matching: find.byType(TextField)).last, 'Prepare tomorrow breakfast');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text("Doesn't repeat"), findsOneWidget, reason: 'Enter without a day asks for one');
    await tester.tap(find.text('24').last);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final tomorrow = find.descendant(of: week, matching: find.textContaining('Tomorrow'));
    expect(tomorrow, findsOneWidget);
    expect(state.todos[TodoScope.tomorrow]!.map((t) => t.text), contains('Prepare tomorrow breakfast'));
    double top(Finder finder) => tester.getTopLeft(finder).dy;
    final task = find.text('Prepare tomorrow breakfast');
    expect(top(task), greaterThan(top(tomorrow)));

    // Ticking it files it under today, arriving at the foot of today's list
    // unticked before it settles; Tomorrow, empty again, goes.
    state.addTodo(TodoScope.today, 'Already today');
    await tester.pumpAndSettle();
    await tester.tap(task);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Prepare tomorrow breakfast').done, isTrue);
    expect(top(task), greaterThan(top(find.text('Already today'))));
    expect(DefaultTextStyle.of(tester.element(task)).style.decoration, isNot(TextDecoration.lineThrough));
    await tester.pumpAndSettle();
    expect(tomorrow, findsNothing);
    expect(DefaultTextStyle.of(tester.element(task)).style.decoration, TextDecoration.lineThrough);
    await tester.tap(task);
    await tester.pumpAndSettle();
    expect(tomorrow, findsOneWidget);
    expect(top(task), greaterThan(top(tomorrow)));
    expect(state.todos[TodoScope.tomorrow]!.single.done, isFalse);
  });

  testWidgets('a removed task closes up rather than vanishing', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    state.addTodo(TodoScope.today, 'Goes away');
    state.addTodo(TodoScope.today, 'Stays');
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final week = find.byType(WeekCard);
    final stays = find.descendant(of: week, matching: find.text('Stays'));
    final before = tester.getTopLeft(stays).dy;
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(tester.getCenter(find.text('Goes away')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: week, matching: find.byTooltip('Remove')).first);
    await tester.pump();
    await tester.pump(Motion.morph ~/ 2);
    expect(state.todos[TodoScope.today]!.map((t) => t.text), ['Stays']);
    expect(find.text('Goes away'), findsOneWidget, reason: 'still closing up');
    final midway = tester.getTopLeft(stays).dy;
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(stays).dy;
    expect(find.text('Goes away'), findsNothing);
    expect(after, lessThan(before));
    expect(midway, allOf(lessThanOrEqualTo(before), greaterThan(after)));
  });

  testWidgets('the add boxes pick a day and its repeat together, yearly included', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final later = find.byType(FurtherAheadCard);
    expect(find.descendant(of: later, matching: find.byTooltip('Repeat')), findsNothing);
    await tester.tap(find.descendant(of: later, matching: find.byTooltip('Pick a day')));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Doesn't repeat"));
    await tester.pumpAndSettle();
    for (final pill in ['Weekly', 'Monthly', 'Yearly', 'Custom']) {
      final size = tester.getSize(find.text(pill));
      final painter = TextPainter(
        text: TextSpan(text: pill, style: tester.widget<Text>(find.text(pill)).style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(tester.element(find.text(pill))),
      )..layout();
      expect(size.width, greaterThanOrEqualTo(painter.width - 0.5), reason: '$pill shows in full');
    }
    // Every so many months lands on the day's date, or a shorter month's last.
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('months'));
    await tester.pumpAndSettle();
    expect(find.text('on the 30th'), findsOneWidget);
    expect(find.text('In shorter months, on the last day.'), findsOneWidget);
    await tester.tap(find.text('Yearly'));
    await tester.pumpAndSettle();
    expect(find.textContaining('year on Oct 30'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Every year'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: later, matching: find.byType(TextField)), 'Renew licence');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final repeat = state.repeats.single;
    expect(
      (repeat.text, repeat.rule, repeat.start),
      ('Renew licence', const RepeatRule.yearly(1), DateTime(2026, 10, 30)),
    );
  });

  testWidgets('dragging a task onto another day moves it there', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    state.addTodo(TodoScope.today, 'Drag me');
    state.toggleWeekEmptyDays();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final week = find.byType(WeekCard);
    final from = tester.getCenter(find.text('Drag me'));
    // An empty day, shown with empty days, takes it at its heading.
    final to = tester.getCenter(find.descendant(of: week, matching: find.textContaining('Oct 25', findRichText: true)));
    await tester.dragFrom(from, to - from);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.today]!.map((t) => t.text), isNot(contains('Drag me')));
    expect(state.todos[TodoScope.week]!.single.dueDate, DateTime(2026, 10, 25));
    expect(tester.takeException(), isNull);
  });

  testWidgets('task actions reveal per row and pills only on each icon', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    state.addTodo(TodoScope.today, 'Hover first');
    state.addTodo(TodoScope.today, 'Hover second');
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final panel = find.byType(WeekCard);
    final edits = find.descendant(of: panel, matching: find.byTooltip('Edit task'));
    final removes = find.descendant(of: panel, matching: find.byTooltip('Remove'));
    double opacity(Finder action) =>
        tester.widget<AnimatedOpacity>(find.ancestor(of: action, matching: find.byType(AnimatedOpacity)).first).opacity;
    Color background(Finder action) => tester
        .widget<IconButton>(find.ancestor(of: action, matching: find.byType(IconButton)).first)
        .style!
        .backgroundColor!
        .resolve({WidgetState.hovered})!;
    expect(edits, findsNothing, reason: 'hover buttons are built only while shown');
    final original = tester.getRect(find.text('Hover first'));
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(tester.getCenter(find.text('Hover first')));
    await tester.pumpAndSettle();
    expect(edits, findsOneWidget);
    expect(opacity(edits.at(0)), 1);
    expect(opacity(removes.at(0)), 1);
    expect(tester.getRect(find.text('Hover first')), original, reason: 'the buttons take the room kept for them');
    expect(background(edits.at(0)), background(removes.at(0)));
    final editButton = tester.widget<IconButton>(
      find.ancestor(of: edits.at(0), matching: find.byType(IconButton)).first,
    );
    expect(editButton.style!.backgroundColor!.resolve({}), Colors.transparent);
    expect(editButton.style!.backgroundColor!.resolve({WidgetState.hovered})!.a, greaterThan(0));
    await pointer.moveTo(tester.getCenter(edits.at(0)));
    await tester.pumpAndSettle();
    await pointer.down(tester.getCenter(edits.at(0)));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(find.text('Edit task'), findsOneWidget);
    expect(state.todos[TodoScope.today]!.first.done, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await pointer.moveTo(tester.getCenter(find.text('Hover second')));
    await tester.pumpAndSettle();
    expect(edits, findsOneWidget, reason: "the first row's buttons go once faded");
    expect(opacity(edits.at(0)), 1);
    expect(tester.getRect(find.text('Hover first')), original);
    expect(tester.getCenter(edits.at(0)).dy, greaterThan(original.bottom), reason: "now on the second row");
  });

  testWidgets('completing yesterday’s carried task removes it from today and undo restores it', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var now = DateTime(2026, 10, 23, 12);
    final store = _testStore();
    final state = AppState(store, clock: () => now);
    state.addTodo(TodoScope.today, 'Collect prescription');
    state.addTodo(TodoScope.today, 'Keep this task');
    now = DateTime(2026, 10, 24, 12);
    state.checkDate();
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('Collect prescription'), findsOneWidget);

    final yesterday = DateTime(2026, 10, 23);
    state.showDay(yesterday);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Collect prescription'));
    await tester.pumpAndSettle();
    expect(state.todosOn(TodoScope.today, yesterday).singleWhere((t) => t.text == 'Collect prescription').done, isTrue);
    state.showDay(state.today);
    await tester.pumpAndSettle();
    expect(find.text('Collect prescription'), findsNothing);
    expect(find.text('Keep this task'), findsOneWidget);

    state.showDay(yesterday);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Collect prescription'));
    await tester.pumpAndSettle();
    expect(
      state.todosOn(TodoScope.today, yesterday).singleWhere((t) => t.text == 'Collect prescription').done,
      isFalse,
    );
    state.showDay(state.today);
    await tester.pumpAndSettle();
    expect(find.text('Collect prescription'), findsOneWidget);
    expect(state.todos[TodoScope.today]!.singleWhere((t) => t.text == 'Collect prescription').done, isFalse);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    store.close();
  });

  testWidgets('tasks can be edited and dated; only yesterday stays editable', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var now = DateTime(2026, 10, 23, 12);
    final state = AppState(_testStore(), clock: () => now);
    state.addTodo(TodoScope.week, 'Original task', dueDate: DateTime(2026, 10, 27));
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    final panel = find.byType(WeekCard);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(tester.getCenter(find.text('Original task')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: panel, matching: find.byTooltip('Edit task')).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Original task'), 'Revised task');
    await tester.tap(find.text('Due 27/10/2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('24').last);
    await tester.pumpAndSettle();
    expect(find.text('Due 24/10/2026'), findsOneWidget, reason: 'a day goes back to the task');
    await tester.tap(find.widgetWithText(TextField, 'Revised task'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(state.todos[TodoScope.tomorrow]!.single.text, 'Revised task');
    state.addTodo(TodoScope.today, 'Yesterday task');
    now = DateTime(2026, 10, 24, 12);
    state.checkDate();
    state.showDay(DateTime(2026, 10, 23));
    await tester.pumpAndSettle();
    expect(state.canEditDay(state.shownDay), isTrue);
    await tester.tap(find.descendant(of: panel, matching: find.text('Add task')).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: panel, matching: find.byType(TextField)).first, 'Late task');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(state.todosOn(TodoScope.today, state.shownDay).map((t) => t.text), contains('Late task'));
    final mark = find.byWidgetPredicate((w) => w is StatusCell && w.day == state.shownDay).first;
    await tester.tap(mark);
    await tester.pumpAndSettle();
    expect(state.statusOf(state.shownDay, tester.widget<StatusCell>(mark).habit), HabitStatus.done);
    final journal = find.byWidgetPredicate((w) => w is TextField && w.expands);
    expect(tester.widget<TextField>(journal).readOnly, isFalse);
    await tester.enterText(journal, 'A late correction');
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.journalOf(state.shownDay), 'A late correction');
    await _shoot(tester, 'yesterday_editable');
    now = DateTime(2026, 10, 25, 12);
    state.checkDate();
    await tester.pumpAndSettle();
    expect(find.text('Add task').hitTestable(), findsNothing);
    expect(find.byTooltip('Edit task'), findsNothing);
    expect(tester.widget<TextField>(journal).readOnly, isTrue);
    expect(tester.widget<StatusCell>(mark).enabled, isFalse);
    state.showToday();
    await tester.pumpAndSettle();
    await _shoot(tester, 'planner_updated');
  });

  testWidgets('Enter saves a note', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    await tester.pumpWidget(EclipseApp(state: state));
    state.showMonth(10);
    await tester.pumpAndSettle();

    final weights = state.habits.firstWhere((h) => h.name == 'File notes');
    final day = DateTime(2026, 10, 6);
    // Middle-click selects other directly and asks for an optional note.
    await tester.pumpAndSettle();

    await tester.tap(
      find.byWidgetPredicate((w) => w is StatusCell && w.day == day && w.habit.id == weights.id),
      buttons: kMiddleMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Sore back');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('What happened?'), findsNothing);
    expect(state.noteOf(day, weights), 'Sore back');
  });

  testWidgets('Option-click selects other, like middle-click', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    await tester.pumpWidget(EclipseApp(state: state));
    state.showMonth(10);
    await tester.pumpAndSettle();

    final habit = state.habits.firstWhere((h) => h.name == 'File notes');
    final day = DateTime(2026, 10, 7);
    final square = find.byWidgetPredicate((w) => w is StatusCell && w.day == day && w.habit.id == habit.id);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.tap(square);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(state.statusOf(day, habit), HabitStatus.other);
    expect(find.text('What happened?'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    // A plain click still marks done.
    await tester.tap(square);
    await tester.pumpAndSettle();
    expect(state.statusOf(day, habit), HabitStatus.done);
  });

  testWidgets('update banner', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    final updater = GitUpdater(repo: '/nowhere', installedCommit: 'abc', executable: '/nowhere/eclipse');
    await tester.pumpWidget(EclipseApp(state: state, updater: updater));
    await tester.pumpAndSettle();
    expect(find.text('A new version is available'), findsNothing);

    updater
      ..newVersion = '1.10.2'
      ..status = UpdateStatus.available
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('v1.10.2'), findsOneWidget);
    await _shoot(tester, 'update_available');

    updater
      ..status = UpdateStatus.updating
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 600));
    await _shoot(tester, 'update_updating');

    updater
      ..error = 'Error: lib/main.dart:12:3: Expected a semicolon'
      ..status = UpdateStatus.failed
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 600));
    await _shoot(tester, 'update_failed');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(updater.status, UpdateStatus.none);
  });

  testWidgets('the big date opens a past day to look at', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var now = DateTime(2026, 10, 22, 12);
    final state = AppState(_testStore(), clock: () => now);
    state.addTodo(TodoScope.today, 'Return library books');
    final read = state.habits.firstWhere((h) => h.name == 'Sketch');
    state.selectStatus(DateTime(2026, 10, 22), read, HabitStatus.done);
    await state.setJournal(DateTime(2026, 10, 22), 'A quiet Thursday.');
    now = DateTime(2026, 10, 24, 9);
    state.checkDate();

    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('22/10'), findsWidgets);

    await tester.tap(find.text('24 October').last);
    await tester.pumpAndSettle();
    expect(find.text('October 2026'), findsOneWidget);
    await _shoot(tester, 'day_picker');
    await tester.tap(find.descendant(of: find.byType(DayPicker), matching: find.text('25')));
    await tester.pumpAndSettle();
    expect(state.viewDay, isNull, reason: 'the future is not open');
    await tester.tap(find.descendant(of: find.byType(DayPicker), matching: find.text('22')));
    // The cards stay put through the change: their headings never fade,
    // while the journal's words fade through to the other day's.
    double opacity(Finder f) => tester
        .widgetList<FadeTransition>(find.ancestor(of: f, matching: find.byType(FadeTransition)))
        .fold(1.0, (a, t) => a * t.opacity.value);
    var journalDipped = false;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(TodayView).evaluate().isEmpty) continue;
      for (final heading in ['Daily rituals', 'Sleep schedule', 'Week ahead', 'Further ahead', 'Journal']) {
        expect(opacity(find.text(heading)), 1, reason: '$heading stays while the day changes');
      }
      final words = find.text('A quiet Thursday.');
      if (words.evaluate().isNotEmpty && opacity(words) < 0.9) journalDipped = true;
    }
    expect(journalDipped, isTrue, reason: "the journal's words fade in");
    await tester.pumpAndSettle();

    expect(state.viewDay, DateTime(2026, 10, 22));
    expect(find.text('THURSDAY  ·  LOOKING BACK'), findsOneWidget);
    expect(find.text('A quiet Thursday.'), findsOneWidget);
    expect(find.text('Add task').hitTestable(), findsNothing, reason: 'look only');
    expect(find.text('22/10'), findsNothing, reason: 'it was new that day');
    expect(find.text('22 Oct'), findsWidgets, reason: 'the past day opens a tab left of Today');
    expect(tester.getCenter(find.text('22 Oct').last).dx, lessThan(tester.getCenter(find.text('Today').first).dx));
    await _shoot(tester, 'past_day');

    double pastTab(String label) =>
        tester.getSize(find.ancestor(of: find.text(label), matching: find.byType(ClipRect)).first).width;
    final before = pastTab('22 Oct');
    state.showDay(DateTime(2026, 10, 23));
    // The tab eases to the new label's width while the labels fade through.
    await tester.pump();
    await tester.pump(Motion.morph ~/ 2);
    final midway = pastTab('Yesterday');
    await tester.pumpAndSettle();
    final after = pastTab('Yesterday');
    expect(after, greaterThan(before));
    expect(midway, inExclusiveRange(before, after));
    expect(find.text('FRIDAY  ·  YESTERDAY'), findsOneWidget);
    expect(find.textContaining('LOOKING BACK'), findsNothing);
    expect(find.text('Yesterday'), findsWidgets);

    double tabWidth() =>
        tester.getSize(find.ancestor(of: find.text('Yesterday'), matching: find.byType(ClipRect)).first).width;
    final open = tabWidth();
    await tester.tap(find.text('Today').hitTestable().first);
    // The pill leaves first; the tab folds only once it has gone.
    await tester.pump();
    await tester.pump(Motion.morph ~/ 2);
    expect(tabWidth(), open, reason: 'still open while the pill glides');
    await tester.pumpAndSettle();
    expect(state.viewDay, isNull);
    expect(tabWidth(), 0, reason: 'folded away');
  });

  testWidgets('the year tab adds up every month', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 24));
    final read = state.habits.firstWhere((h) => h.name == 'Sketch');
    for (final (month, days) in [(8, 10), (9, 4), (10, 2)]) {
      state.habitsFor(2026, month);
      for (var d = 1; d <= days; d++) {
        state.selectStatus(DateTime(2026, month, d), read, HabitStatus.done);
      }
      state.selectStatus(DateTime(2026, month, 20), read, HabitStatus.done);
      state.selectStatus(DateTime(2026, month, 20), read, HabitStatus.missed);
    }
    state.selectStatus(DateTime(2026, 10, 3), state.sleepHabits.first, HabitStatus.done);

    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Year').last);
    await tester.pumpAndSettle();
    expect(state.viewingYear, isTrue);
    expect(find.text('YEAR TO DATE'), findsNWidgets(3), reason: 'kicker and both tables');
    expect(find.text('91%'), findsWidgets, reason: 'August: 10 of 11');
    expect(find.text('80%'), findsWidgets, reason: 'Sketch so far: 16 of 20');
    await _shoot(tester, 'year');

    // Only the months since the first one logged, up to this one.
    expect(find.text('JUL'), findsNothing);
    expect(find.text('AUG'), findsWidgets);
    expect(find.text('NOV'), findsNothing);
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing, reason: 'no earlier year to go to');
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);

    // A ritual added in October fades the months shown before it.
    int faded() => tester.widgetList<Text>(find.text('–')).where((text) => (text.style?.color?.a ?? 1) < 0.3).length;
    final before = faded();
    state.addHabit(2026, 10, 'New ritual');
    await tester.pumpAndSettle();
    expect(faded() - before, 2, reason: 'August and September');

    state.store.setJournal('2025-12-05', 'Started in December.');
    state.showYear();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_left_rounded).first);
    await tester.pumpAndSettle();
    expect(state.viewingYear, isTrue, reason: 'the year switcher stays on the record');
    expect(find.text('2025'), findsWidgets);
    expect(find.text('DEC'), findsWidgets);
    expect(find.text('NOV'), findsNothing, reason: 'nothing before the first month');
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
  });

  testWidgets('the welcome tour walks round, and opens again from the appearance menu', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(Store.memory(), clock: () => DateTime(2026, 10, 23));
    state.nightLightAvailable = true;
    expect(state.firstRun, isTrue);
    expect(state.habits.first.name, 'Drink water on waking', reason: 'a new install starts with examples');
    expect(state.todos[TodoScope.today]!.first.text, 'Tick this off to try it');
    expect(AppState(state.store).firstRun, isFalse, reason: 'only an empty store is a first run');
    state.showMonth(3);
    state.startTour();
    expect(state.viewMonth, isNull, reason: 'the tour walks the Today view');
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Eclipse!'), findsOneWidget);
    // Tests only decode images when asked to.
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        await precacheImage((e.widget as Image).image, e);
      }
    });
    await tester.pump();
    await _shoot(tester, 'tour_0');
    await tester.tap(find.text('Show me around'));
    await tester.pumpAndSettle();
    expect(find.text('Daily rituals'), findsWidgets);
    // The app underneath waits while the tour is up.
    await tester.tap(find.text('Oct').first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(state.viewMonth, isNull);
    for (var i = 1; i < 12; i++) {
      await _shoot(tester, 'tour_$i');
      await tester.tap(find.text(i == 11 ? 'Get started' : 'Next'));
      if (_shotDir.isNotEmpty && i == 7) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 55));
        await _shoot(tester, 'tour_settings_open_55ms');
        await tester.pump(const Duration(milliseconds: 55));
        await _shoot(tester, 'tour_settings_open_110ms');
      }
      if (_shotDir.isNotEmpty && (i == 8 || i == 9)) {
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 210));
        await _shoot(tester, i == 8 ? 'tour_data_transition' : 'tour_google_transition');
      }
      if (_shotDir.isNotEmpty && i == 10) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 105));
        await _shoot(tester, 'tour_appearance_open_105ms');
        await tester.pump(const Duration(milliseconds: 105));
        await _shoot(tester, 'tour_appearance_open_210ms');
      }
      await tester.pumpAndSettle();
    }
    expect(state.touring, isFalse);
    expect(find.text('Get started'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show the welcome tour'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Eclipse!'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(state.touring, isFalse);
  });

  testWidgets('theme switcher, and every theme renders', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    // A little history so streaks, trails and the grid show every status.
    for (final (i, h) in state.habits.indexed) {
      for (var d = 14; d <= 23; d++) {
        final status = (i + d) % 5 == 0 ? 3 : ((i * 3 + d) % 4 == 0 ? 2 : 1);
        state.selectStatus(DateTime(2026, 10, d), h, HabitStatus.values[status]);
      }
    }
    state.addTodo(TodoScope.week, 'Book dentist');
    state.addTodo(TodoScope.month, 'Renew passport');

    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    state.nightLightAvailable = true;
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    expect(find.text('Sunrise'), findsOneWidget);
    for (var i = 1; i < palettes.length; i++) {
      expect(
        tester.getTopLeft(find.text(palettes[i - 1].name)).dy,
        lessThan(tester.getTopLeft(find.text(palettes[i].name)).dy),
      );
    }
    expect(find.text(Platform.isMacOS ? 'Follow Dark mode' : 'Follow the sun'), findsOneWidget);
    await _shoot(tester, 'theme_menu');
    await tester.tap(find.text('Morning Pastel'));
    await tester.pumpAndSettle();
    expect(state.themeName, 'Morning Pastel');

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekends as rest days'));
    await tester.pumpAndSettle();
    expect(state.restWeekends, isTrue);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    state.showMonth(10);
    await tester.pumpAndSettle();
    await _shoot(tester, 'rest_weekends_month');
    state.setRestWeekends(false);

    for (final palette in palettes) {
      final slug = palette.name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
      state.setTheme(palette.name);
      state.showToday();
      await tester.pumpAndSettle();
      await _shoot(tester, 'theme_${slug}_today');
      state.showMonth(10);
      await tester.pumpAndSettle();
      await _shoot(tester, 'theme_${slug}_month');
    }
  });
  testWidgets('everything clickable shows the click cursor', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(_testStore(), clock: () => DateTime(2026, 10, 23));
    state.addTodo(TodoScope.today, 'Tick this off');
    state.addTodo(TodoScope.week, 'Book dentist');
    await tester.pumpWidget(EclipseApp(state: state));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    final missing = <String>[];

    // Hovers each tappable thing that's on screen and not covered, and
    // notes any that keep the arrow.
    Future<void> sweep(String where) async {
      final tappable = find
          .byWidgetPredicate(
            (w) => switch (w) {
              GestureDetector() => w.onTap != null || w.onDoubleTap != null || w.onSecondaryTap != null,
              InkWell() => w.onTap != null,
              ButtonStyleButton() => w.onPressed != null,
              IconButton() => w.onPressed != null,
              _ => false,
            },
          )
          .hitTestable();
      for (final element in tappable.evaluate().toList()) {
        final box = element.renderObject! as RenderBox;
        if (!box.attached) continue;
        await mouse.moveTo(box.localToGlobal(box.size.center(Offset.zero)));
        await tester.pump();
        final cursor = RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
        if (cursor != SystemMouseCursors.click) {
          final label = find
              .descendant(of: find.byElementPredicate((e) => e == element), matching: find.byType(Text))
              .evaluate()
              .map((e) => (e.widget as Text).data)
              .firstOrNull;
          final icon = find
              .descendant(of: find.byElementPredicate((e) => e == element), matching: find.byType(Icon))
              .evaluate()
              .map((e) => (e.widget as Icon).icon)
              .firstOrNull;
          missing.add('$where: ${element.widget.runtimeType} ${label ?? icon ?? ''} shows $cursor');
        }
      }
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
    }

    await sweep('Today');
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await sweep('Settings, General');
    await tester.tap(find.text('Data').hitTestable());
    await tester.pumpAndSettle();
    await sweep('Settings, Backups and sync');
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await sweep('Appearance');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('23 October'));
    await tester.pumpAndSettle();
    await sweep('Calendar');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    state.showMonth(10);
    await tester.pumpAndSettle();
    await sweep('October');
    await tester.tap(find.text('Edit rituals'));
    await tester.pumpAndSettle();
    await sweep('Editing rituals');
    state.showYear();
    await tester.pumpAndSettle();
    await sweep('Year');
    state.startTour();
    await tester.pumpAndSettle();
    await sweep('Welcome tour');

    expect(missing, isEmpty);
  });
}
