part of 'month_view.dart';

/// Rename, reorder, remove and add rituals for one month.
class _RitualEditor extends StatefulWidget {
  const _RitualEditor({required this.year, required this.month, required this.onDone});

  final VoidCallback onDone;

  final int year;
  final int month;

  @override
  State<_RitualEditor> createState() => _RitualEditorState();
}

class _RitualEditorState extends State<_RitualEditor> {
  final _add = TextEditingController();
  final _addFocus = FocusNode();

  /// The days the ritual being added will be on.
  var _addDays = everyDay;

  @override
  void dispose() {
    _add.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    final (year, month) = (widget.year, widget.month);
    final habits = state.habitsFor(year, month);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => state.reorderHabit(year, month, from, to),
            proxyDecorator: (child, _, _) => Material(
              color: p.tile,
              elevation: 0,
              shadowColor: p.shadow.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(16),
              child: child,
            ),
            children: [
              for (final (i, h) in habits.indexed)
                _EditableRow(key: ValueKey(h.id), index: i, year: year, month: month, habit: h, onDone: widget.onDone),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            decoration: BoxDecoration(
              color: p.empty.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.borderSoft),
            ),
            child: Row(
              children: [
                Icon(Icons.add_rounded, size: 18, color: p.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    inputFormatters: const [NoteInputFormatter()],
                    controller: _add,
                    focusNode: _addFocus,
                    style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Add a ritual to ${monthNames[month - 1]}',
                      hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted.withValues(alpha: 0.7)),
                    ),
                    onSubmitted: (v) {
                      state.addHabit(year, month, v, days: _addDays);
                      _add.clear();
                      setState(() => _addDays = everyDay);
                      _addFocus.requestFocus();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // Its days leave the cursor in the name.
                TextFieldTapRegion(
                  child: DayToggles(bits: _addDays, onChanged: (bits) => setState(() => _addDays = bits)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Changes apply to ${monthNames[month - 1]} only. '
            'Each new month starts as a copy of the one before.',
            style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// The sleep schedule's times for one month. The four items themselves
/// stay put.
/// Laid out on the sleep grid's lines: the day headers' height, then each
/// item where its row of squares is, then the score's height left empty.
/// So the card keeps its height, and each name its place, when switching.
class _SleepEditor extends StatelessWidget {
  const _SleepEditor({required this.year, required this.month, required this.nameWidth, required this.maxCell});

  final int year;
  final int month;
  final double nameWidth;
  final double maxCell;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    // Stand-ins, never seen, that take the grid's header and score heights.
    Widget spacer(Widget child) => IgnorePointer(
      child: ExcludeSemantics(
        child: Visibility(visible: false, maintainSize: true, maintainAnimation: true, maintainState: true, child: child),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final row = _GridState.cellFor(constraints.maxWidth, nameWidth, maxCell) + 5;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              spacer(
                SizedBox(
                  width: 40,
                  child: _DayHeader(day: DateTime(year, month), isToday: false, rest: false),
                ),
              ),
              const SizedBox(height: 10),
              for (final h in state.sleepHabitsFor(year, month))
                ConstrainedBox(
                  key: ValueKey(h.id),
                  constraints: BoxConstraints(minHeight: row),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _SleepNoteRow(year: year, month: month, habit: h),
                  ),
                ),
              const SizedBox(height: 16),
              spacer(_MonthScore(year: year, month: month, habits: const [], label: '')),
            ],
          ),
        );
      },
    );
  }
}

class _SleepNoteRow extends StatelessWidget {
  const _SleepNoteRow({required this.year, required this.month, required this.habit});

  final int year;
  final int month;
  final Habit habit;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.borderSoft),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              habit.name,
              style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
            ),
          ),
          _TimeButton(year: year, month: month, habit: habit),
        ],
      ),
    );
  }
}

/// Shows a sleep item's time, or "Select time", and opens a wheel to pick it.
class _TimeButton extends StatelessWidget {
  const _TimeButton({required this.year, required this.month, required this.habit});

  final int year;
  final int month;
  final Habit habit;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final sleep = state.sleepHabitsFor(year, month);
    final index = sleep.indexWhere((h) => h.id == habit.id);
    return TimePill(
      minutes: habit.minutes,
      start: SleepItem.values[index].minutes,
      title: habit.name,
      // Found again each time, as setting a time makes a new list.
      onChanged: (minutes) => state.setSleepTime(
        year,
        month,
        state.sleepHabitsFor(year, month).firstWhere((h) => h.id == habit.id),
        minutes,
      ),
    );
  }
}

class _EditableRow extends StatefulWidget {
  const _EditableRow({
    super.key,
    required this.index,
    required this.year,
    required this.month,
    required this.habit,
    required this.onDone,
  });

  final VoidCallback onDone;
  final int index;
  final int year;
  final int month;
  final Habit habit;

  @override
  State<_EditableRow> createState() => _EditableRowState();
}

class _EditableRowState extends State<_EditableRow> {
  late final _controller = TextEditingController(text: widget.habit.name);
  late final _note = TextEditingController(text: widget.habit.description);
  late String _before = widget.habit.name;
  final _nameFocus = FocusNode(), _noteFocus = FocusNode();

  @override
  void didUpdateWidget(_EditableRow old) {
    super.didUpdateWidget(old);
    if (!_nameFocus.hasFocus && _controller.text != widget.habit.name) _controller.text = widget.habit.name;
    final note = widget.habit.description ?? '';
    if (!_noteFocus.hasFocus && _note.text != note) _note.text = note;
  }

  @override
  void dispose() {
    _controller.dispose();
    _note.dispose();
    _nameFocus.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.borderSoft),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: widget.index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.drag_indicator_rounded, size: 18, color: p.inkMuted.withValues(alpha: 0.6)),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Renames as you type, but a ritual can't be blank: leaving the
                // field empty puts back the name it had before you started.
                Focus(
                  onFocusChange: (focused) {
                    if (focused) {
                      _before = _controller.text;
                    } else if (_controller.text.trim().isEmpty) {
                      _controller.text = _before;
                      state.renameHabit(widget.year, widget.month, widget.habit, _before);
                    }
                    if (!focused) state.saveHabitDrafts();
                  },
                  child: TextField(
                    inputFormatters: const [NoteInputFormatter()],
                    controller: _controller,
                    focusNode: _nameFocus,
                    style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
                    decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                    onSubmitted: (_) => widget.onDone(),
                    onChanged: (v) => state.draftHabitName(widget.year, widget.month, widget.habit, v),
                  ),
                ),
                // Shown on hover over the ritual.
                TextField(
                  inputFormatters: const [NoteInputFormatter()],
                  controller: _note,
                  focusNode: _noteFocus,
                  maxLines: null,
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.done,
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.only(bottom: 6),
                    hintText: 'Add a note',
                    hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted.withValues(alpha: 0.5)),
                  ),
                  onSubmitted: (_) => widget.onDone(),
                  onChanged: (v) => state.draftHabitNote(widget.year, widget.month, widget.habit, v),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextFieldTapRegion(
                    child: DayToggles(
                      bits: widget.habit.weekdays,
                      onChanged: (bits) => state.setHabitDays(widget.year, widget.month, widget.habit, bits),
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove from ${monthNames[widget.month - 1]}',
            iconSize: 18,
            color: p.missed,
            onPressed: () => state.removeHabit(widget.year, widget.month, widget.habit),
            icon: const Icon(Icons.remove_circle_outline_rounded),
          ),
        ],
      ),
    );
  }
}
