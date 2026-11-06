import 'dart:typed_data';

import 'package:sqlite3/wasm.dart';

import 'copy_database.dart';

export 'package:sqlite3/wasm.dart';

typedef Database = CommonDatabase;

/// Set by [BrowserData.open] before anything opens a database.
late CommonSqlite3 sqlite3;

/// The browser's files, for the copies below.
late VirtualFileSystem browserFiles;

const _copy = '/eclipse-copy.db';

/// A consistent, compacted copy of the whole of [db], as a file's bytes.
Uint8List copyOfDatabase(Database db) {
  _remove(_copy);
  db.execute('VACUUM INTO ?', [_copy]);
  try {
    final opened = browserFiles.xOpen(Sqlite3Filename(_copy), SqlFlag.SQLITE_OPEN_READONLY);
    try {
      final bytes = Uint8List(opened.file.xFileSize());
      opened.file.xRead(bytes, 0);
      return bytes;
    } finally {
      opened.file.xClose();
    }
  } finally {
    _remove(_copy);
  }
}

var _placed = 0;

/// Puts a database's [bytes] where SQLite can open them, and says where.
String placeDatabase(List<int> bytes) {
  final path = '/eclipse-placed-${_placed++}.db';
  final opened = browserFiles.xOpen(Sqlite3Filename(path), SqlFlag.SQLITE_OPEN_READWRITE | SqlFlag.SQLITE_OPEN_CREATE);
  try {
    opened.file.xWrite(Uint8List.fromList(bytes), 0);
  } finally {
    opened.file.xClose();
  }
  return path;
}

/// Removes what [placeDatabase] put at [path].
void removeDatabase(String path) => _remove(path);

void _remove(String path) {
  if (browserFiles.xAccess(path, 0) != 0) browserFiles.xDelete(path, 0);
}

/// SQLite's copy-the-whole-database call isn't in the WebAssembly bindings, so
/// this does what it does over SQL: [to] ends up with this database's
/// schema, rows and version, and nothing else. All at once, or not at all.
extension CopyDatabase on CommonDatabase {
  Stream<double> backup(CommonDatabase to, {int nPage = 5}) async* {
    copyOver(this, to);
    yield 1.0;
  }
}
