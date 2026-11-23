import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryMouseButton;
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/pixels.dart';
import '../theme/tokens.dart';
import '../widgets/hover_fill.dart';
import '../widgets/tile.dart';

/// The year day by day, each month its own block, tinted by the share of
/// its rituals done.
class YearHeatmap extends StatefulWidget {
  const YearHeatmap({super.key, required this.year, required this.rituals});

  final int year;

  /// The rituals on each month's list, by month.
  final Map<int, Set<int>> rituals;

  /// How many times the heatmap aggregated a year from SQLite; for tests.
  @visibleForTesting
  static int debugComputes = 0;

  static const _gap = 3.0;
  static const _monthGap = 10.0;
  static const _labelWidth = 44.0;
  static const _monthsHeight = 26.0;

  /// Maximum cell size so stretching across wide windows stays compact enough
  /// for the top cards to fit on one screen before scrolling.
  static const _maxCell = 20.0;

  /// The tile's padding and border, each side.
  static const _tileInset = 25.0;
  static const _minGridWidth = 745.0;

  static int _columns(int year, int month) {
    final skipped = DateTime(year, month).weekday - 1;
    return (skipped + DateUtils.getDaysInMonth(year, month) - 1) ~/ 7 + 1;
  }

  static double _gridWidth(double width) => math.max(width - 2 * _tileInset, _minGridWidth);

  static double _cell(int year, double gridWidth) {
    var columns = 0;
    for (var m = 1; m <= 12; m++) {
      columns += _columns(year, m);
    }
    final room = gridWidth - _labelWidth - 11 * _monthGap - (columns - 12) * _gap;
    return pixelFloor(room / columns).clamp(8.0, _maxCell);
  }

  static double _gridHeight(int year, double gridWidth) =>
      _monthsHeight + 7 * _cell(year, gridWidth) + 6 * _gap;

  static ({double cell, double step, double monthGap, List<int> columns, List<double> monthLefts, double gridSpan})
      _gridLayout(int year, double gridWidth) {
    final cell = _cell(year, gridWidth);
    final step = cell + _gap;
    final columns = [for (var m = 1; m <= 12; m++) _columns(year, m)];
    final used = columns.fold(0.0, (a, c) => a + c * cell + (c - 1) * _gap);
    // Spare width goes between the months, so they run the card's width.
    final monthGap = math.max(0.0, pixelFloor((gridWidth - _labelWidth - used) / 11));
    final monthLefts = List<double>.filled(12, 0);
    var mx = 0.0;
    for (var m = 0; m < 12; m++) {
      monthLefts[m] = mx;
      mx += columns[m] * cell + (columns[m] - 1) * _gap + monthGap;
    }
    return (
      cell: cell,
      step: step,
      monthGap: monthGap,
      columns: columns,
      monthLefts: monthLefts,
      gridSpan: math.max(gridWidth - _labelWidth, mx - monthGap),
    );
  }

  /// Centre of [day] inside the year grid's `CustomPaint` box of width [paintWidth].
  @visibleForTesting
  static Offset dayCenterInGrid(int year, double paintWidth, DateTime day) {
    final layout = _gridLayout(year, paintWidth + _labelWidth);
    final skipped = DateTime(year, day.month).weekday - 1;
    final at = skipped + day.day - 1;
    return Offset(
      layout.monthLefts[day.month - 1] + (at ~/ 7) * layout.step + layout.cell / 2,
      (at % 7) * layout.step + layout.cell / 2,
    );
  }

  /// The card's height across [width], with its title of [titleHeight].
  static double heightFor(int year, double width, double titleHeight) =>
      2 * _tileInset + titleHeight + 18 + _gridHeight(year, _gridWidth(width));

  @override
  State<YearHeatmap> createState() => _YearHeatmapState();
}

class _HeatmapData {
  const _HeatmapData({
    required this.done,
    required this.logged,
    required this.allDone,
    required this.allLogged,
  });

  final Map<String, int> done, logged;
  final int allDone, allLogged;
}

class _YearHeatmapState extends State<YearHeatmap> {
  final _hoveredDay = ValueNotifier<DateTime?>(null);

  AppState? _state;
  int? _year, _habitsRevision, _entriesRevision;
  DateTime? _today;
  List<Holiday>? _holidays;
  Map<int, Set<int>>? _rituals;
  _HeatmapData? _cached;

  @override
  void didUpdateWidget(YearHeatmap old) {
    super.didUpdateWidget(old);
    if (old.year != widget.year) _hoveredDay.value = null;
  }

  @override
  void dispose() {
    _hoveredDay.dispose();
    super.dispose();
  }

