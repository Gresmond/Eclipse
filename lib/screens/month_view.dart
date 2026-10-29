import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../widgets/appear.dart';
import '../widgets/confirm_on_enter.dart';
import '../widgets/day_toggles.dart';
import '../widgets/fade_through.dart';
import '../widgets/note_input.dart';
import '../widgets/ritual_name.dart';
import '../widgets/sleep_time.dart';
import '../widgets/status_cell.dart';
import '../widgets/tile.dart';
import '../widgets/time_wheel.dart';

part 'month_editor.dart';
part 'month_grid.dart';

/// The spreadsheet grid: habits down the side, days across the top.
class MonthView extends StatefulWidget {
  const MonthView({super.key, required this.year, required this.month});

  final int year;
  final int month;

  @override
  State<MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<MonthView> {
  static const _nameWidth = 260.0;

  /// The page's height not taken by the two grids' rows: the page's and
  /// cards' padding, their headers, day headers and percentages.
  static const _chrome = 500.0;

  bool _editing = false;
  bool _editingSleep = false;

  void _finishRituals() {
    FocusManager.instance.primaryFocus?.unfocus();
    AppScope.read(context).saveHabitDrafts();
    setState(() => _editing = false);
  }

  @override
  void didUpdateWidget(MonthView old) {
    super.didUpdateWidget(old);
    if (old.year != widget.year || old.month != widget.month) _editing = _editingSleep = false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) => _build(context, c.maxHeight));

