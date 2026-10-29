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

/// What a task's dialog shows: its own page, or one of the task's details
/// in its place.
enum _Page { main, day, time, repeat, until }

/// How wide a task's dialog is on every page: wide enough for the repeat
/// page's custom row.
const _taskDialogWidth = 408.0;

/// A task's time and repeat, each set on a page of its own in place of
/// the dialog's main one, and the repeat's last day on another. They
/// change as they're set: going back keeps what a page set, cancelling
/// it puts back what was there.
mixin _DetailPages<T extends StatefulWidget> on State<T> {
  _Page _page = _Page.main;
  int? _time;
  _RepeatChoice? _repeat;

  /// What each page open over the main one found, to put back on cancel.
  final _was = <({int? time, _RepeatChoice? repeat})>[];

  void _open(_Page page) => setState(() {
    _was.add((time: _time, repeat: _repeat));
    _page = page;
  });

  /// Back to the page this one opened from, keeping what it set or not.
  void _leave({required bool keep}) => setState(() {
    final was = _was.removeLast();
    if (!keep) {
      _time = was.time;
      _repeat = was.repeat;
    }
    _page = _page == _Page.until ? _Page.repeat : _Page.main;
  });

  /// Back, keeping what this page set; null on the main page.
  VoidCallback? get _back => _page == _Page.main ? null : () => _leave(keep: true);

  /// Back, putting back what this page changed; null on the main page.
  VoidCallback? get _cancel => _page == _Page.main ? null : () => _leave(keep: false);

  Widget _timeRow() =>
      _TimeRow(time: _time, onOpen: () => _open(_Page.time), onClear: () => setState(() => _time = null));

  Widget _repeatRow() =>
      _RepeatRow(repeat: _repeat, onOpen: () => _open(_Page.repeat), onClear: () => setState(() => _repeat = null));

  /// The time, repeat or last day's page, for a task first due on [start].
  Widget _detailPage(DateTime start) {
    final back = _back!;
    return switch (_page) {
      _Page.time => _SubPage(
        title: 'Time',
        onBack: back,
        child: TimeWheel(
          initial: _time ?? 9 * 60,
          unset: _time == null,
          onChanged: (time) => setState(() => _time = time),
          onDone: back,
        ),
      ),
      _Page.until => _SubPage(
        title: 'Repeat until',
        onBack: back,
        child: _MonthCalendar(
          first: start,
          selected: _repeat?.until ?? start,
          onSelected: (day) {
            if (_repeat case final repeat?) _repeat = (rule: repeat.rule, until: day);
            _leave(keep: true);
          },
        ),
      ),
      _ => _SubPage(
        title: 'Repeat',
        onBack: back,
        child: _RepeatPanel(
          start: start,
          current: _repeat,
          onChanged: (repeat) => setState(() => _repeat = repeat),
          onPickUntil: () => _open(_Page.until),
        ),
      ),
    };
  }
}

/// One of a dialog's pages in place of its main one: a back arrow and
/// [title] over [child].
class _SubPage extends StatelessWidget {
  const _SubPage({required this.title, required this.onBack, required this.child});

  final String title;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(tooltip: 'Back', onPressed: onBack, icon: const Icon(Icons.arrow_back_rounded)),
          const SizedBox(width: 4),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
      const SizedBox(height: 4),
      child,
    ],
  );
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
  state.removeTogether(() {
    removeOne();
    if (future) state.endRepeat(repeat, item.repeatDay ?? day);
  });
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

/// "Every Mon, Wed until 12/12/2026".
String _repeatLabel(_RepeatChoice choice) {
  final until = choice.until;
  return until == null ? choice.rule.label : '${choice.rule.label} until ${dayMonth(until)}/${until.year}';
}

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

/// A task's time: "Add a time", or its time, opening the wheel; a cross
/// makes it all day.
class _TimeRow extends StatelessWidget {
  const _TimeRow({required this.time, required this.onOpen, required this.onClear});

  final int? time;
  final VoidCallback onOpen, onClear;

  @override
  Widget build(BuildContext context) {
    final time = this.time;
    return _DetailRow(
      icon: Icons.schedule_rounded,
      label: time == null ? 'Add a time' : clockLabel(time),
      onPressed: onOpen,
      clear: 'All day',
      onClear: time == null ? null : onClear,
    );
  }
}

