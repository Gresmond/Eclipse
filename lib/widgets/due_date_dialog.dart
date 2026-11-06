part of 'todo_panel.dart';

/// A [MonthCalendar] of days from [first] on (to [last], if given). A
/// repeat's [end] is shaded, and [marked] days (the ones it
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

  /// A right-clicked day: the last, or on the last, null for no end.
  final ValueChanged<DateTime?>? onEnd;

  @override
  State<_MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<_MonthCalendar> {
  DateTime get _first => DateUtils.dateOnly(widget.first);
  DateTime? get _last => widget.last == null ? null : DateUtils.dateOnly(widget.last!);

  bool _endable(DateTime day) => widget.onEnd != null && (widget.endable?.call(day) ?? false);

  @override
  Widget build(BuildContext context) => MonthCalendar(
    initial: widget.selected,
    first: _first,
    // An end can be any number of months on.
    last: widget.onEnd == null ? _last : null,
    dayBuilder: _buildDay,
  );

  Widget _buildDay(BuildContext context, DateTime date) {
    final localizations = MaterialLocalizations.of(context);
    final enabled = !date.isBefore(_first) && (_last == null || !date.isAfter(_last!));
    final selected = DateUtils.isSameDay(date, widget.selected);
    final end = !selected && widget.end != null && DateUtils.isSameDay(date, widget.end);
    final today = DateUtils.isSameDay(date, AppScope.read(context).today);
    final marked = !selected && (widget.marked?.call(date) ?? false);
    final endable = _endable(date);
    return GestureDetector(
      onSecondaryTap: end && widget.onEnd != null
          ? () => widget.onEnd!(null)
          : endable
          ? () => widget.onEnd!(date)
          : null,
      child: MouseRegion(
        cursor: enabled || endable || end ? SystemMouseCursors.click : MouseCursor.defer,
        child: Semantics(
          button: true,
          enabled: enabled,
          selected: selected,
          label: localizations.formatFullDate(date),
          excludeSemantics: true,
          child: CalendarDay(
            day: date.day,
            selected: selected,
            within: end,
            isToday: today,
            enabled: enabled,
            marked: marked,
            onTap: () => widget.onSelected(date),
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
    this.location,
    this.onName,
  });

  /// Told a new task's name, typed at the top, on saving; null when it has
  /// one already.
  final ValueChanged<String>? onName;
  final DateTime first;
  final DateTime? last;
  final DateTime? due;
  final bool birthdays;
  final _RepeatChoice? repeat;
  final int? time;
  final bool birthday;
  final int reminders;
  final String? location;

  @override
  State<_DueDateDialog> createState() => _DueDateDialogState();
}

class _DueDateDialogState extends State<_DueDateDialog> with _DetailPages {
  late DateTime _selected;
  late bool _birthday = widget.birthday;
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done() {
    if (widget.onName case final onName?) {
      // Nothing to add yet: stays open, for the name.
      if (_name.text.trim().isEmpty) return;
      onName(_name.text);
    }
    Navigator.pop<_DayChoice>(context, (
      day: _selected,
      repeat: _birthdayRepeat(_birthday, _repeat),
      time: _birthday ? null : _time,
      birthday: _birthday,
      reminders: _reminders(birthday: _birthday),
      location: _place,
    ));
  }

  @override
  void initState() {
    super.initState();
    _time = widget.time;
    _notify = widget.reminders;
    _location.text = widget.location ?? '';
    _repeat = widget.repeat;
    final first = DateUtils.dateOnly(widget.first);
    final last = widget.last == null ? null : DateUtils.dateOnly(widget.last!);
    final due = widget.due == null ? first : DateUtils.dateOnly(widget.due!);
    _selected = due.isBefore(first) ? first : (last != null && due.isAfter(last) ? last : due);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final p = context.palette;
    final panel = _RepeatPanel(
      first: widget.first,
      last: widget.last,
      start: _selected,
      onStart: (day) => setState(() => _selected = day),
      repeat: _repeat,
      onRepeat: (repeat) => setState(() => _repeat = repeat),
      time: _timeRow(),
      notify: _notifyRow(birthday: _birthday),
      location: _locationRow(onSubmitted: _done),
      birthday: widget.birthdays ? _birthday : null,
      onBirthday: (birthday) => setState(() => _birthday = birthday),
    );
    return PagedDialog(
      page: _page,
      onConfirm: _done,
      width: _taskDialogWidth,
      preserveButtons: false,
      padding: dialogPadding,
      actions: [
        DialogDismiss(label: localizations.cancelButtonLabel, onPressed: () => Navigator.pop(context)),
        DialogConfirm(label: localizations.okButtonLabel, onPressed: _done),
      ],
      child: widget.onName == null
          ? panel
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('New task', style: dialogTitleStyle(p)),
                const SizedBox(height: dialogTitleGap),
                TextField(
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  cursorColor: p.ink,
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Task name',
                    hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted),
                  ),
                  onSubmitted: (_) => _done(),
                ),
                const SizedBox(height: 16),
                panel,
              ],
            ),
    );
  }
}
