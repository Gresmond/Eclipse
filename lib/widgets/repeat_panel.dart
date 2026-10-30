part of 'todo_panel.dart';

/// A task's day on a calendar, with its time and how it repeats under it.
/// Repeat is a switch: on, it opens weekly (on chosen weekdays), monthly
/// (on the calendar day's date), custom (every so many days, weeks,
/// months or years from the calendar day) or, where offered, a birthday,
/// which folds the rest and the time away. The calendar then marks every
/// day it comes round, and sets either its first day or its last, as the
/// Starts and Ends chips choose. It changes as it's set.
class _RepeatPanel extends StatefulWidget {
  const _RepeatPanel({
    required this.first,
    this.last,
    required this.start,
    required this.onStart,
    required this.repeat,
    required this.onRepeat,
    this.time,
    this.birthday,
    this.onBirthday,
    this.startsOn = false,
  });

  /// The first and last days the calendar offers for the start.
  final DateTime first;
  final DateTime? last;

  /// The task's day, which a repeat comes round from.
  final DateTime start;
  final ValueChanged<DateTime> onStart;

  final _RepeatChoice? repeat;
  final ValueChanged<_RepeatChoice?> onRepeat;

  /// The time's row, between the calendar and the repeat.
  final Widget? time;

  /// Whether it's a birthday; null where birthdays aren't offered.
  final bool? birthday;
  final ValueChanged<bool>? onBirthday;

  /// Whether it repeats as soon as this opens.
  final bool startsOn;

  @override
  State<_RepeatPanel> createState() => _RepeatPanelState();
}

class _RepeatPanelState extends State<_RepeatPanel> {
  late final _was = widget.repeat?.rule;
  late var _kind = switch (_was?.kind) {
    RepeatKind.weekly || null => RepeatKind.weekly,
    RepeatKind.monthly => RepeatKind.monthly,
    _ => RepeatKind.days,
  };
  late var _days = _was?.weekdays?.fold(0, (bits, d) => bits | weekdayBit(d)) ?? weekdayBit(widget.start.weekday);
  late var _every = switch (_was) {
    final r? when r.kind != RepeatKind.weekly && r.kind != RepeatKind.monthly => r.every,
    _ => 2,
  };

  /// Custom's unit: days, weeks, months or years.
  late var _unit = switch (_was?.kind) {
    final kind? when const [RepeatKind.weeks, RepeatKind.months, RepeatKind.yearly].contains(kind) => kind,
    _ => RepeatKind.days,
  };

  /// Monthly's date: the calendar day's, once it's tapped.
  late var _date = switch (_was) {
    final r? when r.kind == RepeatKind.monthly => r.every,
    _ => widget.start.day,
  };

  /// Whether the calendar sets the last day rather than the first.
  var _ends = false;

  RepeatRule get _rule => switch (_kind) {
    RepeatKind.weekly => RepeatRule.weekly({
      for (var d = 1; d <= 7; d++)
        if (_days & weekdayBit(d) != 0) d,
    }),
    RepeatKind.monthly => RepeatRule.monthly(_date),
    _ => switch (_unit) {
      RepeatKind.months => RepeatRule.months(_every),
      RepeatKind.yearly => RepeatRule.yearly(_every),
      _ => RepeatRule.every(_every, weeks: _unit == RepeatKind.weeks),
    },
  };

