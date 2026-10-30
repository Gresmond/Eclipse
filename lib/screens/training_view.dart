import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/oklch.dart';
import '../training.dart';
import '../training_log.dart';
import '../widgets/day_picker.dart';
import '../widgets/fade_menu.dart';
import '../widgets/hover_fill.dart';
import '../widgets/tile.dart';
import '../widgets/note_input.dart';

part 'training/session.dart';
part 'training/chart.dart';

/// The page under the corner: every exercise's estimated 1RM over time,
/// and the sessions that make it.
class TrainingView extends StatelessWidget {
  const TrainingView({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ColoredBox(
      color: p.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: const [
                  Expanded(flex: 11, child: _ChartTile()),
                  SizedBox(height: 16),
                  Expanded(
                    flex: 9,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 3, child: _SessionTile()),
                        SizedBox(width: 16),
                        Expanded(flex: 2, child: _HistoryTile()),
                      ],
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

/// Each muscle group's colour: evenly round the OKLCH hue circle at one
/// lightness and chroma, so no group shouts louder than another.
Color groupColour(MuscleGroup g, Palette p) {
  final dark = p.brightness == Brightness.dark;
  final h = (20 + g.index * 360 / MuscleGroup.values.length) % 360;
  final l = dark ? 0.78 : 0.62;
  return Oklch(l, math.min(0.13, Oklch.maxChroma(l, h)), h).toColor();
}

/// Line styles that tell apart exercises of one group: solid, then dashes.
const _dashes = <List<double>>[
  [],
  [9, 5],
  [2, 4],
  [12, 4, 2, 4],
  [16, 7],
  [5, 3],
];

String _kg(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String _shortDate(DateTime d) => '${d.day} ${monthNames[d.month - 1].substring(0, 3)}';

TextStyle _label(Palette p, {double size = 14, FontWeight weight = FontWeight.w500, Color? color}) =>
    TextStyle(fontFamily: Fonts.ui, fontSize: size, fontWeight: weight, color: color ?? p.ink, height: 1.25);

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: EdgeInsets.fromLTRB(32, Platform.isMacOS ? 27 : 15, 32, 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'PROGRESS',
                style: _label(p, size: 13, weight: FontWeight.w600, color: p.inkMuted).copyWith(letterSpacing: 1.6),
              ),
              const SizedBox(height: 4),
              Text(
                'Training',
                style: TextStyle(
                  fontFamily: Fonts.display,
                  fontSize: 38,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -1.3,
                  height: 1.05,
                  color: p.ink,
                ),
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

// History

class _HistoryTile extends StatelessWidget {
  const _HistoryTile();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.training.revision, s.today));
    final log = state.training;
    final open = dateKey(log.day ?? state.today);
    final days = log.loggedDays;
    return Tile(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TileHeader(title: 'Past sessions'),
          const SizedBox(height: 10),
          Expanded(
            child: days.isEmpty
                ? Text('Sessions you log will be listed here.', style: _label(p, size: 13.5, color: p.inkMuted))
                : ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final key in days)
                        _HistoryRow(
                          day: DateTime.parse(key),
                          selected: key == open,
                          session: log.session(DateTime.parse(key)),
                          onTap: () {
                            final d = DateTime.parse(key);
                            log.showDay(d == state.today ? null : d);
                          },
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.day, required this.selected, required this.session, required this.onTap});

  final DateTime day;
  final bool selected;
  final List<(Exercise, List<TrainingSet>)> session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final d = day;
    return Hoverable(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      builder: (hover) => AnimatedContainer(
        duration: Motion.hover,
        curve: Motion.hoverCurve,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? p.today.withValues(alpha: 0.35) : p.empty.withValues(alpha: hover ? 0.5 : 0),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(
                '${weekdayNames[d.weekday - 1].substring(0, 3)} ${_shortDate(d)}',
                style: _label(p, size: 13.5, weight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final (e, sets) in session)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(color: groupColour(e.group, p), shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
                        Text('${e.name} ×${sets.length}', style: _label(p, size: 13, color: p.inkMuted)),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
