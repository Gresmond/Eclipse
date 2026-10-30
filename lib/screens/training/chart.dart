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
    final from = months == null ? null : DateTime(today.year, today.month - months, today.day);
    final all = log.points(from: from);

    // Stable dash per exercise: its place among its group's, by name.
    final dash = <String, List<double>>{};
    for (final g in MuscleGroup.values) {
      final mine = log.exercises.where((e) => e.group == g).toList();
      for (final (i, e) in mine.indexed) {
        dash[e.uid] = _dashes[i % _dashes.length];
      }
    }
    final percent = log.axis == TrainingAxis.change;
    final series = [
      for (final MapEntry(key: e, value: points) in all.entries)
        if (!log.hidden.contains(e.uid) && !log.hidden.contains('g:${e.group.name}') && (percent || !e.bodyweight))
          _Series(e, points, groupColour(e.group, p), dash[e.uid] ?? const []),
    ]..sort((a, b) => a.exercise.group.index.compareTo(b.exercise.group.index));
    final charted = all.keys.toList()
      ..sort((a, b) => a.group.index != b.group.index ? a.group.index - b.group.index : a.name.compareTo(b.name));

    return Tile(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TileHeader(
            title: percent
                ? 'Progress since ${from == null ? 'the start' : _shortDate(from)}'
                : 'Estimated one-rep max',
            trailingAtEnd: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Segments(
                  labels: [for (final r in TrainingRange.values) r.label],
                  selected: log.range.index,
                  onSelect: (i) => log.setRange(TrainingRange.values[i]),
                ),
                const SizedBox(width: 10),
                _Segments(
                  labels: const ['kg', '% change'],
                  selected: log.axis.index,
                  onSelect: (i) => log.setAxis(TrainingAxis.values[i]),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: all.isEmpty
                ? Center(
                    child: Text(
                      log.exercises.isEmpty
                          ? 'Log a session below and your progress will show here.'
                          : 'Nothing logged in this range yet.',
                      style: _label(p, color: p.inkMuted),
                    ),
                  )
                : _Chart(
                    series: series,
                    from: from ?? series.map((s) => s.points.first.day).fold(today, (a, b) => b.isBefore(a) ? b : a),
                    to: today,
                    percent: percent,
                    focus: _focus,
                  ),
          ),
          if (charted.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Legend(
              exercises: charted,
              dash: dash,
              hidden: log.hidden,
              percent: percent,
              onHover: (key) => setState(() => _focus = key),
              onToggle: log.toggleHidden,
            ),
          ],
        ],
      ),
    );
  }
}

class _Series {
  _Series(this.exercise, this.points, this.colour, this.dash);
  final Exercise exercise;
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

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      onHover: (e) => setState(() => _pointer = e.localPosition),
      onExit: (_) => setState(() => _pointer = null),
      child: CustomPaint(
        size: Size.infinite,
        painter: _ChartPainter(
          series: widget.series,
          from: widget.from,
          to: widget.to,
          percent: widget.percent,
          focus: widget.focus,
          pointer: _pointer,
          palette: p,
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
    required this.palette,
  });

  final List<_Series> series;
  final DateTime from, to;
  final bool percent;
  final String? focus;
  final Offset? pointer;
  final Palette palette;

  static const _left = 52.0, _bottom = 26.0, _top = 6.0, _right = 20.0;

