import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_through.dart';
import '../widgets/hover_fill.dart';
import '../widgets/note_input.dart';
import '../widgets/progress_ring.dart';
import '../widgets/ritual_name.dart';
import '../widgets/sleep_time.dart';
import '../widgets/status_cell.dart';
import '../widgets/tile.dart';
import '../widgets/todo_panel.dart';
import '../widgets/welcome_tour.dart';

/// Three columns that exactly fill the window: rituals over the sleep
/// schedule, today's to-dos, and tomorrow / week-month tabs / journal. Only a card whose list outgrows it scrolls.
class TodayView extends StatelessWidget {
  const TodayView({super.key});

  static const _gap = 20.0;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.shownDay, s.viewDay, s.today));
    final day = state.shownDay;
    final past = state.viewDay != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        // When width is tight (e.g. a tiled window under 860px), scroll sideways
        // so columns maintain their clean proportions instead of getting squished.
        const minContentWidth = 860.0;
        final needsScroll = constraints.maxWidth < minContentWidth;

        Widget content = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Expanded(flex: 11, child: _HabitColumn()),
            const SizedBox(width: _gap),
            Expanded(
              flex: 9,
              child: TourTarget(
                spot: TourSpot.todayTodos,
                child: TodoPanel(scope: TodoScope.today, day: past ? day : null),
              ),
            ),
            const SizedBox(width: _gap),
            Expanded(
              flex: 9,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: TourTarget(
                      spot: TourSpot.tomorrowTodos,
                      child: TodoPanel(scope: TodoScope.tomorrow, day: past ? day : null),
                    ),
                  ),
                  const SizedBox(height: _gap),
                  Expanded(
                    child: TourTarget(
                      spot: TourSpot.laterTodos,
                      child: TodoPanel(scope: TodoScope.week, day: past ? day : null, tabbed: true),
                    ),
                  ),
                  const SizedBox(height: _gap),
                  Expanded(
                    child: TourTarget(spot: TourSpot.journal, child: const _JournalCard()),
                  ),
                ],
              ),
            ),
          ],
        );

        if (needsScroll) {
          content = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: minContentWidth, height: constraints.maxHeight, child: content),
          );
        }

        return Padding(padding: const EdgeInsets.fromLTRB(32, 0, 32, 28), child: content);
      },
    );
  }
}

