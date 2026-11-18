import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import 'fade_menu.dart';
import 'glide_pill.dart';
import 'smooth_gradient.dart';

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
      // Centred as a whole in a tall row; inside it the switch sits on the
      // title's line, whatever the subtitle's length.
      child: Center(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    strutStyle: const StrutStyle(fontSize: 15, height: _titleLine / 15, forceStrutHeight: true),
                    style: TextStyle(fontFamily: Fonts.ui, fontSize: 15, fontWeight: FontWeight.w500, color: p.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: p.inkMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SettingToggle(on: on),
          ],
        ),
      ),
    );
  }

  /// The title's line is as tall as the switch, so the two share a centre.
  static const _titleLine = 22.0;
}

class DayStartPicker extends StatefulWidget {
  const DayStartPicker({super.key});

  static const hours = [0, 4];

  @override
  State<DayStartPicker> createState() => _DayStartPickerState();
}

class _DayStartPickerState extends State<DayStartPicker> {
  final _keys = [for (final _ in DayStartPicker.hours) GlobalKey()];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    final index = DayStartPicker.hours.indexOf(state.dayStartHour);
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
            style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: p.inkMuted),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(20)),
            // One pill glides to the chosen hour, like the tab bar's.
            child: GlidePill(
              target: index >= 0 ? _keys[index] : null,
              color: p.done,
              child: Row(
                children: [
                  for (final (i, hour) in DayStartPicker.hours.indexed)
                    Expanded(
                      key: _keys[i],
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => state.setDayStartHour(hour),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: context.themed(Motion.morph),
                                curve: Motion.morphCurve,
                                style: TextStyle(
                                  fontFamily: Fonts.ui,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: hour == state.dayStartHour ? p.onDone : p.inkMuted,
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
      duration: context.themed(Motion.click),
      curve: Motion.clickCurve,
      builder: (context, t, _) => Container(
        width: 36,
        height: 22,
        padding: const EdgeInsets.all(4),
        alignment: Alignment.lerp(Alignment.centerLeft, Alignment.centerRight, t),
        decoration: SmoothGradientDecoration(
          borderRadius: BorderRadius.circular(12),
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
