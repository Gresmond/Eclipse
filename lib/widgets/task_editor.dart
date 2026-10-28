part of 'todo_panel.dart';

/// A day from [first] on (to [last], if given), opening on [selected].
Future<DateTime?> _pickDate(BuildContext context, {required DateTime first, DateTime? last, DateTime? selected}) async {
  final picked = await showAppDialog<_DayChoice>(
    context: context,
    builder: (_) => _DueDateDialog(first: first, last: last, due: selected),
  );
  return picked?.day;
}

/// A day, how a task first due on it repeats, its time and its category.
typedef _DayChoice = ({DateTime day, _RepeatChoice? repeat, int? time, TaskCategory? category});

/// A new task's day, as [_pickDate], with its time, repeat and category
/// set under the calendar. Without [calendar], [selected] is the day and
/// only those are asked.
Future<_DayChoice?> _pickDayAndRepeat(
  BuildContext context, {
  required DateTime first,
  DateTime? last,
  DateTime? selected,
  _RepeatChoice? repeat,
  int? time,
  TaskCategory? category,
  bool calendar = true,
}) => showAppDialog<_DayChoice>(
  context: context,
  builder: (_) => _DueDateDialog(
    first: first,
    last: last,
    due: selected,
    details: true,
    repeat: repeat,
    time: time,
    category: category,
    calendar: calendar,
  ),
);

/// A calendar between two days, with no redundant date header, and with
/// [details] the time, repeat and category under it.
class _DueDateDialog extends StatefulWidget {
  const _DueDateDialog({
    required this.first,
    this.last,
    this.due,
    this.details = false,
    this.repeat,
    this.time,
    this.category,
    this.calendar = true,
  });

  final DateTime first;
  final DateTime? last;
  final DateTime? due;
  final bool details, calendar;
  final _RepeatChoice? repeat;
  final int? time;
  final TaskCategory? category;

  @override
  State<_DueDateDialog> createState() => _DueDateDialogState();
}

class _DueDateDialogState extends State<_DueDateDialog> {
  /// Every month shows six weeks' rows, so the dialog (and its arrows)
  /// stays put as the months go by.
  static const _weeks = 6;

  late final DateTime _first;
  late final DateTime? _last;
  late DateTime _selected;
  late DateTime _month;
  late _RepeatChoice? _repeat = widget.repeat;
  late int? _time = widget.time;
  late TaskCategory? _category = widget.category;

  void _done() => Navigator.pop<_DayChoice>(
    context,
    (day: _selected, repeat: _repeat, time: _time, category: _category),
  );

  @override
  void initState() {
    super.initState();
    _first = DateUtils.dateOnly(widget.first);
    _last = widget.last == null ? null : DateUtils.dateOnly(widget.last!);
    final due = widget.due == null ? _first : DateUtils.dateOnly(widget.due!);
    _selected = due.isBefore(_first) ? _first : (_last != null && due.isAfter(_last) ? _last : due);
    _month = DateTime(_selected.year, _selected.month);
  }

  void _moveMonth(int offset) {
    setState(() => _month = DateTime(_month.year, _month.month + offset));
  }

  /// A birthday comes round every year, unless another repeat was set.
  void _pickCategory(TaskCategory? category) => setState(() {
    _category = category;
    if (category == TaskCategory.birthday && _repeat == null) {
      _repeat = (rule: const RepeatRule.yearly(1), until: null);
    }
  });

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final firstMonth = DateTime(_first.year, _first.month);
    final last = _last;
    final lastMonth = last == null ? null : DateTime(last.year, last.month);
    // Weeks start on Monday, as everywhere else in the app.
    final leading = DateTime(_month.year, _month.month).weekday - 1;
    final days = DateUtils.getDaysInMonth(_month.year, _month.month);

