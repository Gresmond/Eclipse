part of 'todo_panel.dart';

/// A day, how a task first due on it repeats, its time and whether it's a
/// birthday.
typedef _DayChoice = ({DateTime day, _RepeatChoice? repeat, int? time, bool birthday});

/// A new task's day from [first] on (to [last], if given), opening on
/// [selected], with its time and repeat set under the calendar, and with
/// [birthdays] whether it's a birthday. Without [calendar], [selected] is
/// the day and only those are asked.
Future<_DayChoice?> _pickDayAndRepeat(
  BuildContext context, {
  required DateTime first,
  DateTime? last,
  DateTime? selected,
  _RepeatChoice? repeat,
  int? time,
  bool birthday = false,
  bool birthdays = false,
  bool calendar = true,
}) => showAppDialog<_DayChoice>(
  context: context,
  builder: (_) => _DueDateDialog(
    first: first,
    last: last,
    due: selected,
    repeat: repeat,
    time: time,
    birthday: birthday,
    birthdays: birthdays,
    calendar: calendar,
  ),
);

/// A task dialog's ribbons.
enum _Ribbon {
  day('Day'),
  task('Task'),
  time('Time'),
  repeat('Repeat');

  const _Ribbon(this.label);
  final String label;
}

/// A task dialog laid out as Settings is: [title] and the [ribbons] along
/// the top, the [selected] one's [child] fading through under them as the
/// panel eases to its height, and [actions] at the foot.
class _TaskDialog extends StatelessWidget {
  const _TaskDialog({
    required this.title,
    required this.ribbons,
    required this.selected,
    required this.onSelect,
    this.disabled = const {},
    required this.child,
    required this.onConfirm,
    required this.actions,
    this.preserveButtons = true,
  });

  final String title;
  final List<_Ribbon> ribbons;
  final _Ribbon selected;
  final ValueChanged<_Ribbon> onSelect;
  final Set<_Ribbon> disabled;
  final Widget child;
  final VoidCallback onConfirm;
  final List<Widget> actions;

  /// As [ConfirmOnEnter.preserveButtons].
  final bool preserveButtons;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ConfirmOnEnter(
      onConfirm: onConfirm,
      preserveButtons: preserveButtons,
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        backgroundColor: p.tile,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: SizedBox(
          width: 480,
          // Scrolls when the window is too short for all of it.
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(fontFamily: Fonts.display, fontSize: 28, color: p.ink),
                      ),
                    ),
                    Ribbons(
                      labels: [for (final r in ribbons) r.label],
                      selected: ribbons.indexOf(selected),
                      onSelect: (i) => onSelect(ribbons[i]),
                      disabled: {for (final r in disabled) ribbons.indexOf(r)},
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                AnimatedSize(
                  duration: Motion.morph,
                  curve: Motion.morphCurve,
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.none,
                  child: FadeThrough(
                    layoutBuilder: (current, previous) => Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.topLeft,
                      children: [
                        for (final w in previous) Positioned(left: 0, right: 0, top: 0, child: w),
                        ?current,
                      ],
                    ),
                    child: KeyedSubtree(key: ValueKey(selected), child: child),
                  ),
                ),
                const SizedBox(height: 14),
                Row(children: [const Spacer(), ...actions]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A task's time and repeat, each set on a ribbon of its own; a birthday
/// has neither, so those ribbons are dimmed.
mixin _TaskDetails<T extends StatefulWidget> on State<T> {
  late _Ribbon _ribbon;
  int? _time;
  _RepeatChoice? _repeat;

  /// The time the wheel shows, kept while the task is all day.
  late int _wheel = _time ?? 9 * 60;

  void _select(_Ribbon ribbon) => setState(() => _ribbon = ribbon);

  Set<_Ribbon> _disabledFor(bool birthday) => birthday ? const {_Ribbon.time, _Ribbon.repeat} : const {};

  /// All day, or at a time on the wheel; Enter on the wheel [onDone].
  Widget _timeTab(VoidCallback onDone) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Pills(
        options: const ['All day', 'At a time'],
        selected: _time == null ? 0 : 1,
        onSelect: (i) => setState(() => _time = i == 0 ? null : _wheel),
      ),
      _FoldAway(
        folded: _time == null,
        child: TimeWheel(initial: _wheel, onChanged: (time) => setState(() => _time = _wheel = time), onDone: onDone),
      ),
    ],
  );

