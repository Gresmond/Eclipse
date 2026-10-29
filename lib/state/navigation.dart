part of '../app_state.dart';

/// Which view is open, and which months there are to open.
mixin _Navigation on ChangeNotifier {
  Store get store;
  DateTime get today;
  bool get lateNight;
  int get dayStartHour;
  bool isFutureMonth(int year, int month);
  void saveDrafts();
  void saveHabitDrafts();

  late int viewYear;

  /// 1-12 when a month tab is open, null for the Today view.
  int? viewMonth;

  /// The year's record is open (with [viewMonth] null).
  bool viewingYear = false;

  /// A past day the Today view is showing, to look at only; null for today.
  DateTime? viewDay;

  /// The day the Today view shows.
  DateTime get shownDay => viewDay ?? today;
  Object get navigation => (viewYear, viewMonth, viewingYear, viewDay, today, lateNight, dayStartHour, firstMonth);

  /// Gym training, every exercise's progress; the page under the corner.
  late final training = TrainingLog(store, notifyListeners);

  /// The Training page is turned to, over whichever view was open.
  bool showingTraining = false;

  void toggleTraining() {
    saveDrafts();
    showingTraining = !showingTraining;
    if (!showingTraining) training.day = null;
    notifyListeners();
  }

  void showToday() {
    saveHabitDrafts();
    viewMonth = null;
    viewingYear = false;
    viewDay = null;
    viewYear = today.year;
    notifyListeners();
  }

  /// Opens a past day's card in the Today view.
  void showDay(DateTime day) {
    saveHabitDrafts();
    viewMonth = null;
    viewingYear = false;
    viewDay = day.isBefore(today) ? dateOnly(day) : null;
    viewYear = today.year;
    notifyListeners();
  }

  /// Opens the record of [viewYear]: every month's percentages at once.
  void showYear() {
    saveHabitDrafts();
    viewMonth = null;
    viewDay = null;
    viewingYear = true;
    notifyListeners();
  }

  void showMonth(int month) {
    saveHabitDrafts();
    viewMonth = month;
    viewingYear = false;
    viewDay = null;
    notifyListeners();
  }

  void shiftYear(int delta) {
    saveHabitDrafts();
    viewYear = (viewYear + delta).clamp(firstMonth.$1, today.year);
    if (!viewingYear) {
      final months = shownMonths(viewYear);
      viewMonth = (viewMonth ?? today.month).clamp(months.first, months.last);
    }
    notifyListeners();
  }

  /// Worked out again after each change, as one can log an earlier day.
  DateTime? _firstDay;

  /// The month you started using the app, or this month before anything
  /// is logged. No earlier month is shown.
  (int, int) get firstMonth {
    final day = _firstDay ??= store.firstActivity() ?? today;
    return day.isAfter(today) ? (today.year, today.month) : (day.year, day.month);
  }

  /// Whether [month] is between the one you started in and this one.
  bool isShownMonth(int year, int month) {
    final (y, m) = firstMonth;
    return year * 12 + month >= y * 12 + m && !isFutureMonth(year, month);
  }

  /// The months of [year] that are shown, in order.
  List<int> shownMonths(int year) => [
    for (var m = 1; m <= 12; m++)
      if (isShownMonth(year, m)) m,
  ];
}
