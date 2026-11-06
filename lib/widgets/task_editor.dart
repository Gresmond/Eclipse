part of 'todo_panel.dart';

/// A day, how a task first due on it repeats, its time, whether it's a
/// birthday, its reminders and where it is.
typedef _DayChoice = ({DateTime day, _RepeatChoice? repeat, int? time, bool birthday, int reminders, String? location});

/// A new task's day from [first] on (to [last], if given), opening on
/// [selected], with its time and repeat set under the calendar, and with
/// [birthdays] whether it's a birthday.
Future<_DayChoice?> _pickDayAndRepeat(
  BuildContext context, {
  required DateTime first,
  DateTime? last,
  DateTime? selected,
  _RepeatChoice? repeat,
  int? time,
  bool birthday = false,
  bool birthdays = false,
  int reminders = 0,
  String? location,
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
    reminders: reminders,
    location: location,
  ),
);

/// What a task's dialog shows: its own page, or its repeat in its place.
enum _Page { main, repeat }

/// How wide a task's dialog is on every page: wide enough for the repeat
/// page's custom row.
const _taskDialogWidth = 408.0;

/// A task's time, set on a wheel over its row, and its repeat, set with
/// the calendar on a page of its own in place of the dialog's main one.
/// The repeat changes as it's set: going back keeps it, cancelling puts
/// back what was there.
mixin _DetailPages<T extends StatefulWidget> on State<T> {
  _Page _page = _Page.main;
  int? _time;
  _RepeatChoice? _repeat;

  /// Its reminders as chosen; what it gives is [Reminder.allowed] of them.
  int _notify = 0;

  /// Where it happens, typed in under the time.
  final _location = TextEditingController();

  @override
  void dispose() {
    _location.dispose();
    super.dispose();
  }

  /// Its location as saved: null when left blank.
  String? get _place => _location.text.trim().isEmpty ? null : _location.text.trim();

  /// Its location, typed straight in; Enter saves, as in the name.
  Widget _locationRow({required VoidCallback onSubmitted}) =>
      _LocationRow(controller: _location, onSubmitted: onSubmitted);

  /// The day a repeat set on its page comes round from.
  DateTime? _repeatStart;

  /// What each page open over the main one found, to put back on cancel.
  final _was = <({_RepeatChoice? repeat, DateTime? start})>[];

  void _open(_Page page) => setState(() {
    _was.add((repeat: _repeat, start: _repeatStart));
    _page = page;
  });

  /// Back to the main page, keeping what this one set or not.
  void _leave({required bool keep}) => setState(() {
    final was = _was.removeLast();
    if (!keep) {
      _repeat = was.repeat;
      _repeatStart = was.start;
    }
    _page = _Page.main;
  });

  /// Back, keeping what this page set; null on the main page.
  VoidCallback? get _back => _page == _Page.main ? null : () => _leave(keep: true);

  /// Back, putting back what this page changed; null on the main page.
  VoidCallback? get _cancel => _page == _Page.main ? null : () => _leave(keep: false);

  /// Opens the wheel over the row, as the sleep schedule's times do.
  Widget _timeRow() => Builder(
    builder: (anchor) => _TimeRow(
      time: _time,
      onOpen: () async {
        final picked = await pickTime(anchor, minutes: _time, start: 9 * 60, alignLeft: true);
        if (picked != null && mounted) setState(() => _time = picked);
      },
      onClear: () => setState(() => _time = null),
    ),
  );

  /// Its reminders, under the time: shown once it has one, or is a
  /// [birthday].
  Widget _notifyRow({required bool birthday}) =>
      _NotifyRow(bits: _notify, time: _time, birthday: birthday, onChanged: (bits) => setState(() => _notify = bits));

  /// The reminders it gives, as saved.
  int _reminders({required bool birthday}) =>
      Reminder.allowed(_notify, birthday: birthday, time: birthday ? null : _time);

  Widget _repeatRow() =>
      _RepeatRow(repeat: _repeat, onOpen: () => _open(_Page.repeat), onClear: () => setState(() => _repeat = null));

  /// The repeat's page: the calendar from [first] on, its start [start].
  Widget _repeatPage(DateTime first, DateTime start) => _SubPage(
    title: 'Repeat',
    onBack: _back!,
    child: _RepeatPanel(
      first: first,
      start: _repeatStart ?? start,
      onStart: (day) => setState(() => _repeatStart = day),
      repeat: _repeat,
      onRepeat: (repeat) => setState(() => _repeat = repeat),
      startsOn: true,
    ),
  );
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
          IconButton(
            tooltip: 'Back',
            iconSize: Scale.navIcon,
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
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

/// What the editor saved; [repeat] null when it doesn't repeat, and
/// [start] the day it comes round from when that was moved.
typedef _TaskEdit = ({
  String text,
  DateTime? due,
  _RepeatChoice? repeat,
  DateTime? start,
  int? time,
  bool birthday,
  int reminders,
  String? location,
});

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
  final onToday = day == state.today;
  final result = await showAppDialog<_TaskEdit>(
    context: context,
    builder: (_) => _EditTaskDialog(item: item, scope: scope, day: day, repeat: repeat),
  );
  if (result == null || !context.mounted) return;
  // Today's lists stay today's across midnight: saved after the day
  // changed, it changes the task, not the day before's record of it.
  if (onToday) day = state.today;
  final choice = result.repeat;
  final (time, birthday, reminders, location) = (result.time, result.birthday, result.reminders, result.location);
  if (repeat == null) {
    if (choice == null) {
      state.editTodo(
        scope,
        item,
        result.text,
        result.due,
        day: day,
        time: time,
        birthday: birthday,
        reminders: reminders,
        location: location,
      );
    } else {
      state.makeRepeating(
        scope,
        item,
        result.text,
        choice.rule,
        start: result.start,
        until: choice.until,
        time: time,
        birthday: birthday,
        reminders: reminders,
        location: location,
      );
    }
    return;
  }
  final from = item.repeatDay ?? day;
  final moved = choice != null && result.start != null && result.start != from;
  if (choice?.rule != repeat.rule || choice?.until != repeat.until || moved) {
    state.changeRepeat(
      repeat,
      from,
      result.text,
      choice?.rule,
      start: moved ? result.start : null,
      until: choice?.until,
      time: time,
      birthday: birthday,
      reminders: reminders,
      location: location,
    );
    return;
  }
  final renamed =
      result.text.trim() != item.text ||
      (time, birthday, reminders, location) != (item.dueTime, item.birthday, item.reminders, item.location);
  if (!renamed && result.due == item.dueDate) return;
  final future = renamed ? await _askWhich(context, removing: false) : false;
  if (future == null || !context.mounted) return;
  if (onToday) day = state.today;
  if (future) {
    state.renameRepeat(
      repeat,
      result.text,
      from,
      time: time,
      birthday: birthday,
      reminders: reminders,
      location: location,
    );
  }
  if (!future || result.due != item.dueDate) {
    state.editTodo(
      scope,
      make?.call() ?? item,
      result.text,
      result.due,
      day: day,
      time: time,
      birthday: birthday,
      reminders: reminders,
      location: location,
    );
  }
}

/// Removes [item] by [removeOne], or, for a repeating task, that time or
/// every time from it on, as chosen. [removeOne] works out its day when
/// it's called, so an answer given after midnight still takes the task
/// from today's lists.
Future<void> _removeTask(BuildContext context, TodoItem item, DateTime day, VoidCallback removeOne) async {
  final state = AppScope.read(context);
  final repeat = state.repeatOf(item);
  if (repeat == null) return removeOne();
  final onToday = day == state.today;
  final future = await _askWhich(context, removing: true);
  if (future == null || !context.mounted) return;
  if (onToday) day = state.today;
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
  builder: (context) => AppAlertDialog(
    title: removing ? 'Remove repeating task' : 'Change repeating task',
    content: Text(
      removing
          ? 'Remove only this one, or this one and every one after it?'
          : 'Change only this one, or this one and every one after it?',
    ),
    actions: [
      DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(context)),
      DialogConfirm(label: 'Only this one', onPressed: () => Navigator.pop(context, false)),
      DialogConfirm(label: 'This and future ones', onPressed: () => Navigator.pop(context, true)),
    ],
  ),
);

