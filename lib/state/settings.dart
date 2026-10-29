part of '../app_state.dart';

/// Choices kept in the database: when a day starts, the colour theme and
/// night light, rest weekends, and what the to-do lists show.
mixin _Settings on ChangeNotifier {
  Store get store;
  LruCache<int, (int, int)> get _streaks;
  void checkDate();

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

  bool isRestDay(DateTime day) => restWeekends && day.weekday >= DateTime.saturday;

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
