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

/// Stays on screen from month to month and morphs: columns spread or close
/// up to the new number of days, squares ease to their new colours, and a
/// ritual new to this month fades in.
///
/// The morph is paint-only: each square is laid out once per change and
/// then just drawn at a new place each frame (see [_ColumnsDelegate]), so
/// even a 14 x 31 grid moves at the display's full frame rate.
class _Grid extends StatefulWidget {
  const _Grid({
    required this.year,
    required this.month,
    required this.habits,
    required this.nameWidth,
    required this.maxCell,
    this.doneLabel = 'of logged rituals done',
    this.times = false,
  });

  final int year;
  final int month;
  final List<Habit> habits;
  final double nameWidth;

  /// The largest square that keeps the page from scrolling.
  final double maxCell;
  final String doneLabel;

  /// The sleep schedule: each item's time beside its name, and no tooltip.
  final bool times;

  @override
  State<_Grid> createState() => _GridState();
}

class _GridState extends State<_Grid> with TickerProviderStateMixin {
  static const _minCol = 22.0;
  static const _maxCell = 64.0;

  late final _palette = ValueNotifier(context.palette);
  final _cells = <int, (Object, List<Widget>)>{};

  List<Widget> _cellsFor(
    Habit habit,
    double size,
    AppState state,
    List<({int number, DateTime day, bool leaving})> columns,
  ) {
    final key = (widget.year, widget.month, _previous, habit, habit.days, size, state.today, state.restWeekends);
    final cached = _cells[habit.id];
    if (cached?.$1 == key) return cached!.$2;
    final cells = [
      for (final c in columns)
        // A leaving column's square is disabled, so it ignores clicks too.
        // A day the ritual isn't on keeps its cell, faded to nothing, so
        // moving to a month with other days fades squares rather than
        // swapping them out.
        StatusCell(
          day: c.day,
          habit: habit,
          size: size,
          enabled: !c.leaving && !c.day.isAfter(state.today) && habit.startedBy(c.day),
          rest: state.isRestDay(c.day),
          off: !habit.onDay(c.day),
          paletteAnimation: _palette,
        ),
    ];
    _cells[habit.id] = (key, cells);
    return cells;
  }

  /// How many day columns are showing, easing between whole numbers. Column
  /// d is (shown - d + 1) of a column wide, between none and all of one.
  late final _shown = AnimationController.unbounded(
    vsync: this,
    value: daysInMonth(widget.year, widget.month).toDouble(),
  );

  /// The month shown before this one: columns it had that this month lacks
  /// keep showing its days while they close up.
  (int, int)? _previous;

  /// Rituals already on screen; any others fade in.
  Set<int> _known = {};

  /// Each ritual's row as last built, and the rows of rituals the new
  /// month lacks, kept at their old places while they fade and close up.
  final _rows = <int, Widget>{};
  final _leaving = <int, (int, Widget)>{};

  /// The squares' size as drawn. A month with more or fewer rituals has
  /// other squares, which ease to their new size with the columns' morph.
  late final _morph = AnimationController(vsync: this, duration: Motion.page, value: 1);
  late final _cellSize = _Lerp(CurvedAnimation(parent: _morph, curve: Motion.morphCurve));

  /// The month the weekend bands are fading from, and the fade into this
  /// month's bands.
  (int, int)? _bandsFrom;
  late final _bands = AnimationController(vsync: this, duration: Motion.morph, value: 1);
  late final _bandsCurved = CurvedAnimation(parent: _bands, curve: Motion.morphCurve);

  /// A grid new on screen builds its first half of rows in its first frame
  /// and the rest, held open at their height, in the next. Its page is
  /// still fading in from nothing then, so opening a month never costs one
  /// long frame.
  late bool _staged = widget.habits.length > 6;

  /// The squares' size in a grid [width] wide: as big as a 31-day month
  /// across the card allows, and no taller than [maxCell].
  static double cellFor(double width, double nameWidth, double maxCell) {
    final col = ((nameWidth + 31 * _minCol).clamp(width, double.infinity) - nameWidth) / 31;
    return [col - 6, maxCell, _maxCell].reduce((a, b) => a < b ? a : b).clamp(_minCol - 6, _maxCell);
  }