/// "Every Mon, Wed until 12/12/2026".
String _repeatLabel(_RepeatChoice choice) {
  final until = choice.until;
  return until == null ? choice.rule.label : '${choice.rule.label} until ${dayAndMonth(until)}';
}

/// Every detail row's button, set rather than scaled by its label's size,
/// so its icon sits in line with the location's and the reminders'.
final _detailButtonStyle = TextButton.styleFrom(
  padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 16, 0),
  minimumSize: const Size(0, _detailRowHeight),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.standard,
);

/// How tall each detail row is, the typed location's too.
const _detailRowHeight = 40.0;

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
            child: TextButton.icon(
              style: _detailButtonStyle,
              icon: Icon(icon, size: 18),
              label: Text(label),
              onPressed: onPressed,
            ),
          ),
        ),
        // As small as the line, so it doesn't grow when the cross comes.
        if (onClear != null) _TaskAction(tooltip: clear, icon: Icons.close_rounded, onPressed: onClear),
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

/// Where a task happens, typed in on a line like the time's: a pin, the
/// place or "Add a location", and a cross that clears it.
class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.controller, required this.onSubmitted});

  final TextEditingController controller;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = Theme.of(context).textTheme.labelLarge!;
    final accent = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Row(
        children: [
          Expanded(
            child: Container(
              height: _detailRowHeight,
              // Lined up with the time button's icon and label.
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.place_rounded, size: 18, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      textCapitalization: TextCapitalization.sentences,
                      inputFormatters: const [NoteInputFormatter()],
                      style: label.copyWith(color: accent),
                      cursorColor: p.accent,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        hintText: 'Add a location',
                        hintStyle: label.copyWith(color: accent),
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (_) => onSubmitted(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            _TaskAction(tooltip: 'No location', icon: Icons.close_rounded, onPressed: controller.clear),
        ],
      ),
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
      label: repeat == null ? 'Doesn’t repeat' : _repeatLabel(repeat),
      onPressed: onOpen,
      clear: 'Stop repeating',
      onClear: repeat == null ? null : onClear,
    );
  }
}

