import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/pixels.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/oklch.dart';
import '../training.dart';
import '../training_log.dart';
import '../widgets/appear.dart';
import '../widgets/day_picker.dart';
import '../widgets/fade_menu.dart';
import '../widgets/fade_through.dart';
import '../widgets/glide_pill.dart';
import '../widgets/hover_fill.dart';
import '../widgets/tile.dart';
import '../widgets/note_input.dart';
import '../widgets/rolling_number.dart';

part 'training/session.dart';
part 'training/chart.dart';

/// Gym training: every exercise's estimated 1RM over time,
/// and the sessions that make it.
class TrainingView extends StatelessWidget {
  const TrainingView({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
      child: PixelColumn(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          Expanded(flex: 11, child: _ChartTile()),
          SizedBox(height: 20),
          Expanded(
            flex: 9,
            child: PixelRow(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _SessionTile()),
                SizedBox(width: 20),
                Expanded(flex: 2, child: _HistoryTile()),
              ],
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

/// Rows that open up and fade in when added, and fade and close up when
/// removed, as a day's tasks do. Those there when it's first built are
/// simply there. Each child must be keyed.
class _FoldingColumn extends StatefulWidget {
  const _FoldingColumn({required this.children});

  final List<Widget> children;

  @override
  State<_FoldingColumn> createState() => _FoldingColumnState();
}

class _FoldingColumnState extends State<_FoldingColumn> {
  late final _seen = {for (final c in widget.children) c.key!};

  /// Removed rows as last built, closing up where they were.
  final _leaving = <Key, ({int index, Widget child})>{};

  @override
  void didUpdateWidget(_FoldingColumn old) {
    super.didUpdateWidget(old);
    final now = {for (final c in widget.children) c.key!};
    for (final (i, c) in old.children.indexed) {
      if (!now.contains(c.key)) _leaving.putIfAbsent(c.key!, () => (index: i, child: c));
    }
    _leaving.removeWhere((k, _) => now.contains(k));
  }

  @override
  Widget build(BuildContext context) {
    final rows = [for (final c in widget.children) Appear(key: c.key, animate: !_seen.contains(c.key), child: c)];
    for (final MapEntry(key: k, value: l) in _leaving.entries) {
      rows.insert(
        l.index.clamp(0, rows.length),
        Appear(
          key: k,
          animate: false,
          shown: false,
          onHidden: () => setState(() => _leaving.remove(k)),
          child: l.child,
        ),
      );
    }
    _seen.addAll([for (final c in widget.children) c.key!]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
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
    final sessions = log.sessions;
    return Tile(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TileHeader(title: 'Past sessions'),
          const SizedBox(height: 10),
          Expanded(
            child: days.isEmpty
                ? Text('Sessions you log will be listed here.', style: _label(p, size: 14, color: p.inkMuted))
                : ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      _FoldingColumn(
                        children: [
                          for (final key in days)
                            _HistoryRow(
                              key: ValueKey(key),
                              day: DateTime.parse(key),
                              selected: key == open,
                              session: sessions[key] ?? const [],
                              onTap: () {
                                final d = DateTime.parse(key);
                                log.showDay(d == state.today ? null : d);
                              },
                              onRepeat: DateTime.parse(key) == state.today
                                  ? null
                                  : () {
                                      log.repeatSession(DateTime.parse(key), state.today);
                                      log.showDay(null);
                                    },
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

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    super.key,
    required this.day,
    required this.selected,
    required this.session,
    required this.onTap,
    required this.onRepeat,
  });

  final DateTime day;
  final bool selected;
  final List<(Exercise, List<TrainingSet>)> session;
  final VoidCallback onTap;

  /// Puts this session on today; null for today's own.
  final VoidCallback? onRepeat;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final d = day;
    return Hoverable(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      builder: (hover) => AnimatedContainer(
        duration: context.themed(Motion.hover),
        curve: Motion.hoverCurve,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? p.today.withValues(alpha: 0.35) : p.empty.withValues(alpha: hover ? 0.5 : 0),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(
                '${weekdayNames[d.weekday - 1].substring(0, 3)} ${_shortDate(d)}',
                style: _label(p, size: 14, weight: FontWeight.w600),
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
                        const SizedBox(width: 4),
                        // A name longer than the row shortens rather than spill out of it.
                        Flexible(
                          child: PixelFit(
                            child: Text(
                              '${e.name} ×${sets.length}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _label(p, size: 14, color: p.inkMuted),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (onRepeat != null)
              // The button is taller than a line of the row, which it must not stretch.
              SizedBox(
                width: 24,
                height: 18,
                child: OverflowBox(
                  maxHeight: 24,
                  child: IgnorePointer(
                    ignoring: !hover,
                    child: AnimatedOpacity(
                      opacity: hover ? 1 : 0,
                      duration: Motion.hover,
                      curve: Motion.hoverCurve,
                      child: _IconAction(icon: Icons.replay_rounded, tooltip: 'Repeat today', onTap: onRepeat!),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
