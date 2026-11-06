import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

export 'package:sqlite3/sqlite3.dart';

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
