import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/pixels.dart';
import '../theme/tokens.dart';
import '../widgets/tile.dart';

/// The year day by day, each month its own block, tinted by the share of
/// its rituals done, beside the rituals that slip most on one weekday.
class YearHeatmap extends StatelessWidget {
  const YearHeatmap({super.key, required this.year, required this.rituals});

  final int year;

  /// The rituals on each month's list, by month.
  final Map<int, Set<int>> rituals;

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

  static int _columns(int year, int month) {
    final skipped = DateTime(year, month).weekday - 1;
    return (skipped + DateUtils.getDaysInMonth(year, month) - 1) ~/ 7 + 1;
  }

  static double _gridWidth(double width) => pixelFloor((width - 2 * _tileInset - _between) * 0.7);

  static double _cell(int year, double gridWidth) {
    var columns = 0;
    for (var m = 1; m <= 12; m++) {
      columns += _columns(year, m);
    }
    final room = gridWidth - _labelWidth - 11 * _monthGap - (columns - 12) * _gap;
    return pixelFloor(room / columns).clamp(8.0, 40.0);
  }

  static double _bodyHeight(int year, double width) {
    final cell = _cell(year, _gridWidth(width));
    final grid = _monthsHeight + 7 * cell + 6 * _gap;
    return grid > _findings * _findingHeight ? grid : _findings * _findingHeight;
  }

  /// The card's height across [width], with its title of [titleHeight].
  static double heightFor(int year, double width, double titleHeight) =>
      2 * _tileInset + titleHeight + 18 + _bodyHeight(year, width);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.habitsRevision, s.entriesRevision, s.today));

    final done = <String, int>{}, logged = <String, int>{};
    final doneOn = <int, List<int>>{}, loggedOn = <int, List<int>>{};
    final names = <int, String>{};
    var allDone = 0, allLogged = 0;
    for (final MapEntry(key: month, value: ids) in rituals.entries) {
      for (final h in state.habitsFor(year, month)) {
        names[h.id] = h.name;
      }
      for (final e in state.store.entriesInMonth(year, month)) {
        // Counted as a month's tab does: other days aren't logged.
        if (!ids.contains(e.habitId) || e.status == HabitStatus.none || e.status == HabitStatus.other) continue;
        final weekday = DateTime.parse(e.day).weekday - 1;
        final isDone = e.status == HabitStatus.done;
        logged[e.day] = (logged[e.day] ?? 0) + 1;
        (loggedOn[e.habitId] ??= List.filled(7, 0))[weekday]++;
        (doneOn[e.habitId] ??= List.filled(7, 0))[weekday] += isDone ? 1 : 0;
        allLogged++;
        if (isDone) {
          done[e.day] = (done[e.day] ?? 0) + 1;
          allDone++;
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
        if (days[i] < _minDays) continue;
        final rate = ticks[i] * 100 / days[i];
        if (lowest == null || rate < lowest) (worst, lowest) = (i, rate);
      }
      if (worst != null && usual - lowest! >= _minDrop) {
        slips.add((name: names[id] ?? '', weekday: worst, rate: lowest.round(), usual: usual.round()));
      }
    }
    slips.sort((a, b) => (a.rate - a.usual).compareTo(b.rate - b.usual));

    final label = capsLabel(p.inkMuted);
    final title = allLogged == 0
        ? 'THE YEAR'
        : 'THE YEAR  ·  ${(allDone * 100 / allLogged).round()}% OF RITUALS DONE';
    return LayoutBuilder(
      builder: (context, c) {
        final grid = _gridWidth(c.maxWidth);
        return Tile(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PixelRow(
                children: [
                  SizedBox(width: grid, child: Text(title, style: label)),
                  const SizedBox(width: _between),
                  Text('WHERE THINGS SLIP', style: label),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: _bodyHeight(year, c.maxWidth),
                child: PixelRow(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: grid,
                      child: _Grid(year: year, today: state.today, width: grid, done: done, logged: logged),
                    ),
                    const SizedBox(width: _between),
                    Expanded(child: _Slips(slips: slips.take(_findings).toList())),
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
    final monthGap = pixelFloor((width - left - used) / 11);
    final dayStyle = TextStyle(fontFamily: Fonts.ui, fontSize: 12, color: p.inkMuted);
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    Color fill(double r) => r < 0.5 ? Color.lerp(p.missed, p.other, r * 2)! : Color.lerp(p.other, p.done, r * 2 - 1)!;

    final children = <Widget>[
      for (final (i, name) in dayNames.indexed)
        Positioned(
          left: 0,
          top: top + i * step,
          height: cell,
          child: Center(child: Text(name, style: dayStyle)),
        ),
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
                borderRadius: BorderRadius.circular(cell >= 16 ? 5 : 3),
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
