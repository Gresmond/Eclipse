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
              borderRadius: BorderRadius.circular(14),
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
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.tileBorder.withValues(alpha: 0.6)),
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
                    style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.ink),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Add a ritual to ${monthNames[month - 1]}',
                      hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted.withValues(alpha: 0.7)),
                    ),
                    onSubmitted: (v) {
                      state.addHabit(year, month, v);
                      _add.clear();
                      _addFocus.requestFocus();
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Changes apply to ${monthNames[month - 1]} only. '
            'Each new month starts as a copy of the one before.',
            style: TextStyle(fontFamily: Fonts.body, fontSize: 13, color: p.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// The sleep schedule's times for one month. The four items themselves
/// stay put.
class _SleepEditor extends StatelessWidget {
  const _SleepEditor({required this.year, required this.month});

  final int year;
  final int month;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final h in state.sleepHabitsFor(year, month))
            _SleepNoteRow(key: ValueKey(h.id), year: year, month: month, habit: h),
          const SizedBox(height: 18),
          Text(
            'Times show beside each item. Changes apply to ${monthNames[month - 1]} only; '
            'each new month starts with the one before\'s.',
            style: TextStyle(fontFamily: Fonts.body, fontSize: 13, color: p.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _SleepNoteRow extends StatelessWidget {
  const _SleepNoteRow({super.key, required this.year, required this.month, required this.habit});

  final int year;
  final int month;
  final Habit habit;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2.5),
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              habit.name,
              style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.ink),
            ),
          ),
          _TimeButton(year: year, month: month, habit: habit),
        ],
      ),
    );
  }
}

/// Shows a sleep item's time, or "Select time", and opens a wheel to pick it.
class _TimeButton extends StatefulWidget {
  const _TimeButton({required this.year, required this.month, required this.habit});

  final int year;
  final int month;
  final Habit habit;

  @override
  State<_TimeButton> createState() => _TimeButtonState();
}

class _TimeButtonState extends State<_TimeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final minutes = widget.habit.minutes;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => showFadeMenu(
          context,
          width: 248,
          above: true,
          builder: (_) => _TimeWheel(year: widget.year, month: widget.month, habitId: widget.habit.id),
        ),
        child: AnimatedContainer(
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: _hover ? p.empty : p.tile.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.tileBorder.withValues(alpha: 0.8)),
          ),
          child: FadeThrough(
            duration: Motion.click,
            child: Text(
              minutes == null ? 'Select time' : clockLabel(minutes),
              key: ValueKey(minutes),
              style: minutes == null
                  ? TextStyle(fontFamily: Fonts.body, fontSize: 13, color: p.inkMuted)
                  : SleepName.timeStyle(p).copyWith(fontSize: 13, color: p.ink),
            ),
          ),
        ),
      ),
    );
  }
}

/// Three wheels, hour, minute (in fives) and am/pm, that set a sleep item's
/// time as they turn. The hour and minute wheels go round and round.
class _TimeWheel extends StatefulWidget {
  const _TimeWheel({required this.year, required this.month, required this.habitId});

  final int year;
  final int month;
  final int habitId;

  @override
  State<_TimeWheel> createState() => _TimeWheelState();
}

class _TimeWheelState extends State<_TimeWheel> {
  static const _row = 38.0;
  static const _rows = 5;

  late final AppState _state = AppScope.of(context);
  late final Habit _habit = _find();
  late final int _start = ((_habit.minutes ?? SleepItem.values[_index].minutes) / 5).round() * 5 % (24 * 60);
  late int _hour = _start ~/ 60 % 12, _minute = _start % 60 ~/ 5;
  late bool _pm = _start >= 12 * 60;

  // Started a few turns in, so the looping wheels can go either way.
  late final _hours = FixedExtentScrollController(initialItem: 12 * 50 + _hour);
  late final _minutes = FixedExtentScrollController(initialItem: 12 * 50 + _minute);
  late final _halves = FixedExtentScrollController(initialItem: _pm ? 1 : 0);

  int get _index => _state.sleepHabitsFor(widget.year, widget.month).indexWhere((h) => h.id == widget.habitId);
  Habit _find() => _state.sleepHabitsFor(widget.year, widget.month)[_index];

