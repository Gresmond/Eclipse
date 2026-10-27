import 'dart:convert';

enum HabitStatus { none, done, missed, other }

class Habit {
  Habit(this.id, this.name, {this.description, this.minutes, this.addedOn});

  /// The day it was added, when that was partway through its month.
  final DateTime? addedOn;

  /// Whether [day] is on or after the day this ritual was added; earlier
  /// days are greyed out and can't be marked.
  bool startedBy(DateTime day) => addedOn == null || !dateOnly(day).isBefore(addedOn!);

  final int id;
  String name;

  /// Shown on hover in place of the name: the note you wrote for a ritual.
  String? description;

  /// A sleep item's time this month, in minutes after midnight; null when
  /// none is set. Rituals have none.
  int? minutes;
}

/// The sleep schedule: the same four in every month, below the rituals.
/// The items are fixed here; their times are set month by month.
enum SleepItem {
  riseEarly('Rise Early', 8 * 60 + 30),
  unwind('Unwind', 21 * 60),
  screenCurfew('Screen Curfew', 22 * 60),
  sleepEarly('Sleep Early', 23 * 60);

  const SleepItem(this.label, this.minutes);
  final String label;

  /// The time before any month sets its own, in minutes after midnight.
  final int minutes;
}

enum TodoScope {
  today('Today'),
  tomorrow('Tomorrow'),
  week('This week'),
  month('This month');

  const TodoScope(this.label);
  final String label;

  /// Key for the period containing [day]. Weeks start on Monday.
  String period(DateTime day) => switch (this) {
    today => dateKey(day),
    tomorrow => dateKey(day),
    week => dateKey(DateTime(day.year, day.month, day.day - (day.weekday - 1))),
    month => '${day.year}-${day.month.toString().padLeft(2, '0')}',
  };
}

class TodoSubtask {
  const TodoSubtask(this.text, {this.done = false, this.numbered = false});
  final String text;
  final bool done;

  /// Whether its task numbers its subtasks. Every subtask of a task carries
  /// the same value, so the setting rides along in the existing list and
  /// older versions, which ignore it, still read the list.
  final bool numbered;

  TodoSubtask copyWith({String? text, bool? done, bool? numbered}) =>
      TodoSubtask(text ?? this.text, done: done ?? this.done, numbered: numbered ?? this.numbered);

  Map<String, dynamic> toJson() => {'text': text, 'done': done, if (numbered) 'numbered': true};
  static List<TodoSubtask> decode(String? value) => value == null
      ? []
      : [
          for (final entry in jsonDecode(value) as List)
            TodoSubtask(entry['text'] as String, done: entry['done'] == true, numbered: entry['numbered'] == true),
        ];
  static String encode(List<TodoSubtask> items) => jsonEncode([for (final item in items) item.toJson()]);
}

class TodoItem {
  TodoItem(
    this.id,
    this.text, {
    required this.since,
    this.done = false,
    this.carried = 0,
    this.dueDate,
    this.doneAt,
    this.uid,
    this.subtasks = const [],
  });

  final int id;
  List<TodoSubtask> subtasks;
  final String? uid;

  /// Its subtasks show 1, 2, 3 and stay in order when ticked.
  bool get numbered => subtasks.isNotEmpty && subtasks.first.numbered;
  DateTime? dueDate;
  String text;
  bool done;

  /// When it was last ticked, which orders the ticked items. Null for items
  /// ticked before this was recorded.
  DateTime? doneAt;

  /// The day it was added. An item still open from an earlier day, week or
  /// month shows it as "From dd/mm".
  final DateTime since;

  /// How many times this item has rolled over unfinished.
  int carried;

  bool sameContent(TodoItem other) {
    if ((id, text, done, doneAt, carried, since, dueDate, uid) !=
            (other.id, other.text, other.done, other.doneAt, other.carried, other.since, other.dueDate, other.uid) ||
        subtasks.length != other.subtasks.length) {
      return false;
    }
    for (var i = 0; i < subtasks.length; i++) {
      if ((subtasks[i].text, subtasks[i].done, subtasks[i].numbered) !=
          (other.subtasks[i].text, other.subtasks[i].done, other.subtasks[i].numbered)) {
        return false;
      }
    }
    return true;
  }
}

