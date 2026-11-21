import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/journal_drive.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pauses the stale-file scan until [gate] completes, and fails the next
/// write of [failText].
class _FlakyFiles extends JournalFiles {
  _FlakyFiles(super.dir);
  Completer<void>? gate;
  final scanning = Completer<void>();
  String? failText;

  @override
  Future<List<DateTime>> days() async {
    if (gate case final g?) {
      if (!scanning.isCompleted) scanning.complete();
      await g.future;
    }
    return super.days();
  }

  @override
  Future<void> write(DateTime day, String text) {
    if (failText != null && text == failText) {
      failText = null;
      return Future.error(const FileSystemException('No space left on device', '/journal'));
    }
    return super.write(day, text);
  }
}

void main() {
  late Directory dir;
  late Store store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('eclipse_journal_files');
    store = Store.memory();
    store.addHabit(2026, 11, 'Read');
    store.setJournal('2026-11-01', 'Old');
    store.setJournal('2026-11-02', 'Other day');
    store.setSetting('journalExported', '1');
  });

  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  test('a day whose file failed to save during a sweep of stale files is written once the disk is back', () async {
    store.setSetting('journalFilesStale', '1'); // an earlier save failed
    final files = _FlakyFiles(Directory('${dir.path}/files'))..gate = Completer<void>();
    final state = AppState(store, journalFiles: files, clock: () => DateTime(2026, 11, 3, 9));
    await files.scanning.future; // the sweep has written both days and is scanning
    files.failText = 'New';
    await state.setJournal(DateTime(2026, 11, 1), 'New'); // fails: disk full
    files.gate!.complete();
    await state.flushFiles();
    state.dispose();
    expect(store.setting('journalFilesStale'), '1', reason: 'still behind, as the failed save left it');
    // Disk is fine again; the app opens next time.
    final again = AppState(store, journalFiles: JournalFiles(files.dir), clock: () => DateTime(2026, 11, 3, 10));
    await again.flushFiles();
    again.dispose();
    expect(files.fileFor(DateTime(2026, 11, 1)).readAsStringSync(), contains('New'));
  });

  test('waiting for the files waits for a sweep a save starts as it finishes', () async {
    final files = _FlakyFiles(Directory('${dir.path}/files'));
    final state = AppState(store, journalFiles: files, clock: () => DateTime(2026, 11, 3, 9));
    addTearDown(state.dispose);
    await state.flushFiles();
    // A save failed earlier; the next that works sweeps the rest, with its
    // scan held up a moment.
    store.setSetting('journalFilesStale', '1');
    files.gate = Completer<void>();
    unawaited(
      files.scanning.future.then((_) => Future<void>.delayed(const Duration(milliseconds: 20), files.gate!.complete)),
    );
    unawaited(state.setJournal(DateTime(2026, 11, 2), 'Last words'));
    // As quitting does: once this returns, the store can close.
    await state.flushFiles();
    expect(files.scanning.isCompleted, isTrue, reason: 'the save started a sweep');
    expect(store.setting('journalFilesStale'), '0', reason: 'and it was waited for');
    expect(files.fileFor(DateTime(2026, 11, 1)).readAsStringSync(), contains('Old'));
  });

  test('JournalFolder hourly check detects MD5 changes in Drive and re-uploads reverted edits', () async {
    final drive = _FakeJournalDrive();
    final config = <String, dynamic>{};
    var now = DateTime(2026, 11, 19, 9);
    final folder = JournalFolder(config, () async {}, now: () => now);
    const text = 'My real entry';
    await folder.copy(
      drive,
      machine: 'pc',
      stamp: 's1',
      writers: () => {'2026-11-19': 'pc'},
      texts: () => {'2026-11-19': text},
      stopped: () => false,
    );
    final folderId = folder.id!;
    final yearId = (config['journalYears'] as Map)['2026'] as String;
    final fileId = (config['journalUp'] as Map)['2026-11-19'][0] as String;

    await drive.writeFile('2026-11-19.md', yearId, utf8.encode('Old reverted entry'), id: fileId);
    now = now.add(const Duration(hours: 2));
    await folder.copy(
      drive,
      machine: 'pc',
      stamp: 's1',
      writers: () => {'2026-11-19': 'pc'},
      texts: () => {'2026-11-19': text},
      stopped: () => false,
    );
    expect(utf8.decode(drive.journalFiles[fileId]!.$3), contains('My real entry'));
    expect(await drive.exists(folderId), isTrue);
  });

  test('a journal file that failed to save is written once the folder works again, even after a restart', () async {
    final localStore = Store.memory();
    addTearDown(localStore.close);
    final day = DateTime(2026, 10, 31);
    final temp = Directory.systemTemp.createTempSync('eclipse-journal-retry-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final files = _FailingJournalFiles(temp);
    localStore.setJournal(dateKey(day), 'Old text');
    localStore.setSetting('journalExported', '1');
    await files.write(day, 'Old text');
    final state = AppState(localStore, journalFiles: files, clock: () => day);
    await state.flushFiles();
    files.fail = true;
    await state.setJournal(day, 'New text');
    await state.flushFiles();
    files.fail = false;
    state.dispose();
    final reopened = AppState(localStore, journalFiles: files, clock: () => day);
    addTearDown(reopened.dispose);
    await reopened.flushFiles();
    expect(files.fileFor(day).readAsStringSync(), contains('New text'));
    expect(localStore.setting('journalFilesStale'), '0');
  });

  test('three overlapping journal merges converge without duplicated revisions', () {
    List<List<Object?>> sent(SyncEngine e) => e.changesSince(0).values.expand((v) => v).toList();
    final stores = [
      for (var i = 0; i < 3; i++)
        () {
          final s = Store.memory();
          addTearDown(s.close);
          return s;
        }(),
    ];
    final engines = [for (var i = 0; i < 3; i++) SyncEngine(stores[i], 'machine$i')];
    for (var i = 0; i < 3; i++) {
      stores[i].setJournal('2026-10-25', ['AAA', 'BBB', 'CCC'][i]);
      stores[i].raw.execute('UPDATE sync_dirty SET at = ?', [1000 + 1000 * i]);
      engines[i].flush();
    }
    final originals = engines.map(sent).toList();
    engines[0].mergeAll([(originals[1], 'B')]);
    engines[1].mergeAll([(originals[2], 'C')]);
    engines[0].mergeAll([(sent(engines[1]), 'B')]);
    engines[2].mergeAll([(originals[0], 'A')]);
    engines[2].mergeAll([(originals[1], 'B')]);
    for (var round = 0; round < 3; round++) {
      for (final a in engines) {
        for (final b in engines) {
          if (a != b) a.mergeAll([(sent(b), b.me)]);
        }
      }
    }
    for (final s in stores) {
      expect(s.journal('2026-10-25'), 'AAA\n\n---\n\nBBB\n\n---\n\nCCC');
    }
    stores[0].setJournal('2026-10-25', 'Reviewed all three');
    engines[0].flush();
    engines[1].mergeAll([(sent(engines[0]), 'A')]);
    expect(stores[1].journal('2026-10-25'), 'Reviewed all three');
  });

  test('journal revisions survive database reopen and old seven-field input', () {
    List<List<Object?>> sent(SyncEngine e) => e.changesSince(0).values.expand((v) => v).toList();
    final temp = Directory.systemTemp.createTempSync('eclipse-journal-reopen-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}/app.db';
    var localStore = Store.open(path);
    var engine = SyncEngine(localStore, 'b');
    engine.mergeAll([
      (
        [
          [
            'journal',
            '2026-10-25',
            'text',
            jsonEncode('Old client'),
            1000,
            'a',
            {'a': 1000},
          ],
        ],
        'a',
      ),
    ]);
    localStore.setJournal('2026-10-25', 'New client');
    engine.flush();
    localStore.close();
    localStore = Store.open(path);
    addTearDown(localStore.close);
    engine = SyncEngine(localStore, 'b');
    final other = Store.memory();
    addTearDown(other.close);
    SyncEngine(other, 'c').mergeAll([(sent(engine), 'b')]);
    expect(other.journal('2026-10-25'), 'New client');
  });
}

class _FailingJournalFiles extends JournalFiles {
  _FailingJournalFiles(super.dir);
  bool fail = false;

  @override
  Future<void> write(DateTime day, String text) {
    if (fail) throw const FileSystemException('A disk that is briefly unavailable');
    return super.write(day, text);
  }
}

class _FakeJournalDrive implements JournalDrive {
  final journalFiles = <String, (String name, String parent, List<int> bytes, String md5)>{};
  final folders = <String, (String name, String? parent)>{};
  int _seq = 0;

  @override
  Future<bool> exists(String id) async => folders.containsKey(id);

  @override
  Future<String?> findFolder(String name, {String? parent}) async {
    for (final e in folders.entries) {
      if (e.value.$1 == name && e.value.$2 == parent) return e.key;
    }
    return null;
  }

  @override
  Future<String> makeFolder(String name, {String? parent}) async {
    final id = 'dir${_seq++}';
    folders[id] = (name, parent);
    return id;
  }

  @override
  Future<(String, String)?> findFile(String name, String folder) async {
    for (final e in journalFiles.entries) {
      if (e.value.$1 == name && e.value.$2 == folder) return (e.key, e.value.$4);
    }
    return null;
  }

  @override
  Future<(Map<String, (String, String)>, Map<String, String>)> listJournal(String folder) async {
    final years = <String, String>{};
    for (final e in folders.entries) {
      if (e.value.$2 == folder) years.putIfAbsent(e.value.$1, () => e.key);
    }
    final filesOut = <String, (String, String)>{};
    for (final y in years.entries) {
      for (final f in journalFiles.entries) {
        if (f.value.$2 == y.value) {
          filesOut.putIfAbsent('${y.key}/${f.value.$1}', () => (f.key, f.value.$4));
        }
      }
    }
    return (filesOut, years);
  }

  @override
  Future<(String, String)> writeFile(String name, String folder, List<int> bytes, {String? id}) async {
    final key = id ?? 'j${_seq++}';
    final sum = md5.convert(bytes).toString();
    journalFiles[key] = (name, folder, bytes, sum);
    return (key, sum);
  }

  @override
  Future<void> bin(String id) async {
    folders.remove(id);
    journalFiles.remove(id);
  }
}