  Widget _build(BuildContext context, double height) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.habitsRevision, s.today, s.restWeekends));
    final (year, month) = (widget.year, widget.month);
    final future = state.isFutureMonth(year, month);
    final habits = state.habitsFor(year, month);
    final label = future
        ? 'PREVIEW  ·  COPIES YOUR LATEST RITUALS'
        : state.isPreviewMonth(year, month)
        ? 'PREVIEW  ·  SAVED WHEN YOU TICK OR EDIT'
        : 'RITUALS  ·  ${habits.length}';
    final sleep = state.sleepHabitsFor(year, month);
    // Squares as big as they can be with both cards on screen at once.
    final maxCell = (height - _chrome) / (habits.length + sleep.length) - 5;

    final Widget body;
    if (_editing) {
      body = ConfirmOnEnter(
        preserveTextInput: true,
        onConfirm: _finishRituals,
        child: _RitualEditor(year: year, month: month, onDone: _finishRituals),
      );
    } else if (habits.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            'No rituals yet. Add some with Edit rituals.',
            style: TextStyle(fontFamily: Fonts.body, fontSize: 16, color: p.inkMuted),
          ),
        ),
      );
    } else {
      body = _Grid(year: year, month: month, habits: habits, nameWidth: _nameWidth, maxCell: maxCell);
    }

    final header = TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w500, color: p.inkMuted);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ritualsTile(label, header, future, body, habits.isEmpty),
          const SizedBox(height: 20),
          // Sized like the rituals' grid, so its squares and days line up
          // with theirs.
          Tile(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The button hangs over the header line rather than making it
                // taller, so the two grids still fit the window.
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const SizedBox(width: double.infinity),
                    Text('SLEEP SCHEDULE  ·  ${sleep.length}', style: header),
                    Positioned(
                      right: 0,
                      top: -12,
                      child: _editButton(
                        future,
                        _editingSleep,
                        'Edit times',
                        () => setState(() => _editingSleep = !_editingSleep),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                AnimatedSize(
                  duration: Motion.morph,
                  curve: Motion.morphCurve,
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.none,
                  child: FadeThrough(
                    layoutBuilder: FadeThrough.sizeToCurrent,
                    child: KeyedSubtree(
                      key: ValueKey(_editingSleep),
                      child: _editingSleep
                          ? ConfirmOnEnter(
                              onConfirm: () => setState(() => _editingSleep = false),
                              child: _SleepEditor(year: year, month: month, nameWidth: _nameWidth, maxCell: maxCell),
                            )
                          : _Grid(
                              year: year,
                              month: month,
                              habits: sleep,
                              nameWidth: _nameWidth,
                              maxCell: maxCell,
                              doneLabel: 'of the logged schedule kept',
                              times: true,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Kept in place for future months, just faded, so the header row
  /// doesn't change height between months.
  Widget _editButton(bool future, bool editing, String label, VoidCallback onTap) {
    return IgnorePointer(
      ignoring: future,
      child: AnimatedOpacity(
        opacity: future ? 0 : 1,
        duration: Motion.morph,
        curve: Motion.morphCurve,
        child: _PillButton(
          label: editing ? 'Done' : label,
          icon: editing ? Icons.check_rounded : Icons.edit_outlined,
          filled: editing,
          onTap: onTap,
        ),
      ),
    );
  }

  Widget _ritualsTile(String label, TextStyle header, bool future, Widget body, bool empty) {
    return Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FadeThrough(
                duration: Motion.click,
                layoutBuilder: FadeThrough.aligned(Alignment.centerLeft),
                child: Text(label, key: ValueKey(label), style: header),
              ),
              const Spacer(),
              _editButton(future, _editing, 'Edit rituals', () {
                AppScope.read(context).saveHabitDrafts();
                setState(() => _editing = !_editing);
              }),
            ],
          ),
          const SizedBox(height: 22),
          // The card stays still. Moving between months morphs the grid in
          // place (see [_Grid]); only switching to the editor fades. The
          // height eases when the new month has a different number of rituals.
          AnimatedSize(
            duration: Motion.morph,
            curve: Motion.morphCurve,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            child: FadeThrough(
              layoutBuilder: FadeThrough.sizeToCurrent,
              child: KeyedSubtree(key: ValueKey((_editing, empty)), child: body),
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthHabitRow extends StatefulWidget {
  const _MonthHabitRow({
    required this.habit,
    required this.cells,
    required this.layout,
    required this.clickableDays,
    required this.nameWidth,
    required this.cellSize,
    required this.laidOut,
    this.names,
  });

  final Habit habit;

  /// The sleep schedule's names, when this row shows a time (see [SleepName]).
  final List<String>? names;

  /// This ritual's square in each column of [layout].
  final List<Widget> cells;
  final _ColumnLayout layout;

  /// How many squares, from the first, can be clicked (days after today can't).
  final int clickableDays;
  final double nameWidth;

  /// The squares' size as drawn, which eases between months, and the size
  /// [cells] are laid out at.
  final Animation<double> cellSize;
  final double laidOut;

  @override
  State<_MonthHabitRow> createState() => _MonthHabitRowState();
}

class _MonthHabitRowState extends State<_MonthHabitRow> {
  bool _hover = false;

  /// Lit only while the pointer is over the squares that can be clicked,
  /// not the empty part of the row past them.
  void _setHover(double? x) {
    final layout = widget.layout;
    final hover = x != null && x < widget.clickableDays.clamp(0, layout.shown.value) * layout.col;
    if (hover != _hover) setState(() => _hover = hover);
  }

  // Rebuilt each frame of a change of size: the row's height follows the
  // squares, but the squares themselves are only drawn smaller or larger.
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: widget.cellSize, builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final p = context.palette;
    const pad = _HighlightPainter.pad;
    final cellSize = widget.cellSize.value;
    final height = cellSize + 5;
    final nameStyle = TextStyle(
      fontFamily: Fonts.body,
      fontSize: 13.5,
      height: 1.15,
      fontWeight: FontWeight.w500,
      color: p.ink,
    );

    return Row(
      children: [
        SizedBox(
          width: widget.nameWidth,
          child: Padding(
            padding: const EdgeInsets.only(right: 16),
            // A long name wraps onto a second line, set a little tighter so
            // the row barely grows, unless squares are too small for two
            // lines: then it's cut short, whole on hover.
            child: widget.names != null
                ? SleepName(habit: widget.habit, names: widget.names!, style: nameStyle)
                : Tooltip(
                    message: widget.habit.description ?? widget.habit.name,
                    child: SizedBox(
                      height: height,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: widget.nameWidth - 16,
                          child: RitualName(
                            habit: widget.habit,
                            maxLines: widget.laidOut + 5 >= 2 * 13.5 * 1.15 + 2 ? 2 : 1,
                            style: nameStyle,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        // Only the squares light up on hover, not the ritual's name.
        Expanded(
          child: MouseRegion(
            onHover: (e) => _setHover(e.localPosition.dx),
            onExit: (_) => _setHover(null),
            // The squares have nothing for a screen reader, and walking a
            // month of them for the accessibility tree costs a frame.
            child: ExcludeSemantics(
              child: Stack(
                children: [
                  Positioned.fill(
                    top: 2.5 - pad + 1,
                    bottom: 2.5 - pad + 1,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _hover ? 1 : 0,
                        duration: Motion.hover,
                        curve: Motion.hoverCurve,
                        child: CustomPaint(
                          painter: _HighlightPainter(
                            layout: widget.layout,
                            clickableDays: widget.clickableDays,
                            cellSize: cellSize,
                            color: p.empty.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Each square is its own repaint boundary already.
                  Flow.unwrapped(
                    delegate: _ColumnsDelegate(widget.layout, height, cellSize / widget.laidOut),
                    clipBehavior: Clip.none,
                    children: widget.cells,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.icon, required this.onTap, this.filled = false});

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = filled ? p.onAccent : p.accent;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: filled ? LinearGradient(colors: p.gradient) : null,
            border: filled ? null : Border.all(color: p.tileBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.isToday, required this.rest});

  final DateTime day;
  final bool isToday;

  /// A weekend shown as a rest day: greyed.
  final bool rest;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final weekend = day.weekday >= DateTime.saturday;
    final letter = weekdayNames[day.weekday - 1][0];
    // Fills its column (less a small gap), so it follows the column's
    // width through a morph without being rebuilt.
    return Center(
      child: RepaintBoundary(
        // Each column keeps its day number from month to month; only the
        // weekday letter and the today marker change, and both ease.
        // Only whether this is today, and whether it's a rest day, are
        // animated; the colours are read from the palette every frame, so
        // they follow a theme cross-fade exactly instead of trailing it.
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: rest ? 1 : 0),
          duration: Motion.morph,
          curve: Motion.morphCurve,
          builder: (context, r, _) => TweenAnimationBuilder<double>(
            tween: Tween(end: isToday ? 1 : 0),
            duration: Motion.morph,
            curve: Motion.morphCurve,
            builder: (context, t, _) {
              final letterFg = Color.lerp(weekend ? p.other : p.inkMuted, p.inkMuted.withValues(alpha: 0.6), r)!;
              final numberFg = Color.lerp(p.ink, p.inkMuted.withValues(alpha: 0.75), r)!;
              // Inset as it sits inside a rest band, 4px from the band on
              // every side with corners following the band's, on every day.
              return Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: p.today.withValues(alpha: t),
                ),
                child: Column(
                  children: [
                    // The new letter rolls up into place as the old one rolls
                    // out above it, rather than every letter blinking out at once.
                    // Clipped to one line, so the two never show stacked.
                    AnimatedSwitcher(
                      duration: Motion.morph,
                      switchInCurve: Motion.morphCurve,
                      switchOutCurve: Motion.morphCurve,
                      layoutBuilder: (current, previous) => ClipRect(
                        child: Stack(alignment: Alignment.center, children: [...previous, ?current]),
                      ),
                      transitionBuilder: (child, anim) => SlideTransition(
                        position: Tween(
                          begin: Offset(0, child.key == ValueKey(letter) ? 1 : -1),
                          end: Offset.zero,
                        ).animate(anim),
                        child: FadeTransition(opacity: anim, child: child),
                      ),
                      child: Text(
                        letter,
                        key: ValueKey(letter),
                        style: TextStyle(
                          fontFamily: Fonts.ui,
                          fontSize: 10,
                          color: Color.lerp(letterFg, p.onToday, t)!.withValues(alpha: 0.8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${day.day}',
                      style: TextStyle(
                        fontFamily: Fonts.ui,
                        fontSize: 12.5,
                        color: Color.lerp(numberFg, p.onToday, t),
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
