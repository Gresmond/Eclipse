import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Where everything is kept: the database, its daily backups and the
/// journal. By default the app's own folder (with the journal in
/// Documents), or a folder chosen in an earlier version, which could move
/// everything (to a synced folder, say).
///
/// That choice lives in a small file in the app's own folder, which is
/// never moved. So does where the journal goes, if you've picked a
/// folder for it: each computer keeps its own, as paths differ.
class DataFolder {
  DataFolder._(this.home, this.chosen, this.documents, this.journalChosen);

  /// The app's own folder: ~/.local/share/dev.nicholas.productivity_app
  final Directory home;

  /// The folder picked in an earlier version; null for the defaults.
  final Directory? chosen;

  final Directory documents;

  /// The folder you picked for the journal; null for the default.
  Directory? journalChosen;

  static File _pointer(Directory home) => File(p.join(home.path, 'data-folder'));
  static File _journalPointer(Directory home) => File(p.join(home.path, 'journal-folder'));

  static Directory? _read(File pointer) {
    final path = pointer.existsSync() ? pointer.readAsStringSync().trim() : '';
    return path.isEmpty ? null : Directory(path);
  }

  static DataFolder load(Directory home, Directory documents) {
    final data = DataFolder._(home, _read(_pointer(home)), documents, _read(_journalPointer(home)));
    data._renameJournal();
    return data;
  }

  /// The journal's folder, when Eclipse picks it.
  static const journalName = 'Eclipse Journals';

  /// Its name in Documents before that.
  static const oldJournalName = 'Eclipse Journal';

  /// Eclipse's own journal folder was 'Eclipse Journal' in Documents, and
  /// 'Journal' inside a chosen data folder, at first: renamed once, with
  /// what's in it. Left where it is if the new name is taken.
  void _renameJournal() {
    if (journalChosen != null) return;
    final old = Directory(
      p.join(chosen == null ? documents.path : root.path, chosen == null ? oldJournalName : 'Journal'),
    );
    try {
      if (old.existsSync() && FileSystemEntity.typeSync(journal.path) == FileSystemEntityType.notFound) {
        old.renameSync(journal.path);
      }
    } on FileSystemException catch (e) {
      debugPrint('Renaming the journal folder failed: $e');
    }
  }

  Directory get root => chosen ?? home;
  String get database => p.join(root.path, 'productivity.db');
  Directory get backups => Directory(p.join(root.path, 'backups'));
  Directory get journal => journalChosen ?? Directory(p.join(chosen == null ? documents.path : root.path, journalName));

  /// Keeps the journal's files in [folder] from now on. Moving the files
  /// already there is up to the caller, which can write them from the
  /// database.
  void useJournal(Directory folder) {
    _journalPointer(home).writeAsStringSync(folder.path);
    journalChosen = folder;
  }

  /// Whether [folder] already holds Eclipse's data (from another computer,
  /// or an earlier move).
  static bool hasData(Directory folder) => File(p.join(folder.path, 'productivity.db')).existsSync();

  /// Asks for a folder with the desktop's own picker; null if cancelled or
  /// there's no picker to ask with.
  static Future<Directory?> pick({required String title, String? start}) async {
    final home = Platform.environment['HOME'] ?? '/';
    final commands = [
      ['kdialog', '--title', title, '--getexistingdirectory', start ?? home],
      ['zenity', '--file-selection', '--directory', '--title=$title', '--filename=${start ?? home}/'],
    ];
    for (final command in commands) {
      try {
        final result = await Process.run(command.first, command.skip(1).toList());
        final path = (result.stdout as String).trim();
        return result.exitCode == 0 && path.isNotEmpty ? Directory(path) : null;
      } on ProcessException {
        continue; // not installed: try the next
      }
    }
    return null;
  }
}
