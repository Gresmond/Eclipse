part of 'sync.dart';

extension on (int, String) {
  int compareTo(int ts, String origin) => $1 != ts ? $1.compareTo(ts) : $2.compareTo(origin);
}

class _Reg {
  _Reg(
    this.kind,
    this.rowkey,
    this.field,
    this.value,
    this.ts,
    this.origin,
    this.vv, [
    this.journalVersions,
    this.seq = 0,
  ]);

  factory _Reg.fromRow(Row r) => _Reg(
    r['kind'] as String,
    r['rowkey'] as String,
    r['field'] as String,
    r['value'] as String,
    r['ts'] as int,
    r['origin'] as String,
    (jsonDecode(r['vv'] as String) as Map).cast<String, int>(),
    r['journal_versions'] == null
        ? null
        : (jsonDecode(r['journal_versions'] as String) as List)
              .map((v) => _JournalVersion.fromJson(v as List))
              .toList(),
    r['seq'] as int,
  );

  factory _Reg.fromJson(List<Object?> j) => _Reg(
    j[0] as String,
    j[1] as String,
    j[2] as String,
    j[3] as String,
    j[4] as int,
    j[5] as String,
    (j[6] as Map).cast<String, int>(),
    j.length < 8 || j[7] == null ? null : (j[7] as List).map((v) => _JournalVersion.fromJson(v as List)).toList(),
  );

  final String kind, rowkey, field, value, origin;
  final int ts;
  final Map<String, int> vv;
  final List<_JournalVersion>? journalVersions;

  /// This computer's own number for it, never sent: what [SyncEngine.latest]
  /// counts in; 0 for another computer's.
  final int seq;

  /// Whether [j], from a file, can be read as one.
  static bool valid(List<Object?> j) {
    if (j.length < 7 || j[0] is! String || j[1] is! String || j[2] is! String || j[4] is! int || j[5] is! String) {
      return false;
    }
    if (!_validVv(j[6]) ||
        (j.length > 7 && j[7] != null && (j[7] is! List || !(j[7] as List).every(_JournalVersion.valid)))) {
      return false;
    }
    if (j[3] case final String value) {
      try {
        return _sensible(j[0] as String, j[1] as String, j[2] as String, jsonDecode(value));
      } on FormatException {
        return false;
      }
    }
    return false;
  }

  static final _monthKey = RegExp(r'^\d{4}-\d{1,2}$');
  static bool _day(String s) => DateTime.tryParse(s) != null;
  static final _clock = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
  static bool _scope(String s) => TodoScope.values.any((scope) => scope.name == s);

  /// A task as it stood on a day: what looking back at that day reads.
  static void _snapshot(String s) {
    final json = jsonDecode(s) as Map;
    if (!_scope(json['scope'] as String) || json['text'] is! String) throw const FormatException('Not a task');
    TodoSubtask.decode(json['subtasks'] as String?);
  }

  /// Whether this version can write it into its row: a key of the kind's
  /// shape, and a value it can take. What this version doesn't keep is only
  /// kept as a register, so anything goes there.
  static bool _sensible(String kind, String rowkey, String field, Object? v) {
    final kept = SyncEngine.fields[kind];
    if (kept == null) return true;
    final slash = rowkey.indexOf('/');
    final head = slash < 0 ? null : rowkey.substring(0, slash);
    final key = switch (kind) {
      'habit_month' => _monthKey.hasMatch(rowkey),
      'month_habit' || 'sleep_note' => head != null && _monthKey.hasMatch(head),
      'entry' || 'todo_history' => head != null && _day(head),
      'journal' => _day(rowkey),
      _ => true,
    };
    if (!key || !kept.containsKey(field)) return key;
    return switch ((kind, field)) {
      (_, SyncEngine._present) || ('habit_month', 'initialized') => v is bool,
      ('entry', 'status') => v == null || v is int && v >= 0 && v < HabitStatus.values.length,
      ('todo', 'scope') || ('todo', 'return_scope') => v == null || v is String && _scope(v),
      ('todo', 'since') => v == null || v is String && _day(v),
      ('todo', 'done') => v == null || v == 0 || v == 1,
      ('todo', 'subtasks') || ('todo_repeat', 'subtasks') => readsAs(v, TodoSubtask.decode),
      ('month_habit', 'days') => readsAs(v, decodeDays),
      ('todo_history', 'snapshot') => readsAs(v, _snapshot),
      ('journal', 'text') => v is String,
      ('setting', 'value') || ('sleep_note', 'note') || ('todo_history', 'snapshot') => v == null || v is String,
      ('todo_repeat', 'rule') => v is String && RepeatRule.decode(v) != null,
      ('todo_repeat', 'start') => v is String && _day(v),
      ('todo_repeat', 'until') => v == null || v is String && _day(v),
      ('todo', 'due_time') || ('todo_repeat', 'time') => v == null || v is String && _clock.hasMatch(v),
      // Any kind, as computers from before birthdays replaced categories send
      // others; only a birthday counts.
      ('todo', 'category') || ('todo_repeat', 'category') => v == null || v is String,
      _ => v == null || v is num || v is String,
    };
  }

  static bool _validVv(Object? vv) => vv is Map && vv.entries.every((e) => e.key is String && e.value is int);

  List<Object?> get row => [
    kind,
    rowkey,
    field,
    value,
    ts,
    origin,
    jsonEncode(vv),
    journalVersions == null ? null : jsonEncode(journalVersions!.map((v) => v.toJson()).toList()),
    seq,
  ];

  List<Object?> toJson() => [
    kind,
    rowkey,
    field,
    value,
    ts,
    origin,
    vv,
    if (journalVersions != null) journalVersions!.map((v) => v.toJson()).toList(),
  ];
}

class _JournalVersion {
  _JournalVersion(this.origin, this.ts, this.text, this.vv);
  factory _JournalVersion.fromJson(List j) =>
      _JournalVersion(j[0] as String, j[1] as int, j[2] as String, (j[3] as Map).cast<String, int>());
  final String origin, text;
  final int ts;
  final Map<String, int> vv;
  static bool valid(Object? j) =>
      j is List && j.length >= 4 && j[0] is String && j[1] is int && j[2] is String && _Reg._validVv(j[3]);
  List<Object?> toJson() => [
    origin,
    ts,
    text,
    {for (final key in (vv.keys.toList()..sort())) key: vv[key]},
  ];
}