  /// How it repeats, for a task first due on [start].
  Widget _repeatTab(DateTime start) =>
      _RepeatPanel(start: start, current: _repeat, onChanged: (repeat) => setState(() => _repeat = repeat));
}

/// A month of days from [first] on (to [last], if given), with arrows to
/// the months either side; weeks start on Monday, as everywhere else in
/// the app.
class _MonthCalendar extends StatefulWidget {
  const _MonthCalendar({required this.first, this.last, required this.selected, required this.onSelected});

  final DateTime first;
  final DateTime? last;
  final DateTime selected;
  final ValueChanged<DateTime> onSelected;

  @override
  State<_MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<_MonthCalendar> {
  late DateTime _month = DateTime(widget.selected.year, widget.selected.month);

  DateTime get _first => DateUtils.dateOnly(widget.first);
  DateTime? get _last => widget.last == null ? null : DateUtils.dateOnly(widget.last!);

  void _moveMonth(int offset) {
    setState(() => _month = DateTime(_month.year, _month.month + offset));
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final firstMonth = DateTime(_first.year, _first.month);
    final last = _last;
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
    final today = DateUtils.isSameDay(date, AppScope.read(context).today);
    return SizedBox(
      height: 42,
      child: Semantics(
        selected: selected,
        label: localizations.formatFullDate(date),
        child: TextButton(
          onPressed: enabled ? () => widget.onSelected(date) : null,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            shape: CircleBorder(side: today && !selected ? BorderSide(color: colors.primary) : BorderSide.none),
            backgroundColor: selected ? colors.primary : null,
            foregroundColor: selected ? colors.onPrimary : colors.onSurface,
          ),
          child: Text(localizations.formatDecimal(day)),
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
    this.calendar = true,
  });

  final DateTime first;
  final DateTime? last;
  final DateTime? due;
  final bool birthdays, calendar;
  final _RepeatChoice? repeat;
  final int? time;
  final bool birthday;

  @override
  State<_DueDateDialog> createState() => _DueDateDialogState();
}

class _DueDateDialogState extends State<_DueDateDialog> with _TaskDetails {
  late DateTime _selected;
  late bool _birthday = widget.birthday;

  void _done() => Navigator.pop<_DayChoice>(context, (
    day: _selected,
    repeat: _birthdayRepeat(_birthday, _repeat),
    time: _birthday ? null : _time,
    birthday: _birthday,
  ));

  bool get _hasDay => widget.calendar || widget.birthdays;

  @override
  void initState() {
    super.initState();
    _time = widget.time;
    _repeat = widget.repeat;
    _ribbon = _hasDay ? _Ribbon.day : _Ribbon.time;
    final first = DateUtils.dateOnly(widget.first);
    final last = widget.last == null ? null : DateUtils.dateOnly(widget.last!);
    final due = widget.due == null ? first : DateUtils.dateOnly(widget.due!);
    _selected = due.isBefore(first) ? first : (last != null && due.isAfter(last) ? last : due);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    return _TaskDialog(
      title: 'When',
      ribbons: [if (_hasDay) _Ribbon.day, _Ribbon.time, _Ribbon.repeat],
      selected: _ribbon,
      onSelect: _select,
      disabled: _disabledFor(_birthday),
      onConfirm: _done,
      preserveButtons: false,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(localizations.cancelButtonLabel)),
        TextButton(onPressed: _done, child: Text(localizations.okButtonLabel)),
      ],
      child: switch (_ribbon) {
        _Ribbon.time => _timeTab(_done),
        _Ribbon.repeat => _repeatTab(_selected),
        _ => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.calendar)
              _MonthCalendar(
                first: widget.first,
                last: widget.last,
                selected: _selected,
                onSelected: (day) => setState(() => _selected = day),
              ),
            if (widget.birthdays) ...[
              const SizedBox(height: 8),
              _BirthdayRow(birthday: _birthday, onChanged: (birthday) => setState(() => _birthday = birthday)),
            ],
          ],
        ),
      },
    );
  }
}

