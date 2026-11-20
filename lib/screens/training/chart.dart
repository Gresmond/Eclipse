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
class _CardGrid extends StatefulWidget {
  const _CardGrid({required this.minWidth, required this.minHeight, required this.children});

  final double minWidth, minHeight;

  /// Each keyed, so it keeps its place and state as others come and go.
  final List<Widget> children;

  static const gap = 12.0;

  /// Columns, rows and each card's size for [count] cards in [box].
  static ({int columns, int rows, double width, double height}) layout(
    int count,
    Size box, {
    required double minWidth,
    required double minHeight,
  }) {
    if (count <= 0 || box.width <= 0 || box.height <= 0) {
      return (columns: 1, rows: math.max(1, count), width: math.max(0.0, box.width), height: math.max(0.0, minHeight));
    }
    final most = math.max(1, ((box.width + gap) / (minWidth + gap)).floor());
    double widthFor(int columns) => (box.width - gap * (columns - 1)) / columns;
    double fitHeight(int rows) => (box.height - gap * (rows - 1)) / rows;
    // Whole rows filling the height, for when the cards scroll.
    final shown = math.max(1, ((box.height + gap) / (minHeight + gap)).floor());
    final scrollHeight = math.max(minHeight, fitHeight(shown));
    final shape = minWidth / minHeight;
    final fits = [
      for (var c = 1; c <= most; c++)
        if (fitHeight((count / c).ceil()) >= minHeight) c,
    ];
    final columns = fits.isNotEmpty ? fits : [for (var c = 1; c <= most; c++) c];
    ({int columns, int rows, double width, double height})? best;
    double bestScore = double.infinity;
    for (final c in columns) {
      final rows = math.max(1, (count / c).ceil());
      final height = fits.isNotEmpty ? fitHeight(rows) : scrollHeight;
      final width = widthFor(c);
      // An empty place counts for more than a card a little off the shape.
      final score = (rows * c - count) + 2 * (math.log(width / height / shape)).abs();
      if (score < bestScore) {
        bestScore = score;
        best = (columns: c, rows: rows, width: pixelFloor(width), height: pixelFloor(height));
      }
    }
    return best!;
  }

  @override
  State<_CardGrid> createState() => _CardGridState();
}

class _CardGridState extends State<_CardGrid> {
  Size? _box;
  List<Key> _shown = const [];
  final _rects = <Key, Rect>{};

  /// Cards hidden, fading out where they were.
  final _leaving = <Key, ({Rect rect, Widget card})>{};
  final _cards = <Key, Widget>{};

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = box.biggest;
      final keys = [for (final c in widget.children) c.key!];
      final resized = _box != null && _box != size;
      final changed = _box != null && !listEquals(keys, _shown);
      if (resized) _leaving.clear();
      // Cards come in since the grid was first laid out fade in.
      final arriving = <Key>{};
      if (changed && !resized) {
        for (final k in _shown) {
          if (!keys.contains(k) && _rects[k] != null && _cards[k] != null) {
            _leaving[k] = (rect: _rects[k]!, card: _cards[k]!);
          }
        }
        for (final k in keys) {
          if (!_shown.contains(k)) arriving.add(k);
          _leaving.remove(k);
        }
      }
      _box = size;
      _shown = keys;

