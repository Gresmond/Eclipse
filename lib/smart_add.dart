import 'dart:math' as math;

import 'models.dart';

typedef QuickTask = ({
  String name,
  DateTime? day,
  int? minutes,
  String? location,
  RepeatRule? repeat,
  DateTime? until,
  int reminders,
  bool birthday,
});

QuickTask _plain(String name) => (
  name: name,
  day: null,
  minutes: null,
  location: null,
  repeat: null,
  until: null,
  reminders: 0,
  birthday: false,
);

const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const _weekday =
    r'mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:rs(?:day)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?';
const _fullWeekday = r'monday|tuesday|wednesday|thursday|friday|saturday|sunday';
const _month =
    r'jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?';
const _ordinal = r'(\d{1,2})(?:st|nd|rd|th)?';
const _dayOrd = r'(\d{1,2})(?:st|nd|rd|th)';
const _quantity =
    r'\d{1,3}|a couple(?: of)?|couple(?: of)?|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve';
const _ordQuantity =
    r'\d{1,3}(?:st|nd|rd|th)|other|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth';
const _ordInterval = '$_quantity|$_ordQuantity';

const _wordNumbers = <String, int>{
  'a': 1,
  'an': 1,
  'one': 1,
  'first': 1,
  'two': 2,
  'couple': 2,
  'couple of': 2,
  'a couple': 2,
  'a couple of': 2,
  'other': 2,
  'second': 2,
  'three': 3,
  'third': 3,
  'four': 4,
  'fourth': 4,
  'five': 5,
  'fifth': 5,
  'six': 6,
  'sixth': 6,
  'seven': 7,
  'seventh': 7,
  'eight': 8,
  'eighth': 8,
  'nine': 9,
  'ninth': 9,
  'ten': 10,
  'tenth': 10,
  'eleven': 11,
  'eleventh': 11,
  'twelve': 12,
  'twelfth': 12,
};

int _count(String quantity) {
  final norm = quantity.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  if (_wordNumbers[norm] case final v?) return v;
  return int.parse(norm.replaceFirst(RegExp(r'(?:st|nd|rd|th)$'), ''));
}

int? _partMinutes(String? part) => switch (part?.toLowerCase()) {
  'morning' => 9 * 60,
  'afternoon' => 14 * 60,
  'evening' => 18 * 60,
  'night' => 20 * 60,
  _ => null,
};

const _prefix = r',?\s+(?:due\s+)?(?:(?:on|by)\s+)?';
const _optPart = r'(?:\s+(morning|afternoon|evening))?';

RegExp _suffix(String pattern) => RegExp('$pattern[.,!?]?\$', caseSensitive: false);

final _relative = _suffix(
  '$_prefix(today|tomorrow|tmrw?|tonight|next week|next month|next weekend|this weekend|on the weekend|the day after tomorrow|day after tomorrow|in ($_quantity) (days?|weeks?|fortnights?|months?)|(?:this|in the) (morning|afternoon|evening))$_optPart',
);
final _weekdayDate = _suffix('$_prefix(?:(next|this(?:\\s+coming)?)\\s+)?($_weekday)(?: (?:the )?$_ordinal)?$_optPart');
final _bareThreeLetterWeekday = RegExp(r'^(mon|tue|wed|thu|fri|sat|sun)$', caseSensitive: false);
final _weekdayDatePreposition = RegExp(
  r'(?:^|\b(?:on|by|due|next|this|before|after|until|through))\s*$',
  caseSensitive: false,
);
final _datePreposition = RegExp(r'\b(?:on|by|due|before|after|until|through|starting)\s*$', caseSensitive: false);
final _ordinalDate = _suffix(r',?\s+(?:(?:due\s+)?(?:on\s+)?the\s+|(?:due|on)\s+)(\d{1,2})(?:st|nd|rd|th)' + _optPart);
final _namedDate = _suffix('$_prefix(?:$_ordinal (?:of )?($_month)|($_month) $_ordinal)(?:,? (\\d{4}))?$_optPart');
final _numericDate = _suffix('$_prefix(\\d{1,2})/(\\d{1,2})(?:/(\\d{4}))?$_optPart');

// Clock bodies: supports 12h colon/dot with am/pm, 24h colon, named times, and 24h dot with connector.
const _clockCoreBare =
    r'(?:(?:1[0-2]|0?[1-9])(?:[:.][0-5]\d)?\s*[ap]\.?m\.?(?![a-z0-9])|(?:[01]?\d|2[0-3]):[0-5]\d(?![a-z0-9:])|(?:noon|midday|midnight)|(?:[01]?\d|2[0-3])\.[0-5]\d(?![a-z0-9.]))';
const _clockCore =
    r'(?:(?<h12>1[0-2]|0?[1-9])(?:[:.](?<m12>[0-5]\d))?\s*(?<ap>[ap])\.?m\.?(?![a-z0-9])|(?<h24>[01]?\d|2[0-3]):(?<m24>[0-5]\d)(?![a-z0-9:])|(?<named>noon|midday|midnight)|(?<hd24>[01]?\d|2[0-3])\.(?<md24>[0-5]\d)(?![a-z0-9.]))';
final _clock = _suffix(r',?\s+(?:(?:due\s+)?(?:at|by)\s+)?' + _clockCore);
final _rangeStart = RegExp(
  r'\s+(?<prep>from|between)\s+(?<first>' + _clockCoreBare + r')\s+(?<join>to|and)[.,!?]?$',
  caseSensitive: false,
);
final _clockConnector = RegExp(r'^(?:due\s+)?(?:at|by)\b', caseSensitive: false);
final _rangePreposition = RegExp(
  r'(?:\b(?:from|between|before|after|past|to|until|through)|\bbetween\b[^,;.!?]*\band)\s*$',
  caseSensitive: false,
);
final _nonClockColonPrefix = RegExp(
  r'\b(?:romans|genesis|exodus|leviticus|numbers|deuteronomy|joshua|judges|ruth|samuel|kings|chronicles|ezra|nehemiah|esther|job|psalms?|proverbs|ecclesiastes|isaiah|jeremiah|lamentations|ezekiel|daniel|hosea|joel|amos|obadiah|jonah|micah|nahum|habakkuk|zephaniah|haggai|zechariah|malachi|matthew|mark|luke|john|acts|corinthians|galatians|ephesians|philippians|colossians|thessalonians|timothy|titus|philemon|hebrews|james|peter|jude|revelation|chapter|verse|ratio|ch\.|v\.)\s*$',
  caseSensitive: false,
);

const _remEnd = r'(?:beforehand|before|early|prior|on\s+the\s+day|that\s+morning|on\s+the\s+morning)';
final _reminder = _suffix(
  r',?\s+(?:(?:and|,)\s+)?(?:remind\s+me|reminder|alert\s+me)\s+(.*?\b' + _remEnd + r')',
);

