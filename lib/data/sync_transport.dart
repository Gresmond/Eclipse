part of 'sync_service.dart';

  /// A file in Drive's name, like a1b2c3d4e5f6a7b8_2026-10-24.json, as the
  /// computer it's from and the file it is there; null for any other name,
  /// so none can reach outside the sync folder.
(String, String)? _split(String name) {
    final match = _fileName.firstMatch(name);
    return match == null ? null : (match[1]!, match[2]!);
  }

final _fileName = RegExp(r'^([A-Za-z0-9-]+)_(\d{4}-\d{2}-\d{2}\.json)$');


  /// A copy of the database in Drive's hidden folder, from a computer. Sync
  /// passes over them: their names aren't change files'.
final _copyName = RegExp(r'^backup_([A-Za-z0-9-]+)_(\d{4}-\d{2}-\d{2}|before-restore)\.db$');
const _keepCopies = 30;


List<DriveBackup> _copiesIn(List<DriveFile> files, String machine, Map<String, dynamic> names) {
    final copies = <DriveBackup>[];
    for (final f in files) {
      final m = _copyName.firstMatch(f.name);
      if (m == null) continue;
      final who = m[1]!;
      if (m[2] == 'before-restore' && who != machine) continue;
      copies.add(
        DriveBackup(
          id: f.id,
          name: f.name,
          day: m[2] == 'before-restore' ? null : DateTime.tryParse(m[2]!),
          saved: DateTime.tryParse(f.modified)?.toLocal() ?? DateTime.now(),
          from: who == machine ? 'this computer' : names[who] as String? ?? 'another computer',
        ),
      );
    }
    final later = copies.where((c) => c.day != null).toList()
      ..sort((a, b) => b.name.substring(b.name.length - 13).compareTo(a.name.substring(a.name.length - 13)));
    return [...copies.where((c) => c.day == null), ...later];
  }


extension _SyncTransport on SyncService {
  Future<List<DriveFile>> _inventory(SyncDrive drive) async {
    if (drive is! AppDataFolder) return drive.list();
    final cached = _config['driveInventory'];
    String? token;
    final prior = <DriveFile>[];
    if (cached is Map && cached['token'] is String && cached['files'] is List) {
      for (final row in cached['files'] as List) {
        if (row case [final String id, final String name, final String modified]) {
          prior.add(DriveFile(id: id, name: name, modified: modified));
        } else {
          return _freshInventory(drive);
        }
      }
      token = cached['token'] as String;
    }
    final (next, files) = await drive.inventory(token, prior);
    _config['driveInventory'] = {
      'token': next,
      'files': [
        for (final f in files) [f.id, f.name, f.modified],
      ],
    };
    return files;
  }

  Future<List<DriveFile>> _freshInventory(AppDataFolder drive) {
    _config.remove('driveInventory');
    return _inventory(drive);
  }

  /// Copies down every other computer's file that's new or changed, into
  /// the folder here, and returns this computer's own, by name. Its own
  /// come down only when the copy here is gone (after signing in again,
  /// say), so any of its edits the database here lost come back.
  Future<Map<String, String>> _pull(SyncDrive drive) async {
    final down = _seen('down'), ids = _seen('ids'), mine = <String, String>{};
    final files = await _inventory(drive), seen = <String, dynamic>{}, copies = <String, int>{};
    if (_stopped) return mine;
    final remoteFiles = <(String, String)>{};
    for (final f in files) {
      copies[f.name] = (copies[f.name] ?? 0) + 1;
    }
    final writes = <(String, String, List<int>)>[];
    for (final f in files) {
      if (_stopped) return mine;
      final (who, day) = _split(f.name) ?? (null, null);
      if (who == null || day == null) continue;
      // Two files of one name (Drive's list lagged behind a new one): each
      // is read.
      final name = copies[f.name]! > 1 ? '${p.basenameWithoutExtension(day)}~${f.id}.json' : day;
      final disk = folder.disk;
      if (!disk.holds(who, name)) continue;
      remoteFiles.add((who, name));
      if (who == machine) {
        if (mine[f.name] == null || f.id == ids[f.name]) mine[f.name] = f.id;
        if (disk.exists(who, name)) continue;
      } else if (down[f.id] == f.modified && disk.exists(who, name)) {
        seen[f.id] = f.modified;
        continue;
      }
      final bytes = await drive.download(f.id);
      if (_stopped) return mine;
      try {
        jsonDecode(utf8.decode(bytes));
      } on FormatException {
        continue; // cut short: fetched again next round
      }
      writes.add((who, name, bytes));
      if (who != machine) seen[f.id] = f.modified;
    }
    final disk = folder.disk;
    final stale = [
      for (final existing in disk.files())
        if (existing.who != machine && !remoteFiles.contains((existing.who, existing.name))) existing,
    ];
    Future<void> applyDisk() async {
      for (final (who, name, bytes) in writes) {
        await disk.writeBytes(who, name, bytes);
        if (_stopped) return;
      }
      for (final item in stale) {
        disk.remove(item.who, item.name);
      }
    }
    if (disk is DatabaseDisk) {
      await disk.batch(applyDisk);
    } else {
      await applyDisk();
    }
    if (_stopped) return mine;
    // By id, as names can repeat; files gone from Drive are forgotten.
    _config['down'] = seen;
    return mine;
  }

