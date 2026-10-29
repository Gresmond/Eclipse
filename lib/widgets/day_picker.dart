import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_theme.dart';
import 'hover_fill.dart';

/// A month of days to pick from, opening on [selected]. Days after
/// [today] can't be picked, and months before [first] aren't shown.
class DayPicker extends StatefulWidget {
  const DayPicker({super.key, required this.today, required this.first, required this.selected, required this.onPick});

  final DateTime today, first, selected;
  final ValueChanged<DateTime> onPick;

  @override
  State<DayPicker> createState() => _DayPickerState();
}

class _DayPickerState extends State<DayPicker> {
  late DateTime _month = DateTime(widget.selected.year, widget.selected.month);

  void _shift(int delta) => setState(() => _month = DateTime(_month.year, _month.month + delta));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final today = widget.today, shown = widget.selected;
    final atToday = _month.year == today.year && _month.month == today.month;
    final atFirst = !_month.isAfter(widget.first);
    final lead = _month.weekday - 1; // Monday first
    final days = daysInMonth(_month.year, _month.month);

    Widget arrow(IconData icon, VoidCallback? onTap) => IconButton(
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      color: p.inkMuted,
      disabledColor: p.inkMuted.withValues(alpha: 0.25),
      onPressed: onTap,
      icon: Icon(icon),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${monthNames[_month.month - 1]} ${_month.year}',
                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: p.ink),
                ),
              ),
              arrow(Icons.chevron_left_rounded, atFirst ? null : () => _shift(-1)),
              arrow(Icons.chevron_right_rounded, atToday ? null : () => _shift(1)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final name in weekdayNames)
                Expanded(
                  child: Center(
                    child: Text(
                      name[0],
                      style: TextStyle(
                        fontFamily: Fonts.ui,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                        color: p.inkMuted.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // Always six weeks' rows, so the arrows stay put month to month.
          for (var week = 0; week < 6; week++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final d = week * 7 + col - lead + 1;
                        if (d < 1 || d > days) return const SizedBox(height: 38);
                        final day = DateTime(_month.year, _month.month, d);
                        return _PickerDay(
                          day: d,
                          selected: day == shown,
                          isToday: day == today,
                          enabled: !day.isAfter(today),
                          onTap: () {
                            Navigator.pop(context);
                            widget.onPick(day);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _PickerDay extends StatelessWidget {
  const _PickerDay({
    required this.day,
    required this.selected,
    required this.isToday,
    required this.enabled,
    required this.onTap,
  });

  final int day;
  final bool selected, isToday, enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = selected
        ? p.onAccent
        : !enabled
        ? p.inkMuted.withValues(alpha: 0.3)
        : isToday
        ? p.accent
        : p.ink;
    return Hoverable(
      onTap: enabled ? onTap : null,
      builder: (hover) => Padding(
        padding: const EdgeInsets.all(2),
        child: AnimatedContainer(
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: selected ? LinearGradient(colors: p.gradient.skip(1).toList()) : null,
            color: selected ? null : (hover && enabled ? p.empty : p.empty.withValues(alpha: 0)),
            border: isToday && !selected ? Border.all(color: p.accent.withValues(alpha: 0.5)) : null,
          ),
          child: Text(
            '$day',
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 13,
              fontWeight: selected || isToday ? FontWeight.w600 : FontWeight.w500,
              color: fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