  @override
  void initState() {
    super.initState();
    // Opening the wheel on an item with no time sets the one it shows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_habit.minutes == null) _save();
    });
  }

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    _halves.dispose();
    super.dispose();
  }

  void _save() => _state.setSleepTime(widget.year, widget.month, _find(), (_hour + (_pm ? 12 : 0)) * 60 + _minute * 5);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = SleepName.timeStyle(p).copyWith(fontSize: 19, fontWeight: FontWeight.w600, color: p.ink);

    Widget wheel({
      required FixedExtentScrollController controller,
      required int count,
      required bool loop,
      required String Function(int) label,
      required int selected,
      required ValueChanged<int> onChanged,
      double width = 56,
    }) {
      Widget item(int i) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => controller.animateToItem(
            // The nearest way round to it.
            loop
                ? controller.selectedItem + (i - controller.selectedItem % count + count ~/ 2) % count - count ~/ 2
                : i,
            duration: Motion.click,
            curve: Motion.clickCurve,
          ),
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: Motion.hover,
              curve: Motion.hoverCurve,
              style: style.copyWith(color: i == selected ? p.ink : p.inkMuted.withValues(alpha: 0.75)),
              child: Text(label(i)),
            ),
          ),
        ),
      );
      return SizedBox(
        width: width,
        // A dragged wheel stops its rows taking the pointer, so their own
        // cursors drop out; this one keeps the hand while it turns.
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ListWheelScrollView.useDelegate(
            controller: controller,
            itemExtent: _row,
            diameterRatio: 1.6,
            perspective: 0.004,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: (i) {
              onChanged(i % count);
              _save();
            },
            childDelegate: loop
                ? ListWheelChildLoopingListDelegate(children: [for (var i = 0; i < count; i++) item(i)])
                : ListWheelChildListDelegate(children: [for (var i = 0; i < count; i++) item(i)]),
          ),
        ),
      );
    }

    return ConfirmOnEnter(
      onConfirm: () => Navigator.of(context).pop(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _habit.name,
              style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, fontWeight: FontWeight.w600, color: p.inkMuted),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: _row * _rows,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // The band the chosen time sits in.
                  Container(
                    height: _row,
                    decoration: BoxDecoration(
                      color: p.empty.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  // Rows fade out towards the wheel's top and bottom edges.
                  ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
                      stops: [0, 0.32, 0.68, 1],
                    ).createShader(rect),
                    // Dragged with the mouse as well as scrolled.
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false, dragDevices: {...PointerDeviceKind.values}),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          wheel(
                            controller: _hours,
                            count: 12,
                            loop: true,
                            label: (i) => '${i == 0 ? 12 : i}',
                            selected: _hour,
                            onChanged: (i) => setState(() => _hour = i),
                          ),
                          Text(':', style: style),
                          wheel(
                            controller: _minutes,
                            count: 12,
                            loop: true,
                            label: (i) => (i * 5).toString().padLeft(2, '0'),
                            selected: _minute,
                            onChanged: (i) => setState(() => _minute = i),
                          ),
                          const SizedBox(width: 6),
                          wheel(
                            controller: _halves,
                            count: 2,
                            loop: false,
                            label: (i) => i == 0 ? 'am' : 'pm',
                            selected: _pm ? 1 : 0,
                            onChanged: (i) => setState(() => _pm = i == 1),
                            width: 52,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  _state.setSleepTime(widget.year, widget.month, _find(), null);
                  Navigator.of(context).pop();
                },
                style: TextButton.styleFrom(foregroundColor: p.inkMuted, visualDensity: VisualDensity.compact),
                child: Text('Clear time', style: TextStyle(fontFamily: Fonts.ui, fontSize: 12.5)),
              ),
            ),
          ],
        ),
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
      margin: const EdgeInsets.symmetric(vertical: 2.5),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.5)),
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
                    style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.ink),
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
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 12.5, color: p.inkMuted),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.only(bottom: 8),
                    hintText: 'Add a note',
                    hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted.withValues(alpha: 0.5)),
                  ),
                  onSubmitted: (_) => widget.onDone(),
                  onChanged: (v) => state.draftHabitNote(widget.year, widget.month, widget.habit, v),
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
