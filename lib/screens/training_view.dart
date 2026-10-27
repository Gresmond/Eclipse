import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/oklch.dart';
import '../training.dart';
import '../training_log.dart';
import '../widgets/day_picker.dart';
import '../widgets/fade_menu.dart';
import '../widgets/tile.dart';

/// The page under the corner: every exercise's estimated 1RM over time,
/// and the sessions that make it.
class TrainingView extends StatelessWidget {
  const TrainingView({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ColoredBox(
      color: p.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: const [
                  Expanded(flex: 11, child: _ChartTile()),
                  SizedBox(height: 16),
                  Expanded(
                    flex: 9,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 3, child: _SessionTile()),
                        SizedBox(width: 16),
                        Expanded(flex: 2, child: _HistoryTile()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Each muscle group's colour: evenly round the OKLCH hue circle at one
/// lightness and chroma, so no group shouts louder than another.
Color groupColour(MuscleGroup g, Palette p) {
  final dark = p.brightness == Brightness.dark;
  final h = (20 + g.index * 360 / MuscleGroup.values.length) % 360;
  final l = dark ? 0.78 : 0.62;
  return Oklch(l, math.min(0.13, Oklch.maxChroma(l, h)), h).toColor();
}

/// Line styles that tell apart exercises of one group: solid, then dashes.
const _dashes = <List<double>>[
  [],
  [9, 5],
  [2, 4],
  [12, 4, 2, 4],
  [16, 7],
  [5, 3],
];

String _kg(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String _shortDate(DateTime d) => '${d.day} ${monthNames[d.month - 1].substring(0, 3)}';

TextStyle _label(Palette p, {double size = 13, FontWeight weight = FontWeight.w500, Color? color}) =>
    TextStyle(fontFamily: Fonts.ui, fontSize: size, fontWeight: weight, color: color ?? p.ink, height: 1.25);

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: EdgeInsets.fromLTRB(32, Platform.isMacOS ? 27 : 15, 32, 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'PROGRESS',
                style: _label(p, size: 12, weight: FontWeight.w600, color: p.inkMuted).copyWith(letterSpacing: 1.6),
              ),
              const SizedBox(height: 4),
              Text(
                'Training',
                style: TextStyle(
                  fontFamily: Fonts.display,
                  fontSize: 38,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -1.3,
                  height: 1.05,
                  color: p.ink,
                ),
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

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

  static const _left = 52.0, _bottom = 26.0, _top = 6.0, _right = 12.0;

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
    // Whole days, counted in UTC so a daylight-saving change can't lose one.
    int days(DateTime a, DateTime b) =>
        DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
    final span = math.max(1, days(start, end));
    double x(DateTime d) => plot.left + plot.width * (days(start, d) / span);
    double y(double v) => plot.bottom - plot.height * ((v - lo) / (hi - lo));

    // Grid and labels.
    final grid = Paint()
      ..color = p.tileBorder.withValues(alpha: 0.7)
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
        style: _label(p, size: 12, color: p.inkMuted),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = math.max(title.width, body.width) + 24, h = title.height + body.height + 18;
    var origin = hit.at + const Offset(12, -12) - Offset(0, h);
    if (origin.dx + w > size.width) origin = Offset(hit.at.dx - 12 - w, origin.dy);
    if (origin.dy < 0) origin = Offset(origin.dx, hit.at.dy + 12);
    final box = RRect.fromRectAndRadius(origin & Size(w, h), const Radius.circular(10));
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
        style: _label(palette, size: 11.5, color: colour),
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
                        size: 10.5,
                        weight: FontWeight.w700,
                        color: groupColour(g, p),
                      ).copyWith(letterSpacing: 1.1),
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
                          Text(e.name, style: _label(p, size: 12.5)),
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
              style: _label(p, size: 11.5, color: p.inkMuted),
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
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        child: AnimatedOpacity(opacity: off ? 0.35 : 1, duration: Motion.hover, child: child),
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
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.6), width: 0.8),
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
                    color: i == selected ? p.done : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    label,
                    style: _label(p, size: 12, weight: FontWeight.w600, color: i == selected ? p.onAccent : p.inkMuted),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Session

class _SessionTile extends StatelessWidget {
  const _SessionTile();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.training.revision, s.today));
    final log = state.training;
    final day = log.day ?? state.today;
    final session = log.session(day);
    final isToday = day == state.today;
    return Tile(
      padding: const EdgeInsets.fromLTRB(24, 20, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TileHeader(
            title: isToday ? "Today's session" : '${weekdayNames[day.weekday - 1]}  ·  ${_shortDate(day)}',
            trailingAtEnd: true,
            trailing: Builder(
              builder: (anchor) => _TextButton(
                label: isToday ? 'Another day' : 'Back to today',
                icon: isToday ? Icons.calendar_today_rounded : null,
                onTap: isToday
                    ? () => showFadeMenu(
                        anchor,
                        width: 312,
                        builder: (_) => DayPicker(
                          today: state.today,
                          selected: day,
                          onPick: (d) => log.showDay(d == state.today ? null : d),
                        ),
                      )
                    : () => log.showDay(null),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final (e, sets) in session)
                  _ExerciseBlock(key: ValueKey(e.uid), day: day, exercise: e, sets: sets),
                _AddExercise(key: ValueKey(dateKey(day)), day: day, logged: {for (final (e, _) in session) e.uid}),
              ],
            ),
          ),
          if (session.isEmpty && log.exercises.isEmpty)
            Text(
              'Type an exercise, pick what it trains, then add your sets.',
              style: _label(p, size: 12, color: p.inkMuted),
            ),
        ],
      ),
    );
  }
}