  static bool _sameHolidays(List<Holiday>? a, List<Holiday> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].start != b[i].start || a[i].end != b[i].end) return false;
    }
    return true;
  }

  static bool _sameRituals(Map<int, Set<int>>? a, Map<int, Set<int>> b) {
    if (a == null || a.length != b.length) return false;
    for (final entry in b.entries) {
      if (!setEquals(a[entry.key], entry.value)) return false;
    }
    return true;
  }

  _HeatmapData _dataFor(AppState state) {
    if (_cached != null &&
        identical(_state, state) &&
        _year == widget.year &&
        _habitsRevision == state.habitsRevision &&
        _entriesRevision == state.entriesRevision &&
        _today == state.today &&
        _sameHolidays(_holidays, state.holidays) &&
        _sameRituals(_rituals, widget.rituals)) {
      return _cached!;
    }
    YearHeatmap.debugComputes++;
    final data = _compute(state, widget.year, widget.rituals);
    _state = state;
    _year = widget.year;
    _habitsRevision = state.habitsRevision;
    _entriesRevision = state.entriesRevision;
    _today = state.today;
    _holidays = List<Holiday>.of(state.holidays);
    _rituals = {for (final e in widget.rituals.entries) e.key: Set<int>.of(e.value)};
    return _cached = data;
  }

  static _HeatmapData _compute(AppState state, int year, Map<int, Set<int>> rituals) {
    final done = <String, int>{}, logged = <String, int>{};
    var allDone = 0, allLogged = 0;
    for (final MapEntry(key: month, value: ids) in rituals.entries) {
      if (!state.isShownMonth(year, month) || state.isPreviewMonth(year, month)) continue;
      final byId = <int, Habit>{};
      for (final h in state.habitsFor(year, month)) {
        byId[h.id] = h;
        if (ids.contains(h.id)) {
          final (mDone, mLogged) = state.scoreOf(year, month, h);
          allDone += mDone;
          allLogged += mLogged;
        }
      }
      for (final e in state.store.entriesInMonth(year, month)) {
        final h = byId[e.habitId];
        // Counted as a month's tab does: other days, days before a ritual was
        // added, and days it isn't scheduled for aren't logged.
        if (h == null || !ids.contains(e.habitId) || e.status == HabitStatus.none || e.status == HabitStatus.other) {
          continue;
        }
        final day = DateTime.parse(e.day);
        if (!h.startedBy(day) || !h.onDay(day) || holidayOn(state.holidays, day) != null) continue;
        final isDone = e.status == HabitStatus.done;
        logged[e.day] = (logged[e.day] ?? 0) + 1;
        if (isDone) done[e.day] = (done[e.day] ?? 0) + 1;
      }
    }
    return _HeatmapData(done: done, logged: logged, allDone: allDone, allLogged: allLogged);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(
      context,
      (s) => (s.habitsRevision, s.entriesRevision, s.today, s.holidays),
    );
    final data = _dataFor(state);

    final label = capsLabel(p.inkMuted);
    final title = data.allLogged == 0
        ? 'THE YEAR'
        : 'THE YEAR  ·  ${(data.allDone * 100 / data.allLogged).round()}% OF RITUALS DONE';
    final first = state.firstMonth;
    final firstDay = DateTime(first.$1, first.$2);
    final shownMonths = state.shownMonths(widget.year).toSet();
    final headerRow = Row(
      children: [
        Expanded(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: label),
        ),
        const SizedBox(width: 12),
        _HeatmapLegend(
          hoveredDay: _hoveredDay,
          data: data,
          holidays: state.holidays,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        final inner = c.maxWidth - 2 * YearHeatmap._tileInset;
        final grid = math.max(inner, YearHeatmap._minGridWidth);
        final gridHeight = YearHeatmap._gridHeight(widget.year, grid);
        final gridWidget = SizedBox(
          width: grid,
          height: gridHeight,
          child: _Grid(
            year: widget.year,
            today: state.today,
            firstDay: firstDay,
            shownMonths: shownMonths,
            width: grid,
            done: data.done,
            logged: data.logged,
            hoveredDay: _hoveredDay,
            onOpenDay: state.showDay,
            onOpenMonth: state.showMonth,
          ),
        );
        return Tile(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              headerRow,
              const SizedBox(height: 18),
              if (inner < YearHeatmap._minGridWidth)
                SingleChildScrollView(scrollDirection: Axis.horizontal, child: gridWidget)
              else
                gridWidget,
            ],
          ),
        );
      },
    );
  }
}

class _HeatmapLegend extends StatelessWidget {
  const _HeatmapLegend({
    required this.hoveredDay,
    required this.data,
    required this.holidays,
  });

