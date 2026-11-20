import '../models.dart';
import 'store.dart';
import 'sqlite.dart' show SqliteException;

/// What a search found: a day's journal entry, or a task.
class SearchHit {
  const SearchHit.journal(this.day, this.text)
    : uid = null,
      done = false,
      subtask = null,
      subtaskIndex = null,
      kind = 'journal';
  const SearchHit.task(
    this.day,
    this.text, {
    required String this.uid,
    required this.done,
    this.subtask,
    this.subtaskIndex,
  }) : kind = 'task';
  const SearchHit.record(this.kind, this.day, this.text, {this.uid})
    : done = false,
      subtask = null,
      subtaskIndex = null;
  final String kind;

  final DateTime day;

  /// The task's name, or the part of the entry around the first match.
  final String text;

  /// The task's; null for a journal entry.
  final String? uid;
  final bool done;

  /// The subtask that matched, when the task's own name didn't.
  final String? subtask;

  /// Where [subtask] is in its task's list.
  final int? subtaskIndex;

  /// What opening it lights: the task's uid, with a subtask's place after a
  /// '#', or the journal day's key.
  String get target => switch (uid) {
    null => dateKey(day),
    final uid => subtaskIndex == null ? uid : '$uid#$subtaskIndex',
  };

  bool get isJournal => kind == 'journal';
}

/// Everything search looks through, read once and matched as you type.
/// Read at the first search, not when it's made, so opening Settings costs
/// nothing; AppState keeps one until a task or the journal changes.
class SearchIndex {
  SearchIndex(this._store);

  final Store _store;

  /// Times the text was read and folded, for tests.
  static int debugBuilds = 0;

  late final List<({String day, String text, String key})> _journal = [
    for (final e in _store.journalEntries()) (day: e.day, text: e.text, key: _fold(e.text)),
  ];
  late final List<
    ({
      ({String uid, String day, String text, bool done, List<TodoSubtask> subtasks, String? location, String? note})
      todo,
      String key,
      List<({int index, String text, String key})> subtasks,
    })
  >
  _todos = () {
    debugBuilds++;
    return [
      for (final t in _store.searchableTodos())
        (
          todo: t,
          // Its location and note match as its name does, and a subtask's
          // note as the subtask.
          key: _fold([t.text, ?t.location, ?t.note].join('\n')),
          subtasks: [
            for (final (i, s) in t.subtasks.indexed) (index: i, text: s.text, key: _fold([s.text, ?s.note].join('\n'))),
          ],
        ),
    ];
  }();

  late final List<({SearchHit hit, String key})> _records = [
    for (final r in _store.raw.select("""
      SELECT 'ritual' AS kind, printf('%04d-%02d-01', year, month) AS day, name || ' · ' || note AS text, NULL AS uid
      FROM month_habits WHERE trim(note) <> ''
      UNION ALL SELECT 'entry', e.day,
        coalesce(m.name || ' · ',
          CASE sh.item WHEN 'sleepBy' THEN 'Sleep · ' WHEN 'wakeUp' THEN 'Wake · ' WHEN 'windDown' THEN 'Wind down · ' WHEN 'inBed' THEN 'In bed · ' END,
          '') || e.note,
        'habit:' || e.habit_id
      FROM entries e
      LEFT JOIN month_habits m ON e.habit_id=m.habit_id AND substr(e.day,1,7)=printf('%04d-%02d',m.year,m.month)
      LEFT JOIN sleep_habits sh ON e.habit_id=sh.habit_id
      WHERE trim(e.note) <> ''
      UNION ALL SELECT 'training', day,
        coalesce((SELECT group_concat(name, ', ') FROM (SELECT DISTINCT x.name AS name FROM training_sets s2 JOIN exercises x ON x.uid=s2.exercise WHERE s2.day=s.day)), '') ||
        coalesce(' · ' || (SELECT group_concat(note, ' · ') FROM (SELECT DISTINCT nullif(trim(s3.note), '') AS note FROM training_sets s3 WHERE s3.day=s.day AND trim(s3.note) <> '')), ''),
        NULL
      FROM (SELECT DISTINCT day FROM training_sets) s
      """))
      (
        hit: SearchHit.record(
          r['kind'] as String,
          DateTime.parse(r['day'] as String),
          r['text'] as String,
          uid: r['uid'] as String?,
        ),
        key: _fold(r['text'] as String),
      ),
  ];

