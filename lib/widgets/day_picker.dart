import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/pixels.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'hover_fill.dart';

/// A month of days to pick from, opening on [selected]. Days after
/// [today] can't be picked, and months before [first] aren't shown.
class DayPicker extends StatelessWidget {
  const DayPicker({super.key, required this.today, required this.first, required this.selected, required this.onPick});

  final DateTime today, first, selected;
  final ValueChanged<DateTime> onPick;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
    child: MonthCalendar(
      initial: selected,
      first: first,
      last: today,
      dayBuilder: (context, day) => CalendarDay(
        day: day.day,
        selected: day == selected,
        isToday: day == today,
        enabled: !day.isAfter(today),
        onTap: () {
          Navigator.pop(context);
          onPick(day);
        },
      ),
    ),
  );
}

/// The app's one calendar: a month's name with arrows to the months either
/// side (no further back than [first]'s month, or on than [last]'s, when
/// set), the weekdays' letters, Monday first, and always six weeks' rows,
/// so the arrows and what's under it stay put month to month. Opens on
/// [initial]'s month; [dayBuilder] draws each day, usually a [CalendarDay].
class MonthCalendar extends StatefulWidget {
  const MonthCalendar({super.key, required this.initial, this.first, this.last, required this.dayBuilder});

  final DateTime initial;
  final DateTime? first, last;
  final Widget Function(BuildContext context, DateTime day) dayBuilder;

  @override
  State<MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<MonthCalendar> {
  late DateTime _month = DateTime(widget.initial.year, widget.initial.month);

  void _shift(int delta) => setState(() => _month = DateTime(_month.year, _month.month + delta));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final localizations = MaterialLocalizations.of(context);
    final (first, last) = (widget.first, widget.last);
    final atFirst = first != null && !_month.isAfter(DateTime(first.year, first.month));
    final atLast = last != null && !_month.isBefore(DateTime(last.year, last.month));
    final lead = _month.weekday - 1; // Monday first
    final days = daysInMonth(_month.year, _month.month);

    Widget arrow(IconData icon, String tooltip, VoidCallback? onTap) => IconButton(
      tooltip: tooltip,
      iconSize: Scale.navIcon,
      visualDensity: VisualDensity.compact,
      color: p.inkMuted,
      disabledColor: p.inkMuted.withValues(alpha: 0.25),
      onPressed: onTap,
      icon: Icon(icon),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PixelRow(
          children: [
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${monthNames[_month.month - 1]} ${_month.year}',
                style: TextStyle(fontFamily: Fonts.ui, fontSize: 15, fontWeight: FontWeight.w600, color: p.ink),
              ),
            ),
            arrow(Icons.chevron_left_rounded, localizations.previousMonthTooltip, atFirst ? null : () => _shift(-1)),
            arrow(Icons.chevron_right_rounded, localizations.nextMonthTooltip, atLast ? null : () => _shift(1)),
          ],
        ),
        const SizedBox(height: 4),
        PixelRow(
          children: [
            for (final name in weekdayNames)
              Expanded(
                child: Center(child: Text(name[0], style: capsLabel(p.inkMuted))),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var week = 0; week < 6; week++)
          PixelRow(
            children: [
              for (var col = 0; col < 7; col++)
                if (week * 7 + col - lead + 1 case final d when d >= 1 && d <= days)
                  // Keyed by its date, so a month's change draws new days
                  // rather than easing the old ones' fills into them.
                  Expanded(
                    key: ValueKey(DateTime(_month.year, _month.month, d)),
                    child: widget.dayBuilder(context, DateTime(_month.year, _month.month, d)),
                  )
                else
                  const Expanded(child: SizedBox(height: CalendarDay.height)),
            ],
          ),
      ],
    );
  }
}

/// A day on any of the app's calendars: a rounded square, [selected]
/// filled in the theme's done colour, [within] (a range, or a repeat's
/// end) tinted, today ringed, and a dot under a [marked] one.
class CalendarDay extends StatelessWidget {
  const CalendarDay({
    super.key,
    required this.day,
    this.selected = false,
    this.within = false,
    required this.isToday,
    this.enabled = true,
    this.marked = false,
    required this.onTap,
  });

  /// Its height, with the gap round it.
  static const height = 38.0;

  final int day;
  final bool selected, within, isToday, enabled, marked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = selected
        ? p.onDone
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
          duration: context.themed(Motion.hover),
          curve: Motion.hoverCurve,
          height: height - 4,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected
                ? p.done
                : within
                ? p.accent.withValues(alpha: hover && enabled ? 0.22 : 0.14)
                : (hover && enabled ? p.empty : p.empty.withValues(alpha: 0)),
            border: isToday && !selected ? Border.all(color: p.accent.withValues(alpha: 0.5)) : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Text(
                '$day',
                style: TextStyle(
                  fontFamily: Fonts.ui,
                  fontSize: 14,
                  fontWeight: selected || isToday ? FontWeight.w600 : FontWeight.w500,
                  color: fg,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (marked)
                Positioned(
                  bottom: -6,
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