class _ExerciseBlock extends StatelessWidget {
  const _ExerciseBlock({super.key, required this.day, required this.exercise, required this.sets});

  final DateTime day;
  final Exercise exercise;
  final List<TrainingSet> sets;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final log = AppScope.read(context).training;
    final colour = groupColour(exercise.group, p);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: 30.0 + sets.length * 36,
            margin: const EdgeInsets.only(right: 12, top: 2),
            decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(2)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: _InlineName(
                        name: exercise.name,
                        onRename: (name) => log.updateExercise(exercise, name: name),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Builder(
                      builder: (anchor) => _GroupPill(
                        group: exercise.group,
                        onTap: () => showFadeMenu(
                          anchor,
                          alignLeft: true,
                          width: 220,
                          builder: (menu) => _GroupMenu(
                            selected: exercise.group,
                            onPick: (g) {
                              Navigator.pop(menu);
                              log.updateExercise(exercise, group: g);
                            },
                          ),
                        ),
                      ),
                    ),
                    if (exercise.bodyweight) ...[
                      const SizedBox(width: 6),
                      Text(
                        'BODYWEIGHT',
                        style: _label(
                          p,
                          size: 10,
                          weight: FontWeight.w600,
                          color: p.inkMuted,
                        ).copyWith(letterSpacing: 1),
                      ),
                    ],
                    const Spacer(),
                    _IconAction(
                      icon: Icons.close_rounded,
                      tooltip: 'Take off this session',
                      onTap: () => log.removeFromDay(day, exercise),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final (i, s) in sets.indexed)
                  _SetRow(
                    key: ValueKey(s.uid),
                    index: i,
                    set: s,
                    bodyweight: exercise.bodyweight,
                    last: i == sets.length - 1,
                    day: day,
                    exercise: exercise,
                  ),
                _TextButton(label: 'Add set', icon: Icons.add_rounded, onTap: () => log.addSet(day, exercise)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SetRow extends StatefulWidget {
  const _SetRow({
    super.key,
    required this.index,
    required this.set,
    required this.bodyweight,
    required this.last,
    required this.day,
    required this.exercise,
  });

  final int index;
  final TrainingSet set;
  final bool bodyweight, last;
  final DateTime day;
  final Exercise exercise;

  @override
  State<_SetRow> createState() => _SetRowState();
}

class _SetRowState extends State<_SetRow> {
  late final _weight = TextEditingController(text: widget.set.weight == null ? '' : _kg(widget.set.weight!));
  late final _reps = TextEditingController(text: widget.set.reps == 0 ? '' : '${widget.set.reps}');
  final _repsFocus = FocusNode();
  bool _hover = false;

  @override
  void dispose() {
    _weight.dispose();
    _reps.dispose();
    _repsFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final log = AppScope.read(context).training;
    final s = widget.set;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text('${widget.index + 1}', style: _label(p, size: 12, color: p.inkMuted)),
            ),
            if (widget.bodyweight)
              SizedBox(
                width: 108,
                child: Text('Bodyweight', style: _label(p, size: 13, color: p.inkMuted)),
              )
            else ...[
              _NumberBox(
                controller: _weight,
                decimal: true,
                hint: 'kg',
                autofocus: widget.last && s.reps == 0 && s.weight == null,
                onChanged: (v) {
                  final w = double.tryParse(v);
                  w == null ? log.updateSet(s, clearWeight: true) : log.updateSet(s, weight: w);
                },
                onSubmitted: () => _repsFocus.requestFocus(),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('kg', style: _label(p, size: 12.5, color: p.inkMuted)),
              ),
              Text('×', style: _label(p, size: 13, color: p.inkMuted)),
              const SizedBox(width: 8),
            ],
            _NumberBox(
              controller: _reps,
              focusNode: _repsFocus,
              hint: 'reps',
              autofocus: widget.last && s.reps == 0 && (widget.bodyweight || s.weight != null),
              onChanged: (v) => log.updateSet(s, reps: int.tryParse(v) ?? 0),
              // Enter on the last set's reps starts the next set.
              onSubmitted: () {
                if (widget.last && s.reps > 0) log.addSet(widget.day, widget.exercise);
              },
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text('reps', style: _label(p, size: 12.5, color: p.inkMuted)),
            ),
            if (s.reps > maxEstimateReps)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  'Over $maxEstimateReps reps, so not charted',
                  style: _label(p, size: 11.5, color: p.inkMuted),
                ),
              ),
            const Spacer(),
            AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: Motion.hover,
              child: _IconAction(icon: Icons.remove_rounded, tooltip: 'Delete set', onTap: () => log.deleteSet(s)),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberBox extends StatelessWidget {
  const _NumberBox({
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onSubmitted,
    this.focusNode,
    this.decimal = false,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final bool decimal, autofocus;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 64,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: p.empty.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.8), width: 0.8),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        style: _label(p, size: 13.5, weight: FontWeight.w600),
        cursorColor: p.accent,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(decimal ? r'^\d{0,4}([.,]\d{0,2})?' : r'^\d{0,3}'))],
        decoration: InputDecoration.collapsed(
          hintText: '',
          hintStyle: _label(p, color: p.inkMuted),
        ),
        onChanged: (v) => onChanged(v.replaceAll(',', '.')),
        onSubmitted: (_) => onSubmitted(),
      ),
    );
  }
}

