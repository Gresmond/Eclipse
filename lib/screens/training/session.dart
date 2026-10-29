part of '../training_view.dart';

// Session

class _SessionTile extends StatelessWidget {
  const _SessionTile();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.training.revision, s.today));
    final log = state.training;
    final day = log.day ?? state.today;
    final session = log.session(day);
    final isToday = day == state.today;
    return Tile(
      padding: const EdgeInsets.fromLTRB(24, 20, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TileHeader(
            title: isToday ? "Today’s session" : '${weekdayNames[day.weekday - 1]}  ·  ${_shortDate(day)}',
            trailingAtEnd: true,
            trailing: Builder(
              builder: (anchor) => _TextButton(
                label: isToday ? 'Another day' : 'Back to today',
                icon: isToday ? Icons.calendar_today_rounded : null,
                onTap: isToday
                    ? () => showFadeMenu(
                        anchor,
                        width: 312,
                        builder: (_) => DayPicker(
                          today: state.today,
                          first: DateTime(state.firstMonth.$1, state.firstMonth.$2),
                          selected: day,
                          onPick: (d) => log.showDay(d == state.today ? null : d),
                        ),
                      )
                    : () => log.showDay(null),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final (e, sets) in session)
                  _ExerciseBlock(key: ValueKey(e.uid), day: day, exercise: e, sets: sets),
                _AddExercise(key: ValueKey(dateKey(day)), day: day, logged: {for (final (e, _) in session) e.uid}),
              ],
            ),
          ),
          if (session.isEmpty && log.exercises.isEmpty)
            Text(
              'Type an exercise, pick what it trains, then add your sets.',
              style: _label(p, size: 12, color: p.inkMuted),
            ),
        ],
      ),
    );
  }
}

class _ExerciseBlock extends StatelessWidget {
  const _ExerciseBlock({super.key, required this.day, required this.exercise, required this.sets});