  @override
  void initState() {
    super.initState();
    if (_staged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _staged = false);
      });
    }
  }

  @override
  void didUpdateWidget(_Grid old) {
    super.didUpdateWidget(old);
    _known = {for (final h in old.habits) h.id};
    final ids = {for (final h in widget.habits) h.id};
    _leaving.removeWhere((id, _) => ids.contains(id));
    for (final (i, h) in old.habits.indexed) {
      final row = _rows[h.id];
      if (!ids.contains(h.id) && row != null) _leaving[h.id] = (i, row);
    }
    if ((old.year, old.month) == (widget.year, widget.month)) return;
    _cellSize.from = _cellSize.value;
    _morph.forward(from: 0);
    _previous = (old.year, old.month);
    _bandsFrom = (old.year, old.month);
    _bands.forward(from: 0);
    _shown
        .animateTo(daysInMonth(widget.year, widget.month).toDouble(), duration: Motion.page, curve: Motion.morphCurve)
        .whenCompleteOrCancel(() {
          if (mounted && _shown.value == daysInMonth(widget.year, widget.month)) setState(() => _previous = null);
        });
  }

  @override
  void dispose() {
    _palette.dispose();
    _bandsCurved.dispose();
    _bands.dispose();
    _shown.dispose();
    _cellSize.parent.dispose();
    _morph.dispose();
    super.dispose();
  }

  /// The date in column [d] (1-based), or null when there is no column d.
  DateTime? _dayAt(int d) {
    if (d <= daysInMonth(widget.year, widget.month)) return DateTime(widget.year, widget.month, d);
    final prev = _previous;
    if (prev == null || d > daysInMonth(prev.$1, prev.$2)) return null;
    return DateTime(prev.$1, prev.$2, d);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.habitsRevision, s.today, s.restWeekends));
    if (_palette.value != p) _palette.value = p;
    final ids = {for (final habit in widget.habits) habit.id};
    _cells.removeWhere((id, _) => !ids.contains(id));
    _rows.removeWhere((id, _) => !ids.contains(id) && !_leaving.containsKey(id));
    final (year, month, habits, nameWidth) = (widget.year, widget.month, widget.habits, widget.nameWidth);
    final dayCount = daysInMonth(year, month);

    return LayoutBuilder(
      builder: (context, constraints) {
        double gridWidth(double days) => (nameWidth + days * _minCol).clamp(constraints.maxWidth, double.infinity);
        // Columns spread across the card. Squares are sized for a 31-day
        // month and as tall as the page allows. They change size only when
        // a month has more or fewer rituals, easing as the columns move.
        double colFor(double days) => (gridWidth(days) - nameWidth) / days;
        final width = gridWidth(dayCount.toDouble());
        final cell = cellFor(constraints.maxWidth, nameWidth, widget.maxCell);
        if (_cellSize.to == 0) _cellSize.from = cell;
        _cellSize.to = cell;
        final columns = [
          for (var d = 1; d <= 31; d++)
            if (_dayAt(d) case final day?) (number: d, day: day, leaving: d > dayCount),
        ];
        // Keep header content stable while only its column width changes.
        final headers = {
          for (final c in columns)
            c.number: _DayHeader(day: c.day, isToday: c.day == state.today, rest: state.isRestDay(c.day)),
        };
        final layout = _ColumnLayout(shown: _shown, colFor: colFor, days: [for (final c in columns) c.number]);

        final rows = <Widget>[
          for (final (i, h) in habits.indexed)
            if (_staged && i >= (habits.length + 1) ~/ 2)
              SizedBox(key: ValueKey(h.id), height: cell + 5)
            else
              Appear(
                key: ValueKey(h.id),
                animate: _known.isNotEmpty && !_known.contains(h.id),
                duration: Motion.page,
                child: IgnorePointer(
                  ignoring: false,
                  child: _rows[h.id] = _MonthHabitRow(
                    habit: h,
                    names: widget.times ? [for (final x in habits) x.name] : null,
                    nameWidth: nameWidth,
                    cellSize: _cellSize,
                    laidOut: cell,
                    layout: layout,
                    clickableDays: columns.where((c) => !c.leaving && !c.day.isAfter(state.today)).length,
                    cells: _cellsFor(h, cell, state, columns),
                  ),
                ),
              ),
        ];
        // A ritual this month lacks fades out and closes up where it was.
        for (final MapEntry(key: id, value: (i, row))
            in _leaving.entries.toList()..sort((a, b) => a.value.$1 - b.value.$1)) {
          rows.insert(
            i.clamp(0, rows.length),
            Appear(
              key: ValueKey(id),
              animate: false,
              shown: false,
              duration: Motion.page,
              onHidden: () => setState(() {
                _leaving.remove(id);
                _rows.remove(id);
              }),
              child: IgnorePointer(child: row),
            ),
          );
        }

        final days = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The headers are a plain row of 31 boxes, cheap enough to lay
            // out each frame, so their width follows the columns'.
            AnimatedBuilder(
              animation: _shown,
              builder: (context, _) {
                final shown = _shown.value;
                final col = colFor(shown);
                return Row(
                  children: [
                    SizedBox(width: nameWidth),
                    for (final c in columns)
                      if (shown > c.number - 1)
                        _Column(
                          width: col * (shown - c.number + 1).clamp(0.0, 1.0),
                          full: col,
                          child: headers[c.number]!,
                        ),
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
            ...rows,
          ],
        );

        Widget grid = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Positioned.fill(
                  left: nameWidth,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: state.restWeekends ? 1 : 0,
                      duration: Motion.morph,
                      curve: Motion.morphCurve,
                      child: CustomPaint(
                        painter: _RestBandPainter(
                          layout: layout,
                          weekend: [for (final c in columns) c.day.weekday >= DateTime.saturday],
                          was: [
                            for (final c in columns)
                              if (_bandsFrom case (final y, final m) when c.number <= daysInMonth(y, m))
                                DateTime(y, m, c.number).weekday >= DateTime.saturday
                              else
                                false,
                          ],
                          fade: _bandsCurved,
                          color: p.inkMuted.withValues(alpha: p.brightness == Brightness.dark ? 0.09 : 0.06),
                        ),
                      ),
                    ),
                  ),
                ),
                days,
              ],
            ),
            const SizedBox(height: 16),
            _MonthScore(year: year, month: month, habits: habits, label: widget.doneLabel),
          ],
        );

        if (width > constraints.maxWidth) {
          grid = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: width, child: grid),
          );
        }
        return grid;
      },
    );
  }
}

