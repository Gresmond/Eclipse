import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'confirm_on_enter.dart';
import 'hover_fill.dart';

/// 'Sat 7 Nov', with the year when it isn't [today]'s.
String _day(DateTime day, DateTime today) =>
    '${weekdayNames[day.weekday - 1].substring(0, 3)} ${day.day} ${monthNames[day.month - 1].substring(0, 3)}'
    '${day.year != today.year ? ' ${day.year}' : ''}';

/// 'Sat 7 Nov – Sun 15 Nov', or one day alone.
String holidayLabel(Holiday h, DateTime today) =>
    h.start == h.end ? _day(h.start, today) : '${_day(h.start, today)} – ${_day(h.end, today)}';

/// Settings' holidays: each current or coming one with a cross to take it
/// away, and a button that adds one. Past ones stay kept, unshown, so their
/// days stay rested.
class HolidaysRow extends StatelessWidget {
  const HolidaysRow({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.holidays, s.today));
    final today = state.today;
    final shown = [
      for (final h in state.holidays)
        if (!h.end.isBefore(today)) h,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Holidays',
                      style: TextStyle(fontFamily: Fonts.ui, fontSize: 15, fontWeight: FontWeight.w500, color: p.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Rest days for rituals and sleep. A blank one won’t break a streak.',
                      style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: p.inkMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add'),
                onPressed: () async {
                  final picked = await showAppDialog<Holiday>(
                    context: context,
                    builder: (_) => _HolidayDialog(today: today),
                  );
                  if (picked != null) state.addHoliday(picked.start, picked.end);
                },
              ),
            ],
          ),
          // Each one fades and folds in or out as it's added or taken away.
          AnimatedSize(
            duration: Motion.morph,
            curve: Motion.morphCurve,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final h in shown)
                  Padding(
                    key: ValueKey(h),
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(Icons.beach_access_rounded, size: 16, color: p.accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            holidayLabel(h, today),
                            style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: p.ink),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove holiday',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          color: p.inkMuted,
                          onPressed: () => state.removeHoliday(h),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A month of days to pick a holiday on: the first click its first day,
/// the next its last (either way round), the days between shaded.
class _HolidayDialog extends StatefulWidget {
  const _HolidayDialog({required this.today});

  final DateTime today;

  @override
  State<_HolidayDialog> createState() => _HolidayDialogState();
}

class _HolidayDialogState extends State<_HolidayDialog> {
  late DateTime _month = DateTime(widget.today.year, widget.today.month);
  DateTime? _start, _end;

  void _shift(int delta) => setState(() => _month = DateTime(_month.year, _month.month + delta));

  void _tap(DateTime day) => setState(() {
    final start = _start;
    if (start == null || _end != null) {
      _start = day;
      _end = null;
    } else if (day.isBefore(start)) {
      _start = day;
      _end = start;
    } else {
      _end = day;
    }
  });

  /// What it picked: one day until the last is clicked.
  Holiday? get _picked => switch (_start) {
    final start? => (start: start, end: _end ?? start),
    null => null,
  };

  void _add() {
    if (_picked case final picked?) Navigator.pop(context, picked);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final picked = _picked;
    final lead = _month.weekday - 1; // Monday first
    final days = daysInMonth(_month.year, _month.month);

    Widget arrow(IconData icon, VoidCallback onTap) => IconButton(
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      color: p.inkMuted,
      onPressed: onTap,
      icon: Icon(icon),
    );

    return ConfirmOnEnter(
      onConfirm: _add,
      child: AlertDialog(
        backgroundColor: p.tile,
        title: const Text('Add a holiday'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${monthNames[_month.month - 1]} ${_month.year}',
                      style: TextStyle(fontFamily: Fonts.ui, fontSize: 15, fontWeight: FontWeight.w600, color: p.ink),
                    ),
                  ),
                  arrow(Icons.chevron_left_rounded, () => _shift(-1)),
                  arrow(Icons.chevron_right_rounded, () => _shift(1)),
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
                            fontSize: 12,
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
                            final end = picked != null && (day == picked.start || day == picked.end);
                            final within = picked != null && !day.isBefore(picked.start) && !day.isAfter(picked.end);
                            return _RangeDay(
                              day: d,
                              end: end,
                              within: within,
                              isToday: day == widget.today,
                              onTap: () => _tap(day),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Text(switch (picked) {
                null => 'Click its first day, then its last.',
                final h when _end == null => '${holidayLabel(h, widget.today)}, or click its last day',
                final h => holidayLabel(h, widget.today),
              }, style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: p.inkMuted)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: picked == null ? null : _add, child: const Text('Add')),
        ],
      ),
    );
  }
}

/// A day of the holiday calendar: its first and last days filled, the
/// days between tinted.
class _RangeDay extends StatelessWidget {
  const _RangeDay({
    required this.day,
    required this.end,
    required this.within,
    required this.isToday,
    required this.onTap,
  });

  final int day;
  final bool end, within, isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      onTap: onTap,
      builder: (hover) => Padding(
        padding: const EdgeInsets.all(2),
        child: AnimatedContainer(
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: end ? LinearGradient(colors: p.gradient.skip(1).toList()) : null,
            color: end
                ? null
                : within
                ? p.accent.withValues(alpha: hover ? 0.22 : 0.14)
                : (hover ? p.empty : p.empty.withValues(alpha: 0)),
            border: isToday && !end ? Border.all(color: p.accent.withValues(alpha: 0.5)) : null,
          ),
          child: Text(
            '$day',
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 14,
              fontWeight: end || isToday ? FontWeight.w600 : FontWeight.w500,
              color: end
                  ? p.onAccent
                  : isToday
                  ? p.accent
                  : p.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