  final DateTime day;
  final Exercise exercise;
  final List<TrainingSet> sets;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final log = AppScope.read(context).training;
    final colour = groupColour(exercise.group, p);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: 30.0 + sets.length * 36,
            margin: const EdgeInsets.only(right: 12, top: 2),
            decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(2)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: _InlineName(
                        name: exercise.name,
                        onRename: (name) => log.updateExercise(exercise, name: name),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Builder(
                      builder: (anchor) => _GroupPill(
                        group: exercise.group,
                        onTap: () => showFadeMenu(
                          anchor,
                          alignLeft: true,
                          width: 220,
                          builder: (menu) => _GroupMenu(
                            selected: exercise.group,
                            onPick: (g) {
                              Navigator.pop(menu);
                              log.updateExercise(exercise, group: g);
                            },
                          ),
                        ),
                      ),
                    ),
                    if (exercise.bodyweight) ...[
                      const SizedBox(width: 6),
                      Text(
                        'BODYWEIGHT',
                        style: _label(
                          p,
                          size: 10,
                          weight: FontWeight.w600,
                          color: p.inkMuted,
                        ).copyWith(letterSpacing: 1),
                      ),
                    ],
                    const Spacer(),
                    _IconAction(
                      icon: Icons.close_rounded,
                      tooltip: 'Take off this session',
                      onTap: () => log.removeFromDay(day, exercise),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final (i, s) in sets.indexed)
                  _SetRow(
                    key: ValueKey(s.uid),
                    index: i,
                    set: s,
                    bodyweight: exercise.bodyweight,
                    last: i == sets.length - 1,
                    day: day,
                    exercise: exercise,
                  ),
                _TextButton(label: 'Add set', icon: Icons.add_rounded, onTap: () => log.addSet(day, exercise)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SetRow extends StatefulWidget {
  const _SetRow({
    super.key,
    required this.index,
    required this.set,
    required this.bodyweight,
    required this.last,
    required this.day,
    required this.exercise,
  });

  final int index;
  final TrainingSet set;
  final bool bodyweight, last;
  final DateTime day;
  final Exercise exercise;

  @override
  State<_SetRow> createState() => _SetRowState();
}

class _SetRowState extends State<_SetRow> {
  late final _weight = TextEditingController(text: widget.set.weight == null ? '' : _kg(widget.set.weight!));
  late final _reps = TextEditingController(text: widget.set.reps == 0 ? '' : '${widget.set.reps}');
  final _repsFocus = FocusNode();
  bool _hover = false;

  @override
  void dispose() {
    _weight.dispose();
    _reps.dispose();
    _repsFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final log = AppScope.read(context).training;
    final s = widget.set;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text('${widget.index + 1}', style: _label(p, size: 12, color: p.inkMuted)),
            ),
            if (widget.bodyweight)
              SizedBox(
                width: 108,
                child: Text('Bodyweight', style: _label(p, size: 13, color: p.inkMuted)),
              )
            else ...[
              _NumberBox(
                controller: _weight,
                decimal: true,
                hint: 'kg',
                autofocus: widget.last && s.reps == 0 && s.weight == null,
                onChanged: (v) {
                  final w = double.tryParse(v);
                  w == null ? log.updateSet(s, clearWeight: true) : log.updateSet(s, weight: w);
                },
                onSubmitted: () => _repsFocus.requestFocus(),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('kg', style: _label(p, size: 12.5, color: p.inkMuted)),
              ),
              Text('×', style: _label(p, size: 13, color: p.inkMuted)),
              const SizedBox(width: 8),
            ],
            _NumberBox(
              controller: _reps,
              focusNode: _repsFocus,
              hint: 'reps',
              autofocus: widget.last && s.reps == 0 && (widget.bodyweight || s.weight != null),
              onChanged: (v) => log.updateSet(s, reps: int.tryParse(v) ?? 0),
              // Enter on the last set's reps starts the next set.
              onSubmitted: () {
                if (widget.last && s.reps > 0) log.addSet(widget.day, widget.exercise);
              },
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text('reps', style: _label(p, size: 12.5, color: p.inkMuted)),
            ),
            if (s.reps > maxEstimateReps)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  'Over $maxEstimateReps reps, so not charted',
                  style: _label(p, size: 11.5, color: p.inkMuted),
                ),
              ),
            const Spacer(),
            AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: Motion.hover,
              curve: Motion.hoverCurve,
              child: _IconAction(icon: Icons.remove_rounded, tooltip: 'Delete set', onTap: () => log.deleteSet(s)),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberBox extends StatelessWidget {
  const _NumberBox({
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onSubmitted,
    this.focusNode,
    this.decimal = false,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final bool decimal, autofocus;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 64,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.8), width: 0.8),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        style: _label(p, size: 13.5, weight: FontWeight.w600),
        cursorColor: p.accent,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(decimal ? r'^\d{0,4}([.,]\d{0,2})?' : r'^\d{0,3}'))],
        decoration: InputDecoration.collapsed(
          hintText: '',
          hintStyle: _label(p, color: p.inkMuted),
        ),
        onChanged: (v) => onChanged(v.replaceAll(',', '.')),
        onSubmitted: (_) => onSubmitted(),
      ),
    );
  }
}

class _InlineName extends StatefulWidget {
  const _InlineName({required this.name, required this.onRename});

  final String name;
  final ValueChanged<String> onRename;

  @override
  State<_InlineName> createState() => _InlineNameState();
}

class _InlineNameState extends State<_InlineName> {
  bool _editing = false;
  late final _text = TextEditingController(text: widget.name);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    setState(() => _editing = false);
    if (_text.text.trim().isNotEmpty && _text.text.trim() != widget.name) widget.onRename(_text.text);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(
      fontFamily: Fonts.display,
      fontSize: 15.5,
      fontWeight: FontWeight.w600,
      color: p.ink,
      letterSpacing: -0.2,
    );
    if (_editing) {
      return IntrinsicWidth(
        child: TextField(
          inputFormatters: const [NoteInputFormatter()],
          controller: _text,
          focusNode: _focus,
          autofocus: true,
          style: style,
          cursorColor: p.accent,
          decoration: const InputDecoration.collapsed(hintText: ''),
          onSubmitted: (_) => _commit(),
        ),
      );
    }
    return Tooltip(
      message: 'Rename',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() {
            _text.text = widget.name;
            _editing = true;
          }),
          child: Text(widget.name, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

class _GroupPill extends StatelessWidget {
  const _GroupPill({required this.group, this.onTap, this.selected = true});

  final MuscleGroup group;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final colour = groupColour(group, p);
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: selected ? 0.2 : 0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colour.withValues(alpha: selected ? 0.6 : 0.25), width: 0.8),
          ),
          child: Text(
            group.label.toUpperCase(),
            style: _label(p, size: 10.5, weight: FontWeight.w700, color: colour).copyWith(letterSpacing: 1.1),
          ),
        ),
      ),
    );
  }
}

