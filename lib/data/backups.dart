import 'dart:io';

import 'package:path/path.dart' as p;

import 'sqlite.dart' show OpenMode, sqlite3;

import 'app_log.dart';
import '../models.dart';
import 'journal_files.dart';
import 'safe_write.dart';
import 'store.dart';

/// One saved copy of the database.
class Backup {
  Backup(this.file, this.day, {this.isBeforeJoin = false, this.isBeforeUpdate = false});

  final File file;

  /// The day it was taken; null for the copies saved just before a restore
  /// or before joining sync or updating.
  final DateTime? day;

  /// Saved just before joining sync replaced everything here.
  final bool isBeforeJoin;

  /// Saved just before an update changed the database's format.
  final bool isBeforeUpdate;

  bool get isBeforeRestore => day == null && !isBeforeJoin && !isBeforeUpdate;

  DateTime get modified => file.lastModifiedSync();
}

/// A saved copy in Google Drive, rather than a file here.
class DriveBackup extends Backup {
  DriveBackup({required this.id, required this.name, required DateTime? day, required this.saved, required this.from})
    : super(File(name), day);

  final String id;
  final String name;
  final DateTime saved;

  /// The computer it's from.
  final String from;

  @override
  DateTime get modified => saved;
}

/// The database failed its check, so no copy of it was taken.
class DataDamaged implements Exception {
  const DataDamaged();
}

/// Daily copies of the database in one folder, newest [keep] kept, plus a
/// copy of whatever was there before the last restore, before joining sync
/// and before the last update that changed its format. Once they're in Drive
/// too, the daily ones here can be turned off.
class Backups {
  Backups(this.dir, {this.keep = 30});

  final Directory dir;
  final int keep;

  static final _daily = RegExp(r'^productivity-(\d{4})-(\d{2})-(\d{2})\.db$');
  static const _beforeRestore = 'before-restore.db';
  static const _beforeJoin = 'before-join.db';
  static const _beforeUpdate = 'before-update.db';

  /// The copy before an update couldn't be made; the update went ahead.
  bool updateCopyFailed = false;

  File _fileFor(DateTime day) => File(p.join(dir.path, 'productivity-${dateKey(day)}.db'));

