part of 'todo_panel.dart';

/// The field at a card's foot for a new task on a day between [first] and
/// [last]. The calendar button picks the day, its time, how it repeats and,
/// with [birthdays], whether it's a birthday; Enter without a day asks for
/// one.
class _DatedAdd extends StatefulWidget {
  const _DatedAdd({required this.first, this.last, this.birthdays = false, required this.onAdd});

  final DateTime first;
  final DateTime? last;
  final bool birthdays;
  final void Function(String text, _DayChoice choice) onAdd;

  @override
  State<_DatedAdd> createState() => _DatedAddState();
}

class _DatedAddState extends State<_DatedAdd> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  _DayChoice? _choice;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<_DayChoice?> _pick() async {
    final (choice, typing, selection) = (_choice, _focus.hasFocus, _controller.selection);
    final picked = await _pickDayAndRepeat(
      context,
      first: widget.first,
      last: widget.last,
      selected: choice?.day,
      repeat: choice?.repeat,
      time: choice?.time,
      birthday: choice?.birthday ?? false,
      birthdays: widget.birthdays,
      reminders: choice?.reminders ?? 0,
      location: choice?.location,
    );
    if (!mounted) return null;
    // Cancelling clears all that was set up, back to the plain field.
    setState(() => _choice = picked);
    if (picked != null || typing) _refocus(_focus, _controller, selection);
    return picked;
  }

  Future<void> _submit() async {
    if (_controller.text.trim().isEmpty) return;
    // Every task has a day: without one yet, it's asked for.
    final choice = _choice ?? await _pick();
    if (choice == null || !mounted) return;
    widget.onAdd(_controller.text, choice);
    setState(() => _choice = null);
    _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final today = AppScope.read(context).today;
    final choice = _choice, due = choice?.day;
    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 6),
      child: _Field(
        controller: _controller,
        focus: _focus,
        leading: _TaskAction(
          tooltip: due == null ? 'Pick a day' : 'Due ${dayAndMonth(due)}, click to change',
          icon: due == null ? Icons.calendar_today_rounded : Icons.event_available_rounded,
          onPressed: _pick,
        ),
        details: choice == null ? null : _ChosenDetails(choice: choice, today: today),
        onSubmitted: _submit,
      ),
    );
  }
}

/// "+ Add task" under a day, which opens into a field: Enter adds and keeps
/// it open for the next, Escape or clicking away closes it. The calendar
/// button picks the next one's day (this one to start), time and repeat,
/// as at the card's foot.
class _AddTask extends StatefulWidget {
  const _AddTask({required this.day, required this.today, this.past});

  final DateTime day, today;

  /// The past day whose lists it adds to; [day] is that day or the next.
  final DateTime? past;

  @override
  State<_AddTask> createState() => _AddTaskState();
}

