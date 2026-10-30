import '../models.dart';
import 'store.dart';

/// What a search found: a day's journal entry, or a task.
class SearchHit {
  const SearchHit.journal(this.day, this.text) : uid = null, done = false, subtask = null;
  const SearchHit.task(this.day, this.text, {required String this.uid, required this.done, this.subtask});

  final DateTime day;

  /// The task's name, or the part of the entry around the first match.
  final String text;

  /// The task's; null for a journal entry.
  final String? uid;
  final bool done;

  /// The subtask that matched, when the task's own name didn't.
  final String? subtask;

  bool get isJournal => uid == null;
}

/// Everything search looks through, read once and matched as you type.
class SearchIndex {
  SearchIndex(Store store)
    : _journal = [for (final e in store.journalEntries()) (day: e.day, text: e.text, key: _fold(e.text))],
      _todos = [
        for (final t in store.searchableTodos())
          (todo: t, key: _fold(t.text), subtasks: [for (final s in t.subtasks) (text: s.text, key: _fold(s.text))]),
      ];

  final List<({String day, String text, String key})> _journal;
  final List<
    ({
      ({String uid, String day, String text, bool done, List<TodoSubtask> subtasks}) todo,
      String key,
      List<({String text, String key})> subtasks,
    })
  >
  _todos;

  /// The words of [query], folded the way the text is.
  static List<String> words(String query) => _fold(query).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  /// Every entry and task holding all the words of [query], in any order,
  /// newest first. Entries come before tasks on the same day.
  List<SearchHit> search(String query) {
    final words = SearchIndex.words(query);
    if (words.isEmpty) return const [];
    bool all(String key) => words.every(key.contains);
    final hits = <(String, int, SearchHit)>[];
    for (final e in _journal) {
      if (all(e.key)) hits.add((e.day, 0, SearchHit.journal(DateTime.parse(e.day), _excerpt(e.text, e.key, words))));
    }
    for (final (:todo, :key, :subtasks) in _todos) {
      String? subtask;
      if (!all(key)) {
        // A subtask holding them all, or between the name and it.
        final match = subtasks.where((s) => words.every((w) => key.contains(w) || s.key.contains(w))).firstOrNull;
        if (match == null) continue;
        subtask = match.text;
      }
      hits.add((
        todo.day,
        1,
        SearchHit.task(DateTime.parse(todo.day), todo.text, uid: todo.uid, done: todo.done, subtask: subtask),
      ));
    }
    hits.sort((a, b) {
      final byDay = b.$1.compareTo(a.$1);
      return byDay != 0 ? byDay : a.$2.compareTo(b.$2);
    });
    return [for (final h in hits) h.$3];
  }
}

/// Lower case, with curly quotes as straight ones, so either matches.
/// Keeps the text's length, so a match's place is the same in both.
String _fold(String text) => text.toLowerCase().replaceAll(RegExp('[‘’′]'), "'").replaceAll(RegExp('[“”″]'), '"');

/// The entry from a little before its first match, on one line.
String _excerpt(String text, String key, List<String> words) {
  var at = text.length;
  for (final w in words) {
    final i = key.indexOf(w);
    if (i >= 0 && i < at) at = i;
  }
  var start = at <= 40 ? 0 : text.lastIndexOf(' ', at - 30) + 1;
  if (start < 0) start = 0;
  final end = start + 240 < text.length ? start + 240 : text.length;
  final line = text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
  return start == 0 ? line : '…$line';
}

/// Where [words] fall in [text], merged, in order, for highlighting.
List<(int, int)> matchRanges(String text, List<String> words) {
  final key = _fold(text);
  final ranges = <(int, int)>[];
  for (final w in words) {
    for (var i = key.indexOf(w); i >= 0; i = key.indexOf(w, i + w.length)) {
      ranges.add((i, i + w.length));
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
