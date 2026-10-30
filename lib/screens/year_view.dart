import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/oklch.dart';
import '../widgets/tile.dart';

/// The year at a glance: each ritual's month percentages side by side, then
/// the year so far. Months are worked out as on their own tabs (ticks out
/// of logged days).
class YearView extends StatelessWidget {
  const YearView({super.key, required this.year});

  final int year;

  /// The smallest a cell gets before the page scrolls instead.
  static const _minCell = 24.0;

  /// [text]'s height in [style], as it's drawn here, wrapping at [width].
  static double _line(BuildContext context, TextStyle style, {String text = 'X', double width = double.infinity}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
      maxLines: 2,
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// The cell height whose rows, each as tall as it or its name, add up to
  /// [room]; at least [_minCell].
  static double _fill(double room, List<double> names) {
    final sorted = [...names]..sort();
    // Rows whose names stand taller than the cell keep their names' height;
    // the cell shares out what's left among the rest.
    for (var tall = 0; tall < sorted.length; tall++) {
      final rest = sorted.length - tall;
      final cell = (room - sorted.skip(rest).fold(0.0, (a, b) => a + b)) / rest;
      if (cell >= sorted[rest - 1]) return math.max(cell, _minCell);
    }
    return _minCell;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) => _build(context, c.maxHeight));

  Widget _build(BuildContext context, double height) {
    final state = AppScope.watch(context, (s) => (s.habitsRevision, s.entriesRevision, s.today));
    final header = TextStyle(
      fontSize: 12,
      letterSpacing: 1.2,
      fontWeight: FontWeight.w500,
      color: context.palette.inkMuted,
    );

    // Every ritual on a saved list this year, newest names and order first.
    final rituals = <int, Habit>{};
    final inMonth = <int, Set<int>>{};
    for (var m = 12; m >= 1; m--) {
      if (!state.isShownMonth(year, m) || state.isPreviewMonth(year, m)) continue;
      final list = state.habitsFor(year, m);
      inMonth[m] = {for (final h in list) h.id};
      for (final h in list) {
        rituals.putIfAbsent(h.id, () => h);
      }
    }
    final sleep = state.sleepHabitsFor(year, state.isFutureMonth(year, 12) ? state.today.month : 12);
    final empty = TextStyle(fontFamily: Fonts.body, fontSize: 15, color: context.palette.inkMuted);

    // Cells as tall as fills the window with both cards, as on a month's
    // tab: the rest is the page's and cards' padding and borders, titles,
    // month names, the rule above each total and the rows' gaps.
    final title = (2 * (24 + 1)) + _line(context, header) + 18;
    final table = title + _line(context, _Table.labelStyle(context.palette)) + 10 + 17;
    // A name on two lines keeps its row at least that tall.
    double name(String text, {bool total = false}) => _line(
      context,
      _Table.nameStyle(context.palette, total: total),
      text: text,
      width: _Table._nameWidth,
    );
    final names = [
      if (rituals.isNotEmpty) ...[for (final h in rituals.values) name(h.name), name('All rituals', total: true)],
      for (final h in sleep) name(h.name),
      name('Whole schedule', total: true),
    ];
    final chrome = 32 + 20 + (rituals.isEmpty ? title + 48 + _line(context, empty) : table) + table + names.length * 8;
    final cell = _fill(height - chrome, names);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tile(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('RITUALS  ·  ${rituals.length}', style: header),
                const SizedBox(height: 18),
                if (rituals.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text('No rituals logged in $year.', style: empty),
                  )
                else
                  _Table(
                    year: year,
                    habits: rituals.values.toList(),
                    has: (h, m) => inMonth[m]?.contains(h.id) ?? false,
                    // Months before a ritual was first added fade like future ones.
                    notYet: (h, m) =>
                        !state.store.habitBeforeYear(h.id, year) &&
                        !inMonth.entries.any((e) => e.key <= m && e.value.contains(h.id)),
                    totalLabel: 'All rituals',
                    cell: cell,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Tile(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SLEEP SCHEDULE  ·  ${sleep.length}', style: header),
                const SizedBox(height: 18),
                _Table(year: year, habits: sleep, has: (_, _) => true, totalLabel: 'Whole schedule', cell: cell),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ticks and logged days, added up.
class _Score {
  int done = 0, logged = 0;

  void add(_Score other) {
    done += other.done;
    logged += other.logged;
  }

  double? get ratio => logged == 0 ? null : done / logged;
}

class _Table extends StatelessWidget {
  const _Table({
    required this.year,
    required this.habits,
    required this.has,
    this.notYet,
    required this.totalLabel,
    required this.cell,
  });

  final int year;
  final List<Habit> habits;

  /// Whether the ritual was on the month's list.
  final bool Function(Habit, int month) has;

  /// Whether the month is before the ritual was first added.
  final bool Function(Habit, int month)? notYet;
  final String totalLabel;

  /// Each cell's height.
  final double cell;

  static const _nameWidth = 240.0;

  static TextStyle nameStyle(Palette p, {bool total = false}) => TextStyle(
    fontFamily: Fonts.body,
    fontSize: 14,
    fontWeight: total ? FontWeight.w600 : FontWeight.w500,
    color: p.ink,
  );

  static TextStyle labelStyle(Palette p) =>
      TextStyle(fontFamily: Fonts.ui, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: p.inkMuted);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.habitsRevision, s.entriesRevision, s.today));

    // Only the months since you started; the year's total keeps its place.
    final shown = state.shownMonths(year);

    _Score score(Habit h, int m) {
      final s = _Score();
      if (!has(h, m)) return s;
      final (done, logged) = state.scoreOf(year, m, h);
      s.done = done;
      s.logged = logged;
      return s;
    }

    final scores = [
      for (final h in habits) [for (final m in shown) score(h, m)],
    ];
    _Score sum(Iterable<_Score> all) => all.fold(_Score(), (a, b) => a..add(b));
    final monthTotals = [for (var i = 0; i < shown.length; i++) sum(scores.map((row) => row[i]))];

    final label = labelStyle(p);

    Widget row(String name, List<_Score> months, {Habit? habit, bool total = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: _nameWidth,
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: nameStyle(p, total: total),
              ),
            ),
            for (final (i, m) in shown.indexed)
              Expanded(
                child: _Cell(
                  ratio: months[i].ratio,
                  height: cell,
                  future: habit != null && (notYet?.call(habit, m) ?? false),
                ),
              ),
            if (shown.length < 12) Spacer(flex: 12 - shown.length),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: _Cell(ratio: sum(months).ratio, height: cell, strong: true),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: _nameWidth),
            for (final m in shown)
              Expanded(
                child: Center(child: Text(monthNames[m - 1].substring(0, 3).toUpperCase(), style: label)),
              ),
            if (shown.length < 12) Spacer(flex: 12 - shown.length),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Center(child: Text(year == state.today.year ? 'YEAR TO DATE' : 'YEAR', style: label)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final (i, h) in habits.indexed) row(h.name, scores[i], habit: h),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ColoredBox(
            color: p.border,
            child: const SizedBox(height: 1, width: double.infinity),
          ),
        ),
        row(totalLabel, monthTotals, total: true),
      ],
    );
  }
}

