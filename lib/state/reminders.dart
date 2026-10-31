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
  String body(DateTime now) {
    if (birthday) return daysBetween(dateOnly(now), day) > 0 ? 'Birthday tomorrow' : 'Birthday today';
    final at = clockLabel(time!);
    final left = moment.difference(now);
    if (daysBetween(dateOnly(now), day) > 0 && left > const Duration(hours: 2)) return 'Tomorrow at $at';
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
  Set<String> shown,
) {
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
    final moment = alerts.first.moment;
    // Over: a timed task once its time comes, a birthday once its day ends.
    final over = item.birthday ? DateTime(day.year, day.month, day.day + 1) : moment;
    if (!now.isBefore(over)) continue;
    final missed = [
      for (final alert in alerts)
        if (!alert.reminder.at(day, time).isAfter(now) &&
            !shown.contains(alert.key) &&
            !(item.birthday && alert.reminder == Reminder.dayBefore && !now.isBefore(moment)))
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

/// Tasks' reminders: checked every so often (the corner card's layer asks),
/// each shown once, by the system and in the window.
mixin _Reminders on ChangeNotifier {
  Store get store;
  DateTime get today;
  DateTime Function() get _clock;
  ReminderNotifier? get notifier;
  void showFound(DateTime day, String target);

  /// The setting that keeps which reminders have shown, on this computer.
  static const _shownSetting = 'remindersShown';

  /// The cards in the corner, oldest first.
  final List<ReminderAlert> reminderCards = [];

  /// Whether the window is open, to show cards in; set by the layer.
  bool windowOpen = true;

  Set<String> _shownKeys() {
    try {
      return {...(jsonDecode(store.setting(_shownSetting) ?? '[]') as List).cast<String>()};
    } on FormatException {
      return {};
    }
  }

  /// Keeps [keys], less those for days long gone.
  void _keepShown(Set<String> keys) {
    final old = dateKey(DateTime(today.year, today.month, today.day - 2));
    keys.removeWhere((key) => key.split('|')[2].compareTo(old) < 0);
    store.setSetting(_shownSetting, jsonEncode(keys.toList()..sort()));
  }

  /// Sends the reminders due now.
  void checkReminders() {
    final now = _clock();
    final shown = _shownKeys();
    final due = dueReminders(store.remindingTodos(today), now, shown);
    if (due.isEmpty) return;
    for (final (alert, keys) in due) {
      shown.addAll(keys);
      notifier?.show(alert, alert.body(now));
      if (windowOpen) reminderCards.add(alert);
    }
    _keepShown(shown);
    notifyListeners();
  }

  /// The tasks [which] says were just set: what they'd remind of already
  /// is past, and doesn't go off.
  void _settleReminders(bool Function(String uid) which) {
    final shown = _shownKeys();
    final due = dueReminders(
      [
        for (final task in store.remindingTodos(today))
          if (which(task.$1.uid ?? '')) task,
      ],
      _clock(),
      shown,
    );
    if (due.isEmpty) return;
    for (final (_, keys) in due) {
      shown.addAll(keys);
    }
    _keepShown(shown);
  }

  /// The time now, for what a card says is left.
  DateTime get reminderNow => _clock();

  void hideReminderCard(ReminderAlert alert) {
    if (reminderCards.remove(alert)) notifyListeners();
  }

  /// Opens the task [uid] where it's listed and lights it.
  void openReminder(String uid) {
    final alert = reminderCards.where((a) => a.uid == uid).lastOrNull;
    if (alert != null) hideReminderCard(alert);
    showFound(today, uid);
  }
}
