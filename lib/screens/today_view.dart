import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/fade_through.dart';
import '../widgets/hover_fill.dart';
import '../widgets/note_input.dart';
import '../widgets/ritual_name.dart';
import '../widgets/search_glow.dart';
import '../widgets/status_cell.dart';
import '../widgets/tile.dart';
import '../widgets/todo_panel.dart';
import '../widgets/welcome_tour.dart';

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

  @override
  void dispose() {
    _firstCheckboxInset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.shownDay, s.today, s.habitsRevision));
    final day = state.shownDay;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // These are the usable bounds after the outer padding. Keep enough
          // room for names, badges and controls, including with larger text.
          final textScale = MediaQuery.textScalerOf(context).scale(15) / 15;
          final minContentWidth = 1216.0 * max(1.0, textScale);
          final sleepHeight = _HabitColumn.sleepHeight(state, day, constraints.maxHeight);

          final content = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Expanded(
                flex: 22,
                child: TourTarget(spot: TourSpot.week, child: WeekCard()),
              ),
              const SizedBox(width: TodayView._gap),
              Expanded(flex: 19, child: _HabitColumn(firstCheckboxInset: _firstCheckboxInset)),
              const SizedBox(width: TodayView._gap),
              Expanded(
                flex: 17,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: TourTarget(
                        spot: TourSpot.later,
                        child: FurtherAheadCard(firstCheckboxInset: _firstCheckboxInset),
                      ),
                    ),
                    const SizedBox(height: TodayView._gap),
                    SizedBox(
                      height: sleepHeight,
                      child: TourTarget(spot: TourSpot.journal, child: const _JournalCard()),
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
    final rows = height - 2 * _HabitsCard.chrome - TodayView._gap;
    final count = rituals + sleep;
    final share = count == 0 ? _HabitsCard._maxRow : rows / count;
    return _HabitsCard.chrome + sleep * share.clamp(_HabitsCard._minRow, _HabitsCard._maxRow);
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
              child: TourTarget(
                spot: TourSpot.rituals,
                child: _HabitsCard(
                  title: 'Daily rituals',
                  habits: rituals,
                  allDone: 'Every ritual done. Beautiful.',
                  cardHeight: constraints.maxHeight - sleepHeight - TodayView._gap,
                  firstCheckboxInset: firstCheckboxInset,
                ),
              ),
            ),
            const SizedBox(height: TodayView._gap),
            SizedBox(
              height: sleepHeight,
              child: TourTarget(
                spot: TourSpot.sleep,
                child: _HabitsCard(
                  title: 'Sleep schedule',
                  habits: sleep,
                  allDone: 'Schedule kept. Sleep well.',
                  times: true,
                ),
              ),
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
    required this.allDone,
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

  /// The line under the title once every one is done.
  final String allDone;

  /// The card's height less its rows: padding, header and gap.
  static const chrome = 24.0 + 54 + 22 + 24;

  static const _minRow = 34.0, _maxRow = 55.0;

  /// Rows share the card's height, 34 to 52px each, and scroll only below
  /// that. A name too long for one line wraps, and its row grows to fit,
  /// taking the space from the others. If that would make the list scroll,
  /// the week trails make way to give the names more room.
  static ({List<double> heights, double cell, bool trail}) _layOutRows(
    BuildContext context,
    List<Habit> habits,
    BoxConstraints constraints,
    double badge,
  ) {
    if (habits.isEmpty) return (heights: const [], cell: 32, trail: false);
    final width = constraints.maxWidth, height = constraints.maxHeight;
    final cell = (height / habits.length).clamp(_minRow, _maxRow) - 10;
    final scaler = MediaQuery.textScalerOf(context);

    ({List<double> heights, double cell, bool trail}) layOut({required bool trail}) {
      // Everything else in a row is a fixed width; the name gets the rest.
      final nameWidth =
          width - _HabitRow.fixedWidth(badge) - (trail ? _HabitRow.weekTrailWidth : 0) - cell.clamp(24, 32);
      double rowFor(String name) {
        final painter = TextPainter(
          text: TextSpan(text: name, style: _HabitRow.nameStyle),
          maxLines: _HabitRow.nameLines,
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: nameWidth.clamp(0, double.infinity));
        final textHeight = painter.height;
        painter.dispose();
        return textHeight + 14;
      }

      final needed = [for (final h in habits) rowFor(h.name)];
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
      return (
        heights: [for (final n in needed) n > extent ? n : extent],
        cell: (extent - 10).clamp(24.0, 32.0),
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
      (s) => (s.shownDay, s.today, s.habitsRevision, s.entriesRevision, s.restWeekends),
    );
    final day = state.shownDay;
    final readOnly = !state.canEditDay(day);
    final done = state.doneOn(day, habits);
    final total = habits.length;
    final subtitle = done == total && total > 0 ? allDone : '';

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
                    if (subtitle.isNotEmpty) const SizedBox(height: 6),
                    // Fades through when the line changes, left-aligned so the
                    // old and new lines share their start.
                    if (subtitle.isNotEmpty)
                      FadeThrough(
                        duration: Motion.click,
                        layoutBuilder: FadeThrough.aligned(Alignment.centerLeft),
                        child: Text(
                          subtitle,
                          key: ValueKey(subtitle),
                          style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
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
                // Every row's badge is as wide as the longest streak's, so the
                // badges, squares and times stay lined up down the card.
                final streaks = state.viewDay != null
                    ? const <int>[]
                    : [for (final h in habits) state.currentStreak(h)];
                final badge = _HabitRow.badgeFor(context, streaks.fold(0, max));
                final rows = _layOutRows(context, habits, constraints, badge);
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
                return IgnorePointer(
                  ignoring: readOnly,
                  child: FadeThrough(
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
                        names: times ? [for (final h in habits) h.name] : null,
                      ),
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
                    duration: Motion.hover,
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
  static const weekTrailWidth = 10.0 + 7 * (6 + 3);

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
    return max(44.0, (12 + 12 + 1.5 + width).ceilToDouble());
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
    final state = AppScope.watch(context, (s) => (s.shownDay, s.today, s.entriesRevision, s.restWeekends));
    // Streaks run up to today, so a past day leaves them out.
    final past = state.viewDay != null;
    final streak = past ? 0 : state.currentStreak(habit);
    final best = state.bestStreak(habit);

    return _HoverHighlight(
      divider: divider,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: Tooltip(
                message: names != null
                    ? (habit.minutes == null ? '' : clockLabel(habit.minutes!))
                    : habit.description ?? habit.name,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: RitualName(
                    habit: habit,
                    maxLines: nameLines,
                    style: nameStyle.copyWith(color: p.ink),
                  ),
                ),
              ),
            ),
            if (weekTrail) ...[const SizedBox(width: 10), _WeekTrail(habit: habit, day: day)],
            const SizedBox(width: 8),
            Tooltip(
              message: past
                  ? ''
                  : streak == 0
                  ? (best > 0 ? 'Best streak: $best days' : 'No streak yet')
                  : '$streak day streak${best > streak ? '  ·  best $best' : ''}',
              child: SizedBox(
                width: badgeWidth,
                // A new streak count (or none) fades through with a slight pop.
                child: FadeThrough(
                  duration: Motion.click,
                  scaleFrom: 0.85,
                  child: streak > 0
                      ? Container(
                          key: ValueKey(streak),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: p.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.local_fire_department_rounded, size: 12, color: p.accent),
                              const SizedBox(width: 2),
                              Text('$streak', style: streakStyle(p.accent)),
                            ],
                          ),
                        )
                      : past
                      ? const SizedBox.shrink(key: ValueKey(-1))
                      : Text(
                          '–',
                          key: const ValueKey(0),
                          style: TextStyle(fontSize: 14, color: p.inkMuted.withValues(alpha: 0.4)),
                        ),
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
            ),
          ],
        ),
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
    final state = AppScope.watch(context, (s) => (s.entriesRevision, s.restWeekends, s.habitsRevision));
    final days = state.trailDays(habit, day);
    // Another day's week fades through in place.
    return FadeThrough(
      child: Row(
        key: ValueKey(dateKey(day)),
        children: [
          // The ritual's last 7 days, skipping ones it isn't on; while it has
          // fewer, the older places are left empty.
          for (var i = 7; i > days.length; i--) _mark(p, state, null),
          for (final past in days.reversed) _mark(p, state, past),
        ],
      ),
    );
  }

  // A rest day's blank mark fades rather than snapping; the colour itself
  // is read from the palette every frame, so it follows a theme change.
  Widget _mark(Palette p, AppState state, DateTime? past) {
    final status = past == null ? null : state.statusOf(past, habit);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: past != null && state.isRestDay(past) ? 1 : 0),
      duration: Motion.morph,
      curve: Motion.morphCurve,
      builder: (context, r, _) => Container(
        margin: const EdgeInsets.only(left: 4),
        width: 6,
        height: 8,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: switch (status) {
            null => Colors.transparent,
            HabitStatus.none => p.empty.withValues(alpha: 1 - 0.55 * r),
            HabitStatus.done => p.done,
            HabitStatus.missed => p.missed.withValues(alpha: 0.75),
            HabitStatus.other => p.other,
          },
        ),
      ),
    );
  }
}

