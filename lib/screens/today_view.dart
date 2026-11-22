import '../widgets/ritual_goal.dart';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, listEquals;

import '../data/platform_files.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme/pixels.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/lru_cache.dart';
import '../widgets/fade_through.dart';
import '../widgets/glide_pill.dart';
import '../widgets/hover_fill.dart';
import '../widgets/note_input.dart';
import '../widgets/rolling_number.dart';
import '../widgets/search_glow.dart';
import '../widgets/status_cell.dart';
import '../widgets/tile.dart';
import '../widgets/todo_panel.dart';

/// Three columns that exactly fill the window: the week ahead's to-dos,
/// rituals over the sleep schedule, and what's further ahead over the
/// journal, lined up with the rituals and sleep cards. Only a card whose
/// list outgrows it scrolls.
class TodayView extends StatefulWidget {
  const TodayView({super.key});

  static const _gap = 22.0;

  @override
  State<TodayView> createState() => _TodayViewState();
}

class _TodayViewState extends State<TodayView> {
  final _firstCheckboxInset = ValueNotifier<double>(0);
  int _narrowTab = 0;
  DateTime? _lastFoundAt;

  // Made once, outside the LayoutBuilder, so resizing the window lays the
  // cards out again without building them again. Opening the page, they
  // build a frame apart: see [StagedBuild].
  late final _rituals = StagedBuild(frames: 1, child: _HabitColumn(firstCheckboxInset: _firstCheckboxInset));
  late final _further = StagedBuild(
    frames: 2,
    child: FurtherAheadCard(firstCheckboxInset: _firstCheckboxInset),
  );

  @override
  void dispose() {
    _firstCheckboxInset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.shownDay, s.today, s.habitsRevision, s.found));
    final found = state.found;
    if (found != null && found.at != _lastFoundAt) {
      _lastFoundAt = found.at;
      if (found.target.startsWith('habit:')) {
        _narrowTab = 0;
      } else if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(found.target)) {
        _narrowTab = 2;
      } else {
        _narrowTab = 1;
      }
    }
    final day = state.shownDay;
    return LayoutBuilder(
      builder: (context, outer) {
        final narrowWeb = kIsWeb && outer.maxWidth < 900;
        final padding = narrowWeb ? const EdgeInsets.fromLTRB(16, 0, 16, 16) : const EdgeInsets.fromLTRB(32, 0, 32, 28);
        return Padding(
          padding: padding,
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (narrowWeb) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedPills(
                      labels: const ['Rituals', 'Tasks', 'Journal'],
                      selected: _narrowTab,
                      expand: true,
                      onSelect: (i) {
                        FocusManager.instance.primaryFocus?.unfocus();
                        if (_narrowTab == 2 && i != 2) AppScope.read(context).saveJournalDraft();
                        setState(() => _narrowTab = i);
                      },
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: FadeThrough(
                        layoutBuilder: FadeThrough.fill,
                        child: switch (_narrowTab) {
                          0 => KeyedSubtree(key: const ValueKey('narrow-rituals'), child: _rituals),
                          1 => KeyedSubtree(
                            key: const ValueKey('narrow-tasks'),
                            child: constraints.maxHeight < 620
                                ? ListView(
                                    padding: EdgeInsets.zero,
                                    children: [
                                      const SizedBox(height: 380, child: WeekCard()),
                                      const SizedBox(height: 14),
                                      SizedBox(height: 300, child: _further),
                                    ],
                                  )
                                : Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      const Expanded(flex: 3, child: WeekCard()),
                                      const SizedBox(height: 14),
                                      Expanded(flex: 2, child: _further),
                                    ],
                                  ),
                          ),
                          _ => const KeyedSubtree(key: ValueKey('narrow-journal'), child: JournalCard()),
                        },
                      ),
                    ),
                  ],
                );
              }

              // These are the usable bounds after the outer padding. Keep enough
              // room for names, badges and controls, including with larger text.
              final textScale = MediaQuery.textScalerOf(context).scale(15) / 15;
              final minContentWidth = 1216.0 * max(1.0, textScale);
              final sleepHeight = _HabitColumn.sleepHeight(state, day, constraints.maxHeight);

              final content = Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Expanded(flex: 22, child: WeekCard()),
                  const SizedBox(width: TodayView._gap),
                  Expanded(flex: 19, child: _rituals),
                  const SizedBox(width: TodayView._gap),
                  Expanded(
                    flex: 17,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _further),
                        const SizedBox(height: TodayView._gap),
                        SizedBox(
                          height: sleepHeight,
                          child: const StagedBuild(frames: 2, child: JournalCard()),
                        ),
                      ],
                    ),
                  ),
                ],
              );

              // Keep the same scroll view when resizing so task fields retain their
              // state as the window crosses the minimum width.
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: max(minContentWidth, constraints.maxWidth),
                  height: constraints.maxHeight,
                  child: content,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// The rituals' card with the sleep schedule's below it. Their rows share
