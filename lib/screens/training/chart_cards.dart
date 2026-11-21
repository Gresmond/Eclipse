part of '../training_view.dart';

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
      child: Column(
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
                    Row(
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