/// A repeat chosen in a dialog: its rule, and the last day it may come
/// round on.
typedef _RepeatChoice = ({RepeatRule rule, DateTime? until});

/// What the editor saved; [repeat] null when it doesn't repeat.
typedef _TaskEdit = ({String text, DateTime? due, _RepeatChoice? repeat, int? time, bool birthday});

/// Edits [item], asking whether a change to a repeating task's name is
/// for that time only or every time from it on. A new rule always is.
/// [make]: makes a time of a repeat not made yet, to change on its own.
Future<void> _editTask(
  BuildContext context,
  TodoScope scope,
  TodoItem item,
  DateTime day, {
  TodoItem Function()? make,
}) async {
  final state = AppScope.read(context);
  final repeat = state.repeatOf(item);
  final result = await showAppDialog<_TaskEdit>(
    context: context,
    builder: (_) => _EditTaskDialog(item: item, scope: scope, day: day, repeat: repeat),
  );
  if (result == null || !context.mounted) return;
  final choice = result.repeat;
  final (time, birthday) = (result.time, result.birthday);
  if (repeat == null) {
    if (choice == null) {
      state.editTodo(scope, item, result.text, result.due, day: day, time: time, birthday: birthday);
    } else {
      state.makeRepeating(scope, item, result.text, choice.rule, until: choice.until, time: time, birthday: birthday);
    }
    return;
  }
  final from = item.repeatDay ?? day;
  if (choice?.rule != repeat.rule || choice?.until != repeat.until) {
    state.changeRepeat(repeat, from, result.text, choice?.rule, until: choice?.until, time: time, birthday: birthday);
    return;
  }
  final renamed = result.text.trim() != item.text || (time, birthday) != (item.dueTime, item.birthday);
  if (!renamed && result.due == item.dueDate) return;
  final future = renamed ? await _askWhich(context, removing: false) : false;
  if (future == null || !context.mounted) return;
  if (future) state.renameRepeat(repeat, result.text, from, time: time, birthday: birthday);
  if (!future || result.due != item.dueDate) {
    state.editTodo(scope, make?.call() ?? item, result.text, result.due, day: day, time: time, birthday: birthday);
  }
}

/// Removes [item] by [removeOne], or, for a repeating task, that time or
/// every time from it on, as chosen.
Future<void> _removeTask(BuildContext context, TodoItem item, DateTime day, VoidCallback removeOne) async {
  final state = AppScope.read(context);
  final repeat = state.repeatOf(item);
  if (repeat == null) return removeOne();
  final future = await _askWhich(context, removing: true);
  if (future == null || !context.mounted) return;
  // This one closes up like any removed task; with [future], the times
  // after it go too.
  removeOne();
  if (future) state.endRepeat(repeat, item.repeatDay ?? day);
}

/// Only this time (false) or this and every time after (true); null if
/// cancelled.
Future<bool?> _askWhich(BuildContext context, {required bool removing}) => showAppDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    backgroundColor: context.palette.tile,
    title: Text(removing ? 'Remove repeating task' : 'Change repeating task'),
    content: Text(
      removing
          ? 'Remove only this one, or this one and every one after it?'
          : 'Change only this one, or this one and every one after it?',
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Only this one')),
      TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('This and future ones')),
    ],
  ),
);

/// One of a task's details under its field, as a button: [icon] and
/// [label], and with [onClear] a cross that takes it away.
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.label, required this.onPressed, this.clear, this.onClear});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// The cross's tooltip.
  final String? clear;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(icon: Icon(icon, size: 18), label: Text(label), onPressed: onPressed),
          ),
        ),
        if (onClear != null) IconButton(tooltip: clear, icon: const Icon(Icons.close_rounded), onPressed: onClear),
      ],
    );
  }
}

