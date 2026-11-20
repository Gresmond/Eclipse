import 'models.dart';

typedef QuickTask = ({
  String name,
  DateTime? day,
  int? minutes,
  String? location,
  RepeatRule? repeat,
  DateTime? until,
  int reminders,
});

const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const _weekday =
    r'mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:rs(?:day)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?';
const _month =
    r'jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?';
const _ordinal = r'(\d{1,2})(?:st|nd|rd|th)?';
const _quantity = r'\d{1,3}|a|one|two|three|four';
int _count(String quantity) => switch (quantity.toLowerCase()) {
  'a' || 'one' => 1,
  'two' || 'other' || 'second' => 2,
  'three' => 3,
  'four' => 4,
  _ => int.parse(quantity),
};
const _prefix = r',?\s+(?:due\s+)?(?:(?:on|by)\s+)?';

RegExp _suffix(String pattern) => RegExp('$pattern[.,!?]?\$', caseSensitive: false);
final _relative = _suffix(
  '$_prefix(today|tomorrow|next week|the day after tomorrow|day after tomorrow|in ($_quantity) (days?|weeks?|fortnights?))',
);
final _weekdayDate = _suffix('$_prefix(next )?($_weekday)(?: (?:the )?$_ordinal)?');
final _bareThreeLetterWeekday = RegExp(r'^(mon|tue|wed|thu|fri|sat|sun)$', caseSensitive: false);
final _weekdayDatePreposition = RegExp(r'(?:^|\b(?:on|by|due|next|this|before|after|until|through))\s*$', caseSensitive: false);
final _datePreposition = RegExp(r'\b(?:on|by|due|before|after|until|through|starting)\s*$', caseSensitive: false);
final _ordinalDate = _suffix(r',?\s+(?:(?:due\s+)?(?:on\s+)?the\s+|(?:due|on)\s+)(\d{1,2})(?:st|nd|rd|th)');
final _namedDate = _suffix('$_prefix(?:$_ordinal (?:of )?($_month)|($_month) $_ordinal)(?:,? (\\d{4}))?');
final _numericDate = _suffix('$_prefix(\\d{1,2})/(\\d{1,2})(?:/(\\d{4}))?');
const _clockPattern = r'(?:(1[0-2]|0?[1-9])(?::([0-5]\d))?\s*([ap])\.?m\.?|([01]?\d|2[0-3]):([0-5]\d)|(noon|midnight))';
final _clock = _suffix(r',?\s+(?:(?:due\s+)?(?:at|by)\s+)?' + _clockPattern);
final _rangeStart = _suffix(r'\s+(from|between)\s+(' + _clockPattern + r')\s+(to|and)');
final _clockConnector = RegExp(r'^(?:due\s+)?(?:at|by)\b', caseSensitive: false);
final _rangePreposition = RegExp(
  r'(?:\b(?:from|between|before|after|past|to|until|through)|\bbetween\b[^,;.!?]*\band)\s*$',
  caseSensitive: false,
);
final _nonClockColonPrefix = RegExp(
  r'\b(?:romans|genesis|exodus|leviticus|numbers|deuteronomy|joshua|judges|ruth|samuel|kings|chronicles|ezra|nehemiah|esther|job|psalms?|proverbs|ecclesiastes|isaiah|jeremiah|lamentations|ezekiel|daniel|hosea|joel|amos|obadiah|jonah|micah|nahum|habakkuk|zephaniah|haggai|zechariah|malachi|matthew|mark|luke|john|acts|corinthians|galatians|ephesians|philippians|colossians|thessalonians|timothy|titus|philemon|hebrews|james|peter|jude|revelation|chapter|verse|ratio|ch\.|v\.)\s*$',
  caseSensitive: false,
);
final _reminder = _suffix(
  r',?\s+(?:and\s+)?remind me (a day|1 day|24 hours|an hour|1 hour|60 minutes|(?:15|20) (?:minutes|mins)) (?:before|beforehand|early)',
);
final _repeatWeekdays = _suffix(
  '\\s+every (?:(other|second) )?((?:$_weekday)(?:(?:,\\s*(?:and )?| and )(?:$_weekday))*)',
);
final _frequency = _suffix(r'\s+(daily|weekly|fortnightly|monthly|yearly|annually)');
final _incompleteSchedule = RegExp(r'\b(?:until|starting|every(?: other| second)?|of|except)$', caseSensitive: false);
final _interval = _suffix('\\s+every (?:($_quantity|other|second) )?(weekdays?|days?|weeks?|fortnights?|months?|years?)');
final _until = RegExp(r'\s+(?:until|through)$', caseSensitive: false);
final _start = RegExp(r'\s+starting$', caseSensitive: false);
final _place = RegExp(r'\s+@([^@]+)$');

