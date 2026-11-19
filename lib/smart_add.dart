typedef QuickTask = ({String name, DateTime? day, int? minutes, String? location});

const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const _weekday =
    r'mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:rs(?:day)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?';
const _month =
    r'jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?';
const _ordinal = r'(\d{1,2})(?:st|nd|rd|th)?';
const _prefix = r',?\s+(?:due\s+)?(?:(?:on|by)\s+)?';

RegExp _suffix(String pattern) => RegExp('$pattern[.,!?]?\$', caseSensitive: false);
final _relative = _suffix('$_prefix(today|tomorrow|next week|the day after tomorrow|day after tomorrow|in (\\d{1,3}) days?)');
final _weekdayDate = _suffix('$_prefix(next )?($_weekday)(?: (?:the )?$_ordinal)?');
final _ordinalDate = _suffix(r',?\s+(?:(?:due\s+)?(?:on\s+)?the\s+|(?:due|on)\s+)(\d{1,2})(?:st|nd|rd|th)');
final _namedDate = _suffix('$_prefix(?:$_ordinal (?:of )?($_month)|($_month) $_ordinal)(?:,? (\\d{4}))?');
final _numericDate = _suffix('$_prefix(\\d{1,2})/(\\d{1,2})(?:/(\\d{4}))?');
final _clock = _suffix(
  r',?\s+(?:(?:due\s+)?(?:at|by)\s+)?(?:(1[0-2]|0?[1-9])(?::([0-5]\d))?\s*([ap])\.?m\.?|([01]?\d|2[0-3]):([0-5]\d)|(noon|midnight))',
);
final _place = RegExp(r'\s+@([^@]+)$');

/// Finds the next real calendar date matching the supplied components.
DateTime? _nextDate(DateTime today, int number, {int? month, int? year, int? weekday}) {
  if (number < 1 || number > 31 || (month != null && (month < 1 || month > 12))) return null;
  if (year != null && month != null) {
    final date = DateTime(year, month, number);
    return date.month == month && !date.isBefore(today) ? date : null;
  }
  for (var i = 0; i < 96; i++) {
    final date = DateTime(today.year, today.month + i, number);
    if (date.day == number &&
        !date.isBefore(today) &&
        (month == null || date.month == month) &&
        (year == null || date.year == year) &&
        (weekday == null || date.weekday == weekday)) {
      return date;
    }
  }
  return null;
}

/// Peel complete scheduling phrases from the end so the title remains intact.
QuickTask parseQuickTask(String raw, DateTime today) {
  var text = raw.trim();
  today = DateTime(today.year, today.month, today.day);
  DateTime? day;
  int? minutes;
  String? location;
  while (true) {
    RegExpMatch? match;
    if (minutes == null && (match = _clock.firstMatch(text)) != null) {
      final m = match!;
      if (m[1] != null) {
        minutes = (int.parse(m[1]!) % 12 + (m[3]!.toLowerCase() == 'p' ? 12 : 0)) * 60 + int.parse(m[2] ?? '0');
      } else if (m[4] != null) {
        minutes = int.parse(m[4]!) * 60 + int.parse(m[5]!);
      } else {
        minutes = m[6]!.toLowerCase() == 'noon' ? 720 : 0;
      }
    } else if (day == null && (match = _relative.firstMatch(text)) != null) {
      final word = match![1]!.toLowerCase();
      final offset = switch (word) {
        'today' => 0,
        'tomorrow' => 1,
        'next week' => 7,
        'the day after tomorrow' || 'day after tomorrow' => 2,
        _ => int.parse(match[2]!),
      };
      day = DateTime(today.year, today.month, today.day + offset);
    } else if (day == null && (match = _weekdayDate.firstMatch(text)) != null) {
      final m = match!;
      final weekday = _weekdays.indexOf(m[2]!.substring(0, 3).toLowerCase()) + 1;
      if (m[3] != null) {
        day = _nextDate(today, int.parse(m[3]!), weekday: weekday);
      } else {
        var offset = (weekday - today.weekday) % 7;
        if (offset == 0 && m[1] != null) offset = 7;
        day = DateTime(today.year, today.month, today.day + offset);
      }
      if (day == null) break;
    } else if (day == null && (match = _namedDate.firstMatch(text)) != null) {
      final m = match!;
      final month = _months.indexOf((m[2] ?? m[3])!.substring(0, 3).toLowerCase()) + 1;
      day = _nextDate(today, int.parse((m[1] ?? m[4])!), month: month, year: int.tryParse(m[5] ?? ''));
      if (day == null) break;
    } else if (day == null && (match = _numericDate.firstMatch(text)) != null) {
      final m = match!;
      day = _nextDate(today, int.parse(m[1]!), month: int.parse(m[2]!), year: int.tryParse(m[3] ?? ''));
      if (day == null) break;
    } else if (day == null && (match = _ordinalDate.firstMatch(text)) != null) {
      day = _nextDate(today, int.parse(match![1]!));
      if (day == null) break;
    } else if (location == null && (match = _place.firstMatch(text)) != null) {
      location = match![1]!.trim();
    } else {
      break;
    }
    text = text.substring(0, match.start).trimRight();
  }
  return (name: text, day: day, minutes: minutes, location: location);
}