  @override
  void initState() {
    super.initState();
    if (widget.startsOn && widget.repeat == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onRepeat((rule: _rule, until: null));
      });
    }
  }

  void _set(VoidCallback change) {
    setState(change);
    widget.onRepeat((rule: _rule, until: widget.repeat?.until));
  }

  bool get _birthday => widget.birthday ?? false;

  void _toggle() {
    _ends = false;
    if (widget.repeat == null && !_birthday) return _set(() {});
    widget.onRepeat(null);
    if (_birthday) widget.onBirthday!(false);
  }

  /// A tapped day: the start, moving monthly's date and a lone weekday
  /// with it, or with Ends chosen, the last day.
  void _tap(DateTime day) {
    final repeat = widget.repeat;
    if (_ends && repeat != null) {
      setState(() => _ends = false);
      widget.onRepeat((rule: repeat.rule, until: day));
      return;
    }
    final was = widget.start;
    final until = repeat?.until;
    widget.onStart(day);
    setState(() {
      _date = day.day;
      if (_days == weekdayBit(was.weekday)) _days = weekdayBit(day.weekday);
    });
    if (repeat != null) widget.onRepeat((rule: _rule, until: until != null && until.isBefore(day) ? null : until));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final repeat = _birthday ? null : widget.repeat;
    final on = widget.repeat != null || _birthday;
    final start = widget.start, until = repeat?.until;
    final ends = _ends && repeat != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MonthCalendar(
          first: ends ? start : widget.first,
          last: ends ? null : widget.last,
          selected: start,
          end: until,
          marked: repeat == null
              ? null
              : (day) => day.isAfter(start) && (until == null || !day.isAfter(until)) && repeat.rule.on(day, start),
          onSelected: _tap,
        ),
        const SizedBox(height: 8),
        if (widget.time case final time?) _BirthdayFold(folded: _birthday, child: time),
        _RepeatSwitch(
          on: on,
          label: on ? (_birthday ? 'Birthday' : _summary(widget.repeat)) : 'Repeat',
          onTap: _toggle,
        ),
        _Unfold(
          open: on,
          child: Padding(padding: const EdgeInsets.fromLTRB(0, 6, 0, 8), child: _options(p)),
        ),
      ],
    );
  }

  /// "Every 2 weeks on Friday, until 3 Dec".
  String _summary(_RepeatChoice? choice) {
    if (choice == null) return 'Repeat';
    final start = widget.start;
    final rule = choice.rule;
    final weekday = weekdayNames[start.weekday - 1];
    final date = '${start.day} ${monthNames[start.month - 1].substring(0, 3)}';
    final n = rule.every;
    final what = switch (rule.kind) {
      RepeatKind.weeks => n == 1 ? 'Every week on $weekday' : 'Every $n weeks on $weekday',
      RepeatKind.months =>
        n == 1 ? 'Every month on the ${ordinal(start.day)}' : 'Every $n months on the ${ordinal(start.day)}',
      RepeatKind.yearly => n == 1 ? 'Every year on $date' : 'Every $n years on $date',
      _ => rule.label,
    };
    final until = choice.until;
    if (until == null) return what;
    final year = until.year == start.year ? '' : ' ${until.year}';
    return '$what, until ${until.day} ${monthNames[until.month - 1].substring(0, 3)}$year';
  }

  Widget _options(Palette p) {
    final label = TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: p.ink);
    final note = TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: p.inkMuted);
    final start = widget.start;
    final until = widget.repeat?.until;
    final custom = _kind != RepeatKind.weekly && _kind != RepeatKind.monthly;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Each row shrinks only when text too large for the dialog's one
        // width would otherwise cut it off. The rows are centred; the notes
        // line up with the switch's text.
        Center(
          child: _ScaleDown(
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Pills(
                  options: const ['Weekly', 'Monthly', 'Custom'],
                  selected: _birthday
                      ? -1
                      : switch (_kind) {
                          RepeatKind.weekly => 0,
                          RepeatKind.monthly => 1,
                          _ => 2,
                        },
                  onSelect: (i) {
                    if (_birthday) widget.onBirthday!(false);
                    _set(() {
                      _kind = [RepeatKind.weekly, RepeatKind.monthly, RepeatKind.days][i];
                      _date = start.day;
                    });
                  },
                ),
                if (widget.birthday != null) ...[
                  const SizedBox(width: 8),
                  _Pills(
                    options: const ['Birthday'],
                    selected: _birthday ? 0 : -1,
                    onSelect: (_) => setState(() {
                      _ends = false;
                      widget.onBirthday!(true);
                    }),
                  ),
                ],
              ],
            ),
          ),
        ),
        _BirthdayFold(
          folded: _birthday,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Monthly has nothing to choose: the summary above says which day.
              if (_kind != RepeatKind.monthly) ...[
                const SizedBox(height: 14),
                SizedBox(
                  height: 40,
                  child: _ScaleDown(
                    alignment: Alignment.center,
                    child: switch (_kind) {
                      RepeatKind.weekly => DayToggles(
                        bits: _days,
                        size: 30,
                        lastReason: 'It needs at least one day',
                        onChanged: (bits) => _set(() => _days = bits),
                      ),
                      _ => Row(
                        children: [
                          Text('Every', style: label),
                          _Stepper(value: _every, min: 1, max: 99, onChanged: (v) => _set(() => _every = v)),
                          const SizedBox(width: 6),
                          _Pills(
                            options: const ['days', 'weeks', 'months', 'years'],
                            selected: const [
                              RepeatKind.days,
                              RepeatKind.weeks,
                              RepeatKind.months,
                              RepeatKind.yearly,
                            ].indexOf(_unit),
                            onSelect: (i) => _set(
                              () => _unit = const [
                                RepeatKind.days,
                                RepeatKind.weeks,
                                RepeatKind.months,
                                RepeatKind.yearly,
                              ][i],
                            ),
                          ),
                        ],
                      ),
                    },
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_kind == RepeatKind.monthly && _date > 28) const SizedBox(height: 8),
                    if ((_kind == RepeatKind.monthly && _date > 28) ||
                        (custom && _unit == RepeatKind.months && start.day > 28))
                      Text('In shorter months, on the last day.', style: note),
                    if (custom && _unit == RepeatKind.yearly && start.month == 2 && start.day == 29)
                      Text('Only in leap years.', style: note),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: _ScaleDown(
                      alignment: Alignment.center,
                      child: _Pills(
                        options: [
                          'Starts ${start.day} ${monthNames[start.month - 1].substring(0, 3)}',
                          until == null
                              ? 'Ends never'
                              : 'Ends ${until.day} ${monthNames[until.month - 1].substring(0, 3)}',
                        ],
                        selected: _ends ? 1 : 0,
                        onSelect: (i) => setState(() => _ends = i == 1),
                      ),
                    ),
                  ),
                  if (until != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: _TaskAction(
                        tooltip: 'No end date',
                        icon: Icons.close_rounded,
                        onPressed: () {
                          setState(() => _ends = false);
                          widget.onRepeat((rule: _rule, until: null));
                        },
                      ),
                    ),
                ],
              ),
              if (_ends)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 12),
                  child: Text('Pick its last day on the calendar.', style: note),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Repeat", or once on how it repeats, in the time row's accent text
