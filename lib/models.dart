import 'dart:convert';
import 'dart:math';

enum HabitStatus { none, done, missed, other }

class Habit {
  Habit(this.id, this.name, {this.description, this.minutes, this.addedOn, this.days = const []});

  /// Which weekdays it's on this month, as changes of weekday bits (see [weekdayBit]), each
  /// from its day on (the first may be from the start of the month, null).
  /// A change partway through the month leaves the days before it alone.
  /// Empty when it's on every day.
  List<(DateTime?, int)> days;

  /// The weekdays it's on now.
  int get weekdays => days.isEmpty ? everyDay : days.last.$2;

  /// Whether [day] is one of its days; other days are greyed out and can't
  /// be marked, and don't count towards its scores or streaks.
  bool onDay(DateTime day) => isOnDay(days, day);

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

/// Weekdays as bits, Monday the lowest.
int weekdayBit(int weekday) => 1 << (weekday - 1);
const everyDay = 0x7f;

/// Whether [day] is on in a ritual's [Habit.days].
bool isOnDay(List<(DateTime?, int)> days, DateTime day) {
  var bits = everyDay;
  for (final (from, b) in days) {
    if (from == null || !dateOnly(day).isBefore(from)) bits = b;
  }
  return bits & weekdayBit(day.weekday) != 0;
}

/// [Habit.days] as saved: `[[null, 21], ["2026-10-27", 127]]`, or null
/// when it's on every day.
String? encodeDays(List<(DateTime?, int)> days) => days.isEmpty
    ? null
    : jsonEncode([
        for (final (from, bits) in days) [from == null ? null : dateKey(from), bits],
      ]);

List<(DateTime?, int)> decodeDays(String? value) => value == null
    ? []
    : [
        for (final change in jsonDecode(value) as List)
          (change[0] == null ? null : DateTime.parse(change[0] as String), change[1] as int),
      ];

/// [days] with [bits] from [from] on (from the start of the month when
/// null), replacing any change made the same day, and with no change that
/// leaves the days as they were.
List<(DateTime?, int)> changeDays(List<(DateTime?, int)> days, DateTime? from, int bits) {
  final kept = [
    if (from != null)
      for (final c in days)
        if (c.$1 == null || c.$1!.isBefore(from)) c,
  ];
  final before = kept.isEmpty ? everyDay : kept.last.$2;
  if (bits != before) kept.add((from, bits));
  return kept.every((c) => c.$2 == everyDay) ? [] : kept;
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
            TodoSubtask(
              curlyQuotes(entry['text'] as String),
              done: entry['done'] == true,
              numbered: entry['numbered'] == true,
            ),
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
    this.dueTime,
    this.birthday = false,
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

  /// The time of day it's at, in minutes from midnight; null for all day.
  int? dueTime;

  /// It's someone's birthday: it comes round every year, and Further ahead
  /// can hide it.
  bool birthday;
  String text;
  bool done;

  /// When it was last ticked, which orders the ticked items. Null for items
  /// ticked before this was recorded.
  DateTime? doneAt;

  /// The day it was added. An item still open from an earlier day, week or
  /// month shows it beside a history icon, as dd/mm.
  final DateTime since;

  /// How many times this item has rolled over unfinished.
  int carried;

  /// The repeating task it's an occurrence of, if any: an occurrence's uid
  /// is its repeat's, '@', and its day, so every computer makes the same one.
  String? get repeatUid => uid?.contains('@') == true ? uid!.substring(0, uid!.indexOf('@')) : null;

  /// The day it's an occurrence for.
  DateTime? get repeatDay => repeatUid == null ? null : DateTime.tryParse(uid!.substring(uid!.indexOf('@') + 1));

  bool sameContent(TodoItem other) {
    if ((id, text, done, doneAt, carried, since, dueDate, dueTime, birthday, uid) !=
            (
              other.id,
              other.text,
              other.done,
              other.doneAt,
              other.carried,
              other.since,
              other.dueDate,
              other.dueTime,
              other.birthday,
              other.uid,
            ) ||
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

enum RepeatKind { weekly, days, weeks, monthly, yearly }

/// Whether a task's stored kind, in its `category` column, makes it a
/// birthday. Other kinds are from before birthdays replaced categories.
bool isBirthday(Object? kind) => kind == 'birthday';

/// A birthday's stored kind.
String? birthdayKind(bool birthday) => birthday ? 'birthday' : null;

/// When a repeating task comes round: on chosen weekdays, every so many
/// days or weeks from its start, on a date each month, or on its start's
/// date every so many years.
class RepeatRule {
  const RepeatRule.weekly(Set<int> this.weekdays) : kind = RepeatKind.weekly, every = 1;
  const RepeatRule.every(this.every, {bool weeks = false})
    : kind = weeks ? RepeatKind.weeks : RepeatKind.days,
      weekdays = null;
  const RepeatRule.monthly(this.every) : kind = RepeatKind.monthly, weekdays = null;
  const RepeatRule.yearly(this.every) : kind = RepeatKind.yearly, weekdays = null;

  final RepeatKind kind;

  /// Monday is 1.
  final Set<int>? weekdays;

  /// The days, weeks or years between, or the date of the month.
  final int every;

  /// 'weekly:1,3,5', 'days:2', 'weeks:2', 'monthly:15' or 'yearly:1'.
  String encode() => '${kind.name}:${kind == RepeatKind.weekly ? (weekdays!.toList()..sort()).join(',') : every}';

  static RepeatRule? decode(String value) {
    final i = value.indexOf(':');
    if (i < 0) return null;
    final kind = RepeatKind.values.asNameMap()[value.substring(0, i)];
    final rest = value.substring(i + 1);
    if (kind == RepeatKind.weekly) {
      final days = {for (final d in rest.split(',')) ?int.tryParse(d)}.where((d) => d >= 1 && d <= 7).toSet();
      return days.isEmpty ? null : RepeatRule.weekly(days);
    }
    final n = int.tryParse(rest);
    if (kind == null || n == null || n < 1 || (kind == RepeatKind.monthly && n > 31)) return null;
    return switch (kind) {
      RepeatKind.monthly => RepeatRule.monthly(n),
      RepeatKind.yearly => RepeatRule.yearly(n),
      _ => RepeatRule.every(n, weeks: kind == RepeatKind.weeks),
    };
  }

  /// Whether it comes round on [day], counting from [start].
  bool on(DateTime day, DateTime start) {
    final since = DateTime.utc(
      day.year,
      day.month,
      day.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    if (since < 0) return false;
    return switch (kind) {
      RepeatKind.weekly => weekdays!.contains(day.weekday),
      RepeatKind.days => since % every == 0,
      RepeatKind.weeks => since % (7 * every) == 0,
      // The 31st falls on a shorter month's last day.
      RepeatKind.monthly => day.day == min(every, DateTime(day.year, day.month + 1, 0).day),
      // A 29 February start comes round in leap years only.
      RepeatKind.yearly => day.month == start.month && day.day == start.day && (day.year - start.year) % every == 0,
    };
  }

  /// 'Every Mon, Wed', 'Every 2 days', 'Every week', 'Monthly on the 15th',
  /// 'Every 2 years'.
  String get label => switch (kind) {
    RepeatKind.weekly =>
      weekdays!.length == 7
          ? 'Every day'
          : 'Every ${[for (final d in weekdays!.toList()..sort()) weekdayNames[d - 1].substring(0, 3)].join(', ')}',
    RepeatKind.days => every == 1 ? 'Every day' : 'Every $every days',
    RepeatKind.weeks => every == 1 ? 'Every week' : 'Every $every weeks',
    RepeatKind.monthly => 'Monthly on the ${ordinal(every)}',
    RepeatKind.yearly => every == 1 ? 'Every year' : 'Every $every years',
  };

  @override
  bool operator ==(Object other) => other is RepeatRule && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}

/// '1st', '2nd', '11th', '23rd'.
String ordinal(int n) {
  final suffix = n % 100 >= 11 && n % 100 <= 13 ? 'th' : const ['th', 'st', 'nd', 'rd'].elementAtOrNull(n % 10) ?? 'th';
  return '$n$suffix';
}

/// A task that comes round by its [rule], from [start] until [until] (if
/// set). Each time is an ordinary to-do, made a week ahead.
class Repeat {
  const Repeat({
    required this.uid,
    required this.text,
    required this.rule,
    required this.start,
    this.until,
    this.time,
    this.birthday = false,
  });

  final String uid;
  final String text;

  /// The time of day each one is at, as [TodoItem.dueTime].
  final int? time;

  /// It's someone's birthday, as [TodoItem.birthday]; it repeats yearly.
  final bool birthday;
  final RepeatRule rule;
  final DateTime start;
  final DateTime? until;

  bool on(DateTime day) => (until == null || !day.isAfter(until!)) && rule.on(day, start);

  /// The first day it comes round on or after [from], if any within a year
  /// and a bit (a monthly 31st needs no more); a yearly one's by its years.
  DateTime? next(DateTime from) {
    var day = from.isBefore(start) ? start : from;
    if (rule.kind == RepeatKind.yearly) {
      // Its years from the one [day] is in, until one has its date.
      for (var year = start.year + ((day.year - start.year) ~/ rule.every) * rule.every; ; year += rule.every) {
        final date = DateTime(year, start.month, start.day);
        if (date.day != start.day) continue;
        if (until != null && date.isAfter(until!)) return null;
        if (!date.isBefore(day)) return date;
      }
    }
    for (var i = 0; i < 400; i++, day = DateTime(day.year, day.month, day.day + 1)) {
      if (until != null && day.isAfter(until!)) return null;
      if (on(day)) return day;
    }
    return null;
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
  // Pasted primes can surround quoted speech too; infer their direction
  // from context just as for keyboard quotes.
  text = text.replaceAll('′', "'").replaceAll('″', '"');
  final result = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == "'" || char == '"') {
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
