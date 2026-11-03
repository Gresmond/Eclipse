import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'confirm_on_enter.dart';
import 'day_picker.dart';

/// 'Sat 7 Nov – Sun 15 Nov', or one day alone, with the year when it
/// isn't [today]'s.
String holidayLabel(Holiday h, DateTime today) => h.start == h.end
    ? shortDay(h.start, today: today)
    : '${shortDay(h.start, today: today)} – ${shortDay(h.end, today: today)}';

/// Settings' holidays: each current or coming one with a cross to take it
/// away, then, muted under Past, those already over, which can be taken
/// away too (one added by mistake); and a button that adds one.
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
    final past = [
      for (final h in state.holidays.reversed)
        if (h.end.isBefore(today)) h,
    ];
    Widget row(Holiday h, {required bool over}) => Padding(
      key: ValueKey(h),
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.beach_access_rounded, size: 16, color: over ? p.inkMuted : p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              holidayLabel(h, today),
              style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: over ? p.inkMuted : p.ink),
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
    );
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
                for (final h in shown) row(h, over: false),
                if (past.isNotEmpty) ...[
                  Padding(
                    key: const ValueKey('past'),
                    padding: const EdgeInsets.only(top: 10, bottom: 2),
                    child: Text(
                      'PAST',
                      style: TextStyle(
                        fontFamily: Fonts.ui,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                        color: p.inkMuted,
                      ),
                    ),
                  ),
                  for (final h in past) row(h, over: true),
                ],
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
  DateTime? _start, _end;

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
              MonthCalendar(
                initial: widget.today,
                dayBuilder: (context, day) => CalendarDay(
                  day: day.day,
                  selected: picked != null && (day == picked.start || day == picked.end),
                  within: picked != null && !day.isBefore(picked.start) && !day.isAfter(picked.end),
                  isToday: day == widget.today,
                  onTap: () => _tap(day),
                ),
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