/// A percentage on a square tinted by how high it is, from missed through
/// other to done; a dash when nothing was logged.
class _Cell extends StatelessWidget {
  const _Cell({required this.ratio, required this.height, this.future = false, this.strong = false});

  final double? ratio;
  final double height;
  final bool future;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final r = ratio;
    // 0% is the missed colour, 50% the other, 100% done.
    final fill = r == null
        ? p.empty.withValues(alpha: future ? 0.25 : 0.55)
        : r < 0.5
        ? Color.lerp(p.missed, p.other, r * 2)!
        : Color.lerp(p.other, p.done, r * 2 - 1)!;
    return Padding(
      // The year's total ends flush with the rule beneath it.
      padding: EdgeInsets.only(left: 4, right: strong ? 0 : 4),
      child: AnimatedContainer(
        duration: Motion.morph,
        curve: Motion.morphCurve,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: fill),
        child: Text(
          r == null ? '–' : '${(r * 100).round()}%',
          style: TextStyle(
            fontFamily: Fonts.ui,
            fontSize: strong ? 15 : 13.5,
            fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
            color: r == null
                ? p.inkMuted.withValues(alpha: future ? 0.25 : 0.5)
                : (contrast(fill, p.onAccent) >= contrast(fill, p.ink) ? p.onAccent : p.ink),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
