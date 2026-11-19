part of '../app_state.dart';

/// A task's reminder going off: the system notification says it, and,
/// while the window is open, a card in the bottom-right corner.
class ReminderAlert {
  const ReminderAlert({
    required this.uid,
    required this.text,
    required this.day,
    required this.time,
    required this.birthday,
    required this.reminder,
  });

  final String uid;
  final String text;

  /// The day the task is on, and its time (none for a birthday).
  final DateTime day;
  final int? time;
  final bool birthday;
  final Reminder reminder;

  /// When the task itself is: its time, or a birthday's whole day from its
  /// start.
  DateTime get moment => DateTime(day.year, day.month, day.day, 0, time ?? 0);

  /// Which one this is, so it shows once: a changed day or time is another.
  String get key => '$uid|${reminder.name}|${dateKey(day)}|${time ?? ''}';

  /// 'In 15 min, at 3:00 pm', 'Tomorrow at 9:30 am', 'Birthday today'.
  String body(DateTime now, {int startHour = 0}) {
    final today = dayOf(now, startHour);
    if (birthday) return daysBetween(today, day) > 0 ? 'Birthday tomorrow' : 'Birthday today';
    final at = clockLabel(time!);
    final left = moment.difference(now);
    final taskDay = dayOf(moment, startHour);
    if (daysBetween(today, taskDay) > 0 && left > const Duration(hours: 2)) return 'Tomorrow at $at';
    final minutes = (left.inSeconds / 60).ceil();
    if (minutes <= 1) return 'Now, at $at';
    if (minutes < 60) return 'In $minutes min, at $at';
    final hours = (minutes / 60).round();
    return 'In $hours ${hours == 1 ? 'hour' : 'hours'}, at $at';
  }
}

/// The reminders of [tasks] (each with the day it's on) to go off at
/// [now], and with each the keys it settles. A task still to come gives
/// its latest one due that hasn't been [shown]; the earlier ones it missed
/// (closed, or asleep) go with it unseen. A birthday's day before only
/// shows that day.
List<(ReminderAlert, List<String>)> dueReminders(
  Iterable<(TodoItem, DateTime)> tasks,
  DateTime now,
  Set<String> shown, {
  int startHour = 0,
}) {
  final due = <(ReminderAlert, List<String>)>[];
  for (final (item, day) in tasks) {
    final uid = item.uid;
    if (uid == null) continue;
    final time = item.birthday ? null : item.dueTime;
    final bits = Reminder.allowed(item.reminders, birthday: item.birthday, time: time);
    final alerts = [
      for (final reminder in Reminder.of(bits))
        ReminderAlert(uid: uid, text: item.text, day: day, time: time, birthday: item.birthday, reminder: reminder),
    ];
    if (alerts.isEmpty) continue;
    final dayStart = item.birthday ? DateTime(day.year, day.month, day.day, startHour) : alerts.first.moment;
    // Over: a timed task once its time comes, a birthday once its day ends.
    final over = item.birthday ? DateTime(day.year, day.month, day.day + 1, startHour) : dayStart;
    if (!now.isBefore(over)) continue;
    final missed = [
      for (final alert in alerts)
        if (!alert.reminder.at(day, time).isAfter(now) &&
            !shown.contains(alert.key) &&
            !(item.birthday && alert.reminder == Reminder.dayBefore && !now.isBefore(dayStart)))
          alert,
    ];
    if (missed.isEmpty) continue;
    missed.sort((a, b) => a.reminder.at(day, time).compareTo(b.reminder.at(day, time)));
    due.add((missed.last, [for (final alert in missed) alert.key]));
  }
  return due;
}

/// Shows a reminder outside the app; [onOpen] is given the uid of one
/// clicked there.
abstract interface class ReminderNotifier {
  void show(ReminderAlert alert, String body);
  set onOpen(void Function(String uid)? open);
}

abstract interface class ReminderActions {
  set onAction(void Function(String key, String action)? callback);
}

/// Whether a reminder may show outside the app, where that's the person's
/// say: in a browser.
enum ReminderAccess { notAsked, allowed, blocked }

abstract interface class ReminderPermission {
  ReminderAccess get access;
  Future<void> ask();
}

