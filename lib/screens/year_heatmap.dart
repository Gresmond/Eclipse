import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/pixels.dart';
import '../theme/tokens.dart';
import '../widgets/tile.dart';

/// The year day by day, each month its own block, tinted by the share of
/// its rituals done, beside the rituals that slip most on one weekday.
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
  static const _findings = 5;
  static const _findingHeight = 30.0;

  /// A weekday's logged days needed before it can be called out.
  static const _minDays = 4;

  /// Points under its usual that make a weekday worth calling out.
  static const _minDrop = 15;

  /// The tile's padding and border, each side.
  static const _tileInset = 25.0;
  static const _between = 40.0;
  static const _narrowBreakpoint = 1155.0;
  static const _minGridWidth = 745.0;

  static int _columns(int year, int month) {
    final skipped = DateTime(year, month).weekday - 1;
    return (skipped + DateUtils.getDaysInMonth(year, month) - 1) ~/ 7 + 1;
  }

  static bool _isStacked(double width) => width < _narrowBreakpoint;

  static double _gridWidth(double width) => _isStacked(width)
      ? math.max(width - 2 * _tileInset, _minGridWidth)
      : pixelFloor((width - 2 * _tileInset - _between) * 0.7);

  static double _cell(int year, double gridWidth) {
    var columns = 0;
    for (var m = 1; m <= 12; m++) {
      columns += _columns(year, m);
    }
    final room = gridWidth - _labelWidth - 11 * _monthGap - (columns - 12) * _gap;
    return pixelFloor(room / columns).clamp(8.0, 40.0);
  }

  static double _gridHeight(int year, double gridWidth) =>
      _monthsHeight + 7 * _cell(year, gridWidth) + 6 * _gap;

  static double _bodyHeight(int year, double width) {
    final grid = _gridHeight(year, _gridWidth(width));
    if (_isStacked(width)) return grid;
    return grid > _findings * _findingHeight ? grid : _findings * _findingHeight;
  }

  /// The card's height across [width], with its title of [titleHeight].
  static double heightFor(int year, double width, double titleHeight) {
    final gridHeight = _gridHeight(year, _gridWidth(width));
    if (_isStacked(width)) {
      return 2 * _tileInset + titleHeight + 18 + gridHeight + 20 + titleHeight + 12 + _findings * _findingHeight;
    }
    return 2 * _tileInset + titleHeight + 18 + _bodyHeight(year, width);
  }

  @override
  State<YearHeatmap> createState() => _YearHeatmapState();
}

class _HeatmapData {
  const _HeatmapData({
    required this.done,
    required this.logged,
    required this.allDone,
    required this.allLogged,
    required this.slips,
  });

  final Map<String, int> done, logged;
  final int allDone, allLogged;
  final List<({String name, int weekday, int rate, int usual})> slips;
}