/// The rituals' card with the sleep schedule's below it. Their rows share
/// the column's height evenly, so rows are the same height in both.
class _HabitColumn extends StatelessWidget {
  const _HabitColumn();

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
        final rows = constraints.maxHeight - 2 * _HabitsCard.chrome - TodayView._gap;
        final count = rituals.length + sleep.length;
        final share = count == 0 ? _HabitsCard._maxRow : rows / count;
        final sleepHeight = _HabitsCard.chrome + sleep.length * share.clamp(_HabitsCard._minRow, _HabitsCard._maxRow);
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
                  noneOn: all.isNotEmpty && rituals.isEmpty,
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
    this.noneOn = false,
  });

  /// None of the month's rituals is on this day: it reads as a rest day.
  final bool noneOn;

  final String title;
  final List<Habit> habits;

  /// The sleep schedule: each item's time beside its name, and no tooltip.
  final bool times;

  /// The line under the title once every one is done.
  final String allDone;

  /// The card's height less its rows: padding, header and gap.
  static const chrome = 22.0 + 60 + 10 + 12;

  static const _minRow = 34.0, _maxRow = 52.0;

  /// Rows share the card's height, 34 to 52px each, and scroll only below
  /// that. A name too long for one line wraps, and its row grows to fit,
  /// taking the space from the others. If that would make the list scroll,
  /// the week trails make way to give the names more room.
  static ({List<double> heights, double cell, bool trail}) _layOutRows(
    BuildContext context,
    List<Habit> habits,
    BoxConstraints constraints,
  ) {
    if (habits.isEmpty) return (heights: const [], cell: 32, trail: false);
    final width = constraints.maxWidth, height = constraints.maxHeight;
    final cell = (height / habits.length).clamp(_minRow, _maxRow) - 10;
    final scaler = MediaQuery.textScalerOf(context);

    ({List<double> heights, double cell, bool trail}) layOut({required bool trail}) {
      // Everything else in a row is a fixed width; the name gets the rest.
      final nameWidth = width - _HabitRow.fixedWidth - (trail ? _HabitRow.weekTrailWidth : 0) - cell.clamp(24, 32);
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
    if (!withTrail.trail || withTrail.heights.fold(0.0, (a, b) => a + b) <= height + 0.5) return withTrail;
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
    final subtitle = done == total && total > 0
        ? allDone
        : noneOn || state.isRestDay(day) && (times || habits.isEmpty)
        ? 'Rest day. Nothing you have to do.'
        : '';

    return Tile(
      padding: const EdgeInsets.fromLTRB(24, 22, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TileHeader(title: title),
                    const SizedBox(height: 6),
                    // Fades through when the line changes, left-aligned so the
                    // old and new lines share their start.
                    FadeThrough(
                      duration: Motion.click,
                      layoutBuilder: (current, previous) =>
                          Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                      child: Text(
                        subtitle,
                        key: ValueKey(subtitle),
                        style: TextStyle(fontFamily: Fonts.body, fontSize: 13, color: p.inkMuted),
                      ),
                    ),
                  ],
                ),
              ),
              ProgressRing(done: done, total: total, size: 60),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final rows = _layOutRows(context, habits, constraints);
                // Yesterday stays editable. A different month's ritual list
                // fades through; otherwise only the marks change.
                return IgnorePointer(
                  ignoring: readOnly,
                  child: FadeThrough(
                    layoutBuilder: (current, previous) =>
                        Stack(fit: StackFit.expand, children: [...previous, ?current]),
                    child: ListView.builder(
                      key: ValueKey([for (final h in habits) '${h.id} ${h.name}'].join('|')),
                      padding: EdgeInsets.zero,
                      itemExtentBuilder: (i, _) => i < habits.length ? rows.heights[i] : null,
                      itemCount: habits.length,
                      itemBuilder: (context, i) => _HabitRow(
                        habit: habits[i],
                        day: day,
                        cellSize: rows.cell,
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
class _HoverHighlight extends StatefulWidget {
  const _HoverHighlight({required this.divider, required this.child});

  final bool divider;
  final Widget child;

  @override
  State<_HoverHighlight> createState() => _HoverHighlightState();
}

class _HoverHighlightState extends State<_HoverHighlight> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: HoverFill(
        hover: _hover,
        child: Stack(
          // The list gives each row a fixed height; the row fills it.
          fit: StackFit.passthrough,
          children: [
            // The divider fades out as the highlight fades in, rather than
            // swapping borders mid-animation.
            if (widget.divider)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _hover ? 0 : 1,
                    duration: Motion.hover,
                    curve: Motion.hoverCurve,
                    child: ColoredBox(color: p.tileBorder.withValues(alpha: 0.5), child: const SizedBox(height: 1)),
                  ),
                ),
              ),
            widget.child,
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
    required this.weekTrail,
    required this.divider,
    this.names,
  });

  static const nameStyle = TextStyle(fontFamily: Fonts.body, fontSize: 13.5, fontWeight: FontWeight.w500);

  /// Long names wrap onto up to this many lines before they're cut short.
  static const nameLines = 3;

  /// Rows at least this wide show the last week's marks.
  static const weekTrailFrom = 240.0;
  static const weekTrailWidth = 10.0 + 7 * (6 + 3);

  /// Padding, gaps and the streak badge: the row less its name, week trail
  /// and square.
  static const fixedWidth = 2 * 8.0 + 8 + 44 + 8;

  final Habit habit;
  final DateTime day;
  final double cellSize;

  /// Whether to show the last week's marks (the card decides, for all rows).
  final bool weekTrail;
  final bool divider;

  /// The sleep schedule's names, when this row shows a time (see [SleepName]).
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
              child: names != null
                  ? SleepName(
                      habit: habit,
                      names: names!,
                      style: nameStyle.copyWith(color: p.ink),
                    )
                  : Tooltip(
                      message: habit.description ?? habit.name,
                      waitDuration: const Duration(milliseconds: 300),
                      // The whole height of the row, not just the line of text,
                      // so the tooltip is easy to catch.
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
                width: 44,
                // A new streak count (or none) fades through with a slight pop.
                child: FadeThrough(
                  duration: Motion.click,
                  scaleFrom: 0.85,
                  child: streak > 0
                      ? Container(
                          key: ValueKey(streak),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                          decoration: BoxDecoration(
                            color: p.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.local_fire_department_rounded, size: 12, color: p.accent),
                              const SizedBox(width: 1.5),
                              Text(
                                '$streak',
                                style: TextStyle(
                                  fontFamily: Fonts.ui,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: p.accent,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        )
                      : past
                      ? const SizedBox.shrink(key: ValueKey(-1))
                      : Text(
                          '–',
                          key: const ValueKey(0),
                          style: TextStyle(fontSize: 13, color: p.inkMuted.withValues(alpha: 0.4)),
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
              rest: state.restsFor(habit, day),
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
    final state = AppScope.watch(context, (s) => (s.entriesRevision, s.restWeekends));
    // Another day's week fades through in place.
    return FadeThrough(
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
      child: Row(
        key: ValueKey(dateKey(day)),
        children: [for (var i = 7; i >= 1; i--) _mark(p, state, DateTime(day.year, day.month, day.day - i))],
      ),
    );
  }

  // A rest day's blank mark fades rather than snapping; the colour itself
  // is read from the palette every frame, so it follows a theme change.
  Widget _mark(Palette p, AppState state, DateTime past) {
    final status = state.statusOf(past, habit);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: state.restsFor(habit, past) || !habit.onDay(past) ? 1 : 0),
      duration: Motion.morph,
      curve: Motion.morphCurve,
      builder: (context, r, _) => Container(
        margin: const EdgeInsets.only(left: 3),
        width: 6,
        height: 8,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2.5),
          color: switch (status) {
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
    return Tile(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TileHeader(
            title: 'Journal',
            trailing: state.journalFiles == null
                ? null
                : _OpenFolderButton(state.journalFiles!.fileFor(day), problem: state.journalFileProblem),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: FadeThrough(
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: _JournalText(key: ValueKey(dateKey(day))),
            ),
          ),
        ],
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
      _controller = TextEditingController(text: _state.journalOf(_day));
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
      style: TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.35, color: p.ink),
      decoration: InputDecoration(
        border: InputBorder.none,
        hintText: _past ? 'Nothing written this day.' : null,
        hintStyle: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted.withValues(alpha: 0.6)),
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
      await Process.start(
        'explorer.exe',
        exists ? ['/select,${file.path}'] : [folder.path],
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
    final p = context.palette;
    final home = Platform.environment['HOME'];
    final shown = home != null && file.path.startsWith(home) ? '~${file.path.substring(home.length)}' : file.path;
    return Tooltip(
      message: problem == null
          ? 'Saved as $shown\nClick to show it in its folder'
          : '$problem\nYour journal is still kept safe in Eclipse.',
      child: IconButton(
        // Small enough not to make this card's header taller than the others.
        constraints: BoxConstraints.tight(const Size.square(24)),
        padding: EdgeInsets.zero,
        iconSize: 16,
        color: (problem == null ? p.inkMuted : p.missed).withValues(alpha: 0.8),
        onPressed: _open,
        icon: const Icon(Icons.folder_open_rounded),
      ),
    );
  }
}
