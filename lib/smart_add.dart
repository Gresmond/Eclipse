/// Parses optional trailing details from a quick task name.
({String name, DateTime? day, int? minutes, String? location}) parseQuickTask(String raw, DateTime today) {
  var text = raw.trim();
  final place = RegExp(r'\s+@([^@]+)$').firstMatch(text);
  final location = place?.group(1)?.trim();
  if (place != null) text = text.substring(0, place.start);
  final clock = RegExp(r'\s+(1[0-2]|0?[1-9])(?::([0-5]\d))?\s*(am|pm)$', caseSensitive: false).firstMatch(text);
  int? time;
  if (clock != null) {
    final hour = int.parse(clock[1]!) % 12 + (clock[3]!.toLowerCase() == 'pm' ? 12 : 0);
    time = hour * 60 + int.parse(clock[2] ?? '0');
    text = text.substring(0, clock.start);
  }
  final weekday = RegExp(r'\s+(today|tomorrow|mon|tue|wed|thu|fri|sat|sun)$', caseSensitive: false).firstMatch(text);
  DateTime? day;
  if (weekday != null) {
    final word = weekday[1]!.toLowerCase();
    const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    final offset = word == 'today'
        ? 0
        : word == 'tomorrow'
        ? 1
        : (days.indexOf(word) + 1 - today.weekday) % 7;
    day = DateTime(today.year, today.month, today.day + offset);
    text = text.substring(0, weekday.start);
  }
  return (name: text.trim(), day: day, minutes: time, location: location);
}
