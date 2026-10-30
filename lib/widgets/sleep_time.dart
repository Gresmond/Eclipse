import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_theme.dart';

/// A sleep item's name with its time to the right. The times of a list
/// line up in one column, centred in the gap between the longest name and
/// whatever follows the names (the squares).
class SleepName extends StatelessWidget {
  const SleepName({super.key, required this.habit, required this.names, required this.style, this.trailing});

  final Habit habit;

  /// Every name in the list, so all rows put their times at the same place.
  final List<String> names;
  final TextStyle style;

  /// The width of the row to the right of the name. When given, the times
  /// centre on the whole row rather than in the space beside the names.
  final double? trailing;

  /// Keeps the time clear of the longest name when the gap is narrow.
  static const _minGap = 14.0;

  /// A little under the body text's size, as a task's due time.
  static TextStyle timeStyle(Palette p) => TextStyle(
    fontFamily: Fonts.time,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: p.inkMuted.withValues(alpha: 0.7),
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static double _width(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final time = timeStyle(p);
    final minutes = habit.minutes;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final longest = names.map((n) => _width(context, n, style)).fold(0.0, math.max);
        // The widest a time can be, so the column doesn't shift between rows.
        final timeWidth = _width(context, '12:30 pm', time);
        final centre = math.min(
          math.max(
            trailing != null ? (width + trailing!) / 2 : (longest + width) / 2,
            longest + _minGap + timeWidth / 2,
          ),
          width - timeWidth / 2,
        );
        final name = Text(habit.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
        // One row, so the name and time share a baseline. When the longest
        // name would run into the times, every row drops its time instead.
        final nameWidth = math.max(0.0, centre - timeWidth / 2 - 8);
        if (minutes == null || nameWidth < longest) return Align(alignment: Alignment.centerLeft, child: name);
        return Align(
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              SizedBox(width: nameWidth, child: name),
              // Right-aligned, so am and pm line up down the column.
              SizedBox(
                width: timeWidth + 8,
                child: Text(clockLabel(minutes), maxLines: 1, textAlign: TextAlign.right, style: time),
              ),
            ],
          ),
        );
      },
    );
  }
}
