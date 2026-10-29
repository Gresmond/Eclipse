import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_theme.dart';

/// The weekdays a ritual or repeating task is on, Monday first: filled
/// when on. The last one on can't be turned off.
class DayToggles extends StatelessWidget {
  const DayToggles({
    super.key,
    required this.bits,
    required this.onChanged,
    this.size = 22,
    this.lastReason = 'A ritual needs at least one day',
  });

  /// [weekdayBit]s.
  final int bits;
  final ValueChanged<int> onChanged;
  final double size;

  /// The last day's tooltip.
  final String lastReason;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var weekday = 1; weekday <= 7; weekday++)
          Padding(
            padding: const EdgeInsets.only(right: 5),
            child: Builder(
              builder: (context) {
                final bit = weekdayBit(weekday);
                final on = bits & bit != 0;
                final last = on && bits == bit;
                return Tooltip(
                  message: last ? lastReason : weekdayNames[weekday - 1],
                  child: MouseRegion(
                    cursor: last ? MouseCursor.defer : SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: last ? null : () => onChanged(bits ^ bit),
                      child: _DayCircle(weekday: weekday, on: on, size: size),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// A weekday's letter in a circle, filled in the done colour when the
/// ritual is on that day.
class _DayCircle extends StatelessWidget {
  const _DayCircle({required this.weekday, required this.on, required this.size});

  final int weekday;
  final bool on;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedContainer(
      duration: Motion.click,
      curve: Motion.clickCurve,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size / 2),
        color: p.done.withValues(alpha: on ? 1 : 0),
        border: Border.all(color: on ? p.done : p.inkMuted.withValues(alpha: 0.35)),
      ),
      child: Text(
        weekdayNames[weekday - 1][0],
        style: TextStyle(
          fontFamily: Fonts.ui,
          fontSize: size * 0.48,
          fontWeight: FontWeight.w600,
          color: on ? p.onAccent : p.inkMuted,
        ),
      ),
    );
  }
}