/// [repeat], or every year for a [birthday] that doesn't already.
_RepeatChoice? _birthdayRepeat(bool birthday, _RepeatChoice? repeat) =>
    !birthday || repeat?.rule == const RepeatRule.yearly(1) ? repeat : (rule: const RepeatRule.yearly(1), until: null);

/// Whether a task is someone's birthday, which comes round every year, all
/// day, in place of a repeat and time; a cross makes it not one.
class _BirthdayRow extends StatelessWidget {
  const _BirthdayRow({required this.birthday, required this.onChanged});

  final bool birthday;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _DetailRow(
    icon: _birthdayIcon,
    label: birthday ? 'Birthday' : 'Not a birthday',
    onPressed: () => onChanged(!birthday),
    clear: 'Not a birthday',
    onClear: birthday ? () => onChanged(false) : null,
  );
}

class _EditTaskDialog extends StatefulWidget {
  const _EditTaskDialog({required this.item, required this.scope, required this.day, this.repeat});
  final TodoItem item;
  final TodoScope scope;
  final DateTime day;

  /// The repeat it's a time of, if any.
  final Repeat? repeat;

  @override
  State<_EditTaskDialog> createState() => _EditTaskDialogState();
}

class _EditTaskDialogState extends State<_EditTaskDialog> with _TaskDetails {
  late final _text = TextEditingController(text: widget.item.text);
  late DateTime? _due = widget.item.dueDate;

  /// Whether the due date's calendar is open.
  bool _picking = false;

  /// Kept as it is: whether it's a birthday is only set when it's added.
  late final bool _birthday = widget.item.birthday;

  @override
  void initState() {
    super.initState();
    _ribbon = _Ribbon.task;
    _time = widget.item.dueTime;
    _repeat = switch (widget.repeat) {
      final r? => (rule: r.rule, until: r.until),
      null => null,
    };
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    if (_text.text.trim().isEmpty) return;
    Navigator.pop<_TaskEdit>(context, (
      text: _text.text,
      due: _due,
      repeat: _birthdayRepeat(_birthday, _repeat),
      time: _birthday ? null : _time,
      birthday: _birthday,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final today = AppScope.read(context).today;
    final start = widget.item.repeatDay ?? _due ?? today;
    return _TaskDialog(
      title: 'Edit task',
      ribbons: const [_Ribbon.task, _Ribbon.time, _Ribbon.repeat],
      selected: _ribbon,
      onSelect: _select,
      disabled: _disabledFor(_birthday),
      onConfirm: _save,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
      child: switch (_ribbon) {
        _Ribbon.time => _timeTab(_save),
        _Ribbon.repeat => _repeatTab(start.isBefore(today) ? today : start),
        _ => _task(today),
      },
    );
  }

  /// Its name and, for a week's or month's task, its due date, whose
  /// calendar folds open under it.
  Widget _task(DateTime today) {
    final dated = widget.scope == TodoScope.week || widget.scope == TodoScope.month;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          inputFormatters: const [NoteInputFormatter()],
          controller: _text,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Task'),
          onSubmitted: (_) => _save(),
        ),
        if (dated) ...[
          const SizedBox(height: 16),
          TextButton.icon(
            icon: const Icon(Icons.calendar_today_outlined, size: 18),
            label: Text(_due == null ? 'Pick a due date' : 'Due ${dayMonth(_due!)}/${_due!.year}'),
            onPressed: () => setState(() => _picking = !_picking),
          ),
          _FoldAway(
            folded: !_picking,
            child: _MonthCalendar(
              first: today,
              selected: _due ?? today,
              onSelected: (day) => setState(() {
                _due = day;
                _picking = false;
              }),
            ),
          ),
        ],
      ],
    );
  }
}

/// How a task repeats: on chosen weekdays, on a date each month, on its
/// date every so many years, or every so many days, weeks or months, with
/// an optional last day whose calendar folds open under it; or never. It
/// changes as it's set.
class _RepeatPanel extends StatefulWidget {
  const _RepeatPanel({required this.start, this.current, required this.onChanged});

  /// The first day it would come round from.
  final DateTime start;

  /// Null when it doesn't repeat.
  final _RepeatChoice? current;