// Clock and calendar suffixes get first choice of "at" and "in".
final _placeIntro = RegExp(r'\s+(at|in)\s+', caseSensitive: false);
final _venue = RegExp(
  r"\b(place|home|work|school|uni|gym|office|library|clinic|hospital|surgery|pharmacy|station|airport|park|pool|court|oval|café|cafe|restaurant|cinema|studio|shop|store|market|supermarket|hall|room|centre|center|beach|hotel|campus|warehouse|street|road|avenue|lane|drive|terrace|square|coles|woolworths|aldi|bunnings)\b",
  caseSensitive: false,
);
final _placeWords = RegExp(r"^[\p{L}\p{N}][\p{L}\p{M}\p{N} ’'&,./-]*$", unicode: true);
final _nonPlace = RegExp(
  r'\b(?:remind me|starting|until|tomorrow|today|every|minutes?|hours?|days?|weeks?|least|most|once|first|last|risk|heart|hand|mind|progress|advance|detail|general|person|writing)\b|\d\s*(?:am|pm)\b',
  caseSensitive: false,
);
final _objectOfAt = RegExp(r'\b(?:look|looking|glance|stare|aim|laugh|smile|point|hint|good|bad|excel)\s*$', caseSensitive: false);

final _namedPlace = RegExp(r"^(?:[\p{Lu}][\p{L}\p{M}’'-]*|\d+)(?:\s+(?:[\p{Lu}][\p{L}\p{M}’'-]*|of|the|and|\d+))*$", unicode: true);
final _singleAcronym = RegExp(r'^[\p{Lu}]{2,}$', unicode: true);
final _addressLetter = RegExp(r'\p{L}', unicode: true);
final _placeContext = RegExp(r'\b(?:meet|dinner|lunch|breakfast|appointment|arrive|shop|pickup|training|workout)\b', caseSensitive: false);
final _singlePlaceWord = RegExp(r"^[\p{L}][\p{L}’'-]*$", unicode: true);

({int start, String location})? _spokenPlace(String text) {
  final matches = _placeIntro.allMatches(text).toList();
  for (var i = matches.length - 1; i >= 0; i--) {
    final intro = matches[i];
    final prefix = text.substring(0, intro.start);
    final prep = intro[1]!.toLowerCase();
    if (prep == 'at' && _objectOfAt.hasMatch(prefix)) continue;
    final place = text.substring(intro.end).trimRight().replaceFirst(RegExp(r'[.,!?]$'), '');
    if (!_placeWords.hasMatch(place) || _nonPlace.hasMatch(place)) continue;
    // Ordinary venue words work in lowercase. Proper names also cover
    // addresses such as "in North Adelaide" and businesses such as "at IKEA".
    if (RegExp(r'^(?:at|in)\s+', caseSensitive: false).hasMatch(place)) continue;
    final isSingleWord = !place.contains(' ');
    final properName =
        _namedPlace.hasMatch(place) &&
        _addressLetter.hasMatch(place) &&
        !(isSingleWord && prep == 'in' && (!_placeContext.hasMatch(prefix) || _singleAcronym.hasMatch(place)));
    final simpleName = _singlePlaceWord.hasMatch(place) && _placeContext.hasMatch(prefix);
    if (!_venue.hasMatch(place) && !properName && !simpleName) continue;
    return (start: intro.start, location: place);
  }
  return null;
}

