part of 'todo_panel.dart';

Future<DateTime?> _pickDueDate(BuildContext context, DateTime? due, TodoScope scope) {
  return showAppDialog<DateTime>(
    context: context,
    builder: (_) => _DueDateDialog(today: AppScope.read(context).today, due: due, scope: scope),
  );
}

/// A calendar with a rolling week or month limit and no redundant date header.
class _DueDateDialog extends StatefulWidget {
  const _DueDateDialog({required this.today, required this.scope, this.due});

  final DateTime today;
  final TodoScope scope;
  final DateTime? due;

  @override
  State<_DueDateDialog> createState() => _DueDateDialogState();
}

class _DueDateDialogState extends State<_DueDateDialog> {
  late final DateTime _first;
  late final DateTime _last;
  late DateTime _selected;
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    _first = DateUtils.dateOnly(widget.today);
    final nextMonth = DateTime(_first.year, _first.month + 1);
    final nextMonthDays = DateUtils.getDaysInMonth(nextMonth.year, nextMonth.month);
    _last = widget.scope == TodoScope.week
        ? DateTime(_first.year, _first.month, _first.day + 7)
        : DateTime(_first.year, _first.month + 1, math.min(_first.day, nextMonthDays));
    final due = widget.due == null ? _first : DateUtils.dateOnly(widget.due!);
    _selected = due.isBefore(_first) ? _first : (due.isAfter(_last) ? _last : due);
    _month = DateTime(_selected.year, _selected.month);
  }

  void _moveMonth(int offset) {
    setState(() => _month = DateTime(_month.year, _month.month + offset));
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final firstMonth = DateTime(_first.year, _first.month);
    final lastMonth = DateTime(_last.year, _last.month);
    final leading = DateUtils.firstDayOffset(_month.year, _month.month, localizations);
    final days = DateUtils.getDaysInMonth(_month.year, _month.month);
    final cells = ((leading + days) / 7).ceil() * 7;

    return ConfirmOnEnter(
      onConfirm: () => Navigator.pop(context, _selected),
      preserveButtons: false,
      child: AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        content: SizedBox(
          width: 308,
          child: Column(
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
                    onPressed: _month.isBefore(lastMonth) ? () => _moveMonth(1) : null,
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
                            localizations.narrowWeekdays[(localizations.firstDayOfWeekIndex + i) % 7],
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              for (var row = 0; row < cells ~/ 7; row++)
                Row(
                  children: [
                    for (var column = 0; column < 7; column++)
                      Expanded(child: _buildDay(row * 7 + column - leading + 1, days, localizations, colors)),
                  ],
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(localizations.cancelButtonLabel)),
          TextButton(onPressed: () => Navigator.pop(context, _selected), child: Text(localizations.okButtonLabel)),
        ],
      ),
    );
  }

  Widget _buildDay(int day, int days, MaterialLocalizations localizations, ColorScheme colors) {
    if (day < 1 || day > days) return const SizedBox(height: 42);
    final date = DateTime(_month.year, _month.month, day);
    final enabled = !date.isBefore(_first) && !date.isAfter(_last);
    final selected = DateUtils.isSameDay(date, _selected);
    final today = DateUtils.isSameDay(date, _first);
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

/// The round tick, animated like a ritual square: the fill blends in, the
/// tick grows in after it, and it dips when pressed and lifts on hover.
class _EditTaskDialog extends StatefulWidget {
  const _EditTaskDialog({required this.item, required this.scope, required this.day});
  final TodoItem item;
  final TodoScope scope;
  final DateTime day;

  @override
  State<_EditTaskDialog> createState() => _EditTaskDialogState();
}

class _EditTaskDialogState extends State<_EditTaskDialog> {
  late final _text = TextEditingController(text: widget.item.text);
  late DateTime? _due = widget.item.dueDate;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    if (_text.text.trim().isEmpty) return;
    Navigator.pop(context, (text: _text.text, due: _due));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
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
              if (widget.scope == TodoScope.week || widget.scope == TodoScope.month) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        icon: const Icon(Icons.calendar_today_outlined, size: 18),
                        label: Text(_due == null ? 'Add a due date' : 'Due ${dayMonth(_due!)}/${_due!.year}'),
                        onPressed: () async {
                          final selected = await _pickDueDate(context, _due, widget.scope);
                          if (selected != null && mounted) setState(() => _due = selected);
                        },
                      ),
                    ),
                    if (_due != null)
                      IconButton(
                        tooltip: 'Clear due date',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() => _due = null),
                      ),
                  ],
                ),
              ],
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