    return ConfirmOnEnter(
      onConfirm: _done,
      preserveButtons: false,
      child: AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        content: SizedBox(
          width: 336,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.calendar) ...[
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          localizations.formatMonthYear(_month),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
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
                for (var row = 0; row < _weeks; row++)
                  Row(
                    children: [
                      for (var column = 0; column < 7; column++)
                        Expanded(child: _buildDay(row * 7 + column - leading + 1, days, localizations, colors)),
                    ],
                  ),
              ],
              if (widget.details) ...[
                SizedBox(height: widget.calendar ? 8 : 4),
                _TimeRow(time: _time, onChanged: (time) => setState(() => _time = time)),
                _RepeatRow(
                  repeat: _repeat,
                  start: _selected,
                  onChanged: (repeat) => setState(() => _repeat = repeat),
                ),
                const SizedBox(height: 4),
                _CategoryRow(category: _category, onChanged: _pickCategory),
                const SizedBox(height: 4),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(localizations.cancelButtonLabel)),
          TextButton(onPressed: _done, child: Text(localizations.okButtonLabel)),
        ],
      ),
    );
  }

  Widget _buildDay(int day, int days, MaterialLocalizations localizations, ColorScheme colors) {
    if (day < 1 || day > days) return const SizedBox(height: 42);
    final date = DateTime(_month.year, _month.month, day);
    final enabled = !date.isBefore(_first) && (_last == null || !date.isAfter(_last));
    final selected = DateUtils.isSameDay(date, _selected);
    final today = DateUtils.isSameDay(date, AppScope.read(context).today);
    return SizedBox(
      height: 42,
      child: Semantics(
        selected: selected,
        label: localizations.formatFullDate(date),
        child: TextButton(
          onPressed: enabled ? () => setState(() => _selected = date) : null,
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

/// A repeat chosen in a dialog: its rule, and the last day it may come
/// round on.
typedef _RepeatChoice = ({RepeatRule rule, DateTime? until});

/// What the editor saved; [repeat] null when it doesn't repeat.
typedef _TaskEdit = ({String text, DateTime? due, _RepeatChoice? repeat, int? time, TaskCategory? category});

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
  final (time, category) = (result.time, result.category);
  if (repeat == null) {
    if (choice == null) {
      state.editTodo(scope, item, result.text, result.due, day: day, time: time, category: category);
    } else {
      state.makeRepeating(scope, item, result.text, choice.rule, until: choice.until, time: time, category: category);
    }
    return;
  }
  final from = item.repeatDay ?? day;
  if (choice?.rule != repeat.rule || choice?.until != repeat.until) {
    state.changeRepeat(repeat, from, result.text, choice?.rule, until: choice?.until, time: time, category: category);
    return;
  }
  final renamed = result.text.trim() != item.text || (time, category) != (item.dueTime, item.category);
  if (!renamed && result.due == item.dueDate) return;
  final future = renamed ? await _askWhich(context, removing: false) : false;
  if (future == null || !context.mounted) return;
  if (future) state.renameRepeat(repeat, result.text, from, time: time, category: category);
  if (!future || result.due != item.dueDate) {
    state.editTodo(scope, make?.call() ?? item, result.text, result.due, day: day, time: time, category: category);
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
  if (future) {
    state.endRepeat(repeat, item.repeatDay ?? day);
  } else {
    removeOne();
  }
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

/// Opens the repeat dialog for a task first due on [start]. Null if
/// cancelled; otherwise the choice, whose own value is null for "doesn't
/// repeat".
Future<({_RepeatChoice? choice})?> _pickRepeat(BuildContext context, DateTime start, _RepeatChoice? current) =>
    showAppDialog<({_RepeatChoice? choice})>(
      context: context,
      builder: (_) => _RepeatDialog(start: start, current: current),
    );

/// "Every Mon, Wed until 12/12/2026".
String _repeatLabel(_RepeatChoice choice) {
  final until = choice.until;
  return until == null ? choice.rule.label : '${choice.rule.label} until ${dayMonth(until)}/${until.year}';
}

/// A task's time: "Add a time", or its time, opening the wheel.
class _TimeRow extends StatelessWidget {
  const _TimeRow({required this.time, required this.onChanged});

  final int? time;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded, size: 18, color: p.inkMuted),
          const SizedBox(width: 10),
          TimePill(minutes: time, start: 9 * 60, placeholder: 'Add a time', alignLeft: true, onChanged: onChanged),
          if (time != null)
            IconButton(
              tooltip: 'All day',
              iconSize: 18,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => onChanged(null),
            ),
        ],
      ),
    );
  }
}

