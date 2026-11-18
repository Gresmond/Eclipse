part of '../app_state.dart';

/// Which view is open, and which months there are to open.
mixin _Navigation on ChangeNotifier {
  Store get store;
  DateTime get today;
  bool get lateNight;
  int get dayStartHour;
  List<Holiday> get holidays;
  bool isFutureMonth(int year, int month);
  void saveDrafts();
  void saveHabitDrafts();
  void _removed(String label, List<RowsBefore> before);

  late int viewYear;

  /// 1-12 when a month tab is open, null for the Today view.
  int? viewMonth;

  /// The year's record is open (with [viewMonth] null).
  bool viewingYear = false;

  /// A past day the Today view is showing, to look at only; null for today.
  DateTime? viewDay;

  /// The day the Today view shows.
  DateTime get shownDay => viewDay ?? today;
  Object get navigation => (
    viewYear,
    viewMonth,
    viewingYear,
    viewDay,
    today,
    lateNight,
    dayStartHour,
    firstMonth,
    holidays,
    showingTraining,
  );

  /// Gym training, every exercise's progress.
  late final training = TrainingLog(store, notifyListeners, onRemoved: _removed);

  /// The Training page is open, in place of whichever view was.
  bool showingTraining = false;

  void _closePages() {
    if (showingTraining) {
      saveDrafts();
      training.day = null;
    }
    showingTraining = false;
  }

  /// Back to the view that was open under Training.
  void closePages() {
    _closePages();
    notifyListeners();
  }

  void toggleTraining() {
    final open = !showingTraining;
    _closePages();
    showingTraining = open;
    notifyListeners();
  }

  void showToday() {
    _closePages();
    saveHabitDrafts();
    viewMonth = null;
    viewingYear = false;
    viewDay = null;
    viewYear = today.year;
    notifyListeners();
  }

  /// Opens a past day's card in the Today view.
  void showDay(DateTime day) {
    _closePages();
    saveHabitDrafts();
    viewMonth = null;
    viewingYear = false;
    viewDay = day.isBefore(today) ? dateOnly(day) : null;
    viewYear = today.year;
    notifyListeners();
  }

  /// What search last opened, a task's uid or a journal day's key, and
  /// when: it lights up briefly where it's shown.
  ({String target, DateTime at})? found;

  /// Opens [day] in the Today view (today's own for today or later), and
  /// lights [target] there.
  void showFound(DateTime day, String target) {
    found = (target: target, at: DateTime.now());
    showDay(day);
  }

  /// Opens the record of [viewYear]: every month's percentages at once.
  void showYear() {
    _closePages();
    saveHabitDrafts();
    viewMonth = null;
    viewDay = null;
    viewingYear = true;
    notifyListeners();
  }

  void showMonth(int month) {
    _closePages();
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