const _weekdayPlural = r'mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays';
const _weekdayListSep = r'(?:\s*/\s*|,\s*(?:and\s+)?|\s+and\s+)';
const _repeatWeekdaysBody =
    '(?:every\\s+(?:(?<every>$_ordInterval)\\s+)?(?<list>(?:$_weekday)(?:$_weekdayListSep(?:$_weekday))*)'
    '|on\\s+(?:(?<list2>(?:$_weekday)(?:$_weekdayListSep(?:$_weekday))+)|(?<list3>(?:$_weekdayPlural)(?:$_weekdayListSep(?:$_weekdayPlural))*)))';
final _repeatWeekdays = _suffix(r'\s+' + _repeatWeekdaysBody);
final _repeatWeekends = _suffix(r',?\s+(?:every\s+weekends?|on\s+weekends|on\s+weekdays)');
final _dayOfMonthRepeat = _suffix(
  r',?\s+(?:(?:on\s+)?the\s+' +
      _dayOrd +
      r'\s+of\s+(?:every|each)\s+month|(?:monthly|every\s+month)\s+(?:on\s+)?(?:the\s+)?' +
      _dayOrd +
      r'|(?:on\s+)?every\s+' +
      _dayOrd +
      r')',
);
final _frequency = _suffix(r'\s+(daily|weekly|fortnightly|monthly|yearly|annually)');
final _incompleteSchedule = RegExp(r'\b(?:until|starting|every(?: other| second)?|of|except)$', caseSensitive: false);
final _interval = _suffix(
  r'\s+every\s+(?:(?<q>' +
      _ordInterval +
      r')\s+)?(?<u>weekdays?|days?|weeks?|fortnights?|months?|years?|mornings?|afternoons?|evenings?|nights?)',
);
final _durationTail = _suffix(r',?\s+for\s+(' + _quantity + r')\s+(days?|weeks?|fortnights?|months?|years?)');
final _until = RegExp(r'\s+(?:until|through)$', caseSensitive: false);
final _start = RegExp(r'\s+starting$', caseSensitive: false);
final _place = RegExp(r'\s+@([^@]+)$');

// Clock and calendar suffixes get first choice of "at" and "in".
final _placeIntro = RegExp(r'\s+(at|in)\s+', caseSensitive: false);
final _venue = RegExp(
  r"\b(place|home|work|school|uni|gym|office|library|clinic|hospital|surgery|pharmacy|chemist|station|airport|park|pool|court|courts|oval|track|stadium|café|cafe|restaurant|pub|bar|bakery|butcher|bank|post office|cinema|theatre|theater|museum|club|dentist|doctor|doctors|gp|vet|physio|optometrist|barber|hairdresser|salon|mechanic|garage|studio|shop|store|market|supermarket|hall|room|centre|center|beach|hotel|campus|depot|warehouse|house|flat|apartment|street|road|avenue|lane|drive|terrace|square|coles|woolworths|aldi|bunnings)\b",
  caseSensitive: false,
);
final _placeWords = RegExp(r"^[\p{L}\p{N}][\p{L}\p{M}\p{N} ’'&,./-]*$", unicode: true);
final _nonPlace = RegExp(
  r'\b(?:remind me|starting|until|tomorrow|today|tonight|every|minutes?|hours?|days?|weeks?|months?|weekend|least|most|once|first|last|risk|heart|hand|mind|progress|advance|detail|general|person|writing|morning|afternoon|evening)\b|\d\s*(?:am|pm)\b',
  caseSensitive: false,
);
final _objectOfAt = RegExp(
  r'\b(?:look|looking|glance|stare|aim|laugh|smile|point|hint|good|bad|excel)\s*$',
  caseSensitive: false,
);

final _namedPlace = RegExp(
  r"^(?:[\p{Lu}][\p{L}\p{M}’'-]*|\d+)(?:\s+(?:[\p{Lu}][\p{L}\p{M}’'-]*|of|the|and|\d+))*$",
  unicode: true,
);
final _singleAcronym = RegExp(r'^[\p{Lu}]{2,}$', unicode: true);
final _addressLetter = RegExp(r'\p{L}', unicode: true);
final _placeContext = RegExp(
  r'\b(?:meet|dinner|lunch|breakfast|appointment|arrive|shop|pickup|training|workout)\b',
  caseSensitive: false,
);
final _singlePlaceWord = RegExp(r"^[\p{L}][\p{L}’'-]*$", unicode: true);

final _birthdayWord = RegExp(r'\b(?:birthday|bday|b-day)\b', caseSensitive: false);
final _birthdayLead = RegExp(r'^birthday\s*(?:[:\-–—]|for)\s+(.+)$', caseSensitive: false);
final _birthdayActionLead = RegExp(
  r'^(?:buy|get|order|bake|make|wrap|pick\s+up|send|write|plan|book|organise|organize|find|shop|deliver|return|cancel|bring|prepare|decorate|check|confirm|rsvp|wish|celebrate|attend|host|throw|post|drop\s+off|collect)\b',
  caseSensitive: false,
);
final _birthdayEventOrGift = RegExp(
  r'\b(?:cake|cards?|gifts?|presents?|party|dinner|lunch|brunch|breakfast|drinks|bash|surprise|decorations|balloons|invitations?|invites|shopping|list|message|text|email|call|video|song|flowers|voucher)\b',
  caseSensitive: false,
);

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

DateTime _addMonths(DateTime d, int months) {
  final first = DateTime(d.year, d.month + months, 1);
  return DateTime(first.year, first.month, math.min(d.day, daysInMonth(first.year, first.month)));
}

