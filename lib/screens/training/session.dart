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
      // Another day's session fades through, as another day does on Today.
      child: FadeThrough(
        layoutBuilder: FadeThrough.fill,
        child: Column(
          key: ValueKey(dateKey(day)),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, box) {
                final title = isToday
                    ? "Today’s session"
                    : '${weekdayNames[day.weekday - 1]}  ·  ${_shortDate(day, todayYear: state.today.year)}';
                final trailing = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    WorkoutToolsButton(day: day),
                    Builder(
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
                  ],
                );
                if (box.maxWidth < 400) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TileHeader(title: title),
                      const SizedBox(height: 6),
                      Align(alignment: Alignment.centerRight, child: trailing),
                    ],
                  );
                }
                return TileHeader(title: title, trailingAtEnd: true, trailing: trailing);
              },
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _FoldingColumn(
                    children: [
                      for (final (e, sets) in session)
                        _ExerciseBlock(key: ValueKey(e.uid), day: day, exercise: e, sets: sets),
                    ],
                  ),
                  AddSessionExercise(
                    key: ValueKey(dateKey(day)),
                    day: day,
                    logged: {for (final (e, _) in session) e.uid},
                  ),
                ],
              ),
            ),
            if (session.isEmpty && log.exercises.isEmpty)
              Text(
                'Type an exercise, pick what it trains, then add your sets.',
                style: _label(p, size: 14, color: p.inkMuted),
              ),
          ],
        ),
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
    final bests = log.personalBests(day, exercise);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Grows and shrinks with its sets as they open and close.
          AnimatedContainer(
            duration: context.themed(Motion.morph),
            curve: Motion.morphCurve,
            width: 3,
            height: 30.0 + sets.length * 36,
            margin: const EdgeInsets.only(right: 12, top: 2),
            decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(4)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PixelRow(
                  children: [
                    // The name and group take what the remove button leaves.
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.start,
                        children: [
                          PixelFit(
                            child: _InlineName(
                              name: exercise.name,
                              onRename: (name) => log.updateExercise(exercise, name: name),
                            ),
                          ),
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
                          PixelTooltip(
                            message: exercise.bodyweight ? 'Switch to weighted' : 'Switch to bodyweight',
                            child: _Chip(
                              label: exercise.bodyweight ? 'Bodyweight' : 'Weighted',
                              colour: p.accent,
                              on: exercise.bodyweight,
                              onTap: () => log.updateExercise(exercise, bodyweight: !exercise.bodyweight),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _DeleteExercise(count: log.setsOf(exercise), onDelete: () => log.deleteExercise(exercise)),
                    _IconAction(
                      icon: Icons.close_rounded,
                      tooltip: 'Remove from this session',
                      onTap: () => log.removeFromDay(day, exercise),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _FoldingColumn(
                  children: [
                    for (final (i, s) in sets.indexed)
                      _SetRow(
                        key: ValueKey(s.uid),
                        index: i,
                        set: s,
                        bodyweight: exercise.bodyweight,
                        best: bests.contains(s.uid),
                        last: i == sets.length - 1,
                        day: day,
                        exercise: exercise,
                      ),
                  ],
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

/// Deleting an exercise outright: the bin asks once, in place, and goes
/// back to a bin when the pointer leaves.
class _DeleteExercise extends StatefulWidget {
  const _DeleteExercise({required this.count, required this.onDelete});

  final int count;
  final VoidCallback onDelete;

  @override
  State<_DeleteExercise> createState() => _DeleteExerciseState();
}

class _DeleteExerciseState extends State<_DeleteExercise> {
  bool _asking = false;

  @override
  Widget build(BuildContext context) => TapRegion(
    onTapOutside: (_) {
      if (_asking) setState(() => _asking = false);
    },
    child: MouseRegion(
      onExit: (_) => setState(() => _asking = false),
      // The bin and the question swap as a fade-through, the room easing
      // between their widths.
      child: AnimatedSize(
        duration: context.themed(Motion.morph),
        curve: Motion.morphCurve,
        alignment: Alignment.centerRight,
        child: FadeThrough(
          duration: Motion.morph,
          layoutBuilder: FadeThrough.aligned(Alignment.centerRight),
          child: _asking
              ? Row(
                  key: const ValueKey(true),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TextButton(label: 'Cancel', onTap: () => setState(() => _asking = false)),
                    const SizedBox(width: 10),
                    _TextButton(
                      label: 'Delete with all ${widget.count} ${widget.count == 1 ? 'set' : 'sets'}',
                      onTap: widget.onDelete,
                    ),
                  ],
                )
              : _IconAction(
                  key: const ValueKey(false),
                  icon: Icons.delete_outline_rounded,
                  tooltip: 'Delete this exercise',
                  onTap: () => setState(() => _asking = true),
                ),
        ),
      ),
    ),
  );
}

class _SetRow extends StatefulWidget {
  const _SetRow({
    super.key,
    required this.index,
    required this.set,
    required this.bodyweight,
    required this.best,
    required this.last,
    required this.day,
    required this.exercise,
  });

  final int index;
  final TrainingSet set;
  final bool bodyweight, best, last;
  final DateTime day;
  final Exercise exercise;

  @override
  State<_SetRow> createState() => _SetRowState();
}

class _SetRowState extends State<_SetRow> {
  late final _weight = TextEditingController(text: widget.set.weight == null ? '' : _kg(widget.set.weight!));
  late final _reps = TextEditingController(text: widget.set.reps == 0 ? '' : '${widget.set.reps}');
  late final _weightFocus = FocusNode()..addListener(_focusChanged);
  late final _repsFocus = FocusNode()..addListener(_focusChanged);
  bool _hover = false;

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  /// A change made elsewhere (on another computer, or by undo) shows here,
  /// unless it's what's being typed.
  @override
  void didUpdateWidget(_SetRow old) {
    super.didUpdateWidget(old);
    final s = widget.set;
    if (s.weight != old.set.weight && s.weight != double.tryParse(_weight.text.replaceAll(',', '.'))) {
      _weight.text = s.weight == null ? '' : _kg(s.weight!);
    }
    if (s.reps != old.set.reps && s.reps != (int.tryParse(_reps.text) ?? 0)) {
      _reps.text = s.reps == 0 ? '' : '${s.reps}';
    }
  }

  @override
  void dispose() {
    _weightFocus
      ..removeListener(_focusChanged)
      ..dispose();
    _repsFocus
      ..removeListener(_focusChanged)
      ..dispose();
    _weight.dispose();
    _reps.dispose();
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: PixelRow(
              children: [
                SizedBox(
                  width: 22,
                  child: Text('${widget.index + 1}', style: _label(p, size: 14, color: p.inkMuted)),
                ),
                if (widget.bodyweight)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 108),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        s.weight != null && s.weight! > 0 ? 'Bodyweight +${_kg(s.weight!)} kg' : 'Bodyweight',
                        style: _label(p, size: 14, color: p.inkMuted),
                      ),
                    ),
                  )
                else ...[
                  _NumberBox(
                    controller: _weight,
                    focusNode: _weightFocus,
                    decimal: true,
                    autofocus: widget.last && s.reps == 0 && s.weight == null,
                    onChanged: (v) {
                      final w = double.tryParse(v);
                      w == null ? log.updateSet(s, clearWeight: true) : log.updateSet(s, weight: w);
                    },
                    onSubmitted: () => _repsFocus.requestFocus(),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text('kg', style: _label(p, size: 14, color: p.inkMuted)),
                  ),
                  Text('×', style: _label(p, size: 14, color: p.inkMuted)),
                  const SizedBox(width: 8),
                ],
                _NumberBox(
                  controller: _reps,
                  focusNode: _repsFocus,
                  autofocus: widget.last && s.reps == 0 && (widget.bodyweight || s.weight != null),
                  onChanged: (v) => log.updateSet(s, reps: int.tryParse(v) ?? 0),
                  // Enter on the last set's reps starts the next set.
                  onSubmitted: () {
                    if (widget.last && s.reps > 0) log.addSet(widget.day, widget.exercise);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text('reps', style: _label(p, size: 14, color: p.inkMuted)),
                ),
                if (s.rpe != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text('RPE ${_kg(s.rpe!)}', style: _label(p, size: 12, color: p.inkMuted)),
                  ),
                if (!widget.bodyweight && s.reps > maxEstimateReps)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(
                        'Over $maxEstimateReps reps, so not charted',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _label(p, size: 12, color: p.inkMuted),
                      ),
                    ),
                  ),
                if (widget.best)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(
                        'Personal best',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _label(p, size: 12, weight: FontWeight.w700, color: p.accent),
                      ),
                    ),
                  ),
                const Spacer(),
                _IconAction(
                  icon: Icons.notes_rounded,
                  color:
                      (s.note?.trim().isNotEmpty == true || s.rpe != null || (widget.bodyweight && (s.weight ?? 0) > 0))
                      ? p.accent
                      : null,
                  tooltip: s.note?.trim().isNotEmpty == true
                      ? '${s.note!.trim()}\nEdit set details'
                      : 'Set note and effort',
                  onTap: () => editSetDetails(context, s, widget.exercise),
                ),
                Focus(
                  onFocusChange: (_) {
                    if (mounted) setState(() {});
                  },
                  child: Builder(
                    builder: (context) {
                      final alwaysShowRemove =
                          defaultTargetPlatform == TargetPlatform.android ||
                          defaultTargetPlatform == TargetPlatform.iOS ||
                          (kIsWeb && MediaQuery.sizeOf(context).width < 900);
                      final showRemove =
                          alwaysShowRemove ||
                          _hover ||
                          _weightFocus.hasFocus ||
                          _repsFocus.hasFocus ||
                          Focus.of(context).hasFocus;
                      return IgnorePointer(
                        ignoring: !showRemove,
                        child: AnimatedOpacity(
                          opacity: showRemove ? 1 : 0,
                          duration: context.themed(Motion.hover),
                          curve: Motion.hoverCurve,
                          child: _IconAction(
                            icon: Icons.remove_rounded,
                            tooltip: 'Remove set',
                            onTap: () => log.deleteSet(s),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          if (s.note?.trim() case final note? when note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 22, bottom: 6),
              child: Text(note, style: _label(p, size: 13, color: p.inkMuted)),
            ),
        ],
      ),
    );
  }
}

class _NumberBox extends StatelessWidget {
  const _NumberBox({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.focusNode,
    this.decimal = false,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
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
        border: Border.all(color: p.border),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        style: _label(p, size: 14, weight: FontWeight.w600),
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
  bool _cancelled = false;
  late final _text = TextEditingController(text: widget.name);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) {
        if (_cancelled) {
          _cancelled = false;
          setState(() => _editing = false);
        } else {
          _commit();
        }
      }
    });
  }

  @override
  void didUpdateWidget(_InlineName old) {
    super.didUpdateWidget(old);
    if (!_editing && widget.name != old.name) _text.text = widget.name;
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
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: p.ink,
      letterSpacing: -0.2,
    );
    if (_editing) {
      return IntrinsicWidth(
        child: Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
              _cancelled = true;
              _text.text = widget.name;
              _focus.unfocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
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
        ),
      );
    }
    return PixelTooltip(
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
          duration: context.themed(Motion.hover),
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? p.empty : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colour.withValues(alpha: selected ? 0.8 : 0.35)),
          ),
          child: PixelFit(child: Text(group.label.toUpperCase(), style: capsLabel(colour))),
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
class AddSessionExercise extends StatefulWidget {
  const AddSessionExercise({super.key, required this.day, required this.logged});

  final DateTime day;

  /// Exercises already on this session.
  final Set<String> logged;

  @override
  State<AddSessionExercise> createState() => AddSessionExerciseState();
}

class AddSessionExerciseState extends State<AddSessionExercise> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _bodyweight = false;

  @override
  void initState() {
    super.initState();
    // The most-used exercises show while the empty field has the cursor.
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_focusChanged)
      ..dispose();
    _text.dispose();
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
        ? (_focus.hasFocus ? log.mostUsed(except: widget.logged) : const <Exercise>[])
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
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.border),
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
                  style: _label(p, size: 14),
                  cursorColor: p.accent,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration.collapsed(
                    hintText: 'Add an exercise',
                    hintStyle: _label(p, size: 14, color: p.inkMuted),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (query.isNotEmpty && matches.isNotEmpty) _add(matches.first);
                  },
                ),
              ),
            ],
          ),
        ),
        // What shows under the field opens and closes its room as it comes
        // and goes.
        AnimatedSize(
          duration: context.themed(Motion.morph),
          curve: Motion.morphCurve,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (matches.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  // Leaves the cursor in the field, which the most-used ones need to stay up.
                  child: TextFieldTapRegion(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final e in matches)
                          _Chip(colour: groupColour(e.group, p), label: e.name, onTap: () => _add(e)),
                      ],
                    ),
                  ),
                ),
              if (query.isNotEmpty && !exact) ...[
                const SizedBox(height: 10),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('New: what does “${_text.text.trim()}” train?', style: _label(p, size: 14, color: p.inkMuted)),
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
                    if (name.isEmpty) return;
                    final e = log.createExercise(name[0].toUpperCase() + name.substring(1), g, bodyweight: _bodyweight);
                    _add(e);
                  },
                ),
              ],
            ],
          ),
        ),
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
          duration: context.themed(Motion.click),
          curve: Motion.clickCurve,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: on ? 0.16 : 0),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colour.withValues(alpha: on ? 0.55 : 0.3)),
          ),
          child: PixelFit(
            child: Text(
              label,
              style: _label(p, size: 14, weight: FontWeight.w600, color: on ? p.ink : p.inkMuted),
            ),
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
              if (icon != null) ...[Icon(icon, size: 16, color: p.accent), const SizedBox(width: 4)],
              PixelFit(
                child: Text(
                  label,
                  style: _label(p, size: 14, weight: FontWeight.w600, color: p.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({super.key, required this.icon, required this.tooltip, required this.onTap, this.color});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return PixelTooltip(
      message: tooltip,
      child: Hoverable(
        focusable: true,
        semanticLabel: tooltip,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        builder: (hover) => AnimatedContainer(
          duration: context.themed(Motion.hover),
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: hover ? p.empty.withValues(alpha: 0.6) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: color ?? p.inkMuted),
        ),
      ),
    );
  }
}