/// button look, and a switch.
class _RepeatSwitch extends StatelessWidget {
  const _RepeatSwitch({required this.on, required this.label, required this.onTap});

  final bool on;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Hoverable(
      onTap: onTap,
      builder: (hover) => AnimatedContainer(
        duration: Motion.hover,
        curve: Motion.hoverCurve,
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: hover ? p.empty.withValues(alpha: 0.6) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(Icons.repeat_rounded, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: FadeThrough(
                duration: Motion.click,
                layoutBuilder: FadeThrough.pinTopLeft,
                child: Text(
                  label,
                  key: ValueKey(label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(color: colors.primary),
                ),
              ),
            ),
            SettingToggle(on: on),
          ],
        ),
      ),
    );
  }
}

/// [child] unfolding down from nothing when [open], and folding away.
class _Unfold extends StatefulWidget {
  const _Unfold({required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<_Unfold> createState() => _UnfoldState();
}

class _UnfoldState extends State<_Unfold> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Motion.morph, value: widget.open ? 1 : 0);
  late final _height = CurvedAnimation(parent: _controller, curve: Motion.morphCurve);

  @override
  void didUpdateWidget(_Unfold old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) widget.open ? _controller.forward() : _controller.reverse();
  }

  @override
  void dispose() {
    _height.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _height,
    alignment: Alignment.topCenter,
    child: FadeTransition(
      opacity: _height,
      child: IgnorePointer(
        ignoring: !widget.open,
        child: ExcludeFocus(excluding: !widget.open, child: widget.child),
      ),
    ),
  );
}

/// [child] at its own size, at the left, or smaller to fit if it's too
/// wide.
class _ScaleDown extends StatelessWidget {
  const _ScaleDown({required this.child, this.alignment = Alignment.centerLeft});

  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, alignment: alignment, child: child);
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
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
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
                    color: p.done.withValues(alpha: i == selected ? 1 : 0),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    option,
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: 14,
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

/// A number to type, with buttons either side to take one off or add one.
class _Stepper extends StatefulWidget {
  const _Stepper({required this.value, required this.min, required this.max, required this.onChanged});

  final int value, min, max;
  final ValueChanged<int> onChanged;

  @override
  State<_Stepper> createState() => _StepperState();
}

class _StepperState extends State<_Stepper> {
  late final _text = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Left empty or out of range, it shows the number it holds.
    _focus.addListener(() {
      if (!_focus.hasFocus) _text.text = '${widget.value}';
    });
  }

  @override
  void didUpdateWidget(_Stepper old) {
    super.didUpdateWidget(old);
    if (int.tryParse(_text.text) != widget.value && !_focus.hasFocus) _text.text = '${widget.value}';
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _step(int value) {
    _text.text = '$value';
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final value = widget.value;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TaskAction(
          tooltip: 'Fewer',
          icon: Icons.remove_rounded,
          onPressed: value > widget.min ? () => _step(value - 1) : null,
        ),
        Container(
          width: 36,
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: p.empty.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.border),
          ),
          child: TextField(
            controller: _text,
            focusNode: _focus,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
            cursorColor: p.ink,
            onTap: () => _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length),
            onChanged: (text) {
              final n = int.tryParse(text);
              if (n != null && n >= widget.min && n <= widget.max && n != value) widget.onChanged(n);
            },
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
          ),
        ),
        _TaskAction(
          tooltip: 'More',
          icon: Icons.add_rounded,
          onPressed: value < widget.max ? () => _step(value + 1) : null,
        ),
      ],
    );
  }
}