  final ValueNotifier<DateTime?> hoveredDay;
  final _HeatmapData data;
  final List<Holiday> holidays;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final muted = TextStyle(
      fontFamily: Fonts.ui,
      fontSize: 12,
      color: p.inkMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ValueListenableBuilder<DateTime?>(
      valueListenable: hoveredDay,
      builder: (context, day, _) {
        if (day == null) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('0%', style: muted),
              const SizedBox(width: 6),
              for (final color in [p.missed, p.other, p.done]) ...[
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 3),
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                ),
              ],
              const SizedBox(width: 3),
              Text('100%', style: muted),
            ],
          );
        }
        final key = dateKey(day);
        final dateStr = '${day.day} ${shortMonth(day.month)}';
        final count = data.logged[key];
        final doneCount = data.done[key] ?? 0;
        final summary = count != null && count > 0
            ? '$dateStr · $doneCount of $count done (${(doneCount * 100 / count).round()}%)'
            : holidayOn(holidays, day) != null
            ? '$dateStr · On holiday'
            : day.weekday == DateTime.saturday || day.weekday == DateTime.sunday
            ? '$dateStr · Rest day'
            : '$dateStr · Nothing logged';
        return Text(
          summary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: Fonts.ui,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: p.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}

class _Grid extends StatefulWidget {
  const _Grid({
    required this.year,
    required this.today,
    required this.firstDay,
    required this.shownMonths,
    required this.width,
    required this.done,
    required this.logged,
    required this.hoveredDay,
    required this.onOpenDay,
    required this.onOpenMonth,
  });

  final int year;
  final DateTime today;
  final DateTime firstDay;
  final Set<int> shownMonths;
  final double width;
  final Map<String, int> done, logged;
  final ValueNotifier<DateTime?> hoveredDay;
  final ValueChanged<DateTime> onOpenDay;
  final ValueChanged<int> onOpenMonth;

  @override
  State<_Grid> createState() => _GridState();
}

class _GridState extends State<_Grid> {
  int? _pressedPointer;
  Offset? _downPos;
  DateTime? _pressedDay;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const gap = YearHeatmap._gap, top = YearHeatmap._monthsHeight, left = YearHeatmap._labelWidth;
    final layout = YearHeatmap._gridLayout(widget.year, widget.width);
    final cell = layout.cell, step = layout.step, columns = layout.columns, monthLefts = layout.monthLefts;
    const dayLine = 16.0;
    final dayStyle = TextStyle(fontFamily: Fonts.ui, fontSize: 12, height: dayLine / 12, color: p.inkMuted);
    // Rows shorter than a line of text name every other day, so no two
    // names touch.
    final everyOther = step < dayLine;
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    final totalGridWidth = layout.gridSpan;
    final totalGridHeight = 7 * cell + 6 * gap;