/// Stays put from day to day; another day's words fade through inside it.
class _JournalCard extends StatelessWidget {
  const _JournalCard();

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
        hintStyle: TextStyle(fontFamily: Fonts.body, fontSize: 16, color: p.inkMuted.withValues(alpha: 0.6)),
      ),
      onChanged: _changed,
    );
  }
}

/// Shows the journal's folder in Dolphin (Finder on a Mac), with the day's
/// file selected once it exists. Each day is a Markdown file there, so
/// entries can be read and kept without the app.
class _OpenFolderButton extends StatelessWidget {
  const _OpenFolderButton(this.file, {this.problem});

  final File file;

  /// Why the files aren't being saved; null while they are.
  final String? problem;

  Future<void> _open() async {
    final folder = file.parent;
    await folder.create(recursive: true);
    final exists = file.existsSync();
    if (Platform.isMacOS) {
      await Process.run('open', exists ? ['-R', file.path] : [folder.path]);
    } else if (Platform.isWindows) {
      // Separate arguments: a path with a space gets quoted, and Explorer
      // only reads /select, before the quotes, not inside them.
      await Process.start(
        'explorer.exe',
        exists ? ['/select,', file.path] : [folder.path],
        mode: ProcessStartMode.detached,
      );
    } else {
      // Detached: Dolphin keeps running after it opens, and on its own.
      try {
        await Process.start(
          'dolphin',
          exists ? ['--select', file.path] : [folder.path],
          mode: ProcessStartMode.detached,
        );
      } on ProcessException {
        await Process.start('xdg-open', [folder.path], mode: ProcessStartMode.detached);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final home = Platform.environment['HOME'];
    final shown = home != null && file.path.startsWith(home) ? '~${file.path.substring(home.length)}' : file.path;
    return HeaderIconButton(
      tooltip: problem == null
          ? 'Saved as $shown\nClick to show it in its folder'
          : '$problem\nYour journal is still kept safe in Eclipse.',
      icon: Icons.folder_open_rounded,
      onPressed: _open,
    );
  }
}