  /// Copies up this computer's files written since they last went. A file
  /// made here is remembered, so one Drive doesn't list yet isn't made twice.
  Future<void> _push(SyncDrive drive, Map<String, String> there) async {
    final up = _seen('up'), ids = _seen('ids');
    final disk = folder.disk;
    for (final f in disk.files()) {
      if (_stopped) return;
      if (f.who != machine || f.name.contains('~')) continue;
      final name = '${machine}_${f.name}';
      final stamp = disk.stamp(f.key);
      if (up[name] == stamp && there.containsKey(name)) continue;
      final bytes = disk.readBytes(f.key), id = there[name] ?? ids[name] as String?;
      final sent = DateTime.now();
      DriveFile made;
      try {
        made = await drive.upload(name, bytes, id: id);
      } on DriveError catch (e) {
        if (!e.notFound || id == null) rethrow;
        made = await drive.upload(name, bytes); // deleted from Drive: made again
      }
      if (_stopped) return;
      _timed(sent, made.modified);
      ids[name] = made.id;
      up[name] = stamp;
    }
  }

  /// Join old daily files into a single monthly file, retaining all distinct
  /// registers, including tombstones and concurrent journal versions.
  /// Day 00 is reserved for these archives and matches older clients' file
  /// filters. A normal edit can never overwrite one.
  Future<void> _compactHistory(SyncDrive drive, Map<String, String> mine) async {
    if (drive is! CopiesDrive) return;
    final today = dateKey(DateTime.now());
    if (_config['compacted'] == today) return;
    final cutoff = dateKey(DateTime.now().subtract(const Duration(days: 90))).substring(0, 7);
    final months = <String, List<String>>{};
    final disk = folder.disk;
    for (final f in disk.files()) {
      if (f.who != machine || !RegExp(r'^\d{4}-\d{2}-\d{2}\.json$').hasMatch(f.name)) continue;
      final month = f.name.substring(0, 7);
      if (month.compareTo(cutoff) >= 0 || f.name.endsWith('-00.json')) continue;
      (months[month] ??= []).add(f.name);
    }
    final eligible = months.entries.where((e) {
      final archived = '${e.key}-00.json', remote = '${machine}_$archived';
      return e.value.length >= 2 ||
          (e.value.isNotEmpty && (mine.containsKey(remote) || disk.exists(machine, archived)));
    });
    for (final MapEntry(key: month, value: days) in eligible) {
      final archived = '$month-00.json', remote = '${machine}_$archived';
      final regs = <String, List>{};
      final sources = <String, List<int>>{};
      var id = mine[remote] ?? _seen('ids')[remote] as String?;
      bool include(List<int> data) {
        try {
          final value = jsonDecode(utf8.decode(data));
          if (value is! Map || value['version'] != 1 || value['registers'] is! List) return false;
          for (final item in value['registers'] as List) {
            if (item is! List || !SyncEngine.validRegister(item)) return false;
            regs[jsonEncode(item)] = item;
          }
          return true;
        } on FormatException {
          return false;
        }
      }

      if (id != null) {
        try {
          if (!include(await drive.download(id))) continue;
        } on DriveError catch (e) {
          if (!e.notFound) rethrow;
          _seen('ids').remove(remote);
          _seen('up').remove(remote);
          id = null;
        }
      }
      if (disk.exists(machine, archived) && !include(disk.readBytes('$machine/$archived'))) continue;
      var badDay = false;
      for (final name in days) {
        final data = disk.readBytes('$machine/$name');
        if (!include(data)) {
          badDay = true;
          break;
        }
        sources[name] = data;
      }
      if (badDay) continue;
      final bytes = utf8.encode(jsonEncode({'version': 1, 'name': computerName, 'registers': regs.values.toList()}));
      DriveFile made;
      try {
        made = await drive.upload(remote, bytes, id: id);
      } on DriveError catch (e) {
        if (!e.notFound || id == null) rethrow;
        made = await drive.upload(remote, bytes);
      }
      if (_stopped) return;
      final verified = await drive.download(made.id);
      if (!listEquals(bytes, verified)) throw const DriveError('Could not verify the compacted history.');
      await disk.writeBytes(machine, archived, bytes);
      _seen('ids')[remote] = made.id;
      _seen('up')[remote] = disk.stamp('$machine/$archived');
      await _save();
      for (final name in days) {
        if (_stopped) return;
        final original = '${machine}_$name', old = mine[original] ?? _seen('ids')[original] as String?;
        if (old == null) continue;
        // A second copy of this installation may have changed a file.
        // Keep it if the retrieved bytes differ from those just archived.
        try {
          if (!listEquals(await drive.download(old), sources[name]) ||
              !listEquals(disk.readBytes('$machine/$name'), sources[name])) {
            continue;
          }
          await (drive as CopiesDrive).delete(old);
        } on DriveError catch (e) {
          if (!e.notFound) rethrow;
        }
        disk.remove(machine, name);
        _seen('ids').remove(original);
        _seen('up').remove(original);
      }
      break;
    }
    _config['compacted'] = today;
    await _save();
  }