class _InlineName extends StatefulWidget {
  const _InlineName({required this.name, required this.onRename});

  final String name;
  final ValueChanged<String> onRename;

  @override
  State<_InlineName> createState() => _InlineNameState();
}

class _InlineNameState extends State<_InlineName> {
  bool _editing = false;
  late final _text = TextEditingController(text: widget.name);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    setState(() => _editing = false);
    if (_text.text.trim().isNotEmpty && _text.text.trim() != widget.name) widget.onRename(_text.text);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(
      fontFamily: Fonts.display,
      fontSize: 15.5,
      fontWeight: FontWeight.w600,
      color: p.ink,
      letterSpacing: -0.2,
    );
    if (_editing) {
      return IntrinsicWidth(
        child: TextField(
          controller: _text,
          focusNode: _focus,
          autofocus: true,
          style: style,
          cursorColor: p.accent,
          decoration: const InputDecoration.collapsed(hintText: ''),
          onSubmitted: (_) => _commit(),
        ),
      );
    }
    return Tooltip(
      message: 'Rename',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() {
            _text.text = widget.name;
            _editing = true;
          }),
          child: Text(widget.name, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

class _GroupPill extends StatelessWidget {
  const _GroupPill({required this.group, this.onTap, this.selected = true});

  final MuscleGroup group;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final colour = groupColour(group, p);
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: selected ? 0.2 : 0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colour.withValues(alpha: selected ? 0.6 : 0.25), width: 0.8),
          ),
          child: Text(
            group.label.toUpperCase(),
            style: _label(p, size: 10.5, weight: FontWeight.w700, color: colour).copyWith(letterSpacing: 1.1),
          ),
        ),
      ),
    );
  }
}

class _GroupMenu extends StatelessWidget {
  const _GroupMenu({required this.selected, required this.onPick});

  final MuscleGroup? selected;
  final ValueChanged<MuscleGroup> onPick;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final g in MuscleGroup.values)
          _GroupPill(group: g, selected: selected == null || g == selected, onTap: () => onPick(g)),
      ],
    ),
  );
}

/// The field to put an exercise on the session: picks one of yours as you
/// type, or makes a new one once you say what it trains.
class _AddExercise extends StatefulWidget {
  const _AddExercise({super.key, required this.day, required this.logged});