  final ValueChanged<_RepeatChoice?> onChanged;

  @override
  State<_RepeatPanel> createState() => _RepeatPanelState();
}

class _RepeatPanelState extends State<_RepeatPanel> {
  late final _was = widget.current?.rule;
  late var _never = _was == null;

  /// Whether the last day's calendar is open.
  var _picking = false;
  late var _kind = switch (_was?.kind) {
    RepeatKind.days || RepeatKind.weeks || RepeatKind.months => RepeatKind.days,
    final kind? => kind,
    null => RepeatKind.weekly,
  };
  late var _days = _was?.weekdays?.fold(0, (bits, d) => bits | weekdayBit(d)) ?? weekdayBit(widget.start.weekday);
  late var _every = switch (_was) {
    final r? when r.kind == RepeatKind.days || r.kind == RepeatKind.weeks || r.kind == RepeatKind.months => r.every,
    _ => 2,
  };

  /// Custom's unit: days, weeks or months.
  late var _unit = switch (_was?.kind) {
    final kind? when kind == RepeatKind.weeks || kind == RepeatKind.months => kind,
    _ => RepeatKind.days,
  };
  late var _date = switch (_was) {
    final r? when r.kind == RepeatKind.monthly => r.every,
    _ => widget.start.day,
  };
  late var _years = switch (_was) {
    final r? when r.kind == RepeatKind.yearly => r.every,
    _ => 1,
  };

  RepeatRule get _rule => switch (_kind) {
    RepeatKind.weekly => RepeatRule.weekly({
      for (var d = 1; d <= 7; d++)
        if (_days & weekdayBit(d) != 0) d,
    }),
    RepeatKind.monthly => RepeatRule.monthly(_date),
    RepeatKind.yearly => RepeatRule.yearly(_years),
    _ when _unit == RepeatKind.months => RepeatRule.months(_every),
    _ => RepeatRule.every(_every, weeks: _unit == RepeatKind.weeks),
  };