class _MonthScore extends StatelessWidget {
  const _MonthScore({required this.year, required this.month, required this.habits, required this.label});
  final int year, month;
  final List<Habit> habits;
  final String label;
  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => s.entriesRevision);
    var done = 0, logged = 0;
    for (final habit in habits) {
      final score = state.scoreOf(year, month, habit);
      done += score.$1;
      logged += score.$2;
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: p.empty.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.tileBorder.withValues(alpha: 0.6), width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: logged == 0 ? 0 : done * 100 / logged),
              duration: Motion.morph,
              curve: Motion.morphCurve,
              builder: (context, percent, _) => Text(
                '${percent.round()}%',
                style: TextStyle(
                  fontFamily: Fonts.display,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(fontFamily: Fonts.ui, fontSize: 12.5, fontWeight: FontWeight.w500, color: p.inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Eases between two values as [parent] runs from 0 to 1.
class _Lerp extends Animation<double> with AnimationWithParentMixin<double> {
  _Lerp(this.parent);

  @override
  final CurvedAnimation parent;
  double from = 0, to = 0;

  @override
  double get value => from + (to - from) * parent.value;
}

/// Where the day columns are at this moment of a morph.
class _ColumnLayout {
  const _ColumnLayout({required this.shown, required this.colFor, required this.days});

  final Animation<double> shown;

  /// Column width for a (fractional) number of columns.
  final double Function(double days) colFor;

  /// The day number (1-31) of each column, in order.
  final List<int> days;

  double get col => colFor(shown.value);

  /// How much of column [d] is showing, 0 to 1.
  double fraction(int d) => (shown.value - d + 1).clamp(0.0, 1.0);
}

/// One day's header box at [width], drawn at its [full] width and clipped,
/// so a column closing up hides its header rather than squashing it.
class _Column extends StatelessWidget {
  const _Column({required this.width, required this.full, required this.child});

  final double width;
  final double full;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fraction = width / full;
    return SizedBox(
      width: width,
      child: ClipRect(
        clipBehavior: fraction < 1 ? Clip.hardEdge : Clip.none,
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: full,
          maxWidth: full,
          fit: OverflowBoxFit.deferToChild,
          child: Opacity(opacity: Curves.easeIn.transform(fraction.clamp(0.0, 1.0)), child: child),
        ),
      ),
    );
  }
}

/// Draws one row's squares in their columns. Laid out once; each frame of
/// a morph only moves them, so nothing is rebuilt or measured again.
class _ColumnsDelegate extends FlowDelegate {
  _ColumnsDelegate(this.layout, this.height, this.scale) : super(repaint: layout.shown);

  final _ColumnLayout layout;
  final double height;

  /// The squares as drawn over as laid out, while they ease to a new size.
  final double scale;

  @override
  Size getSize(BoxConstraints constraints) => Size(constraints.maxWidth, height);

  // The same loose box every time, so a square never needs laying out
  // again while its column moves.
  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.loose(const Size.square(_GridState._maxCell));

  @override
  void paintChildren(FlowPaintingContext context) {
    final col = layout.col;
    for (var i = 0; i < context.childCount; i++) {
      final d = layout.days[i];
      final fraction = layout.fraction(d);
      if (fraction == 0) continue;
      final size = context.getChildSize(i)!;
      context.paintChild(
        i,
        transform: Matrix4.translationValues((d - 1) * col + col / 2, height / 2, 0)
          ..scaleByDouble(scale, scale, 1, 1)
          ..translateByDouble(-size.width / 2, -size.height / 2, 0, 1),
        opacity: Curves.easeIn.transform(fraction),
      );
    }
  }

  @override
  bool shouldRelayout(_ColumnsDelegate old) => old.height != height;

  @override
  bool shouldRepaint(_ColumnsDelegate old) => true;
}

/// The hover highlight behind a row's squares, from the first square to
/// the last one that can be clicked, following the columns as they move.
class _HighlightPainter extends CustomPainter {
  _HighlightPainter({required this.layout, required this.clickableDays, required this.cellSize, required this.color})
    : super(repaint: layout.shown);

  static const pad = 3.0;

  final _ColumnLayout layout;
  final int clickableDays;
  final double cellSize;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (clickableDays == 0) return;
    final col = layout.col;
    final inset = (col - cellSize) / 2;
    final clickable = clickableDays.clamp(0, layout.shown.value) * col;
    final rect = Rect.fromLTWH(inset - pad, 0, clickable - 2 * inset + 2 * pad, size.height);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(cellSize * 0.28 + pad)), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_HighlightPainter old) =>
      old.clickableDays != clickableDays || old.cellSize != cellSize || old.color != color || old.layout != layout;
}