/// the column's height evenly, so rows are the same height in both.
class _HabitColumn extends StatelessWidget {
  const _HabitColumn({required this.firstCheckboxInset});

  final ValueNotifier<double> firstCheckboxInset;

  /// The sleep card's height in a column [height] tall, which the journal
  /// beside it matches.
  static double sleepHeight(AppState state, DateTime day, double height) {
    final rituals = state.habitsFor(day.year, day.month).where((h) => h.onDay(day)).length;
    final sleep = state.sleepHabitsFor(day.year, day.month).length;
    final rows = max(0.0, height - 2 * _HabitsCard.chrome - TodayView._gap);
    final count = rituals + sleep;
    final share = count == 0 ? _HabitsCard._maxRow : rows / count;
    final raw = pixelRound(_HabitsCard.chrome + sleep * share.clamp(_HabitsCard._minRow, _HabitsCard._maxRow));
    final maxSleep = max(
      0.0,
      height - TodayView._gap - (rituals > 0 ? _HabitsCard.chrome + _HabitsCard._minRow : 0.0),
    );
    return raw.clamp(0.0, maxSleep);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.shownDay, s.habitsRevision));
    final day = state.shownDay;
    // Only the rituals that are on that day.
    final all = state.habitsFor(day.year, day.month), sleep = state.sleepHabitsFor(day.year, day.month);
    final rituals = [
      for (final h in all)
        if (h.onDay(day)) h,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final sleepHeight = _HabitColumn.sleepHeight(state, day, constraints.maxHeight);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _HabitsCard(
                title: 'Daily rituals',
                habits: rituals,
                cardHeight: constraints.maxHeight - sleepHeight - TodayView._gap,
                firstCheckboxInset: firstCheckboxInset,
              ),
            ),
            const SizedBox(height: TodayView._gap),
            SizedBox(
              height: sleepHeight,
              child: _HabitsCard(title: 'Sleep schedule', habits: sleep, times: true),
            ),
          ],
        );
      },
    );
  }
}

class _HabitsCard extends StatelessWidget {
  const _HabitsCard({
    required this.title,
    required this.habits,
    this.times = false,
    this.cardHeight,
    this.firstCheckboxInset,
  });

  final String title;
  final List<Habit> habits;
  final double? cardHeight;
  final ValueNotifier<double>? firstCheckboxInset;

  /// The sleep schedule: each item's scheduled time is shown on hover.
  final bool times;

  /// The card's height less its rows: padding, header and gap.
  static const chrome = 24.0 + 54 + 22 + 24;

  static const _minRow = 34.0, _maxRow = 55.0;

  /// Rows share the card's height, 34 to 52px each, and scroll only below
  /// that. A name too long for one line wraps, and its row grows to fit,
  /// taking the space from the others. If that would make the list scroll,
  /// the week trails make way to give the names more room.
  static final _rowHeights = LruCache<(String, double, double), double>(256);

