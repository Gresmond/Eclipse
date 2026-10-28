import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'store.dart';

/// Where everything is kept: the database, its daily backups and the
/// journal. By default the app's own folder (with the journal in
/// Documents), or one folder you choose, such as a synced one, so the
/// whole history can follow you to a new computer.
///
/// The choice itself lives in a small file in the app's own folder, which
/// is never moved. So does where the journal goes, if you've picked a
/// folder for it: each computer keeps its own, as paths differ.
class DataFolder {
  DataFolder._(this.home, this.chosen, this.documents, this.journalChosen);

  /// The app's own folder: ~/.local/share/dev.nicholas.productivity_app
  final Directory home;

  /// The folder you picked; null for the defaults.
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

  /// Eclipse's own journal folder was 'Eclipse Journal' in Documents, and
  /// 'Journal' inside a chosen data folder, at first: renamed once, with
  /// what's in it. Left where it is if the new name is taken.
  void _renameJournal() {
    if (journalChosen != null) return;
    final old = Directory(
      p.join(chosen == null ? documents.path : root.path, chosen == null ? 'Eclipse Journal' : 'Journal'),
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

  /// Uses [folder] from the next start. Unless it already has data of its
  /// own, everything is copied there first; the old copy stays where it
  /// was, untouched.
  void moveTo(Directory folder, Store store) {
    final target = DataFolder._(home, folder, documents, journalChosen);
    if (!hasData(folder)) {
      folder.createSync(recursive: true);
      _copyTree(backups, target.backups);
      _copyTree(journal, target.journal);
      // Last, so a half-finished copy never looks like data to use.
      store.saveCopy(target.database);
    }
    _pointer(home).writeAsStringSync(folder.path);
  }

  /// Mac copies up to 1.10.1 ran sandboxed, which kept everything inside
  /// ~/Library/Containers. The first unsandboxed start copies it out to
  /// [home] and [documents], unless there's data there already; the old copy
  /// stays where it was.
  static void leaveSandbox(Directory home, Directory documents) {
    final userHome = Platform.environment['HOME'];
    if (!Platform.isMacOS || userHome == null) return;
    if (hasData(home) || _pointer(home).existsSync()) return;
    final id = p.basename(home.path);
    final container = p.join(userHome, 'Library', 'Containers', id, 'Data');
    final oldHome = Directory(p.join(container, 'Library', 'Application Support', id));
    if (!hasData(oldHome)) return;
    final oldJournal = Directory(p.join(container, 'Documents', 'Eclipse Journal'));
    final journal = Directory(p.join(documents.path, 'Eclipse Journal'));
    if (FileSystemEntity.typeSync(oldJournal.path, followLinks: false) == FileSystemEntityType.directory) {
      _copyTree(oldJournal, journal);
    }
    _copyTree(Directory(p.join(oldHome.path, 'backups')), Directory(p.join(home.path, 'backups')));
    final pointer = _pointer(oldHome);
    if (pointer.existsSync()) pointer.copySync(_pointer(home).path);
    // The write-ahead log may hold the latest changes. The database itself
    // goes last, so a half-finished copy never looks like data to use.
    for (final name in ['productivity.db-wal', 'productivity.db-shm', 'productivity.db']) {
      final file = File(p.join(oldHome.path, name));
      if (file.existsSync()) file.copySync(p.join(home.path, name));
    }
  }

  static void _copyTree(Directory from, Directory to) {
    if (!from.existsSync()) return;
    for (final entity in from.listSync(recursive: true)) {
      if (entity is! File || entity.path.endsWith('.part')) continue;
      final dest = File(p.join(to.path, p.relative(entity.path, from: from.path)));
      if (dest.existsSync()) continue;
      dest.parent.createSync(recursive: true);
      entity.copySync(dest.path);
    }
  }

  /// Asks for a folder with the desktop's own picker; null if cancelled or
  /// there's no picker to ask with. Windows and Mac ask the app's window
  /// (Explorer's picker, Finder's panel as a sheet), so it opens in front.
  static Future<Directory?> pick({String? start, String title = 'Keep Eclipse\'s data in'}) async {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '/';
    if (Platform.isWindows || Platform.isMacOS) {
      try {
        final path = await const MethodChannel('eclipse/folders')
            .invokeMethod<String>('pick', {'title': title, 'start': start ?? home});
        return path == null || path.isEmpty ? null : Directory(path);
      } on PlatformException {
        return null;
      } on MissingPluginException {
        return null;
      }
    }
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