/// Finds the next real calendar date matching the supplied components.
DateTime? _nextDate(DateTime today, int number, {int? month, int? year, int? weekday}) {
  if (number < 1 || number > 31 || (month != null && (month < 1 || month > 12))) return null;
  if (year != null && month != null) {
    final date = DateTime(year, month, number);
    return date.month == month && !date.isBefore(today) ? date : null;
  }
  for (var i = 0; i <= 96; i++) {
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

({RegExpMatch match, DateTime? day})? _readDay(String text, DateTime today) {
  RegExpMatch? match;
  DateTime? day;
  if ((match = _relative.firstMatch(text)) != null) {
    final word = match![1]!.toLowerCase();
    final offset = switch (word) {
      'today' => 0,
      'tomorrow' => 1,
      'next week' => 7,
      'the day after tomorrow' || 'day after tomorrow' => 2,
      _ => _count(match[2]!) * switch (match[3]!.toLowerCase()) {
        'week' || 'weeks' => 7,
        'fortnight' || 'fortnights' => 14,
        _ => 1,
      },
    };
    day = DateTime(today.year, today.month, today.day + offset);
  } else if ((match = _weekdayDate.firstMatch(text)) != null) {
    final m = match!;
    final token = m[2]!;
    final before = text.substring(0, m.start) + m[0]!.substring(0, m[0]!.indexOf(token));
    if (_bareThreeLetterWeekday.hasMatch(token) &&
        m[3] == null &&
        m[1] == null &&
        (RegExp(r'\b(?:the|a|an|for|in)\s*$', caseSensitive: false).hasMatch(before) ||
            (token == token.toUpperCase() && !_weekdayDatePreposition.hasMatch(before)))) {
      return null;
    }
    final weekday = _weekdays.indexOf(token.substring(0, 3).toLowerCase()) + 1;
    if (m[3] != null) {
      day = _nextDate(today, int.parse(m[3]!), weekday: weekday);
    } else {
      var offset = (weekday - today.weekday) % 7;
      if (m[1] != null) offset = 7 - today.weekday + weekday;
      day = DateTime(today.year, today.month, today.day + offset);
    }
  } else if ((match = _namedDate.firstMatch(text)) != null) {
    final m = match!;
    final month = _months.indexOf((m[2] ?? m[3])!.substring(0, 3).toLowerCase()) + 1;
    day = _nextDate(today, int.parse((m[1] ?? m[4])!), month: month, year: int.tryParse(m[5] ?? ''));
  } else if ((match = _numericDate.firstMatch(text)) != null) {
    final m = match!;
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    if (m[3] == null && a <= 4 && b <= 4 && !_datePreposition.hasMatch(text.substring(0, m.start) + m[0]!.split(RegExp(r'\d')).first)) return null;
    day = _nextDate(today, a, month: b, year: int.tryParse(m[3] ?? ''));
  } else if ((match = _ordinalDate.firstMatch(text)) != null) {
    day = _nextDate(today, int.parse(match![1]!));
  } else {
    return null;
  }
  return (match: match, day: day);
}

/// Peel complete scheduling phrases from the end so the title remains intact.
QuickTask parseQuickTask(String raw, DateTime today, {DateTime? defaultDay, int? defaultTime}) {
  var text = raw.trim();
  today = DateTime(today.year, today.month, today.day);
  DateTime? day;
  int? minutes;
  String? location, endPhrase;
  DateTime? until;
  RepeatRule? repeat;
  int? anchorWeekday;
  var reminders = 0;
  final literal = (name: text, day: null, minutes: null, location: null, repeat: null, until: null, reminders: 0);
  while (true) {
    final hadDay = day != null;
    RegExpMatch? match;
    if ((match = _reminder.firstMatch(text)) != null) {
      final offset = match![1]!.toLowerCase();
      reminders |= switch (offset) {
        'a day' || '1 day' || '24 hours' => Reminder.dayBefore.bit,
        'an hour' || '1 hour' || '60 minutes' => Reminder.hourBefore.bit,
        '20 minutes' || '20 mins' => Reminder.twentyBefore.bit,
        _ => Reminder.quarterBefore.bit,
      };
    } else if (repeat == null && (match = _repeatWeekdays.firstMatch(text)) != null) {
      final m = match!;
      final weekdays = RegExp(
        _weekday,
        caseSensitive: false,
      ).allMatches(m[2]!).map((word) => _weekdays.indexOf(word[0]!.substring(0, 3).toLowerCase()) + 1).toSet();
      if (m[1] == null) {
        repeat = RepeatRule.weekly(weekdays);
      } else {
        if (weekdays.length != 1) return literal;
        anchorWeekday = weekdays.single;
        repeat = const RepeatRule.every(2, weeks: true);
      }
    } else if (repeat == null && (match = _frequency.firstMatch(text)) != null) {
      repeat = switch (match![1]!.toLowerCase()) {
        'daily' => const RepeatRule.every(1),
        'weekly' => const RepeatRule.every(1, weeks: true),
        'fortnightly' => const RepeatRule.every(2, weeks: true),
        'monthly' => const RepeatRule.months(1),
        _ => const RepeatRule.yearly(1),
      };
    } else if (repeat == null && (match = _interval.firstMatch(text)) != null) {
      final m = match!;
      final n = _count(m[1] ?? 'one');
      if (n < 1) return literal;
      repeat = switch (m[2]!.toLowerCase().replaceFirst(RegExp(r's$'), '')) {
        'weekday' => const RepeatRule.weekly({1, 2, 3, 4, 5}),
        'week' => RepeatRule.every(n, weeks: true),
        'fortnight' => RepeatRule.every(2 * n, weeks: true),
        'month' => RepeatRule.months(n),
        'year' => RepeatRule.yearly(n),
        _ => RepeatRule.every(n),
      };
      if (repeat.every > 1000 || (repeat.weekdays != null && n != 1)) return literal;
    } else if (minutes == null && (match = _clock.firstMatch(text)) != null) {
      final m = match!;
      final before = text.substring(0, m.start);
      final range = _rangeStart.firstMatch(before);
      if (range != null &&
          (range[1]!.toLowerCase() == 'between') == (range[9]!.toLowerCase() == 'and')) {
        // Tasks have a single scheduled time. Parse the first endpoint normally.
        text = '${before.substring(0, range.start)} at ${range[2]}';
        continue;
      }
      final trimmed = m[0]!.trimLeft();
      if (!_clockConnector.hasMatch(trimmed) &&
          (_rangePreposition.hasMatch(before) ||
              (m[4] != null && _nonClockColonPrefix.hasMatch(before)) ||
              m[6] != null)) {
        final place = location == null ? _spokenPlace(text) : null;
        if (place != null) {
          location = place.location;
          text = text.substring(0, place.start).trimRight();
          continue;
        }
        break;
      }
      if (m[1] != null) {
        minutes = (int.parse(m[1]!) % 12 + (m[3]!.toLowerCase() == 'p' ? 12 : 0)) * 60 + int.parse(m[2] ?? '0');
      } else if (m[4] != null) {
        minutes = int.parse(m[4]!) * 60 + int.parse(m[5]!);
      } else {
        minutes = m[6]!.toLowerCase() == 'noon' ? 720 : 0;
      }
    } else if (_readDay(text, today) case final found?) {
      match = found.match;
      final prefix = text.substring(0, match.start).trimRight();
      if (_until.hasMatch(prefix)) {
        if (endPhrase != null) return literal;
        endPhrase = match[0]!;
        text = prefix.replaceFirst(_until, '');
        continue;
      }
      if (day != null || found.day == null) return literal;
      day = found.day;
    } else if (location == null && (match = _place.firstMatch(text)) != null) {
      location = match![1]!.trim();
      if (location.isEmpty || RegExp(r'\bremind me\b', caseSensitive: false).hasMatch(location)) return literal;
    } else {
      final place = location == null ? _spokenPlace(text) : null;
      if (place != null) {
        location = place.location;
        text = text.substring(0, place.start).trimRight();
        continue;
      }
      break;
    }
    final prefix = text.substring(0, match.start).trimRight();
    if (!hadDay && day != null && _start.hasMatch(prefix)) {
      if (match[0]!.trim().replaceFirst(RegExp(r'[.,!?]$'), '').toLowerCase() == 'next week') {
        day = DateTime(today.year, today.month, today.day + 8 - today.weekday);
      }
      text = prefix.replaceFirst(_start, '');
    } else {
      text = prefix;
    }
  }
  if ((day != null || repeat != null) && _incompleteSchedule.hasMatch(text)) return literal;
  if (text.isEmpty || (reminders != 0 && (minutes ?? defaultTime) == null)) return literal;
  if (endPhrase != null && repeat == null) return literal;
  if (repeat != null) {
    final start = day ?? defaultDay ?? today;
    var first = start;
    while ((anchorWeekday != null && first.weekday != anchorWeekday) ||
        (repeat.weekdays != null && !repeat.weekdays!.contains(first.weekday))) {
      first = DateTime(first.year, first.month, first.day + 1);
    }
    day = first;
    if (endPhrase != null) {
      // “Tomorrow” is relative to entry. A bare weekday or month/day
      // following a future start belongs to that series.
      final reference = _relative.hasMatch(endPhrase) ? today : start;
      until = _readDay(endPhrase, reference)?.day;
      if (until == null || until.isBefore(first)) return literal;
    }
  }
  return (
    name: text,
    day: day,
    minutes: minutes,
    location: location,
    repeat: repeat,
    until: until,
    reminders: reminders,
  );
}
