import 'dart:async';
import 'dart:io';

import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/journal_files.dart';
import 'package:eclipse/data/store.dart';
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
    unawaited(files.scanning.future.then((_) => Future<void>.delayed(const Duration(milliseconds: 20), files.gate!.complete)));
    unawaited(state.setJournal(DateTime(2026, 11, 2), 'Last words'));
    // As quitting does: once this returns, the store can close.
    await state.flushFiles();
    expect(files.scanning.isCompleted, isTrue, reason: 'the save started a sweep');
    expect(store.setting('journalFilesStale'), '0', reason: 'and it was waited for');
    expect(files.fileFor(DateTime(2026, 11, 1)).readAsStringSync(), contains('Old'));
  });
}