class _AddTaskState extends State<_AddTask> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _hover = false;
  _DayChoice? _choice;

  /// While the calendar is open, what it picked stays though the field is
  /// empty.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      setState(() {
        if (!_focus.hasFocus && !_picking && _controller.text.trim().isEmpty) _choice = null;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(AppState state) {
    final text = _controller.text;
    if (text.trim().isEmpty) return _focus.requestFocus();
    if (widget.past case final past?) {
      state.addTodo(widget.day == past ? TodoScope.today : TodoScope.tomorrow, text, day: past);
    } else {
      switch (_choice) {
        case final choice?:
          _addChosen(state, text, choice.day, choice);
        case null:
          _addDue(state, text, widget.day);
      }
      setState(() => _choice = null);
    }
    _controller.clear();
    _focus.requestFocus();
  }

  Future<void> _pick() async {
    setState(() => _picking = true);
    final (choice, selection, today) = (_choice, _controller.selection, widget.today);
    final picked = await _pickDayAndRepeat(
      context,
      first: today,
      last: DateTime(today.year, today.month, today.day + WeekCard.span),
      selected: choice?.day ?? widget.day,
      repeat: choice?.repeat,
      time: choice?.time,
      birthday: choice?.birthday ?? false,
      birthdays: true,
      reminders: choice?.reminders ?? 0,
      location: choice?.location,
    );
    _picking = false;
    if (!mounted) return;
    setState(() => _choice = picked);
    _refocus(_focus, _controller, selection);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final choice = _choice;
    final moved = choice != null && choice.day != widget.day;
    // Its calendar only once it's been clicked, or while a day is picked.
    final timed = widget.past == null && (_focus.hasFocus || _picking || choice != null);
    return Padding(
      padding: const EdgeInsets.only(left: 18, top: 2, bottom: 2),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            _controller.clear();
            _focus.unfocus();
          },
        },
        // Tinted as a task is under the pointer, and while it's typed in.
        child: MouseRegion(
          cursor: SystemMouseCursors.text,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          // Anywhere on the line puts the cursor in, as a text box, not a
          // button.
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _focus.requestFocus(),
            child: HoverFill(
              hover: _hover || _focus.hasFocus || _picking,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    return Row(
                      children: [
                        // Its buttons leave the cursor in the field; the + lines
                        // up with the tick boxes above.
                        TextFieldTapRegion(
                          child: SizedBox(
                            width: 20,
                            height: _TaskAction.size,
                            child: OverflowBox(
                              maxWidth: _TaskAction.size,
                              child: _TaskAction(icon: Icons.add_rounded, onPressed: () => _submit(state)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            focusNode: _focus,
                            textCapitalization: TextCapitalization.sentences,
                            inputFormatters: const [NoteInputFormatter()],
                            // As a task's name, so the line is a task's height.
                            style: _taskInputStyle(p),
                            cursorColor: p.accent,
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: 'Add task',
                              hintStyle: _taskInputStyle(p).copyWith(color: p.inkMuted),
                              contentPadding: EdgeInsets.zero,
                            ),
                            onSubmitted: (_) => _submit(state),
                          ),
                        ),
                        if (timed)
                          TextFieldTapRegion(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (choice != null)
                                  ConstrainedBox(
                                    constraints: BoxConstraints(maxWidth: _detailsRoom(width - 32 - _TaskAction.size)),
                                    child: _ChosenDetails(choice: choice, today: widget.today, showDay: moved),
                                  ),
                                _TaskAction(
                                  tooltip: choice == null
                                      ? 'Pick a day'
                                      : 'Due ${dayAndMonth(choice.day)}, click to change',
                                  icon: choice == null ? Icons.calendar_today_rounded : Icons.event_available_rounded,
                                  onPressed: _pick,
                                ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How wide a field's details may be when [width] is left beside its
/// buttons: the name gives way to them, keeping enough to read what's typed.
double _detailsRoom(double width) => (width - 120).clamp(0, double.infinity);

/// What's chosen for a new task, all of it on one line: its day, unless
/// [showDay] is off, its time, where it is and how it repeats. It shrinks
/// rather than cut any of them off when the field can't hold them.
class _ChosenDetails extends StatelessWidget {
  const _ChosenDetails({required this.choice, required this.today, this.showDay = true});

  final _DayChoice choice;
  final DateTime today;
  final bool showDay;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final note = TextStyle(fontFamily: Fonts.body, fontSize: 12, color: p.inkMuted);
    final (time, location, repeat) = (choice.time, choice.location, choice.repeat);
    Widget label(IconData icon, String text, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(text, style: note.copyWith(color: color)),
      ],
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          if (showDay) Text(dayAndMonth(choice.day, today: today), style: note),
          if (time != null) Text(clockLabel(time), style: _timeStyle(p).copyWith(fontSize: 12)),
          if (location != null) label(Icons.place_rounded, location, p.inkMuted),
          if (repeat != null)
            label(
              choice.birthday ? _birthdayIcon : Icons.repeat_rounded,
              choice.birthday ? 'Birthday' : _repeatLabel(repeat),
              p.accent,
            ),
        ],
      ),
    );
  }
}

/// A task's time, in the sleep schedule's semi-mono.
TextStyle _timeStyle(Palette p) => SleepName.timeStyle(p);

/// Both task-entry fields use the same typography as the tasks they create.
TextStyle _taskInputStyle(Palette p) => TextStyle(fontFamily: Fonts.body, fontSize: 15, height: 1.35, color: p.ink);

/// A rounded field for a new task's name, as at the foot of a to-do card.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.focus,
    required this.leading,
    this.details,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final Widget leading;
  final Widget? details;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: focus,
      builder: (context, _) => Container(
        padding: const EdgeInsets.fromLTRB(11, 1, 5, 1),
        decoration: BoxDecoration(
          color: p.empty.withValues(alpha: focus.hasFocus ? 0.65 : 0.45),
          borderRadius: BorderRadius.circular(16),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              // Its buttons leave the cursor in the field.
              TextFieldTapRegion(child: leading),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focus,
                  textCapitalization: TextCapitalization.sentences,
                  inputFormatters: const [NoteInputFormatter()],
                  style: _taskInputStyle(p),
                  cursorColor: p.accent,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Add task',
                    hintStyle: _taskInputStyle(p).copyWith(color: p.inkMuted),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onSubmitted: (_) => onSubmitted(),
                ),
              ),
              // Its details keep to the end, the name taking the rest.
              if (details case final details?)
                TextFieldTapRegion(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: _detailsRoom(constraints.maxWidth - _TaskAction.size - 16)),
                      child: details,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A birthday's mark, in place of the repeat arrows in Further ahead.
const _birthdayIcon = Icons.celebration_rounded;

/// A card's button that shows or hides something: lit while it shows.
class _ShowToggle extends StatelessWidget {
  const _ShowToggle({required this.icon, required this.what, required this.shown, required this.onPressed});

  final IconData icon;

  /// What it shows, as in "Show [what]".
  final String what;
  final bool shown;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      HeaderIconButton(tooltip: shown ? 'Hide $what' : 'Show $what', icon: icon, onPressed: onPressed);
}
