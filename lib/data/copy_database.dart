import 'package:sqlite3/common.dart';

/// Makes [to] hold [from]'s schema, rows and version and nothing else, in one
/// transaction, for where SQLite's own backup call isn't available.
void copyOver(CommonDatabase from, CommonDatabase to) {
  const objects =
      "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL";
  to.execute('PRAGMA foreign_keys = OFF');
  to.execute('BEGIN IMMEDIATE');
  try {
    for (final kind in ['trigger', 'view', 'table']) {
      for (final r in to.select('$objects AND type = ?', [kind])) {
        to.execute('DROP $kind IF EXISTS "${r['name']}"');
      }
    }
    final schema = from.select(objects).toList();
    for (final r in schema.where((r) => r['type'] == 'table')) {
      to.execute(r['sql'] as String);
      _copyRows(from, to, r['name'] as String);
    }
    if (from.select("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_sequence'").isNotEmpty) {
      to.execute('DELETE FROM sqlite_sequence');
      _copyRows(from, to, 'sqlite_sequence');
    }
    // After the rows, so the triggers don't take them for edits.
    for (final kind in ['index', 'view', 'trigger']) {
      for (final r in schema.where((r) => r['type'] == kind)) {
        to.execute(r['sql'] as String);
      }
    }
    to.execute('PRAGMA user_version = ${from.select('PRAGMA user_version').first.columnAt(0)}');
    to.execute('COMMIT');
  } catch (_) {
    to.execute('ROLLBACK');
    rethrow;
  } finally {
    to.execute('PRAGMA foreign_keys = ON');
  }
}

void _copyRows(CommonDatabase from, CommonDatabase to, String table) {
  final rows = from.select('SELECT * FROM "$table"');
  if (rows.isEmpty) return;
  final marks = List.filled(rows.columnNames.length, '?').join(', ');
  final insert = to.prepare('INSERT INTO "$table" VALUES ($marks)');
  try {
    for (final row in rows.rows) {
      insert.execute(row);
    }
  } finally {
    insert.close();
  }
}