  // Trigrams preserve substring matching. Short queries and SQLite builds
  // without FTS5 use the same matcher below.
  static final _owners = Expando<SearchIndex>();
  bool _ftsAvailable = true;
  Set<int>? _candidates(List<String> words) {
    final long = words.where((w) => w.runes.length >= 3 && !w.contains(String.fromCharCode(0))).toList();
    if (!_ftsAvailable || long.isEmpty) return null;
    final db = _store.raw;
    if (_owners[_store] != this) {
      _store.inTempWork = true;
      try {
        db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS temp.eclipse_search USING fts5(body, tokenize='trigram')");
        final bodies = [
          for (final e in _journal) e.key,
          for (final e in _todos) [e.key, ...e.subtasks.map((s) => s.key)].join('\n'),
          for (final e in _records) e.key,
        ];
        _store.transaction(() {
          db.execute('DELETE FROM temp.eclipse_search');
          final insert = db.prepare('INSERT INTO temp.eclipse_search(rowid, body) VALUES (?, ?)');
          try {
            for (final (i, body) in bodies.indexed) {
              insert.execute([i + 1, body]);
            }
          } finally {
            insert.close();
          }
        });
        _owners[_store] = this;
      } on SqliteException {
        _ftsAvailable = false;
        return null;
      } finally {
        _store.inTempWork = false;
      }
    }
    final query = long.map((term) => '"${term.replaceAll('"', '""')}"').join(' AND ');
    try {
      return {
        for (final r in db.select('SELECT rowid FROM temp.eclipse_search WHERE body MATCH ?', [query]))
          r['rowid'] as int,
      };
    } on SqliteException {
      return null;
    }
  }

  /// The words of [query], folded the way the text is.
  static List<String> words(String query) => _fold(query).split(_spaces).where((w) => w.isNotEmpty).toList();

  /// Every entry and task holding all the words of [query], in any order,
  /// newest first. Entries come before tasks on the same day.
  List<SearchHit> search(String query) {
    final words = SearchIndex.words(query);
    if (words.isEmpty) return const [];
    bool all(String key) => words.every(key.contains);
    final hits = <(String, int, SearchHit)>[];
    final candidates = _candidates(words);
    var row = 0;
    bool include() {
      row++;
      return candidates == null || candidates.contains(row);
    }

    for (final e in _journal) {
      if (!include()) continue;
      if (all(e.key)) hits.add((e.day, 0, SearchHit.journal(DateTime.parse(e.day), _excerpt(e.text, e.key, words))));
    }
    for (final (:todo, :key, :subtasks) in _todos) {
      if (!include()) continue;
      ({int index, String text, String key})? subtask;
      if (!all(key)) {
        // A subtask holding them all, or between the name and it.
        subtask = subtasks.where((s) => words.every((w) => key.contains(w) || s.key.contains(w))).firstOrNull;
        if (subtask == null) continue;
      }
      hits.add((
        todo.day,
        1,
        SearchHit.task(
          DateTime.parse(todo.day),
          todo.text,
          uid: todo.uid,
          done: todo.done,
          subtask: subtask?.text,
          subtaskIndex: subtask?.index,
        ),
      ));
    }
    for (final (:hit, :key) in _records) {
      if (include() && all(key)) hits.add((dateKey(hit.day), 2, hit));
    }
    hits.sort((a, b) {
      final byDay = b.$1.compareTo(a.$1);
      return byDay != 0 ? byDay : a.$2.compareTo(b.$2);
    });
    return [for (final h in hits) h.$3];
  }
}

/// Lower case, with curly quotes as straight ones, so either matches.
/// Keeps the text's UTF-16 length, so a match's place is the same in both.
String _fold(String text) {
  final lower = text.toLowerCase();
  if (lower.length == text.length) {
    return lower.replaceAll(_singleQuotes, "'").replaceAll(_doubleQuotes, '"');
  }
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    final lc = ch.toLowerCase();
    final folded = lc.length == 1 ? lc : lc[0];
    out.write(
      _singleQuotes.hasMatch(folded)
          ? "'"
          : _doubleQuotes.hasMatch(folded)
          ? '"'
          : folded,
    );
  }
  return out.toString();
}

final _spaces = RegExp(r'\s+');
final _singleQuotes = RegExp('[‘’′]');
final _doubleQuotes = RegExp('[“”″]');

/// The entry from a little before its first match, on one line.
String _excerpt(String text, String key, List<String> words) {
  var at = text.length;
  for (final w in words) {
    final i = key.indexOf(w);
    if (i >= 0 && i < at) at = i;
  }
  var start = at <= 40 ? 0 : text.lastIndexOf(' ', at - 30) + 1;
  if (start < 0) start = 0;
  bool isLowSurrogate(int unit) => (unit & 0xFC00) == 0xDC00;
  if (start > 0 && start < text.length && isLowSurrogate(text.codeUnitAt(start))) start++;
  var end = start + 240 < text.length ? start + 240 : text.length;
  if (end > start && end < text.length && isLowSurrogate(text.codeUnitAt(end))) end--;
  final line = text.substring(start, end).replaceAll(_spaces, ' ').trim();
  return start == 0 ? line : '…$line';
}

/// Where [words] fall in [text], merged, in order, for highlighting.
List<(int, int)> matchRanges(String text, List<String> words) {
  final key = _fold(text);
  final ranges = <(int, int)>[];
  for (final w in words) {
    final word = _fold(w);
    if (word.isEmpty) continue;
    for (var i = key.indexOf(word); i >= 0; i = key.indexOf(word, i + word.length)) {
      ranges.add((i, i + word.length));
    }
  }
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final r in ranges) {
    if (merged.isNotEmpty && r.$1 <= merged.last.$2) {
      final last = merged.removeLast();
      merged.add((last.$1, r.$2 > last.$2 ? r.$2 : last.$2));
    } else {
      merged.add(r);
    }
  }
  return merged;
}
