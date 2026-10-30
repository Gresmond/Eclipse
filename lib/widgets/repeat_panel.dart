part of 'todo_panel.dart';

/// How a task repeats: on chosen weekdays, on a date each month, on its
/// date every so many years, or every so many days, weeks or months, with
/// an optional last day. It repeats as soon as this opens, and changes as
/// it's set.
class _RepeatPanel extends StatefulWidget {
  const _RepeatPanel({required this.start, this.current, required this.onChanged, required this.onPickUntil});

  /// The first day it would come round from.
  final DateTime start;
  final _RepeatChoice? current;

  final ValueChanged<_RepeatChoice> onChanged;

  /// Opens the calendar for its last day.
  final VoidCallback onPickUntil;

  @override
  State<_RepeatPanel> createState() => _RepeatPanelState();
}

class _RepeatPanelState extends State<_RepeatPanel> {
  late final _was = widget.current?.rule;
  late var _kind = switch (_was?.kind) {
    RepeatKind.days || RepeatKind.weeks || RepeatKind.months => RepeatKind.days,
    final kind? => kind,
    null => RepeatKind.weekly,
  };
  late var _days = _was?.weekdays?.fold(0, (bits, d) => bits | weekdayBit(d)) ?? weekdayBit(widget.start.weekday);
  late var _every = switch (_was) {
    final r? when r.kind == RepeatKind.days || r.kind == RepeatKind.weeks || r.kind == RepeatKind.months => r.every,
    _ => 2,
  };

  /// Custom's unit: days, weeks or months.
  late var _unit = switch (_was?.kind) {
    final kind? when kind == RepeatKind.weeks || kind == RepeatKind.months => kind,
    _ => RepeatKind.days,
  };
  late var _date = switch (_was) {
    final r? when r.kind == RepeatKind.monthly => r.every,
    _ => widget.start.day,
  };
  late var _years = switch (_was) {
    final r? when r.kind == RepeatKind.yearly => r.every,
    _ => 1,
  };

  RepeatRule get _rule => switch (_kind) {
    RepeatKind.weekly => RepeatRule.weekly({
      for (var d = 1; d <= 7; d++)
        if (_days & weekdayBit(d) != 0) d,
    }),
    RepeatKind.monthly => RepeatRule.monthly(_date),
    RepeatKind.yearly => RepeatRule.yearly(_years),
    _ when _unit == RepeatKind.months => RepeatRule.months(_every),
    _ => RepeatRule.every(_every, weeks: _unit == RepeatKind.weeks),
  };

  @override
  void initState() {
    super.initState();
    if (widget.current == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChanged((rule: _rule, until: null));
      });
    }
  }

  void _set(VoidCallback change) {
    setState(change);
    widget.onChanged((rule: _rule, until: widget.current?.until));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = TextStyle(fontFamily: Fonts.ui, fontSize: 14.5, color: p.ink);
    final until = widget.current?.until;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          // Each row shrinks only when text too large for the dialog's one
          // width would otherwise cut it off.
          _ScaleDown(
            child: _Pills(
              options: const ['Weekly', 'Monthly', 'Yearly', 'Custom'],
              selected: switch (_kind) {
                RepeatKind.weekly => 0,
                RepeatKind.monthly => 1,
                RepeatKind.yearly => 2,
                _ => 3,
              },
              onSelect: (i) =>
                  _set(() => _kind = [RepeatKind.weekly, RepeatKind.monthly, RepeatKind.yearly, RepeatKind.days][i]),
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 40,
            child: _ScaleDown(
              child: switch (_kind) {
                RepeatKind.weekly => DayToggles(
                  bits: _days,
                  size: 30,
                  lastReason: 'It needs at least one day',
                  onChanged: (bits) => _set(() => _days = bits),
                ),
                RepeatKind.monthly => Row(
                  children: [
                    Text('On the', style: label),
                    _Stepper(value: _date, min: 1, max: 31, onChanged: (v) => _set(() => _date = v)),
                    Text('${ordinal(_date).substring('$_date'.length)} of each month', style: label),
                  ],
                ),
                RepeatKind.yearly => Row(
                  children: [
                    Text('Every', style: label),
                    _Stepper(value: _years, min: 1, max: 99, onChanged: (v) => _set(() => _years = v)),
                    Text(
                      '${_years == 1 ? 'year' : 'years'} on ${monthNames[widget.start.month - 1].substring(0, 3)} ${widget.start.day}',
                      style: label,
                    ),
                  ],
                ),
                _ => Row(
                  children: [
                    Text('Every', style: label),
                    _Stepper(value: _every, min: 1, max: 99, onChanged: (v) => _set(() => _every = v)),
                    const SizedBox(width: 6),
                    _Pills(
                      options: const ['days', 'weeks', 'months'],
                      selected: [RepeatKind.days, RepeatKind.weeks, RepeatKind.months].indexOf(_unit),
                      onSelect: (i) => _set(() => _unit = [RepeatKind.days, RepeatKind.weeks, RepeatKind.months][i]),
                    ),
                    if (_unit == RepeatKind.months)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text('on the ${ordinal(widget.start.day)}', style: label),
                      ),
                  ],
                ),
              },
            ),
          ),
          if ((_kind == RepeatKind.monthly && _date > 28) ||
              (_kind == RepeatKind.days && _unit == RepeatKind.months && widget.start.day > 28))
            Text(
              'In shorter months, on the last day.',
              style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, color: p.inkMuted),
            ),
          if (_kind == RepeatKind.yearly && widget.start.month == 2 && widget.start.day == 29)
            Text(
              'Only in leap years.',
              style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, color: p.inkMuted),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(until == null ? 'No end date' : 'Until ${dayMonth(until)}/${until.year}'),
                    onPressed: widget.onPickUntil,
                  ),
                ),
              ),
              if (until != null)
                IconButton(
                  tooltip: 'No end date',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => widget.onChanged((rule: _rule, until: null)),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// [child] at its own size, at the left, or smaller to fit if it's too
/// wide.
class _ScaleDown extends StatelessWidget {
  const _ScaleDown({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: child);
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
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.85)),
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
                    borderRadius: BorderRadius.circular(17),
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

/// A number with buttons either side to take one off or add one.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.min, required this.max, required this.onChanged});

  final int value, min, max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TaskAction(
          tooltip: 'Fewer',
          icon: Icons.remove_rounded,
          onPressed: value > min ? () => onChanged(value - 1) : null,
        ),
        SizedBox(
          width: 28,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: p.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        _TaskAction(
          tooltip: 'More',
          icon: Icons.add_rounded,
          onPressed: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}
