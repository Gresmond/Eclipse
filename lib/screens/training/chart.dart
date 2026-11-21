part of '../training_view.dart';

// Chart

class _ChartTile extends StatefulWidget {
  const _ChartTile();

  @override
  State<_ChartTile> createState() => _ChartTileState();
}

class _ChartTileState extends State<_ChartTile> {
  /// An exercise uid or `g:group` the legend is hovered on.
  String? _focus;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.training.revision, s.today));
    final log = state.training;
    final today = state.today;
    final months = log.range.months;
    final from = months == null ? null : monthsBefore(today, months);
    final all = log.points(from: from);

    // Stable look per exercise: its place among its group's in the order
    // first logged, so a new exercise never changes an older one's. Once the
    // dashes run out they start again with square points.
    final dash = <String, List<double>>{};
    final square = <String>{};
    final place = {for (final (i, uid) in log.loggedOrder.indexed) uid: i};
    for (final g in MuscleGroup.values) {
      final mine = log.exercises.where((e) => e.group == g && place.containsKey(e.uid)).toList()
        ..sort((a, b) => place[a.uid]!.compareTo(place[b.uid]!));
      for (final (i, e) in mine.indexed) {
        dash[e.uid] = _dashes[i % _dashes.length];
        if ((i ~/ _dashes.length).isOdd) square.add(e.uid);
      }
    }
    final percent = log.axis == TrainingAxis.change;
    final layout = log.layout;
    // A card of its own gives a bodyweight exercise its own scale, so it
    // shows in kg too; sharing a chart, reps would sit on a kg axis unless
    // weighted sets + a weigh-in let us chart total load in kg.
    final bodyweightShown = percent || layout == TrainingLayout.exercises;
    final visible = [
      for (final MapEntry(key: e, value: points) in all.entries)
        if (!log.hidden.contains(e.uid) && !log.hidden.contains('g:${e.group.name}'))
          _Series(
            e,
            points,
            groupColour(e.group, p),
            dash[e.uid] ?? const [],
            square: square.contains(e.uid),
            repsUnit: e.bodyweight && !log.usesTotalLoad(e),
          ),
    ]..sort(_bySeries);
    final series = [
      for (final s in visible)
        if (bodyweightShown || !s.repsUnit) s,
    ];
    final effectiveFocus = _focus != null &&
            series.any((s) => s.exercise.uid == _focus || 'g:${s.exercise.group.name}' == _focus)
        ? _focus
        : null;
    final start = series.isEmpty
        ? from ?? today
        : series.map((s) => s.points.first.day).reduce((a, b) => b.isBefore(a) ? b : a);
    final charted = all.keys.toList()
      ..sort((a, b) => a.group.index != b.group.index ? a.group.index - b.group.index : a.name.compareTo(b.name));
    final repsOnlyUids = {
      for (final e in charted)
        if (e.bodyweight && !log.usesTotalLoad(e)) e.uid,
    };
    final Widget body = switch (layout) {
      TrainingLayout.all => _Chart(series: series, from: start, to: today, percent: percent, focus: effectiveFocus),
      TrainingLayout.exercises => _CardGrid(
        minWidth: 240,
        minHeight: 196,
        children: [
          for (final s in series)
            _ExerciseCard(
              key: ValueKey(s.exercise.uid),
              series: s,
              from: start,
              to: today,
              percent: percent,
              focus: effectiveFocus,
            ),
        ],
      ),
      TrainingLayout.muscles => _CardGrid(
        minWidth: 320,
        minHeight: 268,
        children: [
          for (final g in MuscleGroup.values)
            if (visible.any((s) => s.exercise.group == g))
              _MuscleCard(
                key: ValueKey(g),
                group: g,
                series: [
                  for (final s in series)
                    if (s.exercise.group == g) s,
                ],
                from: start,
                to: today,
                percent: percent,
                focus: effectiveFocus,
              ),
        ],
      ),
    };

    return Tile(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final title = percent
                  ? 'Progress since ${from == null ? 'the start' : _shortDate(start, todayYear: today.year)}'
                  : 'Estimated one-rep max';
              final controls = Wrap(
                spacing: 10,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  SegmentedPills(
                    labels: [for (final l in TrainingLayout.values) l.label],
                    selected: layout.index,
                    compact: true,
                    onSelect: (i) => log.setLayout(TrainingLayout.values[i]),
                  ),
                  SegmentedPills(
                    labels: [for (final r in TrainingRange.values) r.label],
                    selected: log.range.index,
                    compact: true,
                    onSelect: (i) => log.setRange(TrainingRange.values[i]),
                  ),
                  SegmentedPills(
                    labels: const ['kg', '% change'],
                    selected: log.axis.index,
                    compact: true,
                    onSelect: (i) => log.setAxis(TrainingAxis.values[i]),
                  ),
                ],
              );
              if (box.maxWidth < 680) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TileHeader(fadeTitle: true, title: title),
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: controls),
                  ],
                );
              }
              return TileHeader(fadeTitle: true, title: title, trailingAtEnd: true, trailing: controls);
            },
          ),
          const SizedBox(height: 12),
          // Another layout, range or axis fades through, as another day does.
          Expanded(
            child: FadeThrough(
              layoutBuilder: FadeThrough.fill,
              child: KeyedSubtree(
                key: ValueKey((layout, log.range, log.axis, all.isEmpty)),
                child: all.isEmpty
                    ? Center(
                        child: Text(
                          log.exercises.isEmpty
                              ? 'Log a session below and your progress will show here.'
                              : 'Nothing logged in this range yet.',
                          style: _label(p, color: p.inkMuted),
                        ),
                      )
                    : body,
              ),
            ),
          ),
          if (charted.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Legend(
              exercises: charted,
              repsOnly: repsOnlyUids,
              dash: dash,
              square: square,
              hidden: log.hidden,
              bodyweightShown: bodyweightShown,
              onHover: (key) => setState(() => _focus = key),
              onToggle: log.toggleHidden,
            ),
          ],
        ],
      ),
    );
  }
}