  void _set(VoidCallback change) {
    setState(change);
    widget.onChanged(_never ? null : (rule: _rule, until: widget.current?.until));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = TextStyle(fontFamily: Fonts.ui, fontSize: 13.5, color: p.ink);
    final until = widget.current?.until;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Each row shrinks only when text too large for the dialog's one
        // width would otherwise cut it off.
        _ScaleDown(
          child: _Pills(
            options: const ['Never', 'Weekly', 'Monthly', 'Yearly', 'Custom'],
            selected: _never
                ? 0
                : switch (_kind) {
                    RepeatKind.weekly => 1,
                    RepeatKind.monthly => 2,
                    RepeatKind.yearly => 3,
                    _ => 4,
                  },
            onSelect: (i) => _set(() {
              _never = i == 0;
              if (i > 0) _kind = [RepeatKind.weekly, RepeatKind.monthly, RepeatKind.yearly, RepeatKind.days][i - 1];
            }),
          ),
        ),
        _FoldAway(
          folded: _never,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 18),
              SizedBox(
                height: 40,
                child: _ScaleDown(
                  child: switch (_kind) {
                    RepeatKind.weekly => DayToggles(
                      bits: _days,
                      size: 30,
                      lastReason: 'It needs at least one day',
                      onChanged: (bits) => _set(() => _days = bits),
                    ),
                    RepeatKind.monthly => Row(
                      children: [
                        Text('On the', style: label),
                        _Stepper(value: _date, min: 1, max: 31, onChanged: (v) => _set(() => _date = v)),
                        Text('${ordinal(_date).substring('$_date'.length)} of each month', style: label),
                      ],
                    ),
                    RepeatKind.yearly => Row(
                      children: [
                        Text('Every', style: label),
                        _Stepper(value: _years, min: 1, max: 99, onChanged: (v) => _set(() => _years = v)),
                        Text(
                          '${_years == 1 ? 'year' : 'years'} on ${monthNames[widget.start.month - 1].substring(0, 3)} ${widget.start.day}',
                          style: label,
                        ),
                      ],
                    ),
                    _ => Row(
                      children: [
                        Text('Every', style: label),
                        _Stepper(value: _every, min: 1, max: 99, onChanged: (v) => _set(() => _every = v)),
                        const SizedBox(width: 6),
                        _Pills(
                          options: const ['days', 'weeks', 'months'],
                          selected: [RepeatKind.days, RepeatKind.weeks, RepeatKind.months].indexOf(_unit),
                          onSelect: (i) =>
                              _set(() => _unit = [RepeatKind.days, RepeatKind.weeks, RepeatKind.months][i]),
                        ),
                        if (_unit == RepeatKind.months)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text('on the ${ordinal(widget.start.day)}', style: label),
                          ),
                      ],
                    ),
                  },
                ),
              ),
              if ((_kind == RepeatKind.monthly && _date > 28) ||
                  (_kind == RepeatKind.days && _unit == RepeatKind.months && widget.start.day > 28))
                Text(
                  'In shorter months, on the last day.',
                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 12, color: p.inkMuted),
                ),
              if (_kind == RepeatKind.yearly && widget.start.month == 2 && widget.start.day == 29)
                Text(
                  'Only in leap years.',
                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 12, color: p.inkMuted),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.event_outlined, size: 18),
                        label: Text(until == null ? 'No end date' : 'Until ${dayMonth(until)}/${until.year}'),
                        onPressed: () => setState(() => _picking = !_picking),
                      ),
                    ),
                  ),
                  if (until != null)
                    IconButton(
                      tooltip: 'No end date',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => widget.onChanged((rule: _rule, until: null)),
                    ),
                ],
              ),
              _FoldAway(
                folded: !_picking,
                child: _MonthCalendar(
                  first: widget.start,
                  selected: until ?? widget.start,
                  onSelected: (day) {
                    setState(() => _picking = false);
                    widget.onChanged((rule: _rule, until: day));
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// [child] at its own size, at the left, or smaller to fit if it's too
/// wide.
class _ScaleDown extends StatelessWidget {
  const _ScaleDown({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: child);
}

/// A row of choices, one filled.
class _Pills extends StatelessWidget {
  const _Pills({required this.options, required this.selected, required this.onSelect});

  final List<String> options;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.85)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, option) in options.indexed)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: AnimatedContainer(
                  duration: Motion.click,
                  curve: Motion.clickCurve,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: i == selected ? p.done : Colors.transparent,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Text(
                    option,
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: i == selected ? p.onAccent : p.inkMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A number with buttons either side to take one off or add one.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.min, required this.max, required this.onChanged});

  final int value, min, max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TaskAction(
          tooltip: 'Fewer',
          icon: Icons.remove_rounded,
          onPressed: value > min ? () => onChanged(value - 1) : null,
        ),
        SizedBox(
          width: 28,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        _TaskAction(
          tooltip: 'More',
          icon: Icons.add_rounded,
          onPressed: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}

/// Names a subtask, and sets whether its task numbers all its subtasks.
class _SubtaskDialog extends StatefulWidget {
  const _SubtaskDialog({required this.text, required this.numbered});
  final String text;
  final bool numbered;
  @override
  State<_SubtaskDialog> createState() => _SubtaskDialogState();
}

class _SubtaskDialogState extends State<_SubtaskDialog> {
  late final _text = TextEditingController(text: widget.text);
  late bool _numbered = widget.numbered;
  void _save() {
    if (_text.text.trim().isNotEmpty) Navigator.pop(context, (text: _text.text.trim(), numbered: _numbered));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ConfirmOnEnter(
    onConfirm: _save,
    child: AlertDialog(
      title: Text(widget.text.isEmpty ? 'Add subtask' : 'Edit subtask'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              inputFormatters: const [NoteInputFormatter()],
              controller: _text,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Subtask'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 14),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _numbered = !_numbered),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Number the subtasks',
                        style: TextStyle(fontFamily: Fonts.ui, fontSize: 13.5, color: context.palette.ink),
                      ),
                    ),
                    SettingToggle(on: _numbered),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    ),
  );
}

/// Task fades are separate from the ritual grid’s row animations.
