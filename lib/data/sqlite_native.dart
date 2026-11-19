import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'copy_database.dart';

export 'package:sqlite3/sqlite3.dart';

/// Runs [job] on an isolate of its own, with a read-only connection of its
/// own to [db]'s file, so a long read like a copy doesn't hold up the UI.
/// It sees the database as it was when it started. A database with no file
/// (one in memory) is read here instead, before this returns.
///
/// [job] goes to the other isolate, so it mustn't hold anything that can't
/// be sent there: a top-level function, or a closure over plain values.
Future<T> offThread<T>(Database db, T Function(Database db) job) {
  final file = db.select('PRAGMA database_list').first['file'] as String? ?? '';
  return file.isEmpty ? _here(db, job) : _onOwnConnection(file, job);
}

Future<T> _here<T>(Database db, T Function(Database db) job) => Future.sync(() => job(db));

Future<T> _onOwnConnection<T>(String file, T Function(Database db) job) => Isolate.run(() {
  final own = sqlite3.open(file, mode: OpenMode.readOnly);
  try {
    own.execute('PRAGMA busy_timeout = 5000');
    return job(own);
  } finally {
    own.close();
  }
});

/// [copyOfDatabase], once [db] passes SQLite's check of its structure; null
/// when it doesn't.
Uint8List? checkedCopyOf(Database db) => passesCheck(db) ? copyOfDatabase(db) : null;

/// A consistent, compacted copy of the whole of [db], as a file's bytes.
Uint8List copyOfDatabase(Database db) {
  final folder = Directory.systemTemp.createTempSync('eclipse-copy-');
  try {
    final file = File(p.join(folder.path, 'copy.db'));
    db.execute('VACUUM INTO ?', [file.path]);
    return file.readAsBytesSync();
  } finally {
    folder.deleteSync(recursive: true);
  }
}

/// Puts a database's [bytes] where SQLite can open them, and says where.
String placeDatabase(List<int> bytes) {
  final folder = Directory.systemTemp.createTempSync('eclipse-copy-');
  final file = File(p.join(folder.path, 'copy.db'))..writeAsBytesSync(bytes, flush: true);
  return file.path;
}

/// Removes what [placeDatabase] put at [path].
void removeDatabase(String path) => File(path).parent.deleteSync(recursive: true);
