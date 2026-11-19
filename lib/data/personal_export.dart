import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models.dart';
import 'store.dart';

String _icalText(String text) => text
    .replaceAll('\\', '\\\\')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', '\\n')
    .replaceAll(',', '\\,')
    .replaceAll(';', '\\;');

String _foldLine(String line) {
  final output = StringBuffer();
  var used = 0;
  for (final rune in line.runes) {
    final char = String.fromCharCode(rune), size = utf8.encode(char).length;
    if (used + size > 75) {
      output.write('\r\n ');
      used = 1;
    }
    output.write(char);
    used += size;
  }
  return output.toString();
}

String calendarExport(Store store, DateTime today, {required DateTime generated}) {
  final lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Eclipse//Personal planner//EN', 'CALSCALE:GREGORIAN'];
  String day(DateTime d) => dateKey(d).replaceAll('-', '');
  String two(int n) => n.toString().padLeft(2, '0');
  final utc = generated.toUtc(), stamp = '${day(utc)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  final startHour = parseDayStartHour(store.setting('dayStartHour'));
  void event(String uid, String name, DateTime logical, int? minutes, {String? location, String? note, String? rule}) {
    final d = afterMidnight(minutes, startHour) ? DateTime(logical.year, logical.month, logical.day + 1) : logical;
    lines.addAll([
      'BEGIN:VEVENT',
      'UID:${_icalText(uid)}@eclipse',
      'DTSTAMP:$stamp',
      minutes == null
          ? 'DTSTART;VALUE=DATE:${day(d)}'
          : 'DTSTART:${day(d)}T${two(minutes ~/ 60)}${two(minutes % 60)}00',
      'SUMMARY:${_icalText(name)}',
      if (location != null) 'LOCATION:${_icalText(location)}',
      if (note != null) 'DESCRIPTION:${_icalText(note)}',
      if (rule != null) 'RRULE:$rule',
      'END:VEVENT',
    ]);
  }

  final birthdays = {
    for (final r in store.repeats())
      if (r.birthday) r.uid: r,
  };
  for (final row in store.raw.select(
    "SELECT * FROM todos WHERE done=0 AND (due_time IS NOT NULL OR category='birthday')",
  )) {
    final uid = row['uid'] as String, birth = row['category'] == 'birthday';
    if (birth && birthdays.containsKey(uid.split('@').first)) continue;
    final due =
        DateTime.tryParse(row['due_date'] as String? ?? '') ??
        (row['scope'] == 'tomorrow' ? DateTime(today.year, today.month, today.day + 1) : today);
    event(
      uid,
      row['text'] as String,
      due,
      birth ? null : parseClock(row['due_time'] as String),
      location: row['location'] as String?,
      note: row['note'] as String?,
    );
  }
  // The planner materializes only nearby repeats. Include the next timed
  // occurrence even when it falls beyond the current planning window.
  final materialized = {for (final r in store.raw.select("SELECT uid FROM todos")) r['uid']};
  for (final repeat in store.repeats().where((r) => !r.birthday && r.time != null)) {
    var next = repeat.next(today);
    while (next != null && materialized.contains('${repeat.uid}@${dateKey(next)}')) {
      next = repeat.next(DateTime(next.year, next.month, next.day + 1));
    }
    if (next != null) {
      event('${repeat.uid}@${dateKey(next)}', repeat.text, next, repeat.time, location: repeat.location);
    }
  }
  for (final r in birthdays.values) {
    final feb29 = r.start.month == 2 && r.start.day == 29;
    event(
      r.uid,
      r.text,
      r.start,
      null,
      location: r.location,
      rule:
          'FREQ=YEARLY;INTERVAL=${r.rule.every}${feb29 ? ';BYMONTH=2;BYMONTHDAY=-1' : ''}${r.until == null ? '' : ';UNTIL=${day(r.until!)}'}',
    );
  }
  lines.add('END:VCALENDAR');
  return '${lines.map(_foldLine).join('\r\n')}\r\n';
}

Uint8List exportBundle(Store store, DateTime today, {required DateTime generated}) {
  final archive = Archive();
  void file(String path, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  final tables = <String, List<Map<String, Object?>>>{};
  for (final table in [
    'habits',
    'habit_months',
    'month_habits',
    'entries',
    'sleep_habits',
    'sleep_notes',
    'todos',
    'todo_history',
    'todo_repeats',
    'journal',
    'exercises',
    'training_sets',
    'routines',
    'weigh_ins',
  ]) {
    final rows = store.raw.select('SELECT * FROM $table'), columns = rows.columnNames;
    tables[table] = [
      for (final row in rows) {...row},
    ];
    String csv(Object? value) {
      var text = value?.toString() ?? '';
      if (value is String && RegExp(r'^[\s]*[=+@-]').hasMatch(text)) text = "'$text";
      return '"${text.replaceAll('"', '""')}"';
    }

    file(
      'csv/$table.csv',
      [columns.map(csv).join(','), for (final row in rows) columns.map((c) => csv(row[c])).join(',')].join('\r\n'),
    );
  }
  file(
    'eclipse.json',
    const JsonEncoder.withIndent('  ').convert({
      'schema': Store.schemaVersion,
      'exported': generated.toUtc().toIso8601String(),
      'tables': tables,
      'holidays': jsonDecode(store.setting('holidays') ?? '[]'),
      'dayStartHour': parseDayStartHour(store.setting('dayStartHour')),
    }),
  );
  for (final row in tables['journal']!) {
    final day = row['day'] as String;
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) file('journal/$day.md', row['text'] as String);
  }
  file('calendar.ics', calendarExport(store, today, generated: generated));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}
