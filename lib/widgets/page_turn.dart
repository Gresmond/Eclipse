import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Two pages, one over the other, turned by the folded corner at the
/// bottom right. Turning peels [front] away from that corner, folding it
/// back over itself, to show [back]; turning again lays it back down. The
/// idle earmark is the same fold, just small, so the corner you lift is the
/// one that turns.
class PageTurn extends StatefulWidget {
  const PageTurn({
    super.key,
    required this.turned,
    required this.onTurn,
    required this.front,
    required this.back,
    this.tooltip = '',
  });

  /// [back] is showing.
  final bool turned;
  final VoidCallback onTurn;
  final Widget front, back;
  final String tooltip;

  static const duration = Duration(milliseconds: 680);

  @override
  State<PageTurn> createState() => _PageTurnState();
}

class _PageTurnState extends State<PageTurn> with TickerProviderStateMixin {
  late final _turn = AnimationController(vsync: this, duration: PageTurn.duration, value: widget.turned ? 1 : 0)
    ..addStatusListener((_) => setState(() {}));
  late final _lift = AnimationController(vsync: this, duration: Motion.hover);

  static const _frontKey = ValueKey('front'), _backKey = ValueKey('back');

  @override
  void didUpdateWidget(PageTurn old) {
    super.didUpdateWidget(old);
    if (widget.turned != old.turned) widget.turned ? _turn.forward() : _turn.reverse();
  }

  @override
  void dispose() {
    _turn.dispose();
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final moving = _turn.isAnimating;
    final atBack = !moving && _turn.value == 1;
    final atFront = !moving && _turn.value == 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (!atFront)
              KeyedSubtree(
                key: _backKey,
                child: IgnorePointer(ignoring: moving, child: widget.back),
              ),
            if (!atBack)
              KeyedSubtree(
                key: _frontKey,
                child: AnimatedBuilder(
                  animation: _turn,
                  child: IgnorePointer(ignoring: moving, child: widget.front),
                  builder: (context, child) =>
                      moving ? ClipPath(clipper: _KeptClipper(_Fold.turning(size, _turn.value)), child: child) : child!,
                ),
              ),
            // The fold itself, and the shadows either side of it.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_turn, _lift]),
                  builder: (context, _) => CustomPaint(
                    painter: _FoldPainter(
                      fold: moving
                          ? _Fold.turning(size, _turn.value)
                          : _Fold.earmark(size, Motion.hoverCurve.transform(_lift.value)),
                      paper: _paper(p),
                      background: p.background,
                      shadow: p.shadow,
                      revealBackground: !moving,
                    ),
                  ),
                ),
              ),
            ),
            if (!moving)
              Positioned(
                right: 0,
                bottom: 0,
                width: _Fold.hoverLift * 1.6,
                height: _Fold.hoverLift * 1.6,
                child: Tooltip(
                  message: widget.tooltip,
                  waitDuration: const Duration(milliseconds: 600),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => _lift.forward(),
                    onExit: (_) => _lift.reverse(),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _lift.value = 0;
                        widget.onTurn();
                      },
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The page's underside: near white, a touch of the tile's tint so it
  /// belongs to the theme.
  static Color _paper(Palette p) => Color.lerp(p.tile, Colors.white, p.brightness == Brightness.dark ? 0.86 : 0.7)!;
}

/// Where the page is folded: the corner (W, H) has been lifted to [tip], so
/// the crease is the perpendicular bisector of corner and tip.
class _Fold {
  _Fold(this.size, this.tip);

  final Size size;
  final Offset tip;

  static const restLift = 24.0, hoverLift = 36.0;

  factory _Fold.earmark(Size size, double hover) {
    final s = restLift + (hoverLift - restLift) * hover;
    return _Fold(size, Offset(size.width - s, size.height - s));
  }

  /// [t] from 0 (the earmark) to 1 (page gone). The tip is pulled mostly
  /// left first, then sweeps up, as a hand would turn it.
  factory _Fold.turning(Size size, double t) {
    final e = Curves.easeInOutCubic.transform(t);
    final w = size.width, h = size.height;
    final start = Offset(w - restLift, h - restLift);
    // Far enough past the top left that the crease clears the page.
    const reach = 1.37;
    final end = Offset(-reach * w, -reach * h);
    final x = start.dx + (end.dx - start.dx) * e;
    final y = start.dy + (end.dy - start.dy) * math.pow(e, 1.35);
    return _Fold(size, Offset(x, y));
  }