/// How a task repeats, opening the repeat dialog for one first due on
/// [start]; a cross stops it.
class _RepeatRow extends StatelessWidget {
  const _RepeatRow({required this.repeat, required this.start, required this.onChanged});

  final _RepeatChoice? repeat;
  final DateTime start;
  final ValueChanged<_RepeatChoice?> onChanged;

  @override
  Widget build(BuildContext context) {
    final repeat = this.repeat;
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.repeat_rounded, size: 18),
              label: Text(repeat == null ? "Doesn't repeat" : _repeatLabel(repeat)),
              onPressed: () async {
                final picked = await _pickRepeat(context, start, repeat);
                if (picked != null && context.mounted) onChanged(picked.choice);
              },
            ),
          ),
        ),
        if (repeat != null)
          IconButton(
            tooltip: 'Stop repeating',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => onChanged(null),
          ),
      ],
    );
  }
}

/// A task's category, one pill each: clicking the lit one clears it.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category, required this.onChanged});

  final TaskCategory? category;
  final ValueChanged<TaskCategory?> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 4,
        runSpacing: 6,
        children: [
          for (final c in TaskCategory.values)
            CategoryChip(category: c, selected: c == category, onTap: () => onChanged(c == category ? null : c)),
        ],
      ),
    ),
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

