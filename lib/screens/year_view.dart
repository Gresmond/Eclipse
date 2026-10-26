import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/oklch.dart';
import '../widgets/tile.dart';

/// The year at a glance: each ritual's month percentages side by side, then
/// the year so far. Months are worked out as on their own tabs (ticks out
/// of logged days).
class YearView extends StatelessWidget {
  const YearView({super.key, required this.year});

  final int year;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.habitsRevision, s.entriesRevision, s.today));
    final header = TextStyle(
      fontSize: 11,
      letterSpacing: 1.4,
      fontWeight: FontWeight.w500,
      color: context.palette.inkMuted,
    );

    // Every ritual on a saved list this year, newest names and order first.
    final rituals = <int, Habit>{};
    final inMonth = <int, Set<int>>{};
    for (var m = 12; m >= 1; m--) {
      if (state.isFutureMonth(year, m) || state.isPreviewMonth(year, m)) continue;
      final list = state.habitsFor(year, m);
      inMonth[m] = {for (final h in list) h.id};
      for (final h in list) {
        rituals.putIfAbsent(h.id, () => h);
      }
    }
    final sleep = state.sleepHabitsFor(year, state.isFutureMonth(year, 12) ? state.today.month : 12);

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
                    child: Text(
                      'No rituals logged in $year.',
                      style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: context.palette.inkMuted),
                    ),
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
                _Table(year: year, habits: sleep, has: (_, _) => true, totalLabel: 'Whole schedule'),
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
  const _Table({required this.year, required this.habits, required this.has, this.notYet, required this.totalLabel});

  final int year;
  final List<Habit> habits;

  /// Whether the ritual was on the month's list.
  final bool Function(Habit, int month) has;

  /// Whether the month is before the ritual was first added.
  final bool Function(Habit, int month)? notYet;
  final String totalLabel;

  static const _nameWidth = 240.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.habitsRevision, s.entriesRevision, s.today));

    _Score score(Habit h, int m) {
      final s = _Score();
      if (state.isFutureMonth(year, m) || !has(h, m)) return s;
      final (done, logged) = state.scoreOf(year, m, h);
      s.done = done;
      s.logged = logged;
      return s;
    }

    final scores = [
      for (final h in habits) [for (var m = 1; m <= 12; m++) score(h, m)],
    ];
    _Score sum(Iterable<_Score> all) => all.fold(_Score(), (a, b) => a..add(b));
    final monthTotals = [for (var m = 0; m < 12; m++) sum(scores.map((row) => row[m]))];

    final label = TextStyle(
      fontFamily: Fonts.ui,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
      color: p.inkMuted,
    );

    Widget row(String name, List<_Score> months, {Habit? habit, bool total = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: _nameWidth,
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: Fonts.body,
                  fontSize: 13.5,
                  fontWeight: total ? FontWeight.w600 : FontWeight.w500,
                  color: p.ink,
                ),
              ),
            ),
            for (var m = 1; m <= 12; m++)
              Expanded(
                child: _Cell(
                  ratio: months[m - 1].ratio,
                  future: state.isFutureMonth(year, m) || (habit != null && (notYet?.call(habit, m) ?? false)),
                ),
              ),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: _Cell(ratio: sum(months).ratio, strong: true)),
          ],
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: _nameWidth),
            for (var m = 1; m <= 12; m++)
              Expanded(
                child: Center(
                  child: Text(
                    monthNames[m - 1].substring(0, 3).toUpperCase(),
                    style: label.copyWith(
                      color: state.isFutureMonth(year, m) ? p.inkMuted.withValues(alpha: 0.4) : p.inkMuted,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: Center(child: Text(year == state.today.year ? 'YEAR TO DATE' : 'YEAR', style: label)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final (i, h) in habits.indexed) row(h.name, scores[i], habit: h),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ColoredBox(
            color: p.tileBorder.withValues(alpha: 0.7),
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
  const _Cell({required this.ratio, this.future = false, this.strong = false});

  final double? ratio;
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
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: AnimatedContainer(
        duration: Motion.morph,
        curve: Motion.morphCurve,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: fill),
        child: Text(
          r == null ? '–' : '${(r * 100).round()}%',
          style: TextStyle(
            fontFamily: Fonts.ui,
            fontSize: strong ? 14 : 12.5,
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