      final g = _CardGrid.layout(keys.length, size, minWidth: widget.minWidth, minHeight: widget.minHeight);
      const gap = _CardGrid.gap;
      for (final (i, c) in widget.children.indexed) {
        final column = i % g.columns, row = i ~/ g.columns;
        _rects[c.key!] = Rect.fromLTWH(
          pixelRound(column * (g.width + gap)),
          pixelRound(row * (g.height + gap)),
          g.width,
          g.height,
        );
        _cards[c.key!] = c;
      }
      final height = g.rows * g.height + (g.rows - 1) * gap;
      final glide = resized ? Duration.zero : context.themed(Motion.morph);
      return SingleChildScrollView(
        child: SizedBox(
          width: size.width,
          height: math.max(height, _leaving.values.fold(0.0, (h, l) => math.max(h, l.rect.bottom))),
          child: Stack(
            children: [
              // The same widgets as a shown card's, so its fade picks up
              // where it was.
              for (final MapEntry(key: k, value: l) in _leaving.entries)
                AnimatedPositioned.fromRect(
                  key: k,
                  rect: l.rect,
                  duration: glide,
                  curve: Motion.morphCurve,
                  child: Appear(
                    animate: false,
                    shown: false,
                    animateSize: false,
                    onHidden: () => setState(() => _leaving.remove(k)),
                    child: l.card,
                  ),
                ),
              for (final c in widget.children)
                AnimatedPositioned.fromRect(
                  key: c.key,
                  rect: _rects[c.key!]!,
                  duration: glide,
                  curve: Motion.morphCurve,
                  child: Appear(animate: arriving.contains(c.key), animateSize: false, child: c),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// The surface each card in [_CardGrid] sits on.
class _MiniCard extends StatelessWidget {
  const _MiniCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.borderSoft),
      ),
      child: child,
    );
  }
}

/// One exercise: its name and group, where it stands now, and its own chart.
class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({
    super.key,
    required this.series,
    required this.from,
    required this.to,
    required this.percent,
    required this.focus,
  });

  final _Series series;
  final DateTime from, to;
  final bool percent;
  final String? focus;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final e = series.exercise, first = series.points.first, last = series.points.last;
    final String since;
    if (series.points.length == 1) {
      since = 'One session so far';
    } else if (percent) {
      since = 'since ${_shortDate(first.day, todayYear: to.year)}';
    } else {
      final change = last.value - first.value;
      since =
          '${change >= 0 ? '+' : '−'}${_kg(change.abs())} ${series.repsUnit ? 'reps' : 'kg'} since ${_shortDate(first.day, todayYear: to.year)}';
    }
    return _MiniCard(
      child: PixelColumn(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PixelRow(
            children: [
              Expanded(
                child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _label(p, size: 15)),
              ),
              const SizedBox(width: 8),
              PixelFit(child: Text(e.group.label.toUpperCase(), style: capsLabel(series.colour))),
            ],
          ),
          const SizedBox(height: 4),
          // The figure gets a line to itself: beside it, a long one would push
          // the change off a narrow card.
          Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: RollingFigure(
                text: _latest(series, percent: percent),
                value: series.points.last.value,
                style: _label(p, size: 22, weight: FontWeight.w600),
              ),
            ),
          ),
          Text(
            since,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _label(p, size: 12, color: p.inkMuted),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _Chart(series: [series], from: from, to: to, percent: percent, focus: focus),
          ),
        ],
      ),
    );
  }
}

/// One muscle group: each of its exercises as a line on one chart, with a
/// key that tells them apart by dash.
class _MuscleCard extends StatelessWidget {
  const _MuscleCard({
    super.key,
    required this.group,
    required this.series,
    required this.from,
    required this.to,
    required this.percent,
    required this.focus,
  });

  final MuscleGroup group;

  /// The group's charted exercises; empty when all of them are bodyweight
  /// and the chart is in kg.
  final List<_Series> series;
  final DateTime from, to;
  final bool percent;
  final String? focus;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return _MiniCard(
      child: PixelColumn(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PixelFit(child: Text(group.label.toUpperCase(), style: capsLabel(groupColour(group, p)))),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 84),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final s in series)
                    PixelRow(
                      children: [
                        CustomPaint(
                          size: const Size(22, 10),
                          painter: _DashSample(s.colour, s.dash, square: s.square),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            s.exercise.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _label(p, size: 14),
                          ),
                        ),
                        const SizedBox(width: 8),
                        PixelFit(
                          child: RollingFigure(
                            text: _latest(s, percent: percent),
                            value: s.points.last.value,
                            style: _label(p, size: 14, color: p.inkMuted),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (series.isNotEmpty)
            Expanded(
              child: _Chart(series: series, from: from, to: to, percent: percent, focus: focus),
            ),
        ],
      ),
    );
  }
}

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