  Offset get corner => Offset(size.width, size.height);
  Offset get mid => (corner + tip) / 2;

  /// Unit normal of the crease, pointing at the corner.
  Offset get normal {
    final d = corner - tip;
    return d / d.distance;
  }

  double side(Offset x) {
    final m = mid, n = normal;
    return (x.dx - m.dx) * n.dx + (x.dy - m.dy) * n.dy;
  }

  List<Offset> get _rect => [Offset.zero, Offset(size.width, 0), corner, Offset(0, size.height)];

  /// The page on one side of the crease: [lifted] is the corner's side.
  List<Offset> part({required bool lifted}) {
    final pts = _rect;
    final out = <Offset>[];
    bool inside(Offset x) => lifted ? side(x) > 0 : side(x) <= 0;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      final ia = inside(a), ib = inside(b);
      if (ia) out.add(a);
      if (ia != ib) {
        final sa = side(a), sb = side(b);
        out.add(Offset.lerp(a, b, sa / (sa - sb))!);
      }
    }
    return out;
  }

  Offset reflect(Offset x) => x - normal * (2 * side(x));

  /// The lifted part, turned over onto the page.
  List<Offset> get flap => [for (final x in part(lifted: true)) reflect(x)];

  static Path path(List<Offset> pts) => pts.isEmpty ? Path() : (Path()..addPolygon(pts, true));
}

class _KeptClipper extends CustomClipper<Path> {
  _KeptClipper(this.fold);
  final _Fold fold;

  @override
  Path getClip(Size size) => _Fold.path(fold.part(lifted: false));

  @override
  bool shouldReclip(_KeptClipper old) => old.fold.tip != fold.tip || old.fold.size != fold.size;
}

class _FoldPainter extends CustomPainter {
  _FoldPainter({
    required this.fold,
    required this.paper,
    required this.background,
    required this.shadow,
    required this.revealBackground,
  });

  final _Fold fold;
  final Color paper, background, shadow;

  /// Idle, nothing is under the corner yet, so it shows the window's
  /// background (the same on both pages).
  final bool revealBackground;

  @override
  void paint(Canvas canvas, Size size) {
    final lifted = fold.part(lifted: true);
    final flap = fold.flap;
    if (lifted.length < 3 || flap.length < 3) return;
    final liftedPath = _Fold.path(lifted), flapPath = _Fold.path(flap);
    final n = fold.normal, m = fold.mid;
    final length = (fold.corner - fold.tip).distance;

    if (revealBackground) canvas.drawPath(liftedPath, Paint()..color = background);

    // Shade on what's uncovered, darkest along the crease.
    final reach = math.min(48.0, length * 0.35);
    canvas.save();
    canvas.clipPath(liftedPath);
    canvas.drawPaint(
      Paint()
        ..shader = LinearGradient(colors: [shadow.withValues(alpha: 0.28), shadow.withValues(alpha: 0)])
            .createShader(Rect.fromPoints(m, m + n * reach)),
    );
    canvas.restore();

    // The flap's shadow on the page beneath it.
    canvas.drawShadow(flapPath, shadow.withValues(alpha: 0.5), math.min(10, 2 + length * 0.02), false);

    // The flap: lit paper, a little darker where it bends at the crease.
    final across = math.max(1.0, length * 0.5);
    canvas.drawPath(
      flapPath,
      Paint()
        ..shader = LinearGradient(
          colors: [Color.lerp(paper, shadow, 0.16)!, paper, Color.lerp(paper, Colors.white, 0.4)!],
          stops: const [0, 0.35, 1],
        ).createShader(Rect.fromPoints(m, m - n * across)),
    );
    canvas.drawPath(
      flapPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = shadow.withValues(alpha: 0.12),
    );
  }

  @override
  bool shouldRepaint(_FoldPainter old) =>
      old.fold.tip != fold.tip ||
      old.fold.size != fold.size ||
      old.paper != paper ||
      old.background != background ||
      old.revealBackground != revealBackground;
}