  double _value(_Series s, TrainingPoint pt) => percent ? (pt.value / s.points.first.value - 1) * 100 : pt.value;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final plot = Rect.fromLTRB(_left, _top, size.width - _right, size.height - _bottom);
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
      lo -= percent ? 5 : 5;
      hi += percent ? 5 : 5;
    }
    final step = _niceStep((hi - lo) / 4);
    lo = (lo / step).floor() * step;
    hi = (hi / step).ceil() * step;

    final start = dateOnly(from), end = dateOnly(to);
    const days = daysBetween;
    final span = math.max(1, days(start, end));
    double x(DateTime d) => plot.left + plot.width * (days(start, d) / span);
    double y(double v) => plot.bottom - plot.height * ((v - lo) / (hi - lo));

    // Grid and labels.
    final grid = Paint()
      ..color = p.border
      ..strokeWidth = 1;
    for (var v = lo; v <= hi + step / 2; v += step) {
      final yy = y(v);
      canvas.drawLine(Offset(plot.left, yy), Offset(plot.right, yy), grid);
      final text = percent ? '${v > 0 ? '+' : ''}${v.toStringAsFixed(step < 1 ? 1 : 0)}%' : _kg(v);
      _text(canvas, text, Offset(plot.left - 10, yy), p.inkMuted, align: Alignment.centerRight);
    }
    if (percent && lo < 0 && hi > 0) {
      canvas.drawLine(
        Offset(plot.left, y(0)),
        Offset(plot.right, y(0)),
        Paint()
          ..color = p.inkMuted.withValues(alpha: 0.5)
          ..strokeWidth = 1,
      );
    }
    final ticks = math.min(6, span);
    for (var i = 0; i <= ticks; i++) {
      final d = DateTime(start.year, start.month, start.day + (span * i / ticks).round());
      _text(canvas, _shortDate(d), Offset(x(d), plot.bottom + 8), p.inkMuted, align: Alignment.topCenter);
    }

    // Lines, unfocused ones faded under the focused.
    _Hit? hit;
    var hitDistance = 16.0;
    final ordered = [...series.where((s) => !s.focused(focus)), ...series.where((s) => s.focused(focus))];
    for (final s in ordered) {
      final faded = !s.focused(focus);
      final colour = faded ? s.colour.withValues(alpha: 0.18) : s.colour;
      final pts = [for (final pt in s.points) Offset(x(pt.day), y(_value(s, pt)))];
      if (pts.length > 1) {
        final path = Path()..addPolygon(pts, false);
        _stroke(
          canvas,
          path,
          s.dash,
          Paint()
            ..color = colour
            ..strokeWidth = focus != null && !faded ? 2.6 : 2
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round,
        );
      }
      for (final (i, o) in pts.indexed) {
        final rough = s.points[i].rough;
        canvas.drawCircle(o, 3.6, Paint()..color = rough ? p.tile : colour);
        if (rough) {
          canvas.drawCircle(
            o,
            3.6,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..color = colour,
          );
        }
        if (!faded && pointer != null) {
          final d = (pointer! - o).distance;
          if (d < hitDistance) {
            hitDistance = d;
            hit = _Hit(s, s.points[i], o);
          }
        }
      }
    }
    if (hit != null) _tooltip(canvas, size, hit);
  }

  void _tooltip(Canvas canvas, Size size, _Hit hit) {
    final p = palette;
    final pt = hit.point, e = hit.series.exercise;
    final value = e.bodyweight
        ? '${_kg(pt.value)} reps'
        : '${pt.rough ? '≈ ' : ''}${_kg(pt.value)} kg${pt.rough ? '  (±5–10%)' : ''}';
    final change = percent && hit.series.points.first != pt
        ? '  ·  ${_value(hit.series, pt) >= 0 ? '+' : ''}${_value(hit.series, pt).toStringAsFixed(1)}%'
        : '';
    final title = TextPainter(
      text: TextSpan(
        text: e.name,
        style: _label(p, weight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final body = TextPainter(
      text: TextSpan(
        text: '${_shortDate(pt.day)}  ·  $value$change',
        style: _label(p, size: 14, color: p.inkMuted),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = math.max(title.width, body.width) + 24, h = title.height + body.height + 18;
    var origin = hit.at + const Offset(12, -12) - Offset(0, h);
    if (origin.dx + w > size.width) origin = Offset(hit.at.dx - 12 - w, origin.dy);
    if (origin.dy < 0) origin = Offset(origin.dx, hit.at.dy + 12);
    final box = RRect.fromRectAndRadius(origin & Size(w, h), const Radius.circular(12));
    canvas.drawShadow(Path()..addRRect(box), p.shadow.withValues(alpha: 0.4), 6, false);
    canvas.drawRRect(box, Paint()..color = p.tile);
    canvas.drawRRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = p.tileBorder,
    );
    canvas.drawCircle(hit.at, 5.5, Paint()..color = hit.series.colour.withValues(alpha: 0.3));
    title.paint(canvas, origin + const Offset(12, 8));
    body.paint(canvas, origin + Offset(12, 10 + title.height));
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

  static void _stroke(Canvas canvas, Path path, List<double> dash, Paint paint) {
    if (dash.isEmpty) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final PathMetric m in path.computeMetrics()) {
      var at = 0.0, i = 0;
      while (at < m.length) {
        final len = dash[i % dash.length];
        if (i.isEven) canvas.drawPath(m.extractPath(at, math.min(at + len, m.length)), paint);
        at += len;
        i++;
      }
    }
  }

  void _text(Canvas canvas, String text, Offset at, Color colour, {required Alignment align}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: _label(palette, size: 12, color: colour),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (align) {
      Alignment.centerRight => -tp.width,
      _ => -tp.width / 2,
    };
    final dy = align == Alignment.centerRight ? -tp.height / 2 : 0.0;
    tp.paint(canvas, at + Offset(dx, dy));
  }

  @override
  bool shouldRepaint(_ChartPainter old) => true;
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
    required this.dash,
    required this.hidden,
    required this.percent,
    required this.onHover,
    required this.onToggle,
  });

  final List<Exercise> exercises;
  final Map<String, List<double>> dash;
  final Set<String> hidden;
  final bool percent;
  final ValueChanged<String?> onHover;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final groups = <MuscleGroup, List<Exercise>>{};
    for (final e in exercises) {
      (groups[e.group] ??= []).add(e);
    }
    final hasBodyweight = exercises.any((e) => e.bodyweight);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
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
                    child: Text(
                      g.label.toUpperCase(),
                      style: _label(
                        p,
                        size: 12,
                        weight: FontWeight.w700,
                        color: groupColour(g, p),
                      ).copyWith(letterSpacing: 1.2),
                    ),
                  ),
                  for (final e in list)
                    _LegendItem(
                      keyName: e.uid,
                      off: hidden.contains(e.uid) || hidden.contains('g:${g.name}') || (!percent && e.bodyweight),
                      onHover: onHover,
                      onToggle: onToggle,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CustomPaint(
                            size: const Size(22, 10),
                            painter: _DashSample(groupColour(g, p), dash[e.uid] ?? const []),
                          ),
                          const SizedBox(width: 6),
                          Text(e.name, style: _label(p, size: 14)),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        ),
        if (!percent && hasBodyweight)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Bodyweight exercises show in the % change view.',
              style: _label(p, size: 12, color: p.inkMuted),
            ),
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
  _DashSample(this.colour, this.dash);
  final Color colour;
  final List<double> dash;

  @override
  void paint(Canvas canvas, Size size) => _ChartPainter._stroke(
    canvas,
    Path()
      ..moveTo(1, size.height / 2)
      ..lineTo(size.width - 1, size.height / 2),
    dash,
    Paint()
      ..color = colour
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round,
  );

  @override
  bool shouldRepaint(_DashSample old) => old.colour != colour || old.dash != dash;
}

/// A row of options in one pill, the chosen one filled.
class _Segments extends StatelessWidget {
  const _Segments({required this.labels, required this.selected, required this.onSelect});

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.borderSoft),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, label) in labels.indexed)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: AnimatedContainer(
                  duration: Motion.click,
                  curve: Motion.clickCurve,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: p.done.withValues(alpha: i == selected ? 1 : 0),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    label,
                    style: _label(p, size: 14, weight: FontWeight.w600, color: i == selected ? p.onAccent : p.inkMuted),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