    final children = <Widget>[
      for (final (i, name) in dayNames.indexed)
        if (!everyOther || i.isEven)
          // Centred on its row, whatever the row's height.
          Positioned(left: 0, top: top + i * step + (cell - dayLine) / 2, child: Text(name, style: dayStyle)),
      for (var month = 1; month <= 12; month++)
        Positioned(
          left: left + monthLefts[month - 1],
          top: 0,
          child: widget.shownMonths.contains(month)
              ? PixelTooltip(
                  message: 'Open ${monthNames[month - 1]}',
                  child: Hoverable(
                    focusable: true,
                    semanticLabel: 'Open ${monthNames[month - 1]}',
                    onTap: () => widget.onOpenMonth(month),
                    builder: (hover) => Text(
                      shortMonth(month).toUpperCase(),
                      style: capsLabel(hover ? p.ink : p.inkMuted),
                    ),
                  ),
                )
              : Text(shortMonth(month).toUpperCase(), style: capsLabel(p.inkMuted)),
        ),
      Positioned(
        left: left,
        top: top,
        width: totalGridWidth,
        height: totalGridHeight,
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size(totalGridWidth, totalGridHeight),
            painter: _YearDaysPainter(
              year: widget.year,
              today: widget.today,
              cell: cell,
              step: step,
              monthGap: layout.monthGap,
              monthLefts: monthLefts,
              done: widget.done,
              logged: widget.logged,
              palette: p,
              hoveredDay: widget.hoveredDay,
            ),
          ),
        ),
      ),
    ];

    DateTime? dayAt(Offset local) {
      final dy = local.dy;
      if (dy < 0 || dy >= totalGridHeight) return null;
      final row = (dy / step).floor();
      if (row < 0 || row >= 7 || dy - row * step > cell) return null;
      final dx = local.dx;
      for (var month = 1; month <= 12; month++) {
        final mx = monthLefts[month - 1];
        final mWidth = columns[month - 1] * cell + (columns[month - 1] - 1) * gap;
        if (dx < mx || dx > mx + mWidth) continue;
        final col = ((dx - mx) / step).floor();
        if (col < 0 || col >= columns[month - 1] || dx - mx - col * step > cell) return null;
        final skipped = DateTime(widget.year, month).weekday - 1;
        final d = col * 7 + row - skipped + 1;
        if (d < 1 || d > DateUtils.getDaysInMonth(widget.year, month)) return null;
        final day = DateTime(widget.year, month, d);
        if (day.isAfter(widget.today) || day.isBefore(widget.firstDay)) return null;
        return day;
      }
      return null;
    }

    children.add(
      Positioned(
        left: left,
        top: top,
        width: totalGridWidth,
        height: totalGridHeight,
        child: ValueListenableBuilder<DateTime?>(
          valueListenable: widget.hoveredDay,
          builder: (context, hovered, child) => MouseRegion(
            cursor: hovered == null ? MouseCursor.defer : SystemMouseCursors.click,
            hitTestBehavior: HitTestBehavior.translucent,
            onHover: (e) {
              final day = dayAt(e.localPosition);
              if (widget.hoveredDay.value != day) widget.hoveredDay.value = day;
            },
            onExit: (_) {
              if (widget.hoveredDay.value != null) widget.hoveredDay.value = null;
            },
            child: child,
          ),
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) {
              if (e.kind != PointerDeviceKind.mouse || e.buttons == kPrimaryMouseButton) {
                _pressedPointer = e.pointer;
                _downPos = e.position;
                _pressedDay = dayAt(e.localPosition);
              }
            },
            onPointerCancel: (e) {
              if (e.pointer == _pressedPointer) {
                _pressedPointer = null;
                _downPos = null;
                _pressedDay = null;
              }
            },
            onPointerUp: (e) {
              if (e.pointer != _pressedPointer) return;
              final day = _pressedDay;
              final down = _downPos;
              _pressedPointer = null;
              _downPos = null;
              _pressedDay = null;
              if (day != null &&
                  down != null &&
                  (e.position - down).distance <= 8.0 &&
                  dayAt(e.localPosition) == day) {
                widget.onOpenDay(day);
              }
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    return Stack(clipBehavior: Clip.none, children: children);
  }
}

class _YearDaysPainter extends CustomPainter {
  _YearDaysPainter({
    required this.year,
    required this.today,
    required this.cell,
    required this.step,
    required this.monthGap,
    required this.monthLefts,
    required this.done,
    required this.logged,
    required this.palette,
    required this.hoveredDay,
  }) : super(repaint: hoveredDay);

  final int year;
  final DateTime today;
  final double cell;
  final double step;
  final double monthGap;
  final List<double> monthLefts;
  final Map<String, int> done;
  final Map<String, int> logged;
  final Palette palette;
  final ValueNotifier<DateTime?> hoveredDay;

  @override
  void paint(Canvas canvas, Size size) {
    const radius = Radius.circular(4);
    final fillPaint = Paint();
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    Color fill(double r) =>
        r < 0.5 ? Color.lerp(palette.missed, palette.other, r * 2)! : Color.lerp(palette.other, palette.done, r * 2 - 1)!;

    for (var month = 1; month <= 12; month++) {
      final mx = monthLefts[month - 1];
      final skipped = DateTime(year, month).weekday - 1;
      final days = DateUtils.getDaysInMonth(year, month);
      for (var d = 1; d <= days; d++) {
        final day = DateTime(year, month, d);
        final at = skipped + d - 1;
        final key = dateKey(day);
        final count = logged[key];
        fillPaint.color = count == null
            ? palette.empty.withValues(alpha: day.isAfter(today) ? 0.25 : 0.55)
            : fill((done[key] ?? 0) / count);
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(mx + (at ~/ 7) * step, (at % 7) * step, cell, cell),
          radius,
        );
        canvas.drawRRect(rrect, fillPaint);
        if (day == today) {
          strokePaint.color = palette.ink;
          canvas.drawRRect(rrect.deflate(1), strokePaint);
        }
      }
    }

    final hovered = hoveredDay.value;
    if (hovered != null && hovered.year == year) {
      final m = hovered.month;
      final skipped = DateTime(year, m).weekday - 1;
      final at = skipped + hovered.day - 1;
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(monthLefts[m - 1] + (at ~/ 7) * step, (at % 7) * step, cell, cell),
        radius,
      );
      strokePaint.color = hovered == today ? palette.accent : palette.ink;
      canvas.drawRRect(rrect.deflate(1), strokePaint);
    }
  }

  @override
  bool shouldRepaint(_YearDaysPainter old) =>
      old.year != year ||
      old.today != today ||
      old.cell != cell ||
      old.monthGap != monthGap ||
      old.done != done ||
      old.logged != logged ||
      old.palette != palette ||
      old.hoveredDay != hoveredDay;
}