/// Tasks' reminders: checked every so often (the corner card's layer asks),
/// each shown once, by the system and in the window.
mixin _Reminders on ChangeNotifier {
  Store get store;
  DateTime get today;
  DateTime Function() get _clock;
  ReminderNotifier? get notifier;
  bool get closing;
  bool get _disposed;
  int get dayStartHour;
  List<Repeat> get repeats;
  List<DateTime> unmadeOccurrences(Repeat repeat, DateTime from, DateTime to);
  void showFound(DateTime day, String target);

  /// The tasks that remind, each on the calendar day it happens: with a
  /// day starting at 4am, a task at 1:00 am is in the small hours after its
  /// day's evening, on the next date.
  List<(TodoItem, DateTime)> _remindingTodos() => [
    for (final (item, day) in store.remindingTodos(today))
      (
        item,
        afterMidnight(item.birthday ? null : item.dueTime, dayStartHour)
            ? DateTime(day.year, day.month, day.day + 1)
            : day,
      ),
  ];

  /// The setting that keeps which reminders have shown, on this computer.
  static const _shownSetting = 'remindersShown';

  /// The cards in the corner, oldest first.
  final List<ReminderAlert> reminderCards = [];

  /// Whether the window is open, to show cards in; set by the layer.
  bool windowOpen = true;

  Set<String> _shownKeys() {
    try {
      final decoded = jsonDecode(store.setting(_shownSetting) ?? '[]');
      if (decoded is! List) return {};
      return {...decoded.whereType<String>()};
    } on Object {
      return {};
    }
  }

  /// Keeps [keys], less those for days long gone.
  void _keepShown(Set<String> keys) {
    final old = dateKey(DateTime(today.year, today.month, today.day - 2));
    keys.removeWhere((key) {
      final parts = key.split('|');
      return parts.length < 3 || parts[2].compareTo(old) < 0;
    });
    store.setSetting(_shownSetting, jsonEncode(keys.toList()..sort()));
  }

  Future<void>? _held;

  /// Holds reminders until [sync] ends, or for [limit] if it takes longer,
  /// so a time changed on another computer doesn't go off as it was.
  void holdReminders(Future<void> sync, {Duration limit = const Duration(seconds: 20)}) {
    late final Future<void> held;
    held = _held = sync.timeout(limit).catchError((Object _) {}).whenComplete(() {
      if (!identical(_held, held)) return;
      _held = null;
      if (!closing && !_disposed) checkReminders();
    });
  }

  Map<String, int> _snoozed() {
    try {
      return (jsonDecode(store.setting('snoozed') ?? '{}') as Map).cast<String,int>();
    } catch (_) {
      return {};
    }
  }

  Iterable<ReminderAlert> get _activeAlerts sync* {
    for (final (task, day) in _remindingTodos()) {
      for (final reminder in Reminder.of(task.reminders)) {
        yield ReminderAlert(uid: task.uid!, text: task.text, day: day, time: task.birthday ? null : task.dueTime, birthday: task.birthday, reminder: reminder);
      }
    }
  }

  void snoozeReminder(String key) {
    final snoozes = _snoozed()..[key] = _clock().add(const Duration(minutes: 10)).millisecondsSinceEpoch;
    store.setSetting('snoozed', jsonEncode(snoozes));
    reminderCards.removeWhere((a) => a.key == key);
    notifyListeners();
  }

  /// Sends the reminders due now.
  void checkReminders() {
    if (_held != null || _disposed) return;
    final now = _clock();
    final shown = _shownKeys();
    final due = dueReminders(_remindingTodos(), now, shown, startHour: dayStartHour);
    final snoozed = _snoozed();
    if (snoozed.isNotEmpty) {
      final live = {for (final a in _activeAlerts) a.key: a};
      final before = snoozed.length;
      snoozed.removeWhere((key, ms) {
        final alert = live[key];
        if (alert == null) return true;
        if (ms > now.millisecondsSinceEpoch) return false;
        if (now.millisecondsSinceEpoch - ms < const Duration(hours: 1).inMilliseconds) due.add((alert, [key]));
        return true;
      });
      if (snoozed.length != before) store.setSetting('snoozed', jsonEncode(snoozed));
    }
    if (due.isEmpty) return;
    for (final (alert, keys) in due) {
      shown.addAll(keys);
      notifier?.show(alert, alert.body(now, startHour: dayStartHour));
      if (windowOpen) {
        reminderCards.removeWhere((a) => a.uid == alert.uid);
        reminderCards.add(alert);
      }
    }
    _keepShown(shown);
    notifyListeners();
  }

  /// Drops cards for completed, deleted, or modified reminders, and updates
  /// titles if a task was renamed.
  void _pruneReminderCards({bool notify = true}) {
    if (reminderCards.isEmpty) return;
    final active = <String, (TodoItem, DateTime)>{};
    for (final (item, day) in _remindingTodos()) {
      if (item.uid case final uid?) active[uid] = (item, day);
    }
    final now = _clock();
    var changed = false;
    for (var i = reminderCards.length - 1; i >= 0; i--) {
      final card = reminderCards[i];
      final match = active[card.uid];
      if (match == null) {
        reminderCards.removeAt(i);
        changed = true;
        continue;
      }
      final (item, day) = match;
      final time = item.birthday ? null : item.dueTime;
      final bits = Reminder.allowed(item.reminders, birthday: item.birthday, time: time);
      final over = item.birthday
          ? DateTime(day.year, day.month, day.day + 1, dayStartHour)
          : DateTime(day.year, day.month, day.day, 0, time ?? 0);
      if (card.day != day ||
          card.time != time ||
          card.birthday != item.birthday ||
          (bits & card.reminder.bit) == 0 ||
          !now.isBefore(over)) {
        reminderCards.removeAt(i);
        changed = true;
      } else if (card.text != item.text) {
        reminderCards[i] = ReminderAlert(
          uid: card.uid,
          text: item.text,
          day: card.day,
          time: card.time,
          birthday: card.birthday,
          reminder: card.reminder,
        );
        changed = true;
      }
    }
    if (changed && notify) notifyListeners();
  }

  /// The tasks [which] says were just set: what they'd remind of already
  /// is past, and doesn't go off.
  void _settleReminders(bool Function(String uid) which) {
    final shown = _shownKeys();
    final due = dueReminders(
      [
        for (final task in _remindingTodos())
          if (which(task.$1.uid ?? '')) task,
      ],
      _clock(),
      shown,
      startHour: dayStartHour,
    );
    if (due.isEmpty) return;
    for (final (_, keys) in due) {
      shown.addAll(keys);
    }
    _keepShown(shown);
  }

  /// Every reminder still to go off, soonest first and at most [limit], for
  /// a phone to set as alarms. Includes unmaterialized repeating tasks and
  /// birthdays up to [lookaheadDays] ahead.
  List<({String key, String uid, DateTime at, String title, String body})> upcomingReminders({
    int limit = 100,
    int lookaheadDays = 60,
  }) {
    final now = _clock();
    final all = <({String key, String uid, DateTime at, String title, String body})>[];
    final seenKeys = <String>{};

    void addAlert({
      required String uid,
      required String text,
      required DateTime day,
      required int? time,
      required bool birthday,
      required int reminders,
    }) {
      final bits = Reminder.allowed(reminders, birthday: birthday, time: time);
      for (final reminder in Reminder.of(bits)) {
        final at = reminder.at(day, time);
        if (!at.isAfter(now)) continue;
        final alert = ReminderAlert(
          uid: uid,
          text: text,
          day: day,
          time: time,
          birthday: birthday,
          reminder: reminder,
        );
        if (!seenKeys.add(alert.key)) continue;
        all.add((key: alert.key, uid: uid, at: at, title: text, body: alert.body(at, startHour: dayStartHour)));
      }
    }

    for (final (item, day) in _remindingTodos()) {
      final uid = item.uid;
      if (uid == null) continue;
      addAlert(
        uid: uid,
        text: item.text,
        day: day,
        time: item.birthday ? null : item.dueTime,
        birthday: item.birthday,
        reminders: item.reminders,
      );
    }

    final horizon = DateTime(today.year, today.month, today.day + lookaheadDays);
    for (final repeat in repeats) {
      if (repeat.reminders == 0 || (!repeat.birthday && repeat.time == null)) continue;
      final time = repeat.birthday ? null : repeat.time;
      final afterMid = afterMidnight(time, dayStartHour);
      for (final occDay in unmadeOccurrences(repeat, today, horizon)) {
        final calendarDay = afterMid ? DateTime(occDay.year, occDay.month, occDay.day + 1) : occDay;
        addAlert(
          uid: '${repeat.uid}@${dateKey(occDay)}',
          text: repeat.text,
          day: calendarDay,
          time: time,
          birthday: repeat.birthday,
          reminders: repeat.reminders,
        );
      }
    }

    final snoozed = _snoozed();
    if (snoozed.isNotEmpty) {
      for (final alert in _activeAlerts) {
        final ms = snoozed[alert.key];
        if (ms == null || ms <= now.millisecondsSinceEpoch) continue;
        final at = DateTime.fromMillisecondsSinceEpoch(ms);
        all.add((key: alert.key, uid: alert.uid, at: at, title: alert.text, body: 'Snoozed reminder'));
      }
    }
    all.sort((a, b) {
      final cmp = a.at.compareTo(b.at);
      return cmp != 0 ? cmp : a.key.compareTo(b.key);
    });
    return all.take(limit).toList();
  }

  /// The time now, for what a card says is left.
  DateTime get reminderNow => _clock();

  void hideReminderCard(ReminderAlert alert) {
    final before = reminderCards.length;
    reminderCards.removeWhere((a) => a.key == alert.key);
    if (reminderCards.length != before) notifyListeners();
  }

  /// Opens the task [uid] where it's listed and lights it.
  void openReminder(String uid) {
    final before = reminderCards.length;
    reminderCards.removeWhere((a) => a.uid == uid);
    if (reminderCards.length != before) notifyListeners();
    showFound(today, uid);
  }
}
