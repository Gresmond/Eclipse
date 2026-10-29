part of 'store.dart';

/// Some of a table's rows as they stood, for [StoreUndo.putBack].
class RowsBefore {
  RowsBefore._(this.table, this.key, this.where, this.args, this.rows);

  final String table;

  /// The columns that pick out a row.
  final List<String> key;
  final String where;
  final List<Object?> args;
  final List<Map<String, Object?>> rows;
}

/// Putting rows back as they were, for undo. A row put back is an edit
/// like any other, so sync sends it and it wins over the removal.
extension StoreUndo on Store {
  /// [table]'s rows matching [where] as they stand now.
  RowsBefore rowsBefore(String table, List<String> key, String where, [List<Object?> args = const []]) =>
      RowsBefore._(table, key, where, args, [
        for (final r in _db.select('SELECT * FROM $table WHERE $where', args)) {...r},
      ]);

  /// Returns the rows [before] covers to how they stood, touching only the
  /// ones that have changed since.
  void putBack(Iterable<RowsBefore> before) => transaction(() {
    for (final b in before) {
      String id(Map<String, Object?> r) => jsonEncode([for (final k in b.key) r[k]]);
      final then = {for (final r in b.rows) id(r): r};
      final now = {
        for (final r in _db.select('SELECT * FROM ${b.table} WHERE ${b.where}', b.args)) id(r): {...r},
      };
      for (final key in {...then.keys, ...now.keys}) {
        final (was, is_) = (then[key], now[key]);
        if (jsonEncode(was) == jsonEncode(is_)) continue;
        if (is_ != null) {
          _db.execute('DELETE FROM ${b.table} WHERE ${b.key.map((k) => '$k = ?').join(' AND ')}', [
            for (final k in b.key) is_[k],
          ]);
        }
        if (was != null) {
          _db.execute(
            'INSERT INTO ${b.table} (${was.keys.join(', ')}) VALUES (${List.filled(was.length, '?').join(', ')})',
            was.values.toList(),
          );
        }
      }
    }
  });
}