/// '24/10'.
String dayMonth(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

final _nonSpace = RegExp(r'\S');

/// [text] with its first letter upper-case; the rest is left alone.
String capitaliseFirst(String text) {
  final i = text.indexOf(_nonSpace);
  if (i == -1) return text;
  return text.substring(0, i) + text[i].toUpperCase() + text.substring(i + 1);
}

final _straightQuotes = RegExp('[\'"′″]');

/// Leading apostrophes in abbreviated years and common elisions.
final _elision = RegExp(r"(?:\d{2}s?\b(?!['’])|tis\b|twas\b|em\b|cause\b|til\b)", caseSensitive: false);

/// Whether a quote after [char] opens rather than closes.
bool _opensAfter(String char) => char.trim().isEmpty || '([{<—–“‘'.contains(char);

/// Use opening/closing dialogue quotes, apostrophes and curly measurement
/// marks. Replacements keep the same UTF-16 length, preserving caret offsets.
/// Runs on every keystroke, so text without straight quotes or primes is
/// returned as it is.
String curlyQuotes(String text) {
  if (!text.contains(_straightQuotes)) return text;
  final result = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '′' || char == '″') {
      result.write(char == '′' ? '’' : '”');
    } else if (char == "'" || char == '"') {
      final afterOpeningDouble = char == "'" && i > 0 && text[i - 1] == '"' && (i == 1 || _opensAfter(text[i - 2]));
      final opens = i == 0 || _opensAfter(text[i - 1]) || afterOpeningDouble;
      final elision = char == "'" && _elision.matchAsPrefix(text, i + 1) != null;
      result.write(char == '"' ? (opens ? '“' : '”') : (opens && !elision ? '‘' : '’'));
    } else {
      result.write(char);
    }
  }
  return result.toString();
}

/// '--' becomes an en dash and '---' an em dash. Typed one hyphen at a
/// time, the third turns the en dash into an em dash.
String autoDashes(String text) {
  if (!text.contains('-')) return text;
  return text.replaceAll('---', '—').replaceAll('--', '–').replaceAll('–-', '—');
}

String normaliseNote(String text) => autoDashes(capitaliseFirst(curlyQuotes(text)));

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// The day [now] counts towards when each day starts at [startHour] o'clock:
/// before then, it's still the day before. Works in calendar days, so a
/// clock change doesn't shift it.
DateTime dayOf(DateTime now, int startHour) => DateTime(now.year, now.month, now.day - (now.hour < startHour ? 1 : 0));

/// When the day after the one [now] counts towards begins.
DateTime nextDayStart(DateTime now, int startHour) {
  final day = dayOf(now, startHour);
  return DateTime(day.year, day.month, day.day + 1, startHour);
}

/// 'Midnight', '4am'.
String hourLabel(int hour) => hour == 0 ? 'Midnight' : '${hour}am';

/// A time of day as the sleep schedule shows it: "8:30 am", "9 pm".
String clockLabel(int minutes) {
  final (h, m) = (minutes ~/ 60, minutes % 60);
  final hour = h % 12 == 0 ? 12 : h % 12;
  return '$hour${m == 0 ? '' : ':${m.toString().padLeft(2, '0')}'} ${h < 12 ? 'am' : 'pm'}';
}

/// A sleep item's saved time: "21:00", or a time inside a note written
/// before times were picked ("Awaken at 8:30 am"). Null when there's none.
int? parseClock(String text) {
  if (RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text) case final m?) {
    return int.parse(m[1]!) * 60 + int.parse(m[2]!);
  }
  final m = RegExp(r'(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\b', caseSensitive: false).firstMatch(text);
  if (m == null) return null;
  final hour = int.parse(m[1]!) % 12 + (m[3]!.toLowerCase() == 'p' ? 12 : 0);
  return hour * 60 + int.parse(m[2] ?? '0');
}

/// How a sleep item's time is saved: "08:30".
String clockKey(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

String dateKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

const monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

const weekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Stable priority ordering, preserving insertion order within equal groups.
/// Ticked items follow the same groups below the open ones, each group in
/// the order they were ticked (due dates first by date).
List<TodoItem> sortTodos(Iterable<TodoItem> todos) {
  final indexed = todos.indexed.toList();
  int group(TodoItem t) =>
      (t.done ? 3 : 0) +
      (t.subtasks.isNotEmpty
          ? 0
          : t.dueDate != null
          ? 1
          : 2);
  indexed.sort((a, b) {
    final priority = group(a.$2).compareTo(group(b.$2));
    if (priority != 0) return priority;
    if (a.$2.dueDate != null && b.$2.dueDate != null) {
      final due = a.$2.dueDate!.compareTo(b.$2.dueDate!);
      if (due != 0) return due;
    }
    if (a.$2.done) {
      // Items ticked before tick times were kept count as ticked first.
      final (x, y) = (a.$2.doneAt, b.$2.doneAt);
      final ticked = x == null ? (y == null ? 0 : -1) : (y == null ? 1 : x.compareTo(y));
      if (ticked != 0) return ticked;
    }
    return a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}
