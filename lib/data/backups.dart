import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'store.dart';

/// One saved copy of the database.
class Backup {
  Backup(this.file, this.day, {this.isBeforeJoin = false});

  final File file;

  /// The day it was taken; null for the copies saved just before a restore
  /// or before joining sync.
  final DateTime? day;

  /// Saved just before joining sync replaced everything here.
  final bool isBeforeJoin;

  bool get isBeforeRestore => day == null && !isBeforeJoin;

  DateTime get modified => file.lastModifiedSync();
}

/// Daily copies of the database in one folder, newest [keep] kept, plus a
/// copy of whatever was there before the last restore, and before joining
/// sync.
class Backups {
  Backups(this.dir, {this.keep = 30});

  final Directory dir;
  final int keep;

  static final _daily = RegExp(r'^productivity-(\d{4})-(\d{2})-(\d{2})\.db$');
  static const _beforeRestore = 'before-restore.db';
  static const _beforeJoin = 'before-join.db';

  File _fileFor(DateTime day) => File(p.join(dir.path, 'productivity-${dateKey(day)}.db'));

  /// The copies saved before the last restore and before joining sync
  /// first, then newest day first.
  List<Backup> list() {
    if (!dir.existsSync()) return [];
    final daily = <Backup>[];
    Backup? before, beforeJoin;
    for (final f in dir.listSync().whereType<File>()) {
      final name = p.basename(f.path);
      final m = _daily.firstMatch(name);
      if (m != null) {
        daily.add(Backup(f, DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!))));
      } else if (name == _beforeRestore) {
        before = Backup(f, null);
      } else if (name == _beforeJoin) {
        beforeJoin = Backup(f, null, isBeforeJoin: true);
      }
    }
    daily.sort((a, b) => b.day!.compareTo(a.day!));
    return [?before, ?beforeJoin, ...daily];
  }

  /// Saves today's copy if there isn't one yet, then drops the oldest.
  void daily(Store store, DateTime today) {
    final file = _fileFor(today);
    if (file.existsSync()) return;
    dir.createSync(recursive: true);
    store.saveCopy(file.path);
    for (final old in list().where((b) => b.day != null).skip(keep)) {
      old.file.deleteSync();
    }
  }

  /// Saves everything as it is now, before joining sync replaces it with
  /// another computer's data. Only the latest is kept.
  void beforeJoining(Store store) {
    dir.createSync(recursive: true);
    store.saveCopy(p.join(dir.path, _beforeJoin));
  }

  /// Replaces the database with [backup], keeping what was there as the
  /// before-restore copy so the restore itself can be undone.
  Future<void> restore(Store store, Backup backup) async {
    dir.createSync(recursive: true);
    final before = File(p.join(dir.path, _beforeRestore));
    // Restoring the before-restore copy: read it aside so saving over it is safe.
    var source = backup.file;
    if (backup.isBeforeRestore) source = backup.file.copySync('${backup.file.path}.restoring');
    try {
      if (before.existsSync()) before.deleteSync();
      store.saveCopy(before.path);
      await store.restoreFrom(source.path);
    } finally {
      if (source.path != backup.file.path) source.deleteSync();
    }
  }
}