/// A soft band down each run of weekend columns, behind the day headers and
/// squares, marking them as rest days. Follows the columns through a morph.
class _RestBandPainter extends CustomPainter {
  _RestBandPainter({
    required this.layout,
    required this.weekend,
    required this.was,
    required this.fade,
    required this.color,
  }) : super(repaint: Listenable.merge([layout.shown, fade]));

  final _ColumnLayout layout;

  /// Whether each of the layout's columns falls on a weekend, this month
  /// and in the month being left; [fade] runs from the old bands to these.
  final List<bool> weekend;
  final List<bool> was;
  final Animation<double> fade;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = fade.value;
    if (t < 1) _bands(canvas, size, was, color.withValues(alpha: color.a * (1 - t)));
    if (t > 0) _bands(canvas, size, weekend, color.withValues(alpha: color.a * t));
  }

  void _bands(Canvas canvas, Size size, List<bool> weekend, Color color) {
    final col = layout.col;
    final paint = Paint()..color = color;
    double? start;
    var end = 0.0;
    void band() {
      if (start == null || end - start < 4) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(start + 1, -4, end - 1, size.height + 4), const Radius.circular(12)),
        paint,
      );
    }

    for (final (i, d) in layout.days.indexed) {
      final width = col * layout.fraction(d);
      if (weekend[i] && width > 0) {
        start ??= (d - 1) * col;
        end = (d - 1) * col + width;
      } else {
        band();
        start = null;
      }
    }
    band();
  }

  @override
  bool shouldRepaint(_RestBandPainter old) =>
      old.layout != layout ||
      old.color != color ||
      old.fade != fade ||
      !listEquals(old.weekend, weekend) ||
      !listEquals(old.was, was);
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