class _GroupMenu extends StatelessWidget {
  const _GroupMenu({required this.selected, required this.onPick});

  final MuscleGroup? selected;
  final ValueChanged<MuscleGroup> onPick;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final g in MuscleGroup.values)
          _GroupPill(group: g, selected: selected == null || g == selected, onTap: () => onPick(g)),
      ],
    ),
  );
}

/// The field to put an exercise on the session: picks one of yours as you
/// type, or makes a new one once you say what it trains.
class _AddExercise extends StatefulWidget {
  const _AddExercise({super.key, required this.day, required this.logged});

  final DateTime day;

  /// Exercises already on this session.
  final Set<String> logged;

  @override
  State<_AddExercise> createState() => _AddExerciseState();
}

class _AddExerciseState extends State<_AddExercise> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _bodyweight = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add(Exercise e) {
    AppScope.read(context).training.addToDay(widget.day, e);
    _text.clear();
    setState(() => _bodyweight = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final log = AppScope.read(context).training;
    final query = _text.text.trim().toLowerCase();
    final matches = query.isEmpty
        ? const <Exercise>[]
        : log.exercises
              .where((e) => e.name.toLowerCase().contains(query) && !widget.logged.contains(e.uid))
              .take(6)
              .toList();
    final exact = log.exercises.any((e) => e.name.toLowerCase() == query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: p.empty.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.tileBorder.withValues(alpha: 0.8), width: 0.8),
          ),
          child: Row(
            children: [
              Icon(Icons.add_rounded, size: 18, color: p.inkMuted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  inputFormatters: const [NoteInputFormatter()],
                  controller: _text,
                  focusNode: _focus,
                  style: _label(p, size: 13.5),
                  cursorColor: p.accent,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration.collapsed(
                    hintText: 'Add an exercise',
                    hintStyle: _label(p, size: 13.5, color: p.inkMuted),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (matches.isNotEmpty) _add(matches.first);
                  },
                ),
              ),
            ],
          ),
        ),
        if (matches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in matches) _Chip(colour: groupColour(e.group, p), label: e.name, onTap: () => _add(e)),
              ],
            ),
          ),
        if (query.isNotEmpty && !exact) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Text('New: what does “${_text.text.trim()}” train?', style: _label(p, size: 12.5, color: p.inkMuted)),
              const SizedBox(width: 10),
              // Leaves the cursor in the name.
              TextFieldTapRegion(
                child: _Chip(
                  label: 'Bodyweight',
                  colour: p.accent,
                  on: _bodyweight,
                  onTap: () => setState(() => _bodyweight = !_bodyweight),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _GroupMenu(
            selected: null,
            onPick: (g) {
              final name = _text.text.trim();
              final e = log.createExercise(name[0].toUpperCase() + name.substring(1), g, bodyweight: _bodyweight);
              _add(e);
            },
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.colour, required this.onTap, this.on = true});

  final String label;
  final Color colour;
  final VoidCallback onTap;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.click,
          curve: Motion.clickCurve,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: on ? 0.16 : 0),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colour.withValues(alpha: on ? 0.55 : 0.3), width: 0.8),
          ),
          child: Text(
            label,
            style: _label(p, size: 12.5, weight: FontWeight.w600, color: on ? p.ink : p.inkMuted),
          ),
        ),
      ),
    );
  }
}

class _TextButton extends StatelessWidget {
  const _TextButton({required this.label, required this.onTap, this.icon});

  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 15, color: p.accent), const SizedBox(width: 4)],
              Text(
                label,
                style: _label(p, size: 12.5, weight: FontWeight.w600, color: p.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 16, color: p.inkMuted),
          ),
        ),
      ),
    );
  }
}
