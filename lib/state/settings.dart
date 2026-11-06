part of '../app_state.dart';

/// Choices kept in the database: when a day starts, the colour theme and
/// night light, rest weekends, and what the to-do lists show.
mixin _Settings on ChangeNotifier {
  Store get store;
  LruCache<int, (int, int)> get _streaks;
  DateTime get today;
  void checkDate();
  void holidaysChanged();

  /// The hour a new day starts: 0 for midnight or 4 for night owls.
  late int dayStartHour = int.tryParse(store.setting('dayStartHour') ?? '') ?? 0;

  void setDayStartHour(int hour) {
    dayStartHour = hour;
    store.setSetting('dayStartHour', '$hour');
    checkDate();
    notifyListeners();
  }

  /// Name of the chosen colour theme; null until one is picked.
  late String? themeName = _savedTheme();
  late final ValueNotifier<String?> themeNotifier = ValueNotifier(themeName);

  /// Brings saved names up to date: version 2 paired the themes light and
  /// dark (the old Sunset was light and is now Sunrise), version 3 dropped
  /// Citrus, version 4 named the Pastels Morning and Evening. Runs once per
  /// database (a restored backup may need it again).
  String? _savedTheme() {
    final saved = store.setting('theme');
    final version = int.tryParse(store.setting('themeNames') ?? '') ?? 1;
    if (saved == null || version >= _themeNames) return saved;
    var name = version >= 2
        ? saved
        : switch (saved) {
            'Main' => 'Solar Eclipse',
            'Dark' || 'Eclipse' => 'Lunar Eclipse',
            'Soft Pastel' => 'Pastel',
            'Sage & Sunset' => 'Citrus',
            'Sunset' => 'Sunrise',
            final name => name,
          };
    name = switch (name) {
      'Citrus' => 'Solar Eclipse',
      'Dark Citrus' => 'Lunar Eclipse',
      'Pastel' => 'Morning Pastel',
      'Dark Pastel' => 'Evening Pastel',
      final name => name,
    };
    store.setSetting('theme', name);
    store.setSetting('themeNames', '$_themeNames');
    return name;
  }

  static const _themeNames = 4;

  void setTheme(String name) {
    themeName = name;
    themeNotifier.value = name;
    store.transaction(() {
      store.setSetting('theme', name);
      store.setSetting('themeNames', '$_themeNames');
    });
    notifyListeners();
  }

  /// True where night light can be read (a Hyprland session, Windows, or a
  /// Mac's Dark mode); the menu hides the switch otherwise.
  bool nightLightAvailable = false;

  /// Switch to the dark partner when night light comes on, and back when it
  /// goes off. A theme picked in between holds until the next change.
  late bool followNightLight = store.setting('followNightLight') != '0';

  /// Night light as last seen, kept across restarts so a change while the
  /// app was closed still switches, but a restart alone doesn't.
  late bool? _nightLight = switch (store.setting('nightLight')) {
    '1' => true,
    '0' => false,
    _ => null,
  };

  void setFollowNightLight(bool follow) {
    followNightLight = follow;
    store.setSetting('followNightLight', follow ? '1' : '0');
    if (follow && _nightLight != null) _matchNightLight(_nightLight!);
    notifyListeners();
  }

  /// Call with each reading of night light.
  void nightLightIs(bool on) {
    if (on == _nightLight) return;
    _nightLight = on;
    // One save for the reading and the theme it switches to.
    store.transaction(() {
      store.setSetting('nightLight', on ? '1' : '0');
      if (followNightLight) _matchNightLight(on);
    });
  }

  void _matchNightLight(bool on) {
    final name = partnerOf(themeName, dark: on).name;
    if (name != themeName) setTheme(name);
  }

  /// Weekends shown greyed as rest days. A blank rest day doesn't break a
  /// streak; a ritual done on one still counts.
  late bool restWeekends = store.setting('restWeekends') == '1';

  void setRestWeekends(bool rest) {
    restWeekends = rest;
    store.setSetting('restWeekends', rest ? '1' : '0');
    _streaks.clear();
    notifyListeners();
  }

  bool isRestDay(DateTime day) => restWeekends && day.weekday >= DateTime.saturday || holidayOn(holidays, day) != null;

  /// Holidays, earliest first: the same on every computer.
  late List<Holiday> holidays = decodeHolidays(store.setting('holidays'));

  /// Adds a holiday from [start] to [end]; one it overlaps or touches
  /// joins it. A past one (over before today) is never swallowed, so taking
  /// the new one away can't take its rest days with it: the new one only
  /// adds the days around it.
  void addHoliday(DateTime start, DateTime end) {
    var parts = [(start: dateOnly(start), end: dateOnly(end))];
    for (final past in holidays.where((h) => h.end.isBefore(today))) {
      parts = [
        for (final part in parts) ...[
          if (part.start.isBefore(past.start))
            (
              start: part.start,
              end: _earliest(part.end, DateTime(past.start.year, past.start.month, past.start.day - 1)),
            ),
          if (part.end.isAfter(past.end))
            (start: _latest(part.start, DateTime(past.end.year, past.end.month, past.end.day + 1)), end: part.end),
        ],
      ];
    }
    var next = holidays;
    for (final part in parts) {
      next = _joined(next, part.start, part.end);
    }
    _setHolidays(next);
  }

  static DateTime _earliest(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
  static DateTime _latest(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

  /// [holidays] with [from] to [to] added, joined with any it overlaps or
  /// touches that isn't over yet.
  List<Holiday> _joined(List<Holiday> holidays, DateTime from, DateTime to) {
    final kept = <Holiday>[];
    for (final h in holidays) {
      final apart =
          h.end.isBefore(today) ||
          h.end.isBefore(DateTime(from.year, from.month, from.day - 1)) ||
          h.start.isAfter(DateTime(to.year, to.month, to.day + 1));
      if (apart) {
        kept.add(h);
      } else {
        if (h.start.isBefore(from)) from = h.start;
        if (h.end.isAfter(to)) to = h.end;
      }
    }
    return [...kept, (start: from, end: to)];
  }

  void removeHoliday(Holiday holiday) => _setHolidays([
    for (final h in holidays)
      if (h != holiday) h,
  ]);

  void _setHolidays(List<Holiday> next) {
    holidays = decodeHolidays(encodeHolidays(next));
    store.setSetting('holidays', encodeHolidays(holidays));
    _streaks.clear();
    holidaysChanged();
    notifyListeners();
  }

  /// Whether Further ahead shows birthdays.
  late bool laterBirthdays = store.setting('laterBirthdays') != 'hidden';

  void toggleLaterBirthdays() {
    laterBirthdays = !laterBirthdays;
    store.setSetting('laterBirthdays', laterBirthdays ? 'shown' : 'hidden');
    notifyListeners();
  }

  /// Whether Week ahead lists days with nothing due.
  late bool weekEmptyDays = store.setting('weekEmptyDays') == 'shown';

  void toggleWeekEmptyDays() {
    weekEmptyDays = !weekEmptyDays;
    store.setSetting('weekEmptyDays', weekEmptyDays ? 'shown' : 'hidden');
    notifyListeners();
  }

  @override
  void dispose() {
    themeNotifier.dispose();
    super.dispose();
  }
}
