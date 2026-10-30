import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import 'fade_menu.dart';

/// A setting you flip by clicking anywhere on its row.
class SettingSwitchRow extends StatelessWidget {
  const SettingSwitchRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.on,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return FadeMenuRow(
      height: 62,
      grows: true,
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 15, fontWeight: FontWeight.w500, color: p.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, color: p.inkMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SettingToggle(on: on),
        ],
      ),
    );
  }
}

/// Picks the hour a new day starts. Picking just moves the highlight.
class DayStartPicker extends StatefulWidget {
  const DayStartPicker({super.key});

  static const hours = [0, 4];

  @override
  State<DayStartPicker> createState() => _DayStartPickerState();
}

class _DayStartPickerState extends State<DayStartPicker> {
  /// Where the pill sits for [hour]: its left edge and width, as fractions.
  static Offset _pillAt(int hour) {
    const hours = DayStartPicker.hours;
    return Offset(hours.indexOf(hour) / hours.length, 1 / hours.length);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'New day starts at',
            style: TextStyle(fontFamily: Fonts.ui, fontSize: 15, fontWeight: FontWeight.w500, color: p.ink),
          ),
          const SizedBox(height: 2),
          Text(
            'Before then, ticks count for the day before.',
            style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, color: p.inkMuted),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(20)),
            // One pill glides to the chosen hour, like the tab bar's.
            child: Stack(
              children: [
                if (DayStartPicker.hours.contains(state.dayStartHour))
                  Positioned.fill(
                    child: TweenAnimationBuilder<Offset>(
                      tween: Tween(end: _pillAt(state.dayStartHour)),
                      duration: Motion.morph,
                      curve: Motion.morphCurve,
                      builder: (context, pill, _) => Align(
                        // pill.dx is the left edge and pill.dy the width, as
                        // fractions of the row.
                        alignment: Alignment(pill.dy >= 1 ? 0 : 2 * pill.dx / (1 - pill.dy) - 1, 0),
                        child: FractionallySizedBox(
                          widthFactor: pill.dy,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(17),
                              gradient: LinearGradient(colors: p.gradient.skip(1).toList()),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    for (final hour in DayStartPicker.hours)
                      Expanded(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => state.setDayStartHour(hour),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Center(
                                child: AnimatedDefaultTextStyle(
                                  duration: Motion.morph,
                                  curve: Motion.morphCurve,
                                  style: TextStyle(
                                    fontFamily: Fonts.ui,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: hour == state.dayStartHour ? p.onAccent : p.inkMuted,
                                  ),
                                  child: Text(hourLabel(hour)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small switch, drawn to match the app rather than Material's.
class SettingToggle extends StatelessWidget {
  const SettingToggle({super.key, required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Slides and fills as it flips; colours come from the palette each
    // frame, so a theme change recolours it in step with everything else.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: on ? 1 : 0),
      duration: Motion.click,
      curve: Motion.clickCurve,
      builder: (context, t, _) => Container(
        width: 36,
        height: 22,
        padding: const EdgeInsets.all(3),
        alignment: Alignment.lerp(Alignment.centerLeft, Alignment.centerRight, t),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          gradient: LinearGradient(colors: [for (final c in p.gradient.skip(1)) Color.lerp(p.empty, c, t)!]),
          border: Border.all(color: p.tileBorder.withValues(alpha: 1 - t)),
        ),
        child: Container(
          width: 16,
          height: 16,
          // One colour on and off: dark on light themes, light on dark ones.
          decoration: BoxDecoration(color: p.ink, borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}