class _EditTaskDialogState extends State<_EditTaskDialog> {
  late final _text = TextEditingController(text: widget.item.text);
  late DateTime? _due = widget.item.dueDate;
  late _RepeatChoice? _repeat = switch (widget.repeat) {
    final r? => (rule: r.rule, until: r.until),
    null => null,
  };
  late int? _time = widget.item.dueTime;
  late TaskCategory? _category = widget.item.category;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    if (_text.text.trim().isEmpty) return;
    Navigator.pop<_TaskEdit>(
      context,
      (text: _text.text, due: _due, repeat: _repeat, time: _time, category: _category),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final today = AppScope.read(context).today;
    final dated = widget.scope == TodoScope.week || widget.scope == TodoScope.month;
    final start = widget.item.repeatDay ?? _due ?? today;
    return ConfirmOnEnter(
      onConfirm: _save,
      child: AlertDialog(
        backgroundColor: p.tile,
        title: const Text('Edit task'),
        content: SizedBox(
          width: 380,
          child: Column(
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
                  onPressed: () async {
                    final selected = await _pickDate(context, first: today, selected: _due);
                    if (selected != null && mounted) setState(() => _due = selected);
                  },
                ),
              ],
              const SizedBox(height: 4),
              _TimeRow(time: _time, onChanged: (time) => setState(() => _time = time)),
              _RepeatRow(
                repeat: _repeat,
                start: start.isBefore(today) ? today : start,
                onChanged: (repeat) => setState(() => _repeat = repeat),
              ),
              const SizedBox(height: 4),
              _CategoryRow(category: _category, onChanged: (category) => setState(() => _category = category)),
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
}

/// How a task repeats: on chosen weekdays, on a date each month, on its
/// date every so many years, or every so many days or weeks, with an
/// optional last day.
class _RepeatDialog extends StatefulWidget {
  const _RepeatDialog({required this.start, this.current});

  /// The first day it would come round from.
  final DateTime start;
  final _RepeatChoice? current;

  @override
  State<_RepeatDialog> createState() => _RepeatDialogState();
}

class _RepeatDialogState extends State<_RepeatDialog> {
  late final _was = widget.current?.rule;
  late var _kind = switch (_was?.kind) {
    RepeatKind.days || RepeatKind.weeks => RepeatKind.days,
    final kind? => kind,
    null => RepeatKind.weekly,
  };
  late var _days = _was?.weekdays?.fold(0, (bits, d) => bits | weekdayBit(d)) ?? weekdayBit(widget.start.weekday);
  late var _every = switch (_was) {
    final r? when r.kind == RepeatKind.days || r.kind == RepeatKind.weeks => r.every,
    _ => 2,
  };
  late var _weeks = _was?.kind == RepeatKind.weeks;
  late var _date = switch (_was) {
    final r? when r.kind == RepeatKind.monthly => r.every,
    _ => widget.start.day,
  };
  late var _years = switch (_was) {
    final r? when r.kind == RepeatKind.yearly => r.every,
    _ => 1,
  };
  late DateTime? _until = widget.current?.until;

  RepeatRule get _rule => switch (_kind) {
    RepeatKind.weekly => RepeatRule.weekly({
      for (var d = 1; d <= 7; d++)
        if (_days & weekdayBit(d) != 0) d,
    }),
    RepeatKind.monthly => RepeatRule.monthly(_date),
    RepeatKind.yearly => RepeatRule.yearly(_years),
    _ => RepeatRule.every(_every, weeks: _weeks),
  };

  void _save() => Navigator.pop<({_RepeatChoice? choice})>(context, (choice: (rule: _rule, until: _until)));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = TextStyle(fontFamily: Fonts.ui, fontSize: 13.5, color: p.ink);
    return ConfirmOnEnter(
      onConfirm: _save,
      child: AlertDialog(
        backgroundColor: p.tile,
        title: const Text('Repeat'),
        // At least this wide, and wider when the choices need it, so every
        // word shows in full at any text size.
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Pills(
                options: const ['Weekly', 'Monthly', 'Yearly', 'Custom'],
                selected: switch (_kind) {
                  RepeatKind.weekly => 0,
                  RepeatKind.monthly => 1,
                  RepeatKind.yearly => 2,
                  _ => 3,
                },
                onSelect: (i) => setState(
                  () => _kind = [RepeatKind.weekly, RepeatKind.monthly, RepeatKind.yearly, RepeatKind.days][i],
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 40,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: switch (_kind) {
                    RepeatKind.weekly => DayToggles(
                      bits: _days,
                      size: 30,
                      lastReason: 'It needs at least one day',
                      onChanged: (bits) => setState(() => _days = bits),
                    ),
                    RepeatKind.monthly => Row(
                      children: [
                        Text('On the', style: label),
                        _Stepper(value: _date, min: 1, max: 31, onChanged: (v) => setState(() => _date = v)),
                        Text('${ordinal(_date).substring('$_date'.length)} of each month', style: label),
                      ],
                    ),
                    RepeatKind.yearly => Row(
                      children: [
                        Text('Every', style: label),
                        _Stepper(value: _years, min: 1, max: 99, onChanged: (v) => setState(() => _years = v)),
                        Text(
                          '${_years == 1 ? 'year' : 'years'} on ${monthNames[widget.start.month - 1].substring(0, 3)} ${widget.start.day}',
                          style: label,
                        ),
                      ],
                    ),
                    _ => Row(
                      children: [
                        Text('Every', style: label),
                        _Stepper(value: _every, min: 1, max: 99, onChanged: (v) => setState(() => _every = v)),
                        const SizedBox(width: 6),
                        _Pills(
                          options: const ['days', 'weeks'],
                          selected: _weeks ? 1 : 0,
                          onSelect: (i) => setState(() => _weeks = i == 1),
                        ),
                      ],
                    ),
                  },
                ),
              ),
              if (_kind == RepeatKind.monthly && _date > 28)
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
                        label: Text(_until == null ? 'No end date' : 'Until ${dayMonth(_until!)}/${_until!.year}'),
                        onPressed: () async {
                          final picked = await _pickDate(context, first: widget.start, selected: _until);
                          if (picked != null && mounted) setState(() => _until = picked);
                        },
                      ),
                    ),
                  ),
                  if (_until != null)
                    IconButton(
                      tooltip: 'No end date',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() => _until = null),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          if (widget.current != null)
            TextButton(
              onPressed: () => Navigator.pop<({_RepeatChoice? choice})>(context, (choice: null)),
              child: const Text("Don't repeat"),
            ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
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
