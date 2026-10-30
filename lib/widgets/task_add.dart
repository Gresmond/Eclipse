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
    );
    if (!mounted) return null;
    if (picked != null) setState(() => _choice = picked);
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
    final p = context.palette;
    final today = AppScope.read(context).today;
    final due = _choice?.day, repeat = _choice?.repeat, time = _choice?.time, birthday = _choice?.birthday == true;
    final note = TextStyle(fontFamily: Fonts.body, fontSize: 12, color: p.inkMuted);
    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 6),
      child: _Field(
        controller: _controller,
        focus: _focus,
        leading: _TaskAction(
          tooltip: due == null ? 'Pick a day' : 'Due ${dayMonth(due)}/${due.year}, click to change',
          icon: due == null ? Icons.calendar_today_outlined : Icons.event_available_outlined,
          onPressed: _pick,
        ),
        trailing: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (due != null)
                Flexible(
                  child: Text(_shortDate(due, today), maxLines: 1, overflow: TextOverflow.ellipsis, style: note),
                ),
              if (time != null) ...[
                const SizedBox(width: 6),
                Text(clockLabel(time), style: _timeStyle(p).copyWith(fontSize: 12)),
              ],
              if (repeat != null) ...[
                const SizedBox(width: 8),
                Icon(birthday ? _birthdayIcon : Icons.repeat_rounded, size: 12, color: p.accent),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    birthday ? 'Birthday' : repeat.rule.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: note.copyWith(color: p.accent),
                  ),
                ),
              ],
            ],
          ),
        ),
        onSubmitted: _submit,
      ),
    );
  }
}

/// "+ Add task" under a day, which opens into a field: Enter adds and keeps
/// it open for the next, Escape or clicking away closes it. The repeat
/// button makes the next one repeat from that day.
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
  int? _time;

  /// While the wheel is open, the time stays though the field is empty.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      setState(() {
        if (!_focus.hasFocus && !_picking && _controller.text.trim().isEmpty) _time = null;
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
      _addDue(state, text, widget.day, time: _time);
      setState(() => _time = null);
    }
    _controller.clear();
    _focus.requestFocus();
  }

  Future<void> _pick(BuildContext anchor) async {
    setState(() => _picking = true);
    final selection = _controller.selection;
    final picked = await pickTime(anchor, minutes: _time, start: _time ?? 9 * 60);
    _picking = false;
    if (!mounted) return;
    if (picked != null) setState(() => _time = picked);
    _refocus(_focus, _controller, selection);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final time = _time;
    // Its time only once it's been clicked, or while one is set or picked.
    final timed = widget.past == null && (_focus.hasFocus || _picking || time != null);
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(
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
                    const SizedBox(width: 11),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focus,
                        textCapitalization: TextCapitalization.sentences,
                        inputFormatters: const [NoteInputFormatter()],
                        // As a task's name, so the line is a task's height.
                        style: TextStyle(fontFamily: Fonts.body, fontSize: 15, height: 1.35, color: p.ink),
                        cursorColor: p.accent,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'Add task',
                          hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted.withValues(alpha: 0.65)),
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
                            if (time != null) Text(clockLabel(time), style: _timeStyle(p).copyWith(fontSize: 12)),
                            Builder(
                              builder: (anchor) => _TaskAction(
                                tooltip: time == null ? 'Add a time' : 'Change time',
                                icon: Icons.more_time_rounded,
                                onPressed: () => _pick(anchor),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A task's time, in the sleep schedule's semi-mono.
TextStyle _timeStyle(Palette p) => SleepName.timeStyle(p);

/// A rounded field for a new task's name, as at the foot of a to-do card.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.focus,
    required this.leading,
    required this.trailing,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final Widget leading, trailing;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: focus,
      builder: (context, _) => Container(
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: p.empty.withValues(alpha: focus.hasFocus ? 0.65 : 0.45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: focus.hasFocus ? p.accent.withValues(alpha: 0.45) : Colors.transparent),
        ),
        child: Row(
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
                style: TextStyle(fontFamily: Fonts.body, fontSize: 14.5, color: p.ink),
                cursorColor: p.accent,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Add task',
                  hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted.withValues(alpha: 0.65)),
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                ),
                onSubmitted: (_) => onSubmitted(),
              ),
            ),
            // Its buttons and labels keep to the end, the name taking the rest.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: TextFieldTapRegion(child: trailing),
            ),
          ],
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

  static const size = 28.0;

  final IconData icon;

  /// What it shows, as in "Show [what]".
  final String what;
  final bool shown;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      tooltip: shown ? 'Hide $what' : 'Show $what',
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      style: ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const WidgetStatePropertyAll(Size(size, size)),
        shape: const WidgetStatePropertyAll(CircleBorder()),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? p.empty.withValues(alpha: 0.8) : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      icon: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: shown ? p.accent : p.inkMuted.withValues(alpha: 0.45)),
        duration: Motion.click,
        curve: Motion.clickCurve,
        builder: (context, colour, _) => Icon(icon, size: 16, color: colour),
      ),
    );
  }
}