  /// The copies saved before the last restore, joining sync and updating
  /// first, then newest day first.
  List<Backup> list() {
    if (!dir.existsSync()) return [];
    final daily = <Backup>[];
    Backup? before, beforeJoin, beforeUpdate;
    for (final f in dir.listSync().whereType<File>()) {
      final name = p.basename(f.path);
      final m = _daily.firstMatch(name);
      if (m != null) {
        daily.add(Backup(f, DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!))));
      } else if (name == _beforeRestore) {
        before = Backup(f, null);
      } else if (name == _beforeJoin) {
        beforeJoin = Backup(f, null, isBeforeJoin: true);
      } else if (name == _beforeUpdate) {
        beforeUpdate = Backup(f, null, isBeforeUpdate: true);
      }
    }
    daily.sort((a, b) => b.day!.compareTo(a.day!));
    return [?before, ?beforeJoin, ?beforeUpdate, ...daily];
  }

  /// Today's check of the database. Throws [DataDamaged] when it fails.
  void check(Store store) {
    if (!store.isHealthy) throw const DataDamaged();
  }

  /// Checks the database, then saves today's copy if there isn't one yet
  /// and drops the oldest. Throws [DataDamaged] when the database fails its
  /// check: nothing is saved over or dropped, as the older copies are the
  /// way back.
  void daily(Store store, DateTime today) {
    check(store);
    final file = _fileFor(today);
    if (file.existsSync()) return;
    dir.createSync(recursive: true);
    store.saveCopy(file.path);
    if (!isHealthy(file)) {
      file.deleteSync();
      throw StateError('Today’s copy failed its check');
    }
    for (final old in list().where((b) => b.day != null).skip(keep)) {
      old.file.deleteSync();
    }
  }

  /// Removes the daily copies, once they're in Drive instead.
  void dropDaily() {
    for (final old in list().where((b) => b.day != null)) {
      old.file.deleteSync();
    }
  }

  /// Saves everything as it is now, before joining sync replaces it with
  /// another computer's data. Only the latest is kept.
  void beforeJoining(Store store) {
    dir.createSync(recursive: true);
    store.saveCopy(p.join(dir.path, _beforeJoin));
  }

  /// Whether the copy at [file] is whole and is one of Eclipse's.
  static bool isHealthy(File file) {
    try {
      final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
      try {
        final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
        return version >= 1 &&
            version <= Store.schemaVersion &&
            db.select('PRAGMA quick_check').first.columnAt(0) == 'ok';
      } finally {
        db.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Saves the database at [database] as it is, if this version of Eclipse
  /// is about to change its format. Run before it's opened. A copy that can't
  /// be made doesn't stop the update, and [updateCopyFailed] says so.
  void beforeUpdating(String database) {
    if (!File(database).existsSync()) return;
    try {
      final db = sqlite3.open(database);
      try {
        final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
        if (version < 1 || version >= Store.schemaVersion) return;
        dir.createSync(recursive: true);
        replaceSafelySync(p.join(dir.path, _beforeUpdate), (part) => db.execute('VACUUM INTO ?', [part.path]));
        AppLog.note('Saved a copy before updating from database format $version to ${Store.schemaVersion}');
      } finally {
        db.close();
      }
    } catch (e) {
      updateCopyFailed = true;
      AppLog.failure('The copy before updating failed', e);
    }
  }

  /// For when the database at [database] can't be used, with nothing open on
  /// it: puts it aside in the backups folder and puts [backup] in its place.
  /// The files of the [journal] hold writing newer than the copy, so that's kept
  /// too, and sync brings back this computer's own edits from its change
  /// files. If the copy can't be opened, the database goes back as it was.
  void recover(Backup backup, String database, {JournalFiles? journal}) {
    if (!isHealthy(backup.file)) throw StateError('That copy is damaged too');
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[^0-9T]'), '').substring(0, 15);
    final aside = Directory(p.join(dir.path, 'set-aside-$stamp'))..createSync(recursive: true);
    final moved = <(File, String)>[];
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$database$suffix');
      if (!file.existsSync()) continue;
      final to = p.join(aside.path, p.basename(file.path));
      file.renameSync(to);
      moved.add((File(to), file.path));
    }
    try {
      replaceSafelySync(database, (part) => backup.file.copySync(part.path));
      final store = Store.open(database);
      try {
        for (final MapEntry(key: day, value: text) in (journal?.readAllSync() ?? const <String, String>{}).entries) {
          final kept = Store.keepWriting(store.journal(day), text);
          if (kept != store.journal(day)) store.setJournal(day, kept);
        }
      } finally {
        store.close();
      }
      AppLog.note('Recovered from a backup; the damaged data is in ${aside.path}');
    } catch (_) {
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$database$suffix');
        if (file.existsSync()) file.deleteSync();
      }
      for (final (file, path) in moved) {
        file.renameSync(path);
      }
      aside.deleteSync();
      rethrow;
    }
  }

  /// Replaces the database with [backup], keeping what was there as the
  /// before-restore copy so the restore itself can be undone.
  /// [check] runs once it's in; if it throws, what was there before goes
  /// back.
  Future<void> restore(Store store, Backup backup, {void Function()? check}) async {
    dir.createSync(recursive: true);
    final before = File(p.join(dir.path, _beforeRestore));
    // Restoring the before-restore copy: read it aside so saving over it is safe.
    var source = backup.file;
    if (backup.isBeforeRestore) source = backup.file.copySync('${backup.file.path}.restoring');
    try {
      // Written beside the old one and renamed over it, so it's kept until replaced.
      store.saveCopy(before.path);
      await store.restoreFrom(source.path);
      try {
        check?.call();
      } catch (_) {
        await store.restoreFrom(before.path);
        rethrow;
      }
    } finally {
      if (source.path != backup.file.path) source.deleteSync();
    }
  }
}