/// How a task repeats, opening its repeat; a cross stops it.
class _RepeatRow extends StatelessWidget {
  const _RepeatRow({required this.repeat, required this.onOpen, required this.onClear});

  final _RepeatChoice? repeat;
  final VoidCallback onOpen, onClear;

  @override
  Widget build(BuildContext context) {
    final repeat = this.repeat;
    return _DetailRow(
      icon: Icons.repeat_rounded,
      label: repeat == null ? "Doesn't repeat" : _repeatLabel(repeat),
      onPressed: onOpen,
      clear: 'Stop repeating',
      onClear: repeat == null ? null : onClear,
    );
  }
}

/// [repeat], or every year for a [birthday] that doesn't already.
_RepeatChoice? _birthdayRepeat(bool birthday, _RepeatChoice? repeat) =>
    !birthday || repeat?.rule == const RepeatRule.yearly(1) ? repeat : (rule: const RepeatRule.yearly(1), until: null);

/// [child] (the time and repeat) folded away for a birthday: it fades out
/// in the first half while the rows below slide up over the whole, and
/// back the other way.
class _BirthdayFold extends StatefulWidget {
  const _BirthdayFold({required this.folded, required this.child});

  final bool folded;
  final Widget child;

  @override
  State<_BirthdayFold> createState() => _BirthdayFoldState();
}

class _BirthdayFoldState extends State<_BirthdayFold> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Motion.morph, value: widget.folded ? 0 : 1);
  late final _height = CurvedAnimation(parent: _controller, curve: Motion.morphCurve);
  late final _opacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.5, 1, curve: Motion.morphCurve),
  );

  @override
  void didUpdateWidget(_BirthdayFold old) {
    super.didUpdateWidget(old);
    if (widget.folded != old.folded) widget.folded ? _controller.reverse() : _controller.forward();
  }

  @override
  void dispose() {
    _height.dispose();
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _height,
    alignment: Alignment.topCenter,
    child: FadeTransition(
      opacity: _opacity,
      child: IgnorePointer(
        ignoring: widget.folded,
        child: ExcludeFocus(excluding: widget.folded, child: widget.child),
      ),
    ),
  );
}

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

class _EditTaskDialogState extends State<_EditTaskDialog> with _DetailPages {
  late final _text = TextEditingController(text: widget.item.text);
  final _textFocus = FocusNode();

  /// Where the cursor was in the name when a page opened over it.
  TextSelection _selection = const TextSelection.collapsed(offset: -1);
  late DateTime? _due = widget.item.dueDate;

  /// Kept as it is: whether it's a birthday is only set when it's added.
  late final bool _birthday = widget.item.birthday;

  @override
  void initState() {
    super.initState();
    _time = widget.item.dueTime;
    _repeat = switch (widget.repeat) {
      final r? => (rule: r.rule, until: r.until),
      null => null,
    };
  }

  @override
  void dispose() {
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  @override
  void _open(_Page page) {
    if (_page == _Page.main) _selection = _text.selection;
    super._open(page);
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
    final p = context.palette;
    final today = AppScope.read(context).today;
    final start = widget.item.repeatDay ?? _due ?? today;
    return PagedDialog(
      onReturn: () => _refocus(_textFocus, _text, _selection),
      page: _page,
      onConfirm: _save,
      onBack: _back,
      width: _taskDialogWidth,
      backgroundColor: p.tile,
      actions: [
        TextButton(onPressed: _cancel ?? () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _back ?? _save, child: const Text('Save')),
      ],
      child: switch (_page) {
        _Page.main => _main(today),
        _Page.day => _SubPage(
          title: 'Due date',
          onBack: _back!,
          child: _MonthCalendar(
            first: today,
            selected: _due ?? today,
            onSelected: (day) {
              _due = day;
              _leave(keep: true);
            },
          ),
        ),
        _ => _detailPage(start.isBefore(today) ? today : start),
      },
    );
  }

  Widget _main(DateTime today) {
    final dated = widget.scope == TodoScope.week || widget.scope == TodoScope.month;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Edit task', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        TextField(
          inputFormatters: const [NoteInputFormatter()],
          controller: _text,
          focusNode: _textFocus,
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
            onPressed: () => _open(_Page.day),
          ),
        ],
        const SizedBox(height: 4),
        _FoldAway(folded: _birthday, child: _timeRow()),
        _FoldAway(folded: _birthday, child: _repeatRow()),
        const SizedBox(height: 16),
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