  /// Puts this computer's clock right by Google's, from a file just written:
  /// Drive stamps it with its own time. Within a second is network time
  /// doing its job, and left alone.
  void _timed(DateTime sent, String modified) {
    final server = DateTime.tryParse(modified), back = DateTime.now();
    if (server == null || back.difference(sent) > const Duration(seconds: 10)) return;
    final behind = server.millisecondsSinceEpoch - (sent.millisecondsSinceEpoch + back.millisecondsSinceEpoch) ~/ 2;
    engine.offset = _config['clock'] = behind.abs() < 1000 ? 0 : behind;
  }


  /// Today's copy goes up once. Failing doesn't stop sync, and it's tried
  /// again next round.
  Future<void> _copyToDrive(SyncDrive drive) async {
    if (!copiesToDrive || drive is! CopiesDrive) return;
    final today = dateKey(DateTime.now());
    try {
      if (_config['copied'] != today) {
        // Checked and copied away from the UI.
        final copy = await offThread(store.raw, checkedCopyOf);
        if (_stopped) return;
        if (copy == null) throw StateError('The database failed its check');
        final files = await drive.list();
        if (_stopped) return;
        final name = 'backup_${machine}_$today.db';
        final had = files.where((f) => f.name == name).firstOrNull;
        await drive.upload(name, copy, id: had?.id);
        if (_stopped) return;
        final mine = [
          for (final f in files)
            if (_copyName.firstMatch(f.name) case final m? when m[1] == machine && m[2] != 'before-restore') f,
        ]..sort((a, b) => b.name.compareTo(a.name));
        // Today's is new when none had its name.
        for (final old in mine.skip(had == null ? _keepCopies - 1 : _keepCopies)) {
          if (_stopped) return;
          await (drive as CopiesDrive).delete(old.id);
        }
        if (_stopped) return;
        _config['copied'] = today;
        await _save();
        if (_stopped) return;
      }
      afterDriveCopy?.call();
    } catch (e) {
      AppLog.failure('The copy to Drive failed', e);
    }
  }

}

class DriveCopies {
  DriveCopies._(this._drive, this._machine, this._names);

  final SyncDrive _drive;
  final String _machine;
  final Map<String, dynamic> _names;

  Future<List<DriveBackup>> list() async => _copiesIn(await _drive.list(), _machine, _names);

  /// The database as [copy] holds it.
  Future<List<int>> fetch(DriveBackup copy) => _drive.download(copy.id);
}

class _FileSettings implements SyncSettings {
  _FileSettings(Directory home) : _file = File(p.join(home.path, 'sync.json'));

  final File _file;

  @override
  String? read() => _file.existsSync() ? _file.readAsStringSync() : null;

  @override
  void keepDamaged() {
    try {
      if (!_file.existsSync()) return;
      final raw = _file.readAsStringSync();
      // A damaged JSON string can end mid-key or mid-token. Preserve a
      // diagnostic without trying to redact secrets from truncated JSON.
      final redacted = raw.contains('"refresh"') ? 'Damaged sync credentials: <redacted>' : raw;
      replaceSafelySync('${_file.path}.damaged', (part) {
        part.writeAsStringSync('');
        final result = Process.runSync('chmod', ['600', part.path]);
        if (result.exitCode != 0) {
          if (part.existsSync()) part.deleteSync();
          throw FileSystemException('Cannot protect damaged sync settings', part.path);
        }
        part.writeAsStringSync(redacted, flush: true);
      });
    } on FileSystemException {
      // Nothing to keep.
    }
  }

  @override
  Future<void> write(String contents) => replaceSafely(_file.path, (part) async {
    // Protected while still empty, so the sign-in is never readable by others.
    await part.writeAsString('');
    final result = await Process.run('chmod', ['600', part.path]);
    if (result.exitCode != 0) throw FileSystemException('Cannot protect sync credentials', part.path);
    await part.writeAsString(contents, flush: true);
  });
}