/// [repeat], or every year for a [birthday] that doesn't already.
_RepeatChoice? _birthdayRepeat(bool birthday, _RepeatChoice? repeat) =>
    !birthday || repeat?.rule == const RepeatRule.yearly(1) ? repeat : (rule: const RepeatRule.yearly(1), until: null);

/// [child] (the time, or the repeat's options) folded away for a
/// birthday: it fades out in the first half while the rows below slide up
/// over the whole, and back the other way.
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
  late final _opacity = CurvedAnimation(parent: _controller, curve: Motion.secondHalf);

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
    _notify = widget.item.reminders;
    _location.text = widget.item.location ?? '';
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
      start: _repeatStart,
      time: _birthday ? null : _time,
      birthday: _birthday,
      reminders: _reminders(birthday: _birthday),
      location: _place,
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
        DialogDismiss(label: 'Cancel', onPressed: _cancel ?? () => Navigator.pop(context)),
        DialogConfirm(label: 'Save', onPressed: _back ?? _save),
      ],
      child: switch (_page) {
        _Page.main => _main(today),
        _ => _repeatPage(today, start.isBefore(today) ? today : start),
      },
    );
  }

  Widget _main(DateTime today) {
    final dated =
        widget.scope == TodoScope.week || widget.scope == TodoScope.month || (widget.day == today && !widget.item.done);
    // The day it's on, for a task kept by its list rather than a due date.
    final on = _due ?? (widget.scope == TodoScope.tomorrow ? DateTime(today.year, today.month, today.day + 1) : today);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Edit task', style: dialogTitleStyle(context.palette)),
        const SizedBox(height: dialogTitleGap),
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
          _MonthCalendar(
            first: today,
            selected: on.isBefore(today) ? today : on,
            onSelected: (day) => setState(() => _due = day),
          ),
        ],
        const SizedBox(height: 4),
        _FoldAway(folded: _birthday, child: _timeRow()),
        _notifyRow(birthday: _birthday),
        _locationRow(onSubmitted: _save),
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
    child: AppAlertDialog(
      title: widget.text.isEmpty ? 'Add subtask' : 'Edit subtask',
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
                        style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: context.palette.ink),
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
        DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(context)),
        DialogConfirm(label: 'Save', onPressed: _save),
      ],
    ),
  );
}

/// Task fades are separate from the ritual grid’s row animations.
