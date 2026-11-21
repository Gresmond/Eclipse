part of 'todo_panel.dart';

/// A task's day on a calendar, with its time and how it repeats under it.
/// Repeat is a switch: on, it opens weekly (on chosen weekdays), monthly
/// (on the calendar day's date), custom (every so many days, weeks,
/// months or years from the calendar day) or, where offered, a birthday,
/// which folds the rest and the time away. The calendar then marks every
/// day it comes round; a click sets its first day and a right-click on a
/// marked day its last. It changes as it's set.
class _RepeatPanel extends StatefulWidget {
  const _RepeatPanel({
    required this.first,
    this.last,
    required this.start,
    required this.onStart,
    required this.repeat,
    required this.onRepeat,
    this.time,
    this.notify,
    this.location,
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

  /// Its reminders, under the time.
  final Widget? notify;

  /// Where it is, under its reminders.
  final Widget? location;

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

  /// Whether a left-click on the calendar picks the repeat's end date instead
  /// of its start date.
  bool _pickingEnd = false;

  @override
  void didUpdateWidget(_RepeatPanel old) {
    super.didUpdateWidget(old);
    if (widget.repeat == null || _birthday) _pickingEnd = false;
  }

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
    widget.onRepeat((rule: _rule, until: _kept(widget.repeat?.until, _rule, widget.start)));
  }

  /// [until], if it's still a day [rule] comes round on after [start].
  static DateTime? _kept(DateTime? until, RepeatRule rule, DateTime start) =>
      until != null && until.isAfter(start) && rule.on(until, start) ? until : null;

  bool get _birthday => widget.birthday ?? false;

  void _toggle() {
    if (widget.repeat == null && !_birthday) return _set(() {});
    setState(() => _pickingEnd = false);
    widget.onRepeat(null);
    if (_birthday) widget.onBirthday!(false);
  }

  /// A tapped day: the start, moving monthly's date and a lone weekday
  /// with it.
  void _tap(DateTime day) {
    final repeat = widget.repeat;
    final was = widget.start;
    final until = repeat?.until;
    widget.onStart(day);
    setState(() {
      _date = day.day;
      if (_days == weekdayBit(was.weekday)) _days = weekdayBit(day.weekday);
    });
    if (repeat != null) widget.onRepeat((rule: _rule, until: _kept(until, _rule, day)));
  }

  /// A right-clicked day, one it comes round on: the last; the last
  /// again: no end.
  void _end(DateTime? day) => widget.onRepeat((rule: widget.repeat!.rule, until: day));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final repeat = _birthday ? null : widget.repeat;
    final on = widget.repeat != null || _birthday;
    final start = widget.start, until = repeat?.until;
    bool comesRound(DateTime day) => day.isAfter(start) && repeat!.rule.on(day, start);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MonthCalendar(
          first: widget.first,
          last: widget.last,
          selected: start,
          end: until,
          marked: repeat == null ? null : (day) => comesRound(day) && (until == null || !day.isAfter(until)),
          onSelected: _tap,
          endable: repeat == null ? null : comesRound,
          onEnd: repeat == null ? null : _end,
          pickingEnd: repeat != null && _pickingEnd,
        ),
        const SizedBox(height: 8),
        if (widget.time case final time?) Fold(open: !_birthday, opacityCurve: Motion.secondHalf, child: time),
        ?widget.notify,
        ?widget.location,
        _RepeatSwitch(
          on: on,
          label: on ? (_birthday ? 'Birthday' : _summary(widget.repeat)) : 'Repeat',
          onTap: _toggle,
        ),
        Fold(
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
    final date = dayAndMonth(start, today: start);
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
    return '$what, until ${dayAndMonth(until, today: start)}';
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
        Align(
          alignment: Alignment.center,
          child: _ScaleDown(
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedPills(
                  labels: const ['Weekly', 'Monthly', 'Custom'],
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
                  SegmentedPills(
                    labels: const ['Birthday'],
                    selected: _birthday ? 0 : -1,
                    onSelect: (_) => widget.onBirthday!(true),
                  ),
                ],
              ],
            ),
          ),
        ),
        Fold(
          open: !_birthday,
          opacityCurve: Motion.secondHalf,
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
                          SegmentedPills(
                            labels: const ['days', 'weeks', 'months', 'years'],
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
              Builder(
                builder: (context) {
                  final shorterMonth =
                      (_kind == RepeatKind.monthly && _date > 28) ||
                      (custom && _unit == RepeatKind.months && start.day > 28);
                  final leapDay = custom && _unit == RepeatKind.yearly && start.month == 2 && start.day == 29;
                  return Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (shorterMonth || leapDay) const SizedBox(height: 8),
                        if (shorterMonth) Text('In shorter months, on the last day.', style: note),
                        if (leapDay) Text('In other years, on 28 February.', style: note),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: _ScaleDown(
                      alignment: Alignment.center,
                      child: _DateTags(
                        starts: 'Starts ${dayAndMonth(start, today: start)}',
                        ends: until == null ? 'Ends never' : 'Ends ${dayAndMonth(until, today: until)}',
                        canPickEnd: !_birthday && widget.repeat != null,
                        pickingEnd: !_birthday && widget.repeat != null && _pickingEnd,
                        onPickStart: () => setState(() => _pickingEnd = false),
                        onPickEnd: () => setState(() => _pickingEnd = true),
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
                          setState(() => _pickingEnd = false);
                          widget.onRepeat((rule: _rule, until: null));
                        },
                      ),
                    ),
                ],
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
  const _RepeatSwitch({required this.on, required this.label, required this.onTap, this.icon = Icons.repeat_rounded});

  final bool on;
  final String label;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Hoverable(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      builder: (hover) => AnimatedContainer(
        duration: context.themed(Motion.hover),
        curve: Motion.hoverCurve,
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          // Its own colour faded, not transparent black, which dimmed it
          // through a darker shade on the way in and out.
          color: p.empty.withValues(alpha: hover ? 0.6 : 0),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: FadeThrough(
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

/// [child] at its own size, at the left, or smaller to fit if it's too
/// wide.
class _ScaleDown extends StatelessWidget {
  const _ScaleDown({required this.child, this.alignment = Alignment.centerLeft});

  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, alignment: alignment, child: child);
}

/// When it starts and ends: click either tag to choose whether tapping a day
/// sets the start or end date (right-clicking a marked day sets its end too).
class _DateTags extends StatelessWidget {
  const _DateTags({
    required this.starts,
    required this.ends,
    required this.canPickEnd,
    required this.pickingEnd,
    required this.onPickStart,
    required this.onPickEnd,
  });

  final String starts, ends;
  final bool canPickEnd, pickingEnd;
  final VoidCallback onPickStart, onPickEnd;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: p.inkMuted);

    Widget tag(String label, {required bool active, required VoidCallback? onTap}) {
      if (!canPickEnd) return PixelFit(child: Text(label, style: base));
      return Hoverable(
        focusable: true,
        semanticLabel: label,
        onTap: onTap,
        builder: (hover) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: PixelFit(
            child: AnimatedDefaultTextStyle(
              duration: context.themed(Motion.hover),
              curve: Motion.hoverCurve,
              style: base.copyWith(color: active ? p.accent : (hover ? p.ink : p.inkMuted)),
              child: Text(label),
            ),
          ),
        ),
      );
    }

    return PixelTooltip(
      message: pickingEnd
          ? 'Click a marked day on the calendar to set an end date.'
          : 'Left-click to set a start date. Click “Ends” or right-click a day for an end date.',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          tag(starts, active: !pickingEnd, onTap: onPickStart),
          PixelFit(child: Text('  ·  ', style: base)),
          tag(ends, active: pickingEnd, onTap: onPickEnd),
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
  static const _cursorWidth = 2.0;

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
          // A field keeps the cursor's width and a 1px gap free on its
          // right; the same on the left puts the number in the middle.
          padding: const EdgeInsets.only(left: _cursorWidth + 1),
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
            cursorWidth: _cursorWidth,
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
              // The theme's spacing trails the last digit.
              letterSpacing: 0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            // No decorator: on desktop its compact density pushed the
            // number below the middle. The box centres the line instead.
            decoration: null,
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

/// A task's reminders, once it has a time or is a birthday: a switch
/// named for what's on, and, on, the times before to choose any of; at
/// least one stays chosen. Switched on, it's 15 minutes before (a
/// birthday: on the day).
class _NotifyRow extends StatelessWidget {
  const _NotifyRow({
    required this.bits,
    required this.time,
    required this.birthday,
    this.gone = 0,
    required this.onChanged,
  });

  /// As chosen, before [Reminder.given] keeps what this task can give.
  final int bits;
  final int? time;
  final bool birthday;

  /// The times before already past for a one-off task: not offered.
  final int gone;
  final ValueChanged<int> onChanged;

  static String _chip(Reminder r, bool birthday) => switch (r) {
    Reminder.dayBefore => birthday ? 'Day before' : '1 day',
    Reminder.hourBefore => '1 hour',
    Reminder.twentyBefore => '20 min',
    Reminder.quarterBefore => '15 min',
    Reminder.onTheDay => 'On the day',
  };

  /// 'Notify 1 day and 15 min before', 'Notify the day before and on the
  /// day, at 9 am'.
  static String _label(List<Reminder> on, bool birthday) {
    if (on.isEmpty) return 'Notify';
    if (birthday) {
      final days = [for (final r in on) r == Reminder.dayBefore ? 'the day before' : 'on the day'].join(' and ');
      return 'Notify $days, at ${Reminder.birthdayHour} am';
    }
    final times = [for (final r in on) _chip(r, false)];
    final joined = times.length == 1
        ? times.single
        : '${times.sublist(0, times.length - 1).join(', ')} and ${times.last}';
    return 'Notify $joined before';
  }

  @override
  Widget build(BuildContext context) {
    final offered = [
      for (final r in birthday ? Reminder.forBirthday : Reminder.timed)
        if (gone & r.bit == 0) r,
    ];
    final shows = (birthday || time != null) && offered.isNotEmpty;
    final kept = Reminder.given(bits, birthday: birthday, time: time, gone: gone);
    final on = Reminder.of(kept);
    return Fold(
      open: shows,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RepeatSwitch(
            on: kept != 0,
            label: _label(on, birthday),
            icon: Icons.notifications_rounded,
            // Off clears the hidden choices too, or 15 min would stand in.
            onTap: () => onChanged(
              kept != 0
                  ? bits & ~Reminder.allowed(bits, birthday: birthday, time: time)
                  : bits | (birthday ? Reminder.onTheDay : Reminder.quarterBefore).bit,
            ),
          ),
          Fold(
            open: kept != 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
              child: Align(
                alignment: Alignment.center,
                child: _ScaleDown(
                  alignment: Alignment.center,
                  child: SegmentedPills(
                    labels: [for (final r in offered) _chip(r, birthday)],
                    chosen: {
                      for (final (i, r) in offered.indexed)
                        if (kept & r.bit != 0) i,
                    },
                    onSelect: (i) {
                      final bit = offered[i].bit;
                      // The last one chosen stays: the switch turns them off.
                      if (kept == bit) return;
                      // A stand-in 15 min becomes a real choice once touched.
                      onChanged((bits | kept) ^ bit);
                    },
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