DateTime _nextDayOfMonth(DateTime anchor, int dom) {
  final d1 = math.min(dom, daysInMonth(anchor.year, anchor.month));
  if (anchor.day <= d1) return DateTime(anchor.year, anchor.month, d1);
  final next = DateTime(anchor.year, anchor.month + 1, 1);
  return DateTime(next.year, next.month, math.min(dom, daysInMonth(next.year, next.month)));
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

({RegExpMatch match, DateTime? day, int? partMinutes})? _readDay(String text, DateTime today) {
  RegExpMatch? match;
  DateTime? day;
  int? partMinutes;
  if ((match = _relative.firstMatch(text)) != null) {
    final m = match!;
    final word = m[1]!.toLowerCase();
    partMinutes = _partMinutes(m[5]);
    if (m[4] != null) {
      partMinutes ??= _partMinutes(m[4]);
      if (word.startsWith('this')) {
        day = today;
      } else {
        // "in the morning/afternoon/evening" gives time of day; date can still be absent or supplied elsewhere.
        day = null;
      }
    } else if (word == 'tonight') {
      day = today;
      partMinutes ??= 19 * 60;
    } else if (word == 'this weekend' || word == 'on the weekend') {
      day = today.weekday >= DateTime.saturday
          ? today
          : DateTime(today.year, today.month, today.day + (DateTime.saturday - today.weekday));
    } else if (word == 'next weekend') {
      final offset = DateTime.saturday - today.weekday + 7;
      day = DateTime(today.year, today.month, today.day + offset);
    } else if (word == 'next month') {
      day = DateTime(today.year, today.month + 1, 1);
    } else if (m[2] != null && m[3] != null) {
      final n = _count(m[2]!);
      if (n < 1) return (match: m, day: null, partMinutes: null);
      final unit = m[3]!.toLowerCase();
      if (unit.startsWith('month')) {
        day = _addMonths(today, n);
      } else {
        final mult = unit.startsWith('week') ? 7 : (unit.startsWith('fortnight') ? 14 : 1);
        day = DateTime(today.year, today.month, today.day + n * mult);
      }
    } else {
      final offset = switch (word) {
        'today' => 0,
        'tomorrow' || 'tmr' || 'tmrw' => 1,
        'next week' => 7,
        'the day after tomorrow' || 'day after tomorrow' => 2,
        _ => 0,
      };
      day = DateTime(today.year, today.month, today.day + offset);
    }
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
    partMinutes = _partMinutes(m[4]);
    if (m[3] != null) {
      day = _nextDate(today, int.parse(m[3]!), weekday: weekday);
    } else {
      var offset = (weekday - today.weekday) % 7;
      final mod = m[1]?.toLowerCase();
      if (mod == 'next') offset = 7 - today.weekday + weekday;
      day = DateTime(today.year, today.month, today.day + offset);
    }
  } else if ((match = _namedDate.firstMatch(text)) != null) {
    final m = match!;
    final month = _months.indexOf((m[2] ?? m[3])!.substring(0, 3).toLowerCase()) + 1;
    day = _nextDate(today, int.parse((m[1] ?? m[4])!), month: month, year: int.tryParse(m[5] ?? ''));
    partMinutes = _partMinutes(m[6]);
  } else if ((match = _numericDate.firstMatch(text)) != null) {
    final m = match!;
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    if (m[3] == null &&
        a <= 4 &&
        b <= 4 &&
        !_datePreposition.hasMatch(text.substring(0, m.start) + m[0]!.split(RegExp(r'\d')).first)) {
      return null;
    }
    day = _nextDate(today, a, month: b, year: int.tryParse(m[3] ?? ''));
    partMinutes = _partMinutes(m[4]);
  } else if ((match = _ordinalDate.firstMatch(text)) != null) {
    day = _nextDate(today, int.parse(match![1]!));
    partMinutes = _partMinutes(match[2]);
  } else {
    return null;
  }
  return (match: match, day: day, partMinutes: partMinutes);
}

int? _clockMinutes(RegExpMatch m) {
  if (m.namedGroup('h12') case final h?) {
    return (int.parse(h) % 12 + (m.namedGroup('ap')!.toLowerCase() == 'p' ? 12 : 0)) * 60 +
        int.parse(m.namedGroup('m12') ?? '0');
  }
  if (m.namedGroup('h24') case final h?) {
    return int.parse(h) * 60 + int.parse(m.namedGroup('m24')!);
  }
  if (m.namedGroup('hd24') case final h?) {
    return int.parse(h) * 60 + int.parse(m.namedGroup('md24')!);
  }
  return switch (m.namedGroup('named')?.toLowerCase()) {
    'noon' || 'midday' => 720,
    'midnight' => 0,
    _ => null,
  };
}

int? _parseReminderOffsets(String rawBody) {
  var body = rawBody.trim().replaceFirst(RegExp(r'[.,!?]+$'), '');
  final trailingBefore = RegExp(r'\s+(?:beforehand|before|early|prior)$', caseSensitive: false).hasMatch(body);
  final parts = body.split(RegExp(r'\s*(?:,\s*(?:(?:and|&)\s+)?|\s+(?:and|&)\s+)\s*', caseSensitive: false));
  if (parts.isEmpty) return null;

  var bits = 0;
  for (final rawPart in parts) {
    var p = rawPart.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (p == 'on the day' || p == 'that morning' || p == 'on the morning') {
      bits |= Reminder.onTheDay.bit;
      continue;
    }
    final ownBefore = RegExp(r'\s+(?:beforehand|before|early|prior)$').hasMatch(p);
    if (!ownBefore && !trailingBefore) return null;
    p = p.replaceFirst(RegExp(r'\s+(?:beforehand|before|early|prior)$'), '');
    final bit = switch (p) {
      '15m' ||
      '15 min' ||
      '15 mins' ||
      '15 minute' ||
      '15 minutes' ||
      'quarter hour' ||
      'a quarter hour' ||
      'quarter of an hour' ||
      'a quarter of an hour' => Reminder.quarterBefore.bit,
      '20m' || '20 min' || '20 mins' || '20 minute' || '20 minutes' => Reminder.twentyBefore.bit,
      '1h' || '1hr' || '1 hr' || '1 hour' || 'an hour' || '60m' || '60 min' || '60 mins' || '60 minutes' =>
        Reminder.hourBefore.bit,
      '1d' || '1 day' || 'a day' || 'the day' || '24h' || '24hr' || '24 hr' || '24 hour' || '24 hours' =>
        Reminder.dayBefore.bit,
      _ => null,
    };
    if (bit == null) return null;
    bits |= bit;
  }
  return bits == 0 ? null : bits;
}

({int count, String unit})? _parseDuration(String countRaw, String unitRaw) {
  final n = _count(countRaw);
  if (n < 1 || n > 1000) return null;
  final u = unitRaw.toLowerCase().replaceFirst(RegExp(r's$'), '');
  return (count: n, unit: u);
}

DateTime _applyDuration(DateTime start, ({int count, String unit}) dur) => switch (dur.unit) {
  'day' => DateTime(start.year, start.month, start.day + dur.count - 1),
  'week' => DateTime(start.year, start.month, start.day + dur.count * 7 - 1),
  'fortnight' => DateTime(start.year, start.month, start.day + dur.count * 14 - 1),
  'month' => () {
    final end = _addMonths(start, dur.count);
    return DateTime(end.year, end.month, end.day - 1);
  }(),
  _ => DateTime(start.year + dur.count, start.month, start.day - 1),
};

String _spliceOut(String s, int start, int end) {
  var left = s.substring(0, start).trimRight();
  var right = s.substring(end).trimLeft();
  left = left.replaceFirst(RegExp(r'\s*[,;]\s*$'), '');
  if (left.isNotEmpty && right.isNotEmpty) {
    right = right.replaceFirst(RegExp(r'^[,;]\s*'), '');
    if (RegExp(r'^[-–—]\s+').hasMatch(right) && !RegExp(r'[-–—]$').hasMatch(left)) {
      right = right.replaceFirst(RegExp(r'^[-–—]\s+'), '');
    }
    return '$left $right'.trim();
  }
  return '$left$right'.trim();
}

const _ordNc = r'\d{1,2}(?:st|nd|rd|th)?';
const _dayOrdNc = r'\d{1,2}(?:st|nd|rd|th)';
const _anyDateBody =
    '(?:today|tomorrow|tmrw?|tonight|next week|next month|next weekend|this weekend|on the weekend|the day after tomorrow|day after tomorrow'
    '|in (?:$_quantity) (?:days?|weeks?|fortnights?|months?)'
    '|(?:(?:next|this(?:\\s+coming)?)\\s+)?(?:$_weekday)(?:\\s+(?:the\\s+)?$_ordNc)?'
    '|(?:$_ordNc (?:of )?(?:$_month)|(?:$_month) $_ordNc)(?:,? \\d{4})?'
    '|\\d{1,2}/\\d{1,2}(?:/\\d{4})?'
    '|(?:the\\s+)?$_dayOrdNc)';

final _leadSep = RegExp(r'^[\s,:;\-–—]+');
final _leadClock = RegExp(r'^(?:(?:due\s+)?(?:at|by)\s+)?' + _clockCore + r'(?=[\s,:;\-–—]|$)', caseSensitive: false);
final _leadRange = RegExp(
  r'^(?<prep>from|between)\s+(?<first>'
      '$_clockCoreBare'
      r')\s+(?<join>to|and)\s+(?<second>'
      '$_clockCoreBare'
      r')(?=[\s,:;\-–—])',
  caseSensitive: false,
);
final _leadReminder = RegExp(
  r'^(?:remind\s+me|reminder|alert\s+me)\s+((?:(?!\bremind\b).)*?\b'
      r'(?:(?:beforehand|before|early|prior)(?:\s*(?:,|and|&)\s*(?:on\s+the\s+day|that\s+morning|on\s+the\s+morning))?|on\s+the\s+day|that\s+morning|on\s+the\s+morning)'
      r')\b(?:\s*[,;:\-–—]\s*|\s+)',
  caseSensitive: false,
);
final _leadRepeatWeekdays = RegExp(
  '^$_repeatWeekdaysBody' r'(?=\s*[,;:\-–—]|\s+)',
  caseSensitive: false,
);
final _leadRepeatWeekends = RegExp(
  r'^(?:every\s+weekends?|on\s+weekends|on\s+weekdays)(?=\s*[,;:\-–—]|\s+)',
  caseSensitive: false,
);
final _leadInterval = RegExp(
  r'^every\s+(?:(?<q>' +
      _ordInterval +
      r')\s+)?(?<u>weekdays?|days?|weeks?|fortnights?|months?|years?|mornings?|afternoons?|evenings?|nights?)(?=\s*[,;:\-–—]|\s+)',
  caseSensitive: false,
);
final _leadDayOfMonth = RegExp(
  r'^(?:(?:on\s+)?the\s+' +
      _dayOrd +
      r'\s+of\s+(?:every|each)\s+month|(?:monthly|every\s+month)\s+(?:on\s+)?(?:the\s+)?' +
      _dayOrd +
      r'|(?:on\s+)?every\s+' +
      _dayOrd +
      r'(?!\s+(?:' +
      _weekday +
      r'|days?|weeks?|fortnights?|months?|years?)\b))(?=\s*[,;:\-–—]|\s+)',
  caseSensitive: false,
);
final _leadFrequency = RegExp(
  r'^(daily|weekly|fortnightly|monthly|yearly|annually)(?=\s*[,;:\-–—])',
  caseSensitive: false,
);
final _leadStart = RegExp(r'^starting\s+(?<d>' + _anyDateBody + r')(?=\s*[,;:\-–—]|\s+)', caseSensitive: false);
final _leadUntil = RegExp(r'^(?:until|through)\s+(?<d>' + _anyDateBody + r')(?=\s*[,;:\-–—]|\s+)', caseSensitive: false);
final _leadPlace = RegExp(r'^@([^\s,;:]+)(?:\s*[,;:\-–—]\s*|\s+)');

// Leading date expressions (must have task content following).
final _leadRelative = RegExp(
  r'^(?:on\s+|by\s+|due\s+)?(today|tomorrow|tmrw?|tonight|next week|next month|next weekend|this weekend|on the weekend|the day after tomorrow|day after tomorrow|in (' +
      _quantity +
      r') (days?|weeks?|fortnights?|months?)|(?:this|in the) (morning|afternoon|evening))' +
      _optPart +
      r'(?=\s*[,;:\-–—]|\s+)',
  caseSensitive: false,
);
final _leadWeekday = RegExp(
  r'^(?:(on|by|due)\s+)?(?:(next|this(?:\s+coming)?)\s+)?(' +
      _weekday +
      r')(?:\s+(?:the\s+)?' +
      _ordinal +
      r')?' +
      _optPart +
      r'(?=\s*[,;:\-–—]|\s+)',
  caseSensitive: false,
);
final _leadNamedDate = RegExp(
  r'^(?:(?:on|by|due)\s+)?(?:' +
      _ordinal +
      r' (?:of )?(' +
      _month +
      r')|(' +
      _month +
      r') ' +
      _ordinal +
      r')(?:,? (\d{4}))?' +
      _optPart +
      r'(?=\s*[,;:\-–—]|\s+)',
  caseSensitive: false,
);
final _leadNumericDate = RegExp(
  r'^(?:(?:on|by|due)\s+)?(\d{1,2})/(\d{1,2})(?:/(\d{4}))?' + _optPart + r'(?=\s*[,;:\-–—]|\s+)',
  caseSensitive: false,
);
final _leadOrdinalDate = RegExp(
  r'^(?:(?:due\s+)?(?:on\s+)?the\s+|(?:due|on)\s+)(\d{1,2})(?:st|nd|rd|th)' + _optPart + r'(?=\s*[,;:\-–—]|\s+)',
  caseSensitive: false,
);

// Middle-of-sentence high-confidence extractors.
final _midReminder = RegExp(
  r'\s+(?:(?:and|,)\s+)?(?:remind\s+me|reminder|alert\s+me)\s+((?:(?!\bremind\b).)*?\b'
      r'(?:(?:beforehand|before|early|prior)(?:\s*(?:,|and|&)\s*(?:on\s+the\s+day|that\s+morning|on\s+the\s+morning))?|on\s+the\s+day|that\s+morning|on\s+the\s+morning)'
      r')(?=\s*[,;.]|\s+|$)',
  caseSensitive: false,
);
final _midPlace = RegExp(r'(?<=\s)@([^\s,;@]+)(?=\s*[,;.]|\s|$)');
final _midRepeatWeekdays = RegExp(
  r'\s+' '$_repeatWeekdaysBody' r'(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midRepeatWeekends = RegExp(
  r'\s+(?:every\s+weekends?|on\s+weekends|on\s+weekdays)(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midInterval = RegExp(
  r'\s+every\s+(?:(?<q>' +
      _ordInterval +
      r')\s+)?(?<u>weekdays?|days?|weeks?|fortnights?|months?|years?|mornings?|afternoons?|evenings?|nights?)(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midDayOfMonth = RegExp(
  r'\s+(?:(?:on\s+)?the\s+' +
      _dayOrd +
      r'\s+of\s+(?:every|each)\s+month|(?:monthly|every\s+month)\s+(?:on\s+)?(?:the\s+)?' +
      _dayOrd +
      r'|(?:on\s+)?every\s+' +
      _dayOrd +
      r'(?!\s+(?:' +
      _weekday +
      r'|days?|weeks?|fortnights?|months?|years?)\b))(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midStart = RegExp(r'\s+starting\s+(?<d>' + _anyDateBody + r')(?=\s*[,;.]|\s|$)', caseSensitive: false);
final _midUntil = RegExp(r'\s+(?:until|through)\s+(?<d>' + _anyDateBody + r')(?=\s*[,;.]|\s|$)', caseSensitive: false);
final _midRange = RegExp(
  r'\s+(?<prep>from|between)\s+(?<first>' +
      _clockCoreBare +
      r')\s+(?<join>to|and)\s+(?<second>' +
      _clockCoreBare +
      r')(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midClock = RegExp(
  r'\s+(?<conn>(?:due\s+)?(?:at|by)\s+)?' + _clockCore + r'(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midRelative = RegExp(
  r'\s+(?:(?:on|by|due)\s+)?(today|tomorrow|tmrw?|tonight|next week|next month|next weekend|this weekend|on the weekend|the day after tomorrow|day after tomorrow|in (' +
      _quantity +
      r') (days?|weeks?|fortnights?|months?)|(?:this|in the) (morning|afternoon|evening))' +
      _optPart +
      r'(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midWeekday = RegExp(
  r'\s+(?:(?<prep>on|by|due)\s+|(?<mod>next|this(?:\s+coming)?)\s+)(?<wd>' +
      _weekday +
      r')(?:\s+(?:the\s+)?' +
      _ordinal +
      r')?' +
      _optPart +
      r'(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midFullWeekday = RegExp(
  r'\s+(?<wd>' + _fullWeekday + r')(?:\s+(?:the\s+)?' + _ordinal + r')?' + _optPart + r'(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midNamedDate = RegExp(
  r'\s+(?:(?:on|by|due)\s+)?(?:' +
      _ordinal +
      r' (?:of )?(' +
      _month +
      r')|(' +
      _month +
      r') ' +
      _ordinal +
      r')(?:,? (\d{4}))?' +
      _optPart +
      r'(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midNumericDate = RegExp(
  r'\s+(?:(?:on|by|due)\s+)(\d{1,2})/(\d{1,2})(?:/(\d{4}))?' + _optPart + r'(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);
final _midDuration = RegExp(
  r'\s+for\s+(' + _quantity + r')\s+(days?|weeks?|fortnights?|months?|years?)(?=\s*[,;.]|\s|$)',
  caseSensitive: false,
);

final _bareMidWord = RegExp(r'^\s+(?:today|tomorrow|tmrw?)$', caseSensitive: false);
final _midBoundaryRight = RegExp(
  r'^\s*(?:[,;.]|$|\b(?:about|regarding|re|for|with|before|after|around|at|in|on|from|to|until|through|so|then|because|and)\b)',
  caseSensitive: false,
);

bool _midClauseBoundary(String text, int start, int end) =>
    text.substring(0, start).trimRight().endsWith(',') || _midBoundaryRight.hasMatch(text.substring(end));

/// Extracts title, day, time, location, repeat rules, reminders and birthdays
/// from natural language task entry across tail, leading and middle positions.
QuickTask parseQuickTask(String raw, DateTime today, {DateTime? defaultDay, int? defaultTime}) =>
    _parseInternal(raw, today, defaultDay: defaultDay, defaultTime: defaultTime, allowDuration: true);

QuickTask _parseInternal(
  String raw,
  DateTime today, {
  DateTime? defaultDay,
  int? defaultTime,
  required bool allowDuration,
}) {
  var text = raw.trim();
  if (text.isEmpty) return _plain(text);
  final startedUpper = RegExp(r'^[\p{Lu}]', unicode: true).hasMatch(text);
  today = DateTime(today.year, today.month, today.day);
  final literal = _plain(text);

  DateTime? day;
  int? explicitMinutes;
  int? partMinutes;
  String? location, endPhrase;
  DateTime? until;
  RepeatRule? repeat;
  int? anchorWeekday;
  var reminders = 0;
  ({int count, String unit})? durationSpec;
  var durationWasUsed = false;
  var peeledLead = false;

  bool isValidDayOfMonth(int dom) => dom >= 1 && dom <= 31;

  bool parseWeekdayRepeatMatch(String? everyRaw, String listRaw) {
    final weekdays = RegExp(
      _weekday,
      caseSensitive: false,
    ).allMatches(listRaw).map((word) => _weekdays.indexOf(word[0]!.substring(0, 3).toLowerCase()) + 1).toSet();
    if (weekdays.isEmpty) return false;
    if (everyRaw == null) {
      repeat = RepeatRule.weekly(weekdays);
      return true;
    }
    if (weekdays.length != 1) return false;
    final n = _count(everyRaw);
    if (n < 1 || n > 1000) return false;
    anchorWeekday = weekdays.single;
    repeat = RepeatRule.every(n, weeks: true);
    return true;
  }

  bool parseIntervalMatch(String? qRaw, String unitRaw) {
    final n = qRaw == null ? 1 : _count(qRaw);
    if (n < 1 || n > 1000) return false;
    final unit = unitRaw.toLowerCase().replaceFirst(RegExp(r's$'), '');
    switch (unit) {
      case 'morning':
      case 'afternoon':
      case 'evening':
      case 'night':
        if (n != 1) return false;
        repeat = const RepeatRule.every(1);
        partMinutes ??= _partMinutes(unit);
        return true;
      case 'weekday':
        if (n != 1) return false;
        repeat = const RepeatRule.weekly({1, 2, 3, 4, 5});
        return true;
      case 'week':
        repeat = RepeatRule.every(n, weeks: true);
        return true;
      case 'fortnight':
        repeat = RepeatRule.every(2 * n, weeks: true);
        return true;
      case 'month':
        repeat = RepeatRule.months(n);
        return true;
      case 'year':
        repeat = RepeatRule.yearly(n);
        return true;
      default:
        repeat = RepeatRule.every(n);
        return true;
    }
  }

  // Pass 1: peel scheduling clauses from the tail (preserves all tail permutations).
  bool runTailPass() {
    while (true) {
      final hadDay = day != null;
      RegExpMatch? match;
      if ((match = _reminder.firstMatch(text)) != null) {
        final bits = _parseReminderOffsets(match![1]!);
        if (bits == null) return false;
        reminders |= bits;
      } else if (allowDuration && durationSpec == null && (match = _durationTail.firstMatch(text)) != null) {
        final parsed = _parseDuration(match![1]!, match[2]!);
        if (parsed == null) return false;
        durationSpec = parsed;
        durationWasUsed = true;
      } else if (repeat == null && (match = _repeatWeekdays.firstMatch(text)) != null) {
        final m = match!;
        final list = (m.namedGroup('list') ?? m.namedGroup('list2') ?? m.namedGroup('list3'))!;
        if (!parseWeekdayRepeatMatch(m.namedGroup('every'), list)) return false;
      } else if (repeat == null && (match = _repeatWeekends.firstMatch(text)) != null) {
        repeat = match![0]!.toLowerCase().contains('weekday')
            ? const RepeatRule.weekly({1, 2, 3, 4, 5})
            : const RepeatRule.weekly({DateTime.saturday, DateTime.sunday});
      } else if (repeat == null && (match = _dayOfMonthRepeat.firstMatch(text)) != null) {
        final m = match!;
        final dom = int.parse((m[1] ?? m[2] ?? m[3])!);
        if (!isValidDayOfMonth(dom)) return false;
        repeat = RepeatRule.monthly(dom);
      } else if (repeat == null && (match = _interval.firstMatch(text)) != null) {
        final m = match!;
        if (!parseIntervalMatch(m.namedGroup('q'), m.namedGroup('u')!)) return false;
      } else if (repeat == null && (match = _frequency.firstMatch(text)) != null) {
        repeat = switch (match![1]!.toLowerCase()) {
          'daily' => const RepeatRule.every(1),
          'weekly' => const RepeatRule.every(1, weeks: true),
          'fortnightly' => const RepeatRule.every(2, weeks: true),
          'monthly' => const RepeatRule.months(1),
          _ => const RepeatRule.yearly(1),
        };
      } else if (explicitMinutes == null && (match = _clock.firstMatch(text)) != null) {
        final m = match!;
        final before = text.substring(0, m.start);
        final range = _rangeStart.firstMatch(before);
        if (range != null &&
            (range.namedGroup('prep')!.toLowerCase() == 'between') ==
                (range.namedGroup('join')!.toLowerCase() == 'and')) {
          text = '${before.substring(0, range.start)} at ${range.namedGroup('first')}';
          continue;
        }
        final trimmed = m[0]!.trimLeft();
        final hasConnector = _clockConnector.hasMatch(trimmed);
        final isDot24 = m.namedGroup('hd24') != null;
        if (!hasConnector &&
            (_rangePreposition.hasMatch(before) ||
                (m.namedGroup('h24') != null && _nonClockColonPrefix.hasMatch(before)) ||
                m.namedGroup('named') != null ||
                isDot24)) {
          final place = location == null ? _spokenPlace(text) : null;
          if (place != null) {
            location = place.location;
            text = text.substring(0, place.start).trimRight();
            continue;
          }
          break;
        }
        explicitMinutes = _clockMinutes(m);
        if (explicitMinutes == null) return false;
      } else if (_readDay(text, today) case final found?) {
        match = found.match;
        final prefix = text.substring(0, match.start).trimRight();
        if (_until.hasMatch(prefix)) {
          if (endPhrase != null) return false;
          endPhrase = match[0]!;
          text = prefix.replaceFirst(_until, '');
          partMinutes ??= found.partMinutes;
          continue;
        }
        if (found.partMinutes != null && found.day == null) {
          partMinutes ??= found.partMinutes;
        } else {
          if (day != null || found.day == null) return false;
          day = found.day;
          partMinutes ??= found.partMinutes;
        }
      } else if (location == null && (match = _place.firstMatch(text)) != null) {
        location = match![1]!.trim();
        if (location!.isEmpty || RegExp(r'\bremind me\b', caseSensitive: false).hasMatch(location!)) return false;
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
    return true;
  }

  if (!runTailPass()) return literal;
  if ((day != null || repeat != null) && _incompleteSchedule.hasMatch(text)) return literal;

  // Pass 2: peel unambiguous scheduling clauses from the start when content remains after them.
  while (text.isNotEmpty) {
    final beforePass = text;
    RegExpMatch? match;
    if ((match = _leadReminder.firstMatch(text)) != null) {
      final rest = text.substring(match!.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      final bits = _parseReminderOffsets(match[1]!);
      if (bits == null) return literal;
      reminders |= bits;
      text = rest;
      peeledLead = true;
    } else if (repeat == null && (match = _leadRepeatWeekdays.firstMatch(text)) != null) {
      final m = match!;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      final list = (m.namedGroup('list') ?? m.namedGroup('list2') ?? m.namedGroup('list3'))!;
      if (!parseWeekdayRepeatMatch(m.namedGroup('every'), list)) return literal;
      text = rest;
      peeledLead = true;
    } else if (repeat == null && (match = _leadRepeatWeekends.firstMatch(text)) != null) {
      final m = match!;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      repeat = m[0]!.toLowerCase().contains('weekday')
          ? const RepeatRule.weekly({1, 2, 3, 4, 5})
          : const RepeatRule.weekly({DateTime.saturday, DateTime.sunday});
      text = rest;
      peeledLead = true;
    } else if (repeat == null && (match = _leadDayOfMonth.firstMatch(text)) != null) {
      final m = match!;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      final dom = int.parse((m[1] ?? m[2] ?? m[3])!);
      if (!isValidDayOfMonth(dom)) return literal;
      repeat = RepeatRule.monthly(dom);
      text = rest;
      peeledLead = true;
    } else if (repeat == null && (match = _leadInterval.firstMatch(text)) != null) {
      final m = match!;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      if (!parseIntervalMatch(m.namedGroup('q'), m.namedGroup('u')!)) return literal;
      text = rest;
      peeledLead = true;
    } else if (repeat == null && (match = _leadFrequency.firstMatch(text)) != null) {
      final m = match!;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      repeat = switch (m[1]!.toLowerCase()) {
        'daily' => const RepeatRule.every(1),
        'weekly' => const RepeatRule.every(1, weeks: true),
        'fortnightly' => const RepeatRule.every(2, weeks: true),
        'monthly' => const RepeatRule.months(1),
        _ => const RepeatRule.yearly(1),
      };
      text = rest;
      peeledLead = true;
    } else if (day == null && (match = _leadStart.firstMatch(text)) != null) {
      final m = match!;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      final d = m.namedGroup('d')!;
      if (d.toLowerCase() == 'next week') {
        day = DateTime(today.year, today.month, today.day + 8 - today.weekday);
      } else {
        final found = _readDay(' $d', today);
        if (found == null || found.day == null) return literal;
        day = found.day;
      }
      text = rest;
      peeledLead = true;
    } else if (endPhrase == null && (match = _leadUntil.firstMatch(text)) != null) {
      final m = match!;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      endPhrase = ' ${m.namedGroup('d')!}';
      text = rest;
      peeledLead = true;
    } else if (explicitMinutes == null &&
        (match = _leadRange.firstMatch(text)) != null &&
        (match!.namedGroup('prep')!.toLowerCase() == 'between') ==
            (match.namedGroup('join')!.toLowerCase() == 'and')) {
      final m = match;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      // Extract the first endpoint cleanly.
      final firstClock = RegExp('^$_clockCore', caseSensitive: false).firstMatch(m.namedGroup('first')!);
      if (firstClock == null) break;
      final parsedMin = _clockMinutes(firstClock);
      if (parsedMin == null) break;
      explicitMinutes = parsedMin;
      text = rest;
      peeledLead = true;
    } else if (explicitMinutes == null && (match = _leadClock.firstMatch(text)) != null) {
      final m = match!;
      final rawLead = text.substring(0, m.end).trimLeft();
      final hasConn = _clockConnector.hasMatch(rawLead);
      final isDot24 = m.namedGroup('hd24') != null;
      final isNamed = m.namedGroup('named') != null;
      final trailingText = text.substring(m.end);
      final hasPunctSep = RegExp(r'^\s*[,:]').hasMatch(trailingText);
      if (!hasConn && (isDot24 || (isNamed && !hasPunctSep) || (m.namedGroup('h24') != null && !hasPunctSep))) {
        break;
      }
      final rest = trailingText.replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      final parsedMin = _clockMinutes(m);
      if (parsedMin == null) break;
      explicitMinutes = parsedMin;
      text = rest;
      peeledLead = true;
    } else if (location == null && (match = _leadPlace.firstMatch(text)) != null) {
      final loc = match![1]!.trim();
      final rest = text.substring(match.end).trimLeft();
      if (loc.isEmpty || rest.isEmpty) break;
      location = loc;
      text = rest;
      peeledLead = true;
    } else if ((match = _leadRelative.firstMatch(text)) != null) {
      final m = match!;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      final found = _readDay(' ${m[0]!}', today);
      if (found == null) break;
      if (found.partMinutes != null && found.day == null) {
        partMinutes ??= found.partMinutes;
      } else {
        if (day != null || found.day == null) break;
        day = found.day;
        partMinutes ??= found.partMinutes;
      }
      text = rest;
      peeledLead = true;
    } else if ((match = _leadWeekday.firstMatch(text)) != null) {
      final m = match!;
      final wdToken = m[3]!;
      final hasPrepOrMod = m[1] != null || m[2] != null;
      final trailing = text.substring(m.end);
      final hasSepOrTime =
          RegExp(r'^\s*[,;:\-–—]').hasMatch(trailing) ||
          _leadClock.hasMatch(trailing.trimLeft());
      if (_bareThreeLetterWeekday.hasMatch(wdToken) && !hasPrepOrMod && !hasSepOrTime) {
        break;
      }
      final rest = trailing.replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      final found = _readDay(' ${m[0]!}', today);
      if (found == null || day != null || found.day == null) break;
      day = found.day;
      partMinutes ??= found.partMinutes;
      text = rest;
      peeledLead = true;
    } else if ((match = _leadNamedDate.firstMatch(text)) != null ||
        (match = _leadNumericDate.firstMatch(text)) != null ||
        (match = _leadOrdinalDate.firstMatch(text)) != null) {
      final m = match!;
      final rest = text.substring(m.end).replaceFirst(_leadSep, '').trimLeft();
      if (rest.isEmpty) break;
      final found = _readDay(' ${m[0]!}', today);
      if (found == null || day != null || found.day == null) break;
      day = found.day;
      partMinutes ??= found.partMinutes;
      text = rest;
      peeledLead = true;
    }
    if (text == beforePass) break;
  }

  // Pass 3: extract high-confidence mid-sentence scheduling clauses if still unset.
  while (true) {
    final beforeMid = text;
    RegExpMatch? m;
    if ((m = _midReminder.firstMatch(text)) != null) {
      final next = _spliceOut(text, m!.start, m.end);
      if (next.isEmpty) break;
      final bits = _parseReminderOffsets(m[1]!);
      if (bits == null) return literal;
      reminders |= bits;
      text = next;
      continue;
    }
    if (location == null && (m = _midPlace.firstMatch(text)) != null) {
      final loc = m![1]!.trim();
      final next = _spliceOut(text, m.start, m.end);
      if (loc.isNotEmpty && next.isNotEmpty && !RegExp(r'\bremind\b', caseSensitive: false).hasMatch(loc)) {
        location = loc;
        text = next;
        continue;
      }
    }
    if (allowDuration && durationSpec == null && (m = _midDuration.firstMatch(text)) != null) {
      final next = _spliceOut(text, m!.start, m.end);
      if (next.isNotEmpty) {
        final parsed = _parseDuration(m[1]!, m[2]!);
        if (parsed == null) return literal;
        durationSpec = parsed;
        durationWasUsed = true;
        text = next;
        continue;
      }
    }
    if (repeat == null && (m = _midRepeatWeekdays.firstMatch(text)) != null) {
      final next = _spliceOut(text, m!.start, m.end);
      final list = (m.namedGroup('list') ?? m.namedGroup('list2') ?? m.namedGroup('list3'))!;
      if (next.isNotEmpty && parseWeekdayRepeatMatch(m.namedGroup('every'), list)) {
        text = next;
        continue;
      }
    }
    if (repeat == null && (m = _midRepeatWeekends.firstMatch(text)) != null) {
      final next = _spliceOut(text, m!.start, m.end);
      if (next.isNotEmpty) {
        repeat = m[0]!.toLowerCase().contains('weekday')
            ? const RepeatRule.weekly({1, 2, 3, 4, 5})
            : const RepeatRule.weekly({DateTime.saturday, DateTime.sunday});
        text = next;
        continue;
      }
    }
    if (repeat == null && (m = _midDayOfMonth.firstMatch(text)) != null) {
      final next = _spliceOut(text, m!.start, m.end);
      final dom = int.parse((m[1] ?? m[2] ?? m[3])!);
      if (next.isNotEmpty && isValidDayOfMonth(dom)) {
        repeat = RepeatRule.monthly(dom);
        text = next;
        continue;
      }
    }
    if (repeat == null && (m = _midInterval.firstMatch(text)) != null) {
      final next = _spliceOut(text, m!.start, m.end);
      if (next.isNotEmpty && parseIntervalMatch(m.namedGroup('q'), m.namedGroup('u')!)) {
        text = next;
        continue;
      }
    }
    if (day == null && (m = _midStart.firstMatch(text)) != null) {
      final next = _spliceOut(text, m!.start, m.end);
      final d = m.namedGroup('d')!;
      if (next.isNotEmpty) {
        if (d.toLowerCase() == 'next week') {
          day = DateTime(today.year, today.month, today.day + 8 - today.weekday);
          text = next;
          continue;
        }
        final found = _readDay(' $d', today);
        if (found != null && found.day != null) {
          day = found.day;
          text = next;
          continue;
        }
      }
    }
    if (endPhrase == null && (m = _midUntil.firstMatch(text)) != null) {
      final next = _spliceOut(text, m!.start, m.end);
      if (next.isNotEmpty) {
        endPhrase = ' ${m.namedGroup('d')!}';
        text = next;
        continue;
      }
    }
    if (explicitMinutes == null &&
        (m = _midRange.firstMatch(text)) != null &&
        (m!.namedGroup('prep')!.toLowerCase() == 'between') ==
            (m.namedGroup('join')!.toLowerCase() == 'and')) {
      final next = _spliceOut(text, m.start, m.end);
      final firstClock = RegExp('^$_clockCore', caseSensitive: false).firstMatch(m.namedGroup('first')!);
      final parsedMin = firstClock == null ? null : _clockMinutes(firstClock);
      if (next.isNotEmpty && parsedMin != null) {
        explicitMinutes = parsedMin;
        text = next;
        continue;
      }
    }
    if (explicitMinutes == null && (m = _midClock.firstMatch(text)) != null) {
      final hasConn = m!.namedGroup('conn') != null;
      final is12 = m.namedGroup('h12') != null;
      final is24 = m.namedGroup('h24') != null && !_nonClockColonPrefix.hasMatch(text.substring(0, m.start));
      final isNamed = m.namedGroup('named') != null;
      final isDot24 = m.namedGroup('hd24') != null;
      if (is12 || (hasConn && (is24 || isNamed || isDot24))) {
        final next = _spliceOut(text, m.start, m.end);
        final parsedMin = _clockMinutes(m);
        if (next.isNotEmpty && parsedMin != null) {
          explicitMinutes = parsedMin;
          text = next;
          continue;
        }
      }
    }
    if (day == null && (m = _midRelative.firstMatch(text)) != null) {
      if (!_bareMidWord.hasMatch(m![0]!) || _midClauseBoundary(text, m.start, m.end)) {
        final next = _spliceOut(text, m.start, m.end);
        final found = _readDay(m[0]!, today);
        if (next.isNotEmpty && found != null) {
          if (found.partMinutes != null && found.day == null) {
            if (partMinutes == null) {
              partMinutes = found.partMinutes;
              text = next;
              continue;
            }
          } else if (found.day != null) {
            day = found.day;
            partMinutes ??= found.partMinutes;
            text = next;
            continue;
          }
        }
      }
    }
    if (day == null &&
        ((m = _midWeekday.firstMatch(text)) != null ||
            ((m = _midFullWeekday.firstMatch(text)) != null && _midClauseBoundary(text, m!.start, m.end)))) {
      final next = _spliceOut(text, m!.start, m.end);
      final found = _readDay(m[0]!, today);
      if (next.isNotEmpty && found != null && found.day != null) {
        day = found.day;
        partMinutes ??= found.partMinutes;
        text = next;
        continue;
      }
    }
    if (day == null && ((m = _midNamedDate.firstMatch(text)) != null || (m = _midNumericDate.firstMatch(text)) != null)) {
      final next = _spliceOut(text, m!.start, m.end);
      final found = _readDay(m[0]!, today);
      if (next.isNotEmpty && found != null && found.day != null) {
        day = found.day;
        partMinutes ??= found.partMinutes;
        text = next;
        continue;
      }
    }
    if (text == beforeMid) break;
  }

  // Pass 4: one more tail pass in case middle extraction uncovered a trailing clause.
  if (!runTailPass()) return literal;

  // If duration was provisionally stripped for a non-repeating task ("Book hotel tomorrow for 3 days"),
  // re-parse with allowDuration: false so "for 3 days" stays intact in the task name.
  if (durationWasUsed && repeat == null) {
    return _parseInternal(raw, today, defaultDay: defaultDay, defaultTime: defaultTime, allowDuration: false);
  }
  if (endPhrase != null && durationSpec != null) return literal;
  if ((day != null || repeat != null) && _incompleteSchedule.hasMatch(text)) return literal;
  if (text.isEmpty) return literal;

  // Preserve leading sentence capitalization if a leading clause was peeled off.
  if (peeledLead && (startedUpper || raw.trimLeft().startsWith('@')) && text.isNotEmpty) {
    final first = text[0];
    if (first.toUpperCase() != first) {
      text = '${first.toUpperCase()}${text.substring(1)}';
    }
  }

  // Auto-detect birthdays when there is no explicit clock time or explicit other repeat.
  var birthday = false;
  if (explicitMinutes == null && repeat == null) {
    final hasBirthdayWord = _birthdayWord.hasMatch(text);
    if (hasBirthdayWord && !_birthdayActionLead.hasMatch(text) && !_birthdayEventOrGift.hasMatch(text)) {
      birthday = true;
      partMinutes = null;
      if (_birthdayLead.firstMatch(text) case final lead?) {
        final cleaned = lead[1]!.trim();
        if (cleaned.isNotEmpty) text = cleaned;
      }
      if (day != null) repeat = const RepeatRule.yearly(1);
    }
  }

  final minutes = birthday ? null : (explicitMinutes ?? partMinutes);
  final effectiveTime = birthday ? null : (minutes ?? defaultTime);
  if (reminders != 0) {
    final valid = Reminder.allowed(reminders, birthday: birthday, time: effectiveTime);
    if (valid != reminders) return literal;
  }
  if (endPhrase != null && repeat == null) return literal;

  if (repeat case final rule?) {
    final start = day ?? defaultDay ?? today;
    var first = rule.kind == RepeatKind.monthly ? _nextDayOfMonth(start, rule.every) : start;
    while ((anchorWeekday != null && first.weekday != anchorWeekday) ||
        (rule.weekdays != null && !rule.weekdays!.contains(first.weekday))) {
      first = DateTime(first.year, first.month, first.day + 1);
    }
    day = first;
    if (endPhrase case final end?) {
      // “Tomorrow” is relative to entry. A bare weekday or month/day
      // following a future start belongs to that series.
      final reference = _relative.hasMatch(end) ? today : start;
      until = _readDay(end, reference)?.day;
      if (until == null || until.isBefore(first)) return literal;
    } else if (durationSpec case final dur?) {
      until = _applyDuration(first, dur);
      if (until.isBefore(first)) return literal;
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
    birthday: birthday,
  );
}
