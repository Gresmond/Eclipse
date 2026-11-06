import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart';

import 'safe_write.dart';

/// One change file: `key` names it for [SyncDisk] and sync's records, and
/// `who` is the computer it's from.
typedef SyncFile = ({String key, String who, String name});

/// Where sync keeps its change files: a folder on a computer, a database in
/// a browser, which has no folders.
abstract interface class SyncDisk {
  /// Every change file, in order of [SyncFile.key].
  List<SyncFile> files();
  bool exists(String who, String name);

  /// Whether [who] and [name] stay inside this disk, whatever Drive said.
  bool holds(String who, String name);
  String readText(String key);
  Uint8List readBytes(String key);

  /// Changes whenever the file does.
  String stamp(String key);

  /// Replaces the file whole, so a crash never leaves half of it.
  void writeText(String who, String name, String text);
  Future<void> writeBytes(String who, String name, List<int> bytes);
  void clear();

  /// Runs [job] away from the drawing, where that's possible. [job] gets the
  /// disk to use and must not capture anything that can't cross isolates.
  Future<T> away<T>(T Function(SyncDisk disk) job);
}

/// A folder of a folder per computer: `<folder>/<computer id>/2026-10-24.json`.
class FolderDisk implements SyncDisk {
  FolderDisk(this.root);

  final String root;

  @override
  List<SyncFile> files() {
    final dir = Directory(root);
    if (!dir.existsSync()) return [];
    final found = [
      for (final d in dir.listSync().whereType<Directory>())
        for (final f in d.listSync().whereType<File>())
          if (f.path.endsWith('.json')) f,
    ]..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final f in found)
        (key: p.relative(f.path, from: root), who: p.basename(f.parent.path), name: p.basename(f.path)),
    ];
  }

  String _path(String who, String name) => p.join(root, who, name);

  @override
  bool exists(String who, String name) => File(_path(who, name)).existsSync();

  @override
  bool holds(String who, String name) => p.isWithin(root, _path(who, name));

  @override
  String readText(String key) => File(p.join(root, key)).readAsStringSync();

  @override
  Uint8List readBytes(String key) => File(p.join(root, key)).readAsBytesSync();

  @override
  String stamp(String key) {
    final stat = File(p.join(root, key)).statSync();
    return '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
  }

  @override
  void writeText(String who, String name, String text) {
    final file = File(_path(who, name));
    file.parent.createSync(recursive: true);
    replaceSafelySync(file.path, (part) => part.writeAsStringSync(text, flush: true));
  }

  @override
  Future<void> writeBytes(String who, String name, List<int> bytes) async {
    final file = File(_path(who, name));
    await file.parent.create(recursive: true);
    await replaceSafely(file.path, (part) => part.writeAsBytes(bytes, flush: true));
  }

  @override
  void clear() {
    final dir = Directory(root);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  @override
  Future<T> away<T>(T Function(SyncDisk disk) job) {
    final folder = root;
    return Isolate.run(() => job(FolderDisk(folder)));
  }
}

/// Change files as rows of a database of their own. Each write is one
/// statement, so it's whole or not there.
class DatabaseDisk implements SyncDisk {
  DatabaseDisk(this._db) {
    _db.execute(
      'CREATE TABLE IF NOT EXISTS sync_files ('
      'key TEXT PRIMARY KEY, who TEXT NOT NULL, name TEXT NOT NULL, bytes BLOB NOT NULL, version INTEGER NOT NULL)',
    );
  }

  final CommonDatabase _db;

  @override
  List<SyncFile> files() => [
    for (final r in _db.select("SELECT key, who, name FROM sync_files WHERE name LIKE '%.json' ORDER BY key"))
      (key: r['key'] as String, who: r['who'] as String, name: r['name'] as String),
  ];

  @override
  bool exists(String who, String name) =>
      _db.select('SELECT 1 FROM sync_files WHERE key = ?', ['$who/$name']).isNotEmpty;

  /// Rows have no outside to reach.
  @override
  bool holds(String who, String name) => true;

  Uint8List _bytes(String key) {
    final rows = _db.select('SELECT bytes FROM sync_files WHERE key = ?', [key]);
    if (rows.isEmpty) throw StateError('No change file $key');
    return rows.first['bytes'] as Uint8List;
  }

  @override
  String readText(String key) => utf8.decode(_bytes(key));

  @override
  Uint8List readBytes(String key) => _bytes(key);

  @override
  String stamp(String key) {
    final rows = _db.select('SELECT length(bytes) AS size, version FROM sync_files WHERE key = ?', [key]);
    if (rows.isEmpty) throw StateError('No change file $key');
    return '${rows.first['size']}:${rows.first['version']}';
  }

  @override
  void writeText(String who, String name, String text) => _put(who, name, utf8.encode(text));

  @override
  Future<void> writeBytes(String who, String name, List<int> bytes) async => _put(who, name, bytes);

  void _put(String who, String name, List<int> bytes) => _db.execute(
    'INSERT INTO sync_files (key, who, name, bytes, version) '
    'VALUES (?1, ?2, ?3, ?4, (SELECT COALESCE(MAX(version), 0) + 1 FROM sync_files)) '
    'ON CONFLICT (key) DO UPDATE SET bytes = ?4, version = (SELECT MAX(version) + 1 FROM sync_files)',
    ['$who/$name', who, name, Uint8List.fromList(bytes)],
  );

  @override
  void clear() => _db.execute('DELETE FROM sync_files');

  @override
  Future<T> away<T>(T Function(SyncDisk disk) job) async => job(this);
}

/// Where sync keeps its settings, sync.json on a computer: beside the data
/// rather than in it, so a restored backup doesn't change them.
abstract interface class SyncSettings {
  /// Null when there are none yet. Throws if they can't be read.
  String? read();

  /// Keeps what couldn't be understood for a look, before it's overwritten.
  void keepDamaged();
  Future<void> write(String contents);
}

/// The settings in a row of a database, as [DatabaseDisk] keeps its files.
class DatabaseSettings implements SyncSettings {
  DatabaseSettings(this._db) {
    _db.execute(
      'CREATE TABLE IF NOT EXISTS sync_settings (id INTEGER PRIMARY KEY CHECK (id = 1), contents TEXT NOT NULL)',
    );
  }

  final CommonDatabase _db;

  @override
  String? read() {
    final rows = _db.select('SELECT contents FROM sync_settings');
    return rows.isEmpty ? null : rows.first['contents'] as String;
  }

  @override
  void keepDamaged() {}

  @override
  Future<void> write(String contents) async =>
      _db.execute('INSERT OR REPLACE INTO sync_settings VALUES (1, ?)', [contents]);
}