  static ({List<double> heights, double cell, bool trail}) _layOutRows(
    BuildContext context,
    AppState state,
    DateTime day,
    List<Habit> habits,
    BoxConstraints constraints,
    double badge,
  ) {
    if (habits.isEmpty) return (heights: const [], cell: 32, trail: false);
    final width = constraints.maxWidth, height = constraints.maxHeight;
    final cell = (height / habits.length).clamp(_minRow, _maxRow) - 10;
    final scaler = MediaQuery.textScalerOf(context);
    final scaleKey = scaler.scale(15);

    ({List<double> heights, double cell, bool trail}) layOut({required bool trail}) {
      // Everything else in a row is a fixed width; the name gets the rest.
      final nameWidth =
          width - _HabitRow.fixedWidth(badge) - (trail ? _HabitRow.weekTrailWidth : 0) - cell.clamp(24, 32);
      final clampedWidth = nameWidth.clamp(0.0, double.infinity);
      final widthBucket = (clampedWidth * 2).roundToDouble() / 2;
      double rowFor(String name) {
        final key = (name, widthBucket, scaleKey);
        final cached = _rowHeights[key];
        if (cached != null) return cached;
        final painter = TextPainter(
          text: TextSpan(text: name, style: _HabitRow.nameStyle),
          maxLines: _HabitRow.nameLines,
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: clampedWidth);
        final textHeight = painter.height;
        painter.dispose();
        final rowHeight = textHeight + 14;
        _rowHeights[key] = rowHeight;
        return rowHeight;
      }

      final needed = [for (final h in habits) rowFor(ritualProgress(state, day, h))];
      // Tall rows take what they need; the rest share what's left. Each
      // round can only shrink the share, so a few rounds settle it.
      var extent = (height / habits.length).clamp(_minRow, _maxRow);
      for (var round = 0; round < 3; round++) {
        final tall = [
          for (final n in needed)
            if (n > extent) n,
        ];
        if (tall.length == habits.length) break;
        final left = height - tall.fold(0.0, (a, b) => a + b);
        final share = (left / (habits.length - tall.length)).clamp(_minRow, _maxRow);
        if (share == extent) break;
        extent = share;
      }
      // Each row's edge on a whole pixel; together they still fill the card.
      var bottom = 0.0;
      final edges = [0.0, for (final n in needed) pixelRound(bottom += n > extent ? n : extent)];
      return (
        heights: [for (var i = 0; i < needed.length; i++) edges[i + 1] - edges[i]],
        cell: pixelFloor(extent - 10).clamp(24.0, 32.0),
        trail: trail,
      );
    }

    final withTrail = layOut(trail: width >= _HabitRow.weekTrailFrom);
    if (!withTrail.trail || withTrail.heights.fold(0.0, (a, b) => a + b) <= height + 0.5) {
      return withTrail;
    }
    return layOut(trail: false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(
      context,
      (s) => (s.shownDay, s.today, s.habitsRevision, s.entriesRevision, s.restWeekends, s.holidays),
    );
    final day = state.shownDay;
    // A holiday needs nothing tracked.
    final onHoliday = holidayOn(state.holidays, day) != null;

    return Tile(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TileHeader(title: title),
                    DayFold(
                      folded: !onHoliday,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'On holiday',
                            style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Every row's badge is as wide as the longest streak ever, so the
                // badges, squares and times stay lined up down the card and in
                // the same place from day to day.
                final streaks = [
                  for (final h in habits)
                    if (h.weekly == null) state.bestStreak(h),
                ];
                final badge = _HabitRow.badgeFor(context, streaks.fold(0, max));
                final rows = _layOutRows(context, state, day, habits, constraints, badge);
                final sleepNames = times ? [for (final h in habits) h.name] : null;
                final alignment = firstCheckboxInset;
                if (alignment != null && rows.heights.isNotEmpty) {
                  // Both cards share their padding, title and gap. Their
                  // titles grow together with text scaling; only the ritual
                  // subtitle and the space inside its first row add an inset.
                  final headerHeight = TileHeader.titleHeight(context, title);
                  final normalChrome = 2 * (24.0 + 1) + headerHeight + 22;
                  final inset = max(
                    0.0,
                    cardHeight! - constraints.maxHeight - normalChrome + (rows.heights.first - rows.cell) / 2,
                  );
                  if ((alignment.value - inset).abs() > 0.01) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted && (alignment.value - inset).abs() > 0.01) alignment.value = inset;
                    });
                  }
                }
                // Yesterday stays editable. A different month's ritual list
                // fades through; otherwise only the marks change.
                return FadeThrough(
                  layoutBuilder: FadeThrough.fill,
                  child: ListView.builder(
                    key: ValueKey([for (final h in habits) '${h.id} ${h.name}'].join('|')),
                    padding: EdgeInsets.zero,
                    itemExtentBuilder: (i, _) => i < habits.length ? rows.heights[i] : null,
                    itemCount: habits.length,
                    itemBuilder: (context, i) => _HabitRow(
                      habit: habits[i],
                      day: day,
                      cellSize: rows.cell,
                      badgeWidth: badge,
                      weekTrail: rows.trail,
                      divider: i > 0,
                      names: sleepNames,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades a highlight in behind [child] on hover, as the month grid's rows
/// do. Only the highlight and divider repaint; [child] is never rebuilt.
class _HoverHighlight extends StatelessWidget {
  const _HoverHighlight({required this.divider, required this.child});

  final bool divider;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      builder: (hover) => HoverFill(
        hover: hover,
        child: Stack(
          // The list gives each row a fixed height; the row fills it.
          fit: StackFit.passthrough,
          children: [
            // The divider fades out as the highlight fades in, rather than
            // swapping borders mid-animation.
            if (divider)
              Positioned(
                left: 8,
                right: 8,
                top: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: hover ? 0 : 1,
                    duration: context.themed(Motion.hover),
                    curve: Motion.hoverCurve,
                    child: ColoredBox(color: p.borderSoft, child: const SizedBox(height: 1)),
                  ),
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}

class _HabitRow extends StatelessWidget {
  const _HabitRow({
    required this.habit,
    required this.day,
    required this.cellSize,
    required this.badgeWidth,
    required this.weekTrail,
    required this.divider,
    this.names,
  });

  static const nameStyle = TextStyle(fontFamily: Fonts.body, fontSize: 15, fontWeight: FontWeight.w400, height: 1.35);

  /// Long names wrap onto up to this many lines before they're cut short.
  static const nameLines = 4;

  /// Rows at least this wide show the last week's marks.
  static const weekTrailFrom = 240.0;
  static const weekTrailWidth = 10.0 + 7 * (6 + 4);

  /// Padding, gaps and the streak badge: the row less its name, week trail
  /// and square.
  static double fixedWidth(double badge) => 2 * 8.0 + 8 + badge + 8;

  static TextStyle streakStyle(Color color) => TextStyle(
    fontFamily: Fonts.ui,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// The badge's slot: 44px, or wider when [streak] needs it.
  static double badgeFor(BuildContext context, int streak) {
    final painter = TextPainter(
      text: TextSpan(text: '$streak', style: streakStyle(const Color(0xFF000000))),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    // Padding, flame and its gap around the count.
    return max(44.0, (12 + MediaQuery.textScalerOf(context).scale(12) + 2 + width).ceilToDouble());
  }

  final Habit habit;
  final DateTime day;
  final double cellSize;

  /// The streak badge's slot, shared by the card's rows.
  final double badgeWidth;

  /// Whether to show the last week's marks (the card decides, for all rows).
  final bool weekTrail;
  final bool divider;

  /// Non-null for sleep rows, whose scheduled time is shown on hover.
  final List<String>? names;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.shownDay, s.today, s.entriesRevision, s.restWeekends, s.holidays));
    final (streak, best) = habit.weekly == null ? state.streaksOn(habit, day) : (0, 0);

    return SearchGlow(
      target: 'habit:${habit.id}',
      radius: 12,
      child: _HoverHighlight(
        divider: divider,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: PixelTooltip(
                  message: names != null
                      ? (habit.minutes == null ? '' : clockLabel(habit.minutes!))
                      : habit.description ?? habit.name,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      ritualProgress(state, day, habit),
                      maxLines: nameLines,
                      overflow: TextOverflow.ellipsis,
                      style: nameStyle.copyWith(color: p.ink),
                    ),
                  ),
                ),
              ),
              if (weekTrail) ...[const SizedBox(width: 10), _WeekTrail(habit: habit, day: day)],
              const SizedBox(width: 8),
              SizedBox(
                width: badgeWidth,
                child: habit.weekly == null
                    ? _StreakBadge(day: day, streak: streak, best: best)
                    : Center(
                        child: PixelTooltip(
                          message: '${habit.weekly}x a week',
                          child: Icon(Icons.date_range_rounded, size: 18, color: p.inkMuted),
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              StatusCell(
                day: day,
                habit: habit,
                size: cellSize,
                enabled: state.canEditDay(day) && habit.startedBy(day),
                rest: state.isRestDay(day),
                staysThroughDays: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A ritual's streak as of [day]. A new count, on this day or another, rolls
/// in the same pill. None at all (a dash) has no pill, so the pill fades
/// through to or from it: quickly with a slight pop on the same day, and with
/// the rest of the page on another.
class _StreakBadge extends StatefulWidget {
  const _StreakBadge({required this.day, required this.streak, required this.best});

  final DateTime day;
  final int streak;
  final int best;

  @override
  State<_StreakBadge> createState() => _StreakBadgeState();
}

class _StreakBadgeState extends State<_StreakBadge> {
  /// Whether the badge last faded with the day. Changes only as it starts a
  /// fade: restyling the fade rebuilds what's in it, so a count mid-roll
  /// would jump.
  var _withDay = false;

  @override
  void didUpdateWidget(_StreakBadge old) {
    super.didUpdateWidget(old);
    if ((old.streak == 0) != (widget.streak == 0)) _withDay = old.day != widget.day;
  }

  @override
  Widget build(BuildContext context) {
    final streak = widget.streak, best = widget.best;
    return FadeThrough(
      duration: _withDay ? Motion.page : Motion.click,
      scaleFrom: _withDay ? 1.0 : 0.85,
      child: PixelTooltip(
        key: ValueKey(streak == 0),
        message: streak == 0
            ? (best > 0 ? 'Best streak: $best days' : 'No streak yet')
            : '$streak day streak${best > streak ? '  ·  best $best' : ''}',
        child: SizedBox(
          width: double.infinity,
          child: Center(heightFactor: 1, child: _badge(context, streak)),
        ),
      ),
    );
  }

  Widget _badge(BuildContext context, int streak) {
    final p = context.palette;
    if (streak == 0) {
      return Text('–', style: TextStyle(fontSize: 14, color: p.inkMuted.withValues(alpha: 0.4)));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department_rounded, size: 12, color: p.accent),
          const SizedBox(width: 2),
          RollingNumber(value: streak, duration: Motion.page, style: _HabitRow.streakStyle(p.accent)),
        ],
      ),
    );
  }
}

/// Seven small marks for the last week, oldest first.
class _WeekTrail extends StatelessWidget {
  const _WeekTrail({required this.habit, required this.day});

  final Habit habit;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.entriesRevision, s.restWeekends, s.holidays, s.habitsRevision));
    final days = state.trailDays(habit, day);
    final offset = 7 - days.length;
    final statuses = List<HabitStatus?>.filled(7, null);
    var restMask = 0;
    for (var i = 0; i < days.length; i++) {
      final past = days[days.length - 1 - i];
      final slot = offset + i;
      statuses[slot] = state.statusOf(past, habit);
      if (state.isRestDay(past)) restMask |= 1 << slot;
    }
    // Another day's week fades through in place.
    return FadeThrough(
      child: _WeekTrailMarks(
        key: ValueKey(dateKey(day)),
        statuses: statuses,
        restMask: restMask,
        palette: p,
      ),
    );
  }
}

class _WeekTrailMarks extends StatefulWidget {
  const _WeekTrailMarks({
    super.key,
    required this.statuses,
    required this.restMask,
    required this.palette,
  });

  final List<HabitStatus?> statuses;
  final int restMask;
  final Palette palette;

  @override
  State<_WeekTrailMarks> createState() => _WeekTrailMarksState();
}

class _WeekTrailMarksState extends State<_WeekTrailMarks> {
  late int _toMask = widget.restMask;
  late final List<double> _fromRest = List<double>.generate(
    7,
    (i) => (widget.restMask & (1 << i)) != 0 ? 1.0 : 0.0,
  );
  double _morphStep = 0;
  double _currentStep = 0;

  double _restAt(int i, double stepValue) {
    final to = (_toMask & (1 << i)) != 0 ? 1.0 : 0.0;
    if (_morphStep == 0) return to;
    final t = (stepValue - (_morphStep - 1)).clamp(0.0, 1.0);
    return _fromRest[i] + (to - _fromRest[i]) * t;
  }

  @override
  void didUpdateWidget(_WeekTrailMarks old) {
    super.didUpdateWidget(old);
    if (widget.restMask != _toMask) {
      for (var i = 0; i < 7; i++) {
        _fromRest[i] = _restAt(i, _currentStep);
      }
      _toMask = widget.restMask;
      _morphStep += 1.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _morphStep),
      duration: context.themed(Motion.morph),
      curve: Motion.morphCurve,
      builder: (context, v, _) {
        _currentStep = v;
        return CustomPaint(
          size: const Size(70, 8),
          painter: _WeekTrailPainter(
            statuses: widget.statuses,
            fromRest: _fromRest,
            toMask: _toMask,
            morphStep: _morphStep,
            stepValue: v,
            palette: widget.palette,
          ),
        );
      },
    );
  }
}

class _WeekTrailPainter extends CustomPainter {
  _WeekTrailPainter({
    required this.statuses,
    required this.fromRest,
    required this.toMask,
    required this.morphStep,
    required this.stepValue,
    required this.palette,
  });

  final List<HabitStatus?> statuses;
  final List<double> fromRest;
  final int toMask;
  final double morphStep;
  final double stepValue;
  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    const radius = Radius.circular(4);
    final paint = Paint();
    final t = morphStep == 0 ? 1.0 : (stepValue - (morphStep - 1)).clamp(0.0, 1.0);
    for (var i = 0; i < 7; i++) {
      final status = statuses[i];
      if (status == null) continue;
      final to = (toMask & (1 << i)) != 0 ? 1.0 : 0.0;
      final r = morphStep == 0 ? to : fromRest[i] + (to - fromRest[i]) * t;
      paint.color = switch (status) {
        HabitStatus.none => palette.empty.withValues(alpha: 1 - 0.55 * r),
        HabitStatus.done => palette.done,
        HabitStatus.missed => palette.missed.withValues(alpha: 0.75),
        HabitStatus.other => palette.other,
      };
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * 10.0 + 4.0, 0, 6, 8), radius), paint);
    }
  }