class _Chart extends StatefulWidget {
  const _Chart({required this.series, required this.from, required this.to, required this.percent, this.focus});

  final List<_Series> series;
  final DateTime from, to;
  final bool percent;
  final String? focus;

  @override
  State<_Chart> createState() => _ChartState();
}

class _ChartState extends State<_Chart> {
  Offset? _pointer;

  /// [_pointer] is where a finger last tapped, not where a mouse is.
  bool _touch = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      onHover: (e) => setState(() {
        _pointer = e.localPosition;
        _touch = false;
      }),
      onExit: (_) => setState(() {
        if (!_touch) _pointer = null;
      }),
      // No hover by touch: a tap shows what is under it, and stays until a
      // tap somewhere else.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (e.kind == PointerDeviceKind.mouse) return;
          setState(() {
            _pointer = e.localPosition;
            _touch = true;
          });
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _ChartPainter(
            series: widget.series,
            from: widget.from,
            to: widget.to,
            percent: widget.percent,
            focus: widget.focus,
            pointer: _pointer,
            touch: _touch,
            palette: p,
            textScaler: MediaQuery.textScalerOf(context),
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.series,
    required this.from,
    required this.to,
    required this.percent,
    required this.focus,
    required this.pointer,
    required this.touch,
    required this.palette,
    required this.textScaler,
  });

  final List<_Series> series;
  final DateTime from, to;
  final bool percent;
  final String? focus;
  final Offset? pointer;

  /// [pointer] is a finger's tap, which gets more room to miss by.
  final bool touch;
  final Palette palette;
  final TextScaler textScaler;

  static const _left = 52.0, _bottom = 26.0, _top = 6.0, _right = 20.0;

  double _value(_Series s, TrainingPoint pt) =>
      percent ? (s.points.first.value <= 0 ? 0.0 : (pt.value / s.points.first.value - 1) * 100) : pt.value;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final scale = math.max(1.0, textScaler.scale(12) / 12);
    final plot = Rect.fromLTRB(
      _left * scale,
      _top * scale,
      size.width - _right * scale,
      size.height - _bottom * scale,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    // Y range, padded a little and rounded to tidy ticks.
    var lo = double.infinity, hi = -double.infinity;
    for (final s in series) {
      for (final pt in s.points) {
        final v = _value(s, pt);
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    if (lo == double.infinity) {
      lo = 0;
      hi = percent ? 10 : 100;
    }
    if (percent) {
      lo = math.min(lo, 0);
      hi = math.max(hi, 0);
    }
    if (hi - lo < 1e-9) {
      lo -= 5;
      hi += 5;
    }
    final step = _niceStep((hi - lo) / 4);
    lo = (lo / step).floor() * step;
    hi = (hi / step).ceil() * step;

    final start = dateOnly(from), end = dateOnly(to);
    final span = daysBetween(start, end);
    double x(DateTime d) => plot.left + plot.width * (daysBetween(start, d) / math.max(1, span));
    double y(double v) => plot.bottom - plot.height * ((v - lo) / (hi - lo));

    // Grid and labels.
    final grid = Paint()
      ..color = p.border
      ..strokeWidth = 1;
    for (var v = lo; v <= hi + step / 2; v += step) {
      final yy = y(v);
      canvas.drawLine(Offset(plot.left, _crisp(yy)), Offset(plot.right, _crisp(yy)), grid);
      final text = percent ? _pct(v, decimals: step < 1 ? 1 : 0) : _kg(v);
      _text(canvas, text, Offset(plot.left - 10, yy), p.inkMuted, align: Alignment.centerRight);
    }
    if (percent && lo < 0 && hi > 0) {
      canvas.drawLine(
        Offset(plot.left, _crisp(y(0))),
        Offset(plot.right, _crisp(y(0))),
        Paint()
          ..color = p.inkMuted.withValues(alpha: 0.5)
          ..strokeWidth = 1,
      );
    }
    // Over more than one calendar year a date says which: on the first label
    // and on the first of each new year. Fewer labels where they would crowd.
    final years = start.year != end.year || start.year != to.year;
    final ticks = math.min(span, (plot.width / (years ? 90 : 60)).floor()).clamp(0, 6);
    int? year;
    for (var i = 0; i <= ticks; i++) {
      final d = DateTime(start.year, start.month, start.day + (span * i / math.max(1, ticks)).round());
      final text = years && d.year != year ? '${_shortDate(d)} ${d.year}' : _shortDate(d);
      year = d.year;
      _text(canvas, text, Offset(x(d), plot.bottom + 8), p.inkMuted, align: Alignment.topCenter);
    }

    // Unfocused series faded under the focused. Within each, lines, then
    // hollow points, then solid ones, so a hollow centre never covers a
    // solid point on the same spot.
    final hits = <_Hit>[];
    final lines = <(_Series, List<Offset>)>[];
    final dense = <_Series>{};
    for (final faded in const [true, false]) {
      final drawn = [
        for (final s in series)
          if (s.focused(focus) != faded) (s, [for (final pt in s.points) Offset(x(pt.day), y(_value(s, pt)))]),
      ];
      Color colour(_Series s) => faded ? s.colour.withValues(alpha: 0.18) : s.colour;
      for (final (s, pts) in drawn) {
        if (pts.length > 1) _stroke(canvas, pts, s.dash, colour(s), focus != null && !faded ? 2.6 : 2);
      }
      // A line whose points would touch goes without them; one shows when
      // it is pointed at.
      for (final (s, pts) in drawn) {
        for (var i = 0; i + 1 < pts.length; i++) {
          if ((pts[i + 1] - pts[i]).distance < 8) dense.add(s);
        }
      }
      for (final rough in const [true, false]) {
        for (final (s, pts) in drawn) {
          if (dense.contains(s)) continue;
          for (final (i, o) in pts.indexed) {
            if (s.points[i].rough != rough) continue;
            _dot(canvas, o, colour(s), p.tile, rough: rough, square: s.square);
          }
        }
      }
      if (!faded) {
        lines.addAll(drawn);
        for (final (s, pts) in drawn) {
          for (final (i, o) in pts.indexed) {
            hits.add(_Hit(s, s.points[i], o));
          }
        }
      }
    }
    final at = pointer;
    if (at == null || hits.isEmpty) return;
    var nearest = hits.reduce((a, b) => (b.at - at).distance < (a.at - at).distance ? b : a);
    if ((nearest.at - at).distance >= (touch ? 24 : 16)) {
      // Not on a point: the line under the pointer, and its session nearest
      // in date.
      (_Series, List<Offset>)? line;
      var reach = touch ? 16.0 : 8.0;
      for (final (s, pts) in lines) {
        for (var i = 0; i + 1 < pts.length; i++) {
          final d = _distanceToSegment(at, pts[i], pts[i + 1]);
          if (d < reach) {
            reach = d;
            line = (s, pts);
          }
        }
      }
      if (line == null) return;
      final (s, pts) = line;
      var i = 0;
      for (var j = 1; j < pts.length; j++) {
        if ((pts[j].dx - at.dx).abs() < (pts[i].dx - at.dx).abs()) i = j;
      }
      nearest = _Hit(s, s.points[i], pts[i]);
    }
    // Every point of that day whose dot overlaps the nearest one.
    final stack = [
      for (final h in hits)
        if (h.point.day == nearest.point.day && (h.at - nearest.at).distance < 7.2) h,
    ];
    for (final h in stack) {
      if (!dense.contains(h.series)) continue;
      _dot(canvas, h.at, h.series.colour, p.tile, rough: h.point.rough, square: h.series.square);
    }
    _tooltip(canvas, size, stack, year: years);
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final length = ab.distanceSquared;
    if (length == 0) return (p - a).distance;
    final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / length).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  /// One point: a circle, or a square for a series past the last dash style.
  /// A [rough] one is hollow.
  static void _dot(Canvas canvas, Offset o, Color colour, Color tile, {required bool rough, required bool square}) {
    if (square) {
      // Straight edges, so on whole pixels.
      final side = rough ? 8.0 : 6.0;
      final rect = Rect.fromCenter(center: Offset(pixelRound(o.dx), pixelRound(o.dy)), width: side, height: side);
      canvas.drawRect(rect, Paint()..color = colour);
      if (rough) canvas.drawRect(rect.deflate(2), Paint()..color = tile);
      return;
    }
    canvas.drawCircle(o, 3.6, Paint()..color = rough ? tile : colour);
    if (rough) {
      // A filled ring: a stroked circle comes out jagged under Impeller on Linux.
      final circle = Rect.fromCircle(center: o, radius: 4.4);
      final ring = RRect.fromRectAndRadius(circle, Radius.circular(circle.shortestSide / 2));
      canvas.drawDRRect(ring, ring.deflate(1.6), Paint()..color = colour);
    }
  }

  /// One block per hit (name, date and value, the day's sets), stacked.
  /// With [year], dates say which year.
  void _tooltip(Canvas canvas, Size size, List<_Hit> stack, {required bool year}) {
    final p = palette;
    TextPainter line(String text, {Color? colour, bool title = false}) => TextPainter(
      text: TextSpan(
        text: text,
        style: title ? _label(p, weight: FontWeight.w600, color: colour) : _label(p, size: 14, color: p.inkMuted),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    final blocks = <List<TextPainter>>[];
    try {
      for (final hit in stack) {
        final pt = hit.point, s = hit.series, e = s.exercise;
        final value = s.repsUnit
            ? '${_kg(pt.value)} reps'
            : '${pt.rough ? '≈ ' : ''}${_kg(pt.value)} kg${pt.rough ? '  (±5–10%)' : ''}';
        final change = percent && s.points.first != pt ? '  ·  ${_pct(_value(s, pt))}' : '';
        String describeSet(TrainingSet set) {
          final base = e.bodyweight
              ? (set.weight != null && set.weight! > 0
                    ? '+${_kg(set.weight!)} kg × ${set.reps}'
                    : '${set.reps} reps')
              : '${_kg(set.weight ?? 0)} × ${set.reps}';
          return set.rpe == null ? base : '$base @ RPE ${_kg(set.rpe!)}';
        }
        final notes = [
          for (final (i, set) in pt.sets.indexed)
            if ((set.note ?? '').trim().isNotEmpty)
              pt.sets.length == 1 ? set.note!.trim() : 'Set ${i + 1}: ${set.note!.trim()}',
        ];
        blocks.add([
          line(e.name, colour: s.colour, title: true),
          line('${_shortDate(pt.day)}${year ? ' ${pt.day.year}' : ''}  ·  $value$change'),
          // What was actually done that day: the line itself goes set by set.
          line(pt.sets.map(describeSet).join(',  ')),
          for (final n in notes) line(n),
        ]);
      }
      const gap = 2.0, between = 10.0;
      double blockHeight(List<TextPainter> b) => b.fold(0.0, (h, t) => h + t.height) + gap * (b.length - 1);
      final widest = blocks.expand((b) => b).map((t) => t.width).reduce(math.max);
      final w = pixelCeil(widest + 24),
          h = pixelCeil(blocks.fold(0.0, (h, b) => h + blockHeight(b)) + between * (blocks.length - 1) + 16);
      final anchor = stack.first.at;
      var origin = anchor + const Offset(12, -12) - Offset(0, h);
      if (origin.dx + w > size.width) origin = Offset(anchor.dx - 12 - w, origin.dy);
      if (origin.dy < 0) origin = Offset(origin.dx, anchor.dy + 12);
      // A wide or tall one still has to stay on the chart.
      if (origin.dx < 0) origin = Offset(0, origin.dy);
      if (origin.dy + h > size.height) origin = Offset(origin.dx, math.max(0, size.height - h));
      origin = Offset(pixelRound(origin.dx), pixelRound(origin.dy));
      final box = RRect.fromRectAndRadius(origin & Size(w, h), const Radius.circular(12));
      canvas.drawShadow(Path()..addRRect(box), p.shadow.withValues(alpha: 0.4), 6, false);
      canvas.drawRRect(box, Paint()..color = p.tile);
      canvas.drawRRect(
        box.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = p.tileBorder,
      );
      for (final hit in stack) {
        canvas.drawCircle(hit.at, 5.5, Paint()..color = hit.series.colour.withValues(alpha: 0.3));
      }
      var top = origin.dy + 8;
      for (final block in blocks) {
        for (final t in block) {
          t.paint(canvas, Offset(origin.dx + 12, top));
          top += t.height + gap;
        }
        top += between - gap;
      }
    } finally {
      for (final block in blocks) {
        for (final t in block) {
          t.dispose();
        }
      }
    }
  }

  static double _niceStep(double raw) {
    if (raw <= 0) return 1;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final f = raw / mag;
    return (f <= 1
            ? 1
            : f <= 2
            ? 2
            : f <= 2.5
            ? 2.5
            : f <= 5
            ? 5
            : 10) *
        mag;
  }

  /// Where a one-wide line goes to fill the row of pixels nearest [at], rather
  /// than blur across two.
  static double _crisp(double at) => pixelRound(at - 0.5) + 0.5;

  /// Draws lines through [pts], dashed if [dash] has any lengths. Impeller on
  /// Linux leaves stroked paths jagged, but smooths lines. They overlap where
  /// they meet, so a see-through colour draws them as one on a layer.
  static void _stroke(Canvas canvas, List<Offset> pts, List<double> dash, Color colour, double width) {
    final fading = colour.a < 1;
    if (fading) {
      var bounds = Rect.fromPoints(pts.first, pts.first);
      for (final o in pts) {
        bounds = bounds.expandToInclude(Rect.fromPoints(o, o));
      }
      canvas.saveLayer(bounds.inflate(width), Paint()..color = Color.fromRGBO(0, 0, 0, colour.a));
    }
    final paint = Paint()
      ..color = colour.withValues(alpha: 1)
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    var i = 0;
    var left = dash.isEmpty ? double.infinity : dash.first;
    for (var s = 0; s + 1 < pts.length; s++) {
      final a = pts[s], along = pts[s + 1] - a;
      final length = along.distance;
      var at = 0.0;
      while (at < length) {
        final step = math.min(left, length - at);
        if (i.isEven) canvas.drawLine(a + along * (at / length), a + along * ((at + step) / length), paint);
        at += step;
        left -= step;
        if (left <= 0) {
          i++;
          left = dash[i % dash.length];
        }
      }
    }
    if (fading) canvas.restore();
  }

  void _text(Canvas canvas, String text, Offset at, Color colour, {required Alignment align}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: _label(palette, size: 12, color: colour),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    try {
      final dx = switch (align) {
        Alignment.centerRight => -tp.width,
        _ => -tp.width / 2,
      };
      final dy = align == Alignment.centerRight ? -tp.height / 2 : 0.0;
      tp.paint(canvas, at + Offset(dx, dy));
    } finally {
      tp.dispose();
    }
  }

  static bool _sameSeries(List<_Series> a, List<_Series> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final sa = a[i], sb = b[i];
      if (sa.exercise.uid != sb.exercise.uid ||
          sa.exercise.name != sb.exercise.name ||
          sa.exercise.bodyweight != sb.exercise.bodyweight ||
          sa.repsUnit != sb.repsUnit ||
          sa.colour != sb.colour ||
          sa.square != sb.square ||
          !listEquals(sa.dash, sb.dash) ||
          (!identical(sa.points, sb.points) && !_samePoints(sa.points, sb.points))) {
        return false;
      }
    }
    return true;
  }

  static bool _samePoints(List<TrainingPoint> a, List<TrainingPoint> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final pa = a[i], pb = b[i];
      if (pa.day != pb.day || pa.value != pb.value || pa.rough != pb.rough || pa.sets.length != pb.sets.length) {
        return false;
      }
      for (var j = 0; j < pa.sets.length; j++) {
        final ca = pa.sets[j], cb = pb.sets[j];
        if (ca.uid != cb.uid || ca.weight != cb.weight || ca.reps != cb.reps || ca.rpe != cb.rpe || ca.note != cb.note) {
          return false;
        }
      }
    }
    return true;
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      from != old.from ||
      to != old.to ||
      percent != old.percent ||
      focus != old.focus ||
      pointer != old.pointer ||
      touch != old.touch ||
      textScaler != old.textScaler ||
      (!identical(palette, old.palette) && !palette.sameColours(old.palette)) ||
      !_sameSeries(series, old.series);
}

class _Hit {
  _Hit(this.series, this.point, this.at);
  final _Series series;
  final TrainingPoint point;
  final Offset at;
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.exercises,
    required this.repsOnly,
    required this.dash,
    required this.square,
    required this.hidden,
    required this.bodyweightShown,
    required this.onHover,
    required this.onToggle,
  });

  final List<Exercise> exercises;
  final Set<String> repsOnly;
  final Map<String, List<double>> dash;

  /// Exercises whose points are squares.
  final Set<String> square;
  final Set<String> hidden;

  /// Bodyweight exercises are charted: in % change, or on cards of their own.
  final bool bodyweightShown;
  final ValueChanged<String?> onHover;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final groups = <MuscleGroup, List<Exercise>>{};
    for (final e in exercises) {
      (groups[e.group] ??= []).add(e);
    }
    return Wrap(
      spacing: 18,
      runSpacing: 6,
      children: [
        for (final MapEntry(key: g, value: list) in groups.entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _LegendItem(
                keyName: 'g:${g.name}',
                off: hidden.contains('g:${g.name}'),
                onHover: onHover,
                onToggle: onToggle,
                child: PixelFit(child: Text(g.label.toUpperCase(), style: capsLabel(groupColour(g, p)))),
              ),
              for (final e in list)
                _LegendItem(
                  keyName: e.uid,
                  off:
                      hidden.contains(e.uid) ||
                      hidden.contains('g:${g.name}') ||
                      (!bodyweightShown && repsOnly.contains(e.uid)),
                  onHover: onHover,
                  onToggle: onToggle,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CustomPaint(
                        size: const Size(22, 10),
                        painter: _DashSample(
                          groupColour(g, p),
                          dash[e.uid] ?? const [],
                          square: square.contains(e.uid),
                        ),
                      ),
                      const SizedBox(width: 6),
                      PixelFit(child: Text(e.name, style: _label(p, size: 14))),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.keyName,
    required this.off,
    required this.onHover,
    required this.onToggle,
    required this.child,
  });

  final String keyName;
  final bool off;
  final ValueChanged<String?> onHover;
  final ValueChanged<String> onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => onHover(keyName),
    onExit: (_) => onHover(null),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onToggle(keyName),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: AnimatedOpacity(opacity: off ? 0.35 : 1, duration: Motion.hover, curve: Motion.hoverCurve, child: child),
      ),
    ),
  );
}

class _DashSample extends CustomPainter {
  _DashSample(this.colour, this.dash, {required this.square});
  final Color colour;
  final List<double> dash;

  /// Shows the square point that tells it from the same dash with circles.
  final bool square;

  @override
  void paint(Canvas canvas, Size size) {
    _ChartPainter._stroke(
      canvas,
      [Offset(1, size.height / 2), Offset(size.width - 1, size.height / 2)],
      dash,
      colour,
      2,
    );
    if (square) {
      _ChartPainter._dot(canvas, size.center(Offset.zero), colour, colour, rough: false, square: true);
    }
  }

  @override
  bool shouldRepaint(_DashSample old) =>
      old.colour != colour || !listEquals(old.dash, dash) || old.square != square;
}