/// Muscle groups in their order, then exercises by name.
int _bySeries(_Series a, _Series b) {
  final g = a.exercise.group.index.compareTo(b.exercise.group.index);
  return g != 0 ? g : a.exercise.name.compareTo(b.exercise.name);
}

String _pct(double v, {int decimals = 1, bool sign = true}) {
  final rounded = double.parse(v.toStringAsFixed(decimals));
  final clean = rounded.abs() < 1e-9 ? 0.0 : rounded;
  final prefix = sign && clean > 0 ? '+' : '';
  return '$prefix${clean.toStringAsFixed(decimals)}%';
}

/// [s]'s latest point as a card heads it: kg, reps, or % since its first.
String _latest(_Series s, {required bool percent}) {
  final first = s.points.first, last = s.points.last;
  if (percent) {
    final change = first.value <= 0 ? 0.0 : (last.value / first.value - 1) * 100;
    return _pct(change);
  }
  if (s.repsUnit) return '${_kg(last.value)} reps';
  return '${last.rough ? '≈ ' : ''}${_kg(last.value)} kg';
}

/// Cards in an even grid that fills the chart tile: as many rows and
/// columns as leave the fewest empty places with cards of about the shape
/// of [minWidth] by [minHeight], stretched to fill the tile. Cards never
/// get smaller than that; when they would, whole rows fill the tile's
/// height and the rest scroll.
///
/// Hiding or showing a card (from the legend) glides the others to their
/// new places and sizes as it fades; a window resize simply lays them out
/// again.
class _Series {
  _Series(this.exercise, this.points, this.colour, this.dash, {this.square = false, this.repsUnit = false});
  final Exercise exercise;

  /// Its points are squares, not circles.
  final bool square;
  final bool repsUnit;
  final List<TrainingPoint> points;
  final Color colour;
  final List<double> dash;

  bool focused(String? focus) => focus == null || focus == exercise.uid || focus == 'g:${exercise.group.name}';
}