class _YearHeatmapState extends State<YearHeatmap> {
  AppState? _state;
  int? _year, _habitsRevision, _entriesRevision;
  DateTime? _today;
  bool? _restWeekends;
  List<Holiday>? _holidays;
  Map<int, Set<int>>? _rituals;
  _HeatmapData? _cached;

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
        _restWeekends == state.restWeekends &&
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
    _restWeekends = state.restWeekends;
    _holidays = List<Holiday>.of(state.holidays);
    _rituals = {for (final e in widget.rituals.entries) e.key: Set<int>.of(e.value)};
    return _cached = data;
  }

  static _HeatmapData _compute(AppState state, int year, Map<int, Set<int>> rituals) {
    final done = <String, int>{}, logged = <String, int>{};
    final doneOn = <int, List<int>>{}, loggedOn = <int, List<int>>{};
    final names = <int, String>{};
    var allDone = 0, allLogged = 0;
    for (final MapEntry(key: month, value: ids) in rituals.entries) {
      if (!state.isShownMonth(year, month) || state.isPreviewMonth(year, month)) continue;
      final byId = <int, Habit>{};
      for (final h in state.habitsFor(year, month)) {
        names[h.id] = h.name;
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
        if (h.weekly == null) {
          final weekday = day.weekday - 1;
          (loggedOn[e.habitId] ??= List.filled(7, 0))[weekday]++;
          (doneOn[e.habitId] ??= List.filled(7, 0))[weekday] += isDone ? 1 : 0;
        }
      }
    }

    final slips = <({String name, int weekday, int rate, int usual})>[];
    for (final MapEntry(key: id, value: days) in loggedOn.entries) {
      final ticks = doneOn[id]!;
      final total = days.fold(0, (a, b) => a + b);
      final usual = ticks.fold(0, (a, b) => a + b) * 100 / total;
      int? worst;
      double? lowest;
      for (var i = 0; i < 7; i++) {
        if (days[i] < YearHeatmap._minDays) continue;
        final rate = ticks[i] * 100 / days[i];
        if (lowest == null || rate < lowest) (worst, lowest) = (i, rate);
      }
      if (worst != null && usual - lowest! >= YearHeatmap._minDrop) {
        slips.add((name: names[id] ?? '', weekday: worst, rate: lowest.round(), usual: usual.round()));
      }
    }
    slips.sort((a, b) => (a.rate - a.usual).compareTo(b.rate - b.usual));
    return _HeatmapData(done: done, logged: logged, allDone: allDone, allLogged: allLogged, slips: slips);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(
      context,
      (s) => (s.habitsRevision, s.entriesRevision, s.today, s.restWeekends, s.holidays),
    );
    final data = _dataFor(state);

    final label = capsLabel(p.inkMuted);
    final title = data.allLogged == 0
        ? 'THE YEAR'
        : 'THE YEAR  ·  ${(data.allDone * 100 / data.allLogged).round()}% OF RITUALS DONE';
    final topSlips = data.slips.take(YearHeatmap._findings).toList();
    return LayoutBuilder(
      builder: (context, c) {
        final stacked = YearHeatmap._isStacked(c.maxWidth);
        final grid = YearHeatmap._gridWidth(c.maxWidth);
        final gridWidget = _Grid(
          year: widget.year,
          today: state.today,
          width: grid,
          done: data.done,
          logged: data.logged,
        );
        if (stacked) {
          final gridHeight = YearHeatmap._gridHeight(widget.year, grid);
          return Tile(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: label),
                const SizedBox(height: 18),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: grid, height: gridHeight, child: gridWidget),
                ),
                const SizedBox(height: 20),
                Text('WHERE THINGS SLIP', style: label),
                const SizedBox(height: 12),
                _Slips(slips: topSlips),
              ],
            ),
          );
        }
        return Tile(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PixelRow(
                children: [
                  SizedBox(width: grid, child: Text(title, style: label)),
                  const SizedBox(width: YearHeatmap._between),
                  Expanded(child: Text('WHERE THINGS SLIP', style: label)),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: YearHeatmap._bodyHeight(widget.year, c.maxWidth),
                child: PixelRow(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: grid, child: gridWidget),
                    const SizedBox(width: YearHeatmap._between),
                    Expanded(child: _Slips(slips: topSlips)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.year, required this.today, required this.width, required this.done, required this.logged});

  final int year;
  final DateTime today;
  final double width;
  final Map<String, int> done, logged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const gap = YearHeatmap._gap, top = YearHeatmap._monthsHeight, left = YearHeatmap._labelWidth;
    final cell = YearHeatmap._cell(year, width);
    final step = cell + gap;
    final columns = [for (var m = 1; m <= 12; m++) YearHeatmap._columns(year, m)];
    final used = columns.fold(0.0, (a, c) => a + c * cell + (c - 1) * gap);
    // Spare width goes between the months, so they run the card's width.
    final monthGap = math.max(0.0, pixelFloor((width - left - used) / 11));
    const dayLine = 16.0;
    final dayStyle = TextStyle(fontFamily: Fonts.ui, fontSize: 12, height: dayLine / 12, color: p.inkMuted);
    // Rows shorter than a line of text name every other day, so no two
    // names touch.
    final everyOther = step < dayLine;
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    Color fill(double r) => r < 0.5 ? Color.lerp(p.missed, p.other, r * 2)! : Color.lerp(p.other, p.done, r * 2 - 1)!;

    final children = <Widget>[
      for (final (i, name) in dayNames.indexed)
        if (!everyOther || i.isEven)
          // Centred on its row, whatever the row's height.
          Positioned(left: 0, top: top + i * step + (cell - dayLine) / 2, child: Text(name, style: dayStyle)),
    ];
    var x = left;
    for (var month = 1; month <= 12; month++) {
      children.add(
        Positioned(left: x, top: 0, child: Text(shortMonth(month).toUpperCase(), style: capsLabel(p.inkMuted))),
      );
      final skipped = DateTime(year, month).weekday - 1;
      for (var d = 1; d <= DateUtils.getDaysInMonth(year, month); d++) {
        final day = DateTime(year, month, d);
        final at = skipped + d - 1;
        final key = dateKey(day);
        final count = logged[key];
        children.add(
          Positioned(
            left: x + (at ~/ 7) * step,
            top: top + (at % 7) * step,
            width: cell,
            height: cell,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: count == null
                    ? p.empty.withValues(alpha: day.isAfter(today) ? 0.25 : 0.55)
                    : fill((done[key] ?? 0) / count),
                border: day == today ? Border.all(color: p.ink, width: 2) : null,
              ),
            ),
          ),
        );
      }
      x += columns[month - 1] * cell + (columns[month - 1] - 1) * gap + monthGap;
    }
    return Stack(clipBehavior: Clip.none, children: children);
  }
}

class _Slips extends StatelessWidget {
  const _Slips({required this.slips});

  final List<({String name, int weekday, int rate, int usual})> slips;

  static const _weekdays = ['Mondays', 'Tuesdays', 'Wednesdays', 'Thursdays', 'Fridays', 'Saturdays', 'Sundays'];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(fontFamily: Fonts.body, fontSize: 14, fontWeight: FontWeight.w500, color: p.ink);
    final muted = TextStyle(color: p.inkMuted);
    if (slips.isEmpty) return Text('Nothing stands out yet.', style: style.copyWith(color: p.inkMuted));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in slips)
          SizedBox(
            height: YearHeatmap._findingHeight,
            child: Text.rich(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              TextSpan(
                style: style,
                children: [
                  TextSpan(text: s.name),
                  TextSpan(text: ' slips on ', style: muted),
                  TextSpan(text: _weekdays[s.weekday]),
                  TextSpan(text: '  ${s.rate}%, usually ${s.usual}%', style: muted),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