  final DateTime day;

  /// Exercises already on this session.
  final Set<String> logged;

  @override
  State<_AddExercise> createState() => _AddExerciseState();
}

class _AddExerciseState extends State<_AddExercise> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _bodyweight = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add(Exercise e) {
    AppScope.read(context).training.addToDay(widget.day, e);
    _text.clear();
    setState(() => _bodyweight = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final log = AppScope.read(context).training;
    final query = _text.text.trim().toLowerCase();
    final matches = query.isEmpty
        ? const <Exercise>[]
        : log.exercises
              .where((e) => e.name.toLowerCase().contains(query) && !widget.logged.contains(e.uid))
              .take(6)
              .toList();
    final exact = log.exercises.any((e) => e.name.toLowerCase() == query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: p.empty.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.tileBorder.withValues(alpha: 0.8), width: 0.8),
          ),
          child: Row(
            children: [
              Icon(Icons.add_rounded, size: 18, color: p.inkMuted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  style: _label(p, size: 13.5),
                  cursorColor: p.accent,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration.collapsed(
                    hintText: 'Add an exercise',
                    hintStyle: _label(p, size: 13.5, color: p.inkMuted),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (matches.isNotEmpty) _add(matches.first);
                  },
                ),
              ),
            ],
          ),
        ),
        if (matches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in matches) _Chip(colour: groupColour(e.group, p), label: e.name, onTap: () => _add(e)),
              ],
            ),
          ),
        if (query.isNotEmpty && !exact) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Text('New: what does “${_text.text.trim()}” train?', style: _label(p, size: 12.5, color: p.inkMuted)),
              const SizedBox(width: 10),
              _Chip(
                label: 'Bodyweight',
                colour: p.accent,
                on: _bodyweight,
                onTap: () => setState(() => _bodyweight = !_bodyweight),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _GroupMenu(
            selected: null,
            onPick: (g) {
              final name = _text.text.trim();
              final e = log.createExercise(name[0].toUpperCase() + name.substring(1), g, bodyweight: _bodyweight);
              _add(e);
            },
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.colour, required this.onTap, this.on = true});

  final String label;
  final Color colour;
  final VoidCallback onTap;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.click,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: on ? colour.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colour.withValues(alpha: on ? 0.55 : 0.3), width: 0.8),
          ),
          child: Text(
            label,
            style: _label(p, size: 12.5, weight: FontWeight.w600, color: on ? p.ink : p.inkMuted),
          ),
        ),
      ),
    );
  }
}

class _TextButton extends StatelessWidget {
  const _TextButton({required this.label, required this.onTap, this.icon});

  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 15, color: p.accent), const SizedBox(width: 4)],
              Text(
                label,
                style: _label(p, size: 12.5, weight: FontWeight.w600, color: p.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 16, color: p.inkMuted),
          ),
        ),
      ),
    );
  }
}

// History

class _HistoryTile extends StatelessWidget {
  const _HistoryTile();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.training.revision, s.today));
    final log = state.training;
    final open = dateKey(log.day ?? state.today);
    final days = log.loggedDays;
    return Tile(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TileHeader(title: 'Past sessions'),
          const SizedBox(height: 10),
          Expanded(
            child: days.isEmpty
                ? Text('Sessions you log will be listed here.', style: _label(p, size: 12.5, color: p.inkMuted))
                : ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final key in days)
                        _HistoryRow(
                          day: DateTime.parse(key),
                          selected: key == open,
                          session: log.session(DateTime.parse(key)),
                          onTap: () {
                            final d = DateTime.parse(key);
                            log.showDay(d == state.today ? null : d);
                          },
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({required this.day, required this.selected, required this.session, required this.onTap});

  final DateTime day;
  final bool selected;
  final List<(Exercise, List<TrainingSet>)> session;
  final VoidCallback onTap;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final d = widget.day;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.hover,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.today.withValues(alpha: 0.35)
                : _hover
                ? p.empty.withValues(alpha: 0.5)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 88,
                child: Text(
                  '${weekdayNames[d.weekday - 1].substring(0, 3)} ${_shortDate(d)}',
                  style: _label(p, size: 12.5, weight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final (e, sets) in widget.session)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(color: groupColour(e.group, p), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 5),
                          Text('${e.name} ×${sets.length}', style: _label(p, size: 12, color: p.inkMuted)),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
