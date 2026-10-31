part of 'todo_panel.dart';

/// A month of days from [first] on (to [last], if given), with arrows to
/// the months either side; weeks start on Monday, as everywhere else in
/// the app. A repeat's [end] is shaded, and [marked] days (the ones it
/// comes round on) have a dot. Right-clicking a day [endable] says sets
/// it as the end, past [last] too.
class _MonthCalendar extends StatefulWidget {
  const _MonthCalendar({
    required this.first,
    this.last,
    required this.selected,
    this.end,
    this.marked,
    required this.onSelected,
    this.endable,
    this.onEnd,
  });

  final DateTime first;
  final DateTime? last;
  final DateTime selected;
  final DateTime? end;
  final bool Function(DateTime day)? marked;
  final ValueChanged<DateTime> onSelected;
  final bool Function(DateTime day)? endable;
  final ValueChanged<DateTime>? onEnd;

  @override
  State<_MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<_MonthCalendar> {
  late DateTime _month = DateTime(widget.selected.year, widget.selected.month);

  DateTime get _first => DateUtils.dateOnly(widget.first);
  DateTime? get _last => widget.last == null ? null : DateUtils.dateOnly(widget.last!);

  bool _endable(DateTime day) => widget.onEnd != null && (widget.endable?.call(day) ?? false);

  void _moveMonth(int offset) {
    setState(() => _month = DateTime(_month.year, _month.month + offset));
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final firstMonth = DateTime(_first.year, _first.month);
    // An end can be any number of months on.
    final last = widget.onEnd == null ? _last : null;
    final lastMonth = last == null ? null : DateTime(last.year, last.month);
    final leading = DateTime(_month.year, _month.month).weekday - 1;
    final days = DateUtils.getDaysInMonth(_month.year, _month.month);
    final weeks = ((leading + days) / 7).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(localizations.formatMonthYear(_month), style: Theme.of(context).textTheme.titleSmall),
              ),
            ),
            IconButton(
              tooltip: localizations.previousMonthTooltip,
              onPressed: _month.isAfter(firstMonth) ? () => _moveMonth(-1) : null,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            IconButton(
              tooltip: localizations.nextMonthTooltip,
              onPressed: lastMonth == null || _month.isBefore(lastMonth) ? () => _moveMonth(1) : null,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: Center(
                    child: Text(
                      localizations.narrowWeekdays[(1 + i) % 7],
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
          ],
        ),
        // Only the weeks the month has, the rows below moving with it.
        AnimatedSize(
          duration: Motion.morph,
          curve: Motion.morphCurve,
          alignment: Alignment.topCenter,
          child: Column(
            children: [
              for (var row = 0; row < weeks; row++)
                Row(
                  children: [
                    for (var column = 0; column < 7; column++)
                      Expanded(child: _buildDay(row * 7 + column - leading + 1, days, localizations, colors)),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDay(int day, int days, MaterialLocalizations localizations, ColorScheme colors) {
    if (day < 1 || day > days) return const SizedBox(height: 42);
    final date = DateTime(_month.year, _month.month, day);
    final enabled = !date.isBefore(_first) && (_last == null || !date.isAfter(_last!));
    final selected = DateUtils.isSameDay(date, widget.selected);
    final end = !selected && widget.end != null && DateUtils.isSameDay(date, widget.end);
    final today = DateUtils.isSameDay(date, AppScope.read(context).today);
    final marked = !selected && (widget.marked?.call(date) ?? false);
    final endable = _endable(date);
    return SizedBox(
      height: 42,
      child: GestureDetector(
        onSecondaryTap: endable ? () => widget.onEnd!(date) : null,
        child: MouseRegion(
          cursor: enabled || endable ? SystemMouseCursors.click : MouseCursor.defer,
          child: Semantics(
            selected: selected,
            label: localizations.formatFullDate(date),
            child: TextButton(
              onPressed: enabled ? () => widget.onSelected(date) : null,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                shape: CircleBorder(side: today && !selected ? BorderSide(color: colors.primary) : BorderSide.none),
                backgroundColor: selected
                    ? colors.primary
                    : end
                    ? colors.primary.withValues(alpha: 0.28)
                    : null,
                foregroundColor: selected ? colors.onPrimary : colors.onSurface,
              ),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  Text(localizations.formatDecimal(day)),
                  if (marked)
                    Positioned(
                      bottom: -7,
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(color: colors.primary, shape: BoxShape.circle),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A calendar with no redundant date header, and the time and repeat
/// under it, and with [birthdays] whether it's a birthday.
class _DueDateDialog extends StatefulWidget {
  const _DueDateDialog({
    required this.first,
    this.last,
    this.due,
    this.repeat,
    this.time,
    this.birthday = false,
    this.birthdays = false,
    this.reminders = 0,
  });

  final DateTime first;
  final DateTime? last;
  final DateTime? due;
  final bool birthdays;
  final _RepeatChoice? repeat;
  final int? time;
  final bool birthday;
  final int reminders;

  @override
  State<_DueDateDialog> createState() => _DueDateDialogState();
}

class _DueDateDialogState extends State<_DueDateDialog> with _DetailPages {
  late DateTime _selected;
  late bool _birthday = widget.birthday;

  void _done() => Navigator.pop<_DayChoice>(context, (
    day: _selected,
    repeat: _birthdayRepeat(_birthday, _repeat),
    time: _birthday ? null : _time,
    birthday: _birthday,
    reminders: _reminders(birthday: _birthday),
  ));

  @override
  void initState() {
    super.initState();
    _time = widget.time;
    _notify = widget.reminders;
    _repeat = widget.repeat;
    final first = DateUtils.dateOnly(widget.first);
    final last = widget.last == null ? null : DateUtils.dateOnly(widget.last!);
    final due = widget.due == null ? first : DateUtils.dateOnly(widget.due!);
    _selected = due.isBefore(first) ? first : (last != null && due.isAfter(last) ? last : due);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    return PagedDialog(
      page: _page,
      onConfirm: _done,
      width: _taskDialogWidth,
      preserveButtons: false,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(localizations.cancelButtonLabel)),
        TextButton(onPressed: _done, child: Text(localizations.okButtonLabel)),
      ],
      child: _RepeatPanel(
        first: widget.first,
        last: widget.last,
        start: _selected,
        onStart: (day) => setState(() => _selected = day),
        repeat: _repeat,
        onRepeat: (repeat) => setState(() => _repeat = repeat),
        time: _timeRow(),
        notify: _notifyRow(birthday: _birthday),
        birthday: widget.birthdays ? _birthday : null,
        onBirthday: (birthday) => setState(() => _birthday = birthday),
      ),
    );
  }
}