  @override
  bool shouldRepaint(_WeekTrailPainter old) =>
      old.stepValue != stepValue ||
      old.morphStep != morphStep ||
      old.toMask != toMask ||
      old.palette != palette ||
      !listEquals(old.statuses, statuses);
}

/// Stays put from day to day; another day's words fade through inside it.
class JournalCard extends StatelessWidget {
  const JournalCard({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.shownDay, s.journalFileProblem, s.journalFiles?.dir.path));
    final day = state.shownDay;
    // The whole tile lights when search opens the day's entry.
    return SearchGlow(
      target: dateKey(day),
      radius: 24,
      over: true,
      child: Tile(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TileHeader(
              title: 'Journal',
              trailingAtEnd: true,
              trailing: state.journalFiles == null
                  ? null
                  : _OpenFolderButton(state.journalFiles!.fileFor(day), problem: state.journalFileProblem),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: FadeThrough(
                layoutBuilder: FadeThrough.fill,
                child: _JournalText(key: ValueKey(dateKey(day))),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One day's words.
class _JournalText extends StatefulWidget {
  const _JournalText({super.key});

  @override
  State<_JournalText> createState() => _JournalTextState();
}

class _JournalTextState extends State<_JournalText> {
  TextEditingController? _controller;
  late AppState _state;

  /// The day this writes to. Another day gets a new one; words typed just
  /// before midnight still land on the day they were typed.
  late DateTime _day;

  /// Earlier than yesterday is read only; updated as the date advances.
  late bool _past;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = AppScope.watch(context, (s) => (s.journalRevision, s.today));
    final controller = _controller;
    if (controller == null) {
      _day = _state.shownDay;
      _past = !_state.canEditDay(_day);
      final text = _state.journalOf(_day);
      _state.journalShown(_day, text);
      _controller = TextEditingController(text: text);
      return;
    }
    _past = !_state.canEditDay(_day);
    // Changed elsewhere (synced in, or a restore): shown in place, keeping
    // focus and the cursor where it was in what you'd written. Typing not
    // saved yet is newer than what's stored, and sync saves it before it
    // merges, so it's never replaced.
    if (_state.hasJournalDraft(_day)) return;
    final text = _state.journalOf(_day);
    final old = controller.value;
    _state.journalShown(_day, text);
    if (text == old.text) return;
    final shift = old.text.isEmpty ? 0 : max(text.indexOf(old.text), 0);
    controller.value = TextEditingValue(
      text: text,
      selection: old.selection.isValid
          ? TextSelection(
              baseOffset: min(old.selection.baseOffset + shift, text.length),
              extentOffset: min(old.selection.extentOffset + shift, text.length),
            )
          : TextSelection.collapsed(offset: text.length),
    );
  }

  void _changed(String text) => _state.draftJournal(_day, text);

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return TextField(
      textCapitalization: TextCapitalization.sentences,
      inputFormatters: const [NoteInputFormatter()],
      controller: _controller,
      readOnly: _past,
      expands: true,
      maxLines: null,
      textAlignVertical: TextAlignVertical.top,
      style: TextStyle(fontFamily: Fonts.body, fontSize: 16, height: 1.7, color: p.ink),
      decoration: InputDecoration(
        border: InputBorder.none,
        hintText: _past ? 'Nothing written this day.' : null,
        hintStyle: TextStyle(fontFamily: Fonts.body, fontSize: 16, color: p.inkMuted),
      ),
      onChanged: _changed,
    );
  }
}

/// Shows the journal's folder in Dolphin, with the day's
/// file selected once it exists. Each day is a Markdown file there, so
/// entries can be read and kept without the app.
class _OpenFolderButton extends StatelessWidget {
  const _OpenFolderButton(this.file, {this.problem});

  final File file;

  /// Why the files aren't being saved; null while they are.
  final String? problem;

  @override
  Widget build(BuildContext context) {
    final home = Platform.environment['HOME'];
    final shown = home != null && file.path.startsWith(home) ? '~${file.path.substring(home.length)}' : file.path;
    return HeaderIconButton(
      tooltip: problem == null
          ? 'Saved as $shown\nClick to show it in its folder'
          : '$problem\nYour journal is still kept safe in Eclipse.',
      icon: Icons.folder_open_rounded,
      onPressed: () => showInFiles(file),
    );
  }
}
