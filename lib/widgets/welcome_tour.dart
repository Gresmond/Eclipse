import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';
import 'fade_through.dart';
import 'settings_dialog.dart';
import 'fade_menu.dart';

/// The parts of the app the welcome tour points at.
enum TourSpot {
  rituals,
  sleep,
  todayTodos,
  tomorrowTodos,
  laterTodos,
  journal,
  date,
  tabs,
  settings,
  appearance,
  settingsPreview,
  googleSync,
  appearancePreview,
}

/// Marks [child] as [spot] for the welcome tour to find. Several may share
/// a spot; the tour lights them up as one.
class TourTarget extends StatefulWidget {
  const TourTarget({super.key, required this.spot, required this.child});

  final TourSpot spot;
  final Widget child;

  static final _mounted = <TourSpot, Set<_TourTargetState>>{};

  /// The box round every laid-out [spot], in [ancestor]'s coordinates;
  /// null when there's none.
  static Rect? rectOf(TourSpot spot, RenderBox ancestor, {bool layoutBounds = false}) {
    Rect? rect;
    final targets = _mounted[spot] ?? const <_TourTargetState>{};
    // Rapid Back/Next can leave an old preview fading out while a new copy
    // enters. Only the incoming panel is the destination for these steps.
    final preview =
        spot == TourSpot.settingsPreview || spot == TourSpot.appearancePreview || spot == TourSpot.googleSync;
    for (final target in preview && targets.isNotEmpty ? [targets.last] : targets) {
      final box = target.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      // Preview entrances scale at paint time. Their final layout bounds keep
      // the spotlight and guide from chasing a destination that moves each frame.
      final transform = Matrix4.identity();
      if (layoutBounds) {
        RenderObject child = box;
        while (child != ancestor) {
          final parent = child.parent;
          if (parent == null) break;
          final step = Matrix4.identity();
          if (parent is! RenderTransform) parent.applyPaintTransform(child, step);
          transform.setFrom(step.multiplied(transform));
          child = parent;
        }
      }
      final r = MatrixUtils.transformRect(
        layoutBounds ? transform : box.getTransformTo(ancestor),
        Offset.zero & box.size,
      );
      rect = rect?.expandToInclude(r) ?? r;
    }
    return rect;
  }

  @override
  State<TourTarget> createState() => _TourTargetState();
}

class _TourTargetState extends State<TourTarget> {
  @override
  void initState() {
    super.initState();
    TourTarget._mounted.putIfAbsent(widget.spot, () => {}).add(this);
  }

  @override
  void didUpdateWidget(TourTarget old) {
    super.didUpdateWidget(old);
    if (old.spot == widget.spot) return;
    TourTarget._mounted[old.spot]?.remove(this);
    TourTarget._mounted.putIfAbsent(widget.spot, () => {}).add(this);
  }

  @override
  void dispose() {
    TourTarget._mounted[widget.spot]?.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Step {
  const _Step(this.title, this.body, [this.spot, this.settingsRibbon]);

  final String title, body;

  /// What it lights up; null for a card in the middle of the window.
  final TourSpot? spot;
  final int? settingsRibbon;
}

List<_Step> _steps(AppState state) => [
  const _Step(
    'Welcome to Eclipse!',
    'A home for your daily rituals, to-dos, and journal. '
        'Here is a quick tour of the basics.',
  ),
  _Step(
    'Daily rituals',
    Platform.isMacOS
        ? 'Click a square for done, right-click for not done, or Option-click for other. '
              'Repeat the same click to clear the mark. '
              'Done days build each streak and fill the ring.'
        : 'Click a square for done, right-click for not done, or middle-click for other. '
              'Repeat the same mouse button to clear the mark. '
              'Done days build each streak and fill the ring.',
    TourSpot.rituals,
  ),
  const _Step(
    'Sleep schedule',
    'Track your sleep schedule independently from your daily rituals. '
        'Each item’s target time appears beside its name, and you can edit the schedule from a month view.',
    TourSpot.sleep,
  ),
  const _Step(
    'Today’s to-dos',
    'Type a task and press Enter to add it, then tick it off when done. Use the pencil '
        'to edit its text. Unfinished tasks carry forward with the day they came from.',
    TourSpot.todayTodos,
  ),
  const _Step(
    'Tomorrow',
    'Plan the next day here. When a new day starts, unfinished Tomorrow tasks move '
        'into Today automatically, alongside anything still unfinished from today.',
    TourSpot.tomorrowTodos,
  ),
  const _Step(
    'This week and this month',
    'Switch tabs for longer plans. Add a due date when creating or editing a task. '
        'Tasks here automatically move from ‘This month’ to ‘This week’ as the date approaches. '
        'A task in ‘This week’ moves into ‘Tomorrow’ when it’s due tomorrow and finally '
        '‘Today’ when it’s due. Ticking a planner task moves it into Today as done.',
    TourSpot.laterTodos,
  ),
  const _Step(
    'Journal',
    'Your journal saves as you type. The folder button opens the day’s '
        'Markdown copy. Choose its folder in Settings or sync it to Google Drive. Edits made to those files '
        'outside Eclipse are not read back into the app.',
    TourSpot.journal,
  ),
  const _Step(
    'Looking back',
    'Click the date to open a past day. Yesterday stays editable until your next day '
        'starts. Older days are read only. Correct yesterday’s task text without '
        'changing today’s text. Completing a carried task also clears its unfinished carryover.',
    TourSpot.date,
  ),
  const _Step(
    'Months and the year',
    'Open a month for the full daily grid. Edit its ritual list and notes, or the '
        'sleep schedule and target times. Year compares monthly and yearly totals '
        'for rituals and sleep. Use the arrows to visit other months and years.',
    TourSpot.tabs,
  ),
  const _Step(
    'Settings',
    'Choose your day-start hour and journal folder. With weekends as rest days, '
        'blank weekends do not break streaks. Done rituals still count. Reopen this '
        'tour here whenever you want.',
    TourSpot.settingsPreview,
    0,
  ),
  const _Step(
    'Data and backups',
    'Data shows your data folder and the last 30 daily backups. Restore '
        'a copy there if you need to go back; Eclipse saves a safety copy before restoring.',
    TourSpot.settingsPreview,
    1,
  ),
  const _Step(
    'Google sync',
    'Connect Google in Data to sync through Eclipse’s hidden Drive folder. '
        'Use the same account on your computers. Each keeps its own theme and journal '
        'folder; changing accounts asks how to handle the existing data.',
    TourSpot.googleSync,
    1,
  ),
  _Step(
    'Appearance',
    'Pick a theme. Each one comes in a light and dark pair.'
        '${state.nightLightAvailable ? switch (Platform.operatingSystem) {
                'macos' => ' With ‘Follow Dark mode’ enabled, Eclipse follows macOS Light and Dark modes. '
                    'For automatic switching, choose ‘Auto’ in System Settings → Appearance.',
                'windows' => ' With ‘Follow the sun’ enabled, Eclipse switches to your theme’s dark partner '
                    'while Windows Night light is on, and back to its light partner when Night light turns off.',
                _ => ' With ‘Follow the sun’ enabled, Eclipse switches to your theme’s dark partner '
                    'while night light is on, and back to its light partner when night light turns off.',
              } : ''}',
    TourSpot.appearancePreview,
  ),
];

/// A first look round the app: dims the window and lights up one part at a
/// time, with a card beside it. Arrow keys and Enter step through; Escape
/// skips. Shown over the whole window while [AppState.touring].
class WelcomeTour extends StatefulWidget {
  const WelcomeTour({super.key, required this.appearanceBuilder});

  final WidgetBuilder appearanceBuilder;

  @override
  State<WelcomeTour> createState() => _WelcomeTourState();
}

enum _GuideSide { center, below, right, left, above }

class _WelcomeTourState extends State<WelcomeTour> with TickerProviderStateMixin {
  var _index = 0;
  var _shown = false;
  Rect? _spot;
  TourSpot? _measuredSpot;
  Rect? _appearanceAnchor;
  Size? _measuredSize;
  bool _measurementPending = false;
  bool _followSettingsResize = false;
  _TourGeometry? _from, _to;
  late final _travel = AnimationController(vsync: this, duration: Motion.morph, value: 1);
  late final _geometryChanges = Listenable.merge([_travel, _layoutWatch]);

  _TourGeometry get _geometry {
    final frame = _TourGeometry.lerp(_from!, _to!, Motion.morphCurve.transform(_travel.value));
    // The panel already animates its bounds; only the guide needs travel easing.
    return _followSettingsResize
        ? _TourGeometry(hole: _to!.hole, card: frame.card, width: frame.width, radius: frame.radius)
        : frame;
  }

  // Follow the actual dialog bounds while its ribbon changes height.
  late final _layoutWatch = AnimationController(vsync: this, duration: Motion.morph + Motion.click)
    ..addListener(() => _measure(_steps(AppScope.of(context))[_index].spot));

  @override
  void dispose() {
    _travel.dispose();
    _layoutWatch.dispose();
    super.dispose();
  }

  static const _cardWidth = 360.0, _welcomeWidth = 420.0, _margin = 24.0, _gap = 20.0;

  @override
  void initState() {
    super.initState();
    // Fades in from nothing once the first frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  void _go(int index, int count) {
    if (index < 0) return;
    if (index >= count) return _close();
    final steps = _steps(AppScope.of(context));
    final current = _geometry;
    _followSettingsResize =
        steps[_index].spot == TourSpot.settingsPreview && steps[index].spot == TourSpot.settingsPreview;
    _from = current;
    setState(() => _index = index);
    _travel.forward(from: 0);
    _layoutWatch.forward(from: 0);
  }

  void _close() => setState(() => _shown = false);

  /// Where the current step's spot is now. Measured after layout, since the
  /// window can be resized under the tour.
  void _measure(TourSpot? spot) {
    if (_measurementPending) return;
    _measurementPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementPending = false;
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      if (spot != _steps(AppScope.of(context))[_index].spot) return;
      final bounds = spot == null ? null : TourTarget.rectOf(spot, box, layoutBounds: true);
      final appearanceAnchor = TourTarget.rectOf(TourSpot.appearance, box);
      final exact =
          spot == TourSpot.settingsPreview || spot == TourSpot.googleSync || spot == TourSpot.appearancePreview;
      final rect = exact ? bounds : bounds?.inflate(8);
      if (rect != _spot ||
          spot != _measuredSpot ||
          appearanceAnchor != _appearanceAnchor ||
          box.size != _measuredSize) {
        final width = spot == null ? _welcomeWidth : _cardWidth;
        final target = _TourGeometry(
          hole: rect ?? Rect.fromCenter(center: box.size.center(Offset.zero), width: 0, height: 0),
          card: _cardAt(rect, width, box.size),
          width: width,
          radius: spot == TourSpot.appearancePreview ? 18 : (spot == TourSpot.googleSync ? 16 : 24),
        );
        // The spotlight follows the panel's own resize. The guide keeps
        // the same travel clock as every other slide, without restarting
        // or rebasing the easing on each measurement.
        if (_followSettingsResize) {
          _to = target;
        } else {
          if (!_travel.isAnimating && target != _to) {
            _from = _geometry;
            _travel.forward(from: 0);
          }
          _to = target;
        }
        setState(() {
          _spot = rect;
          _appearanceAnchor = appearanceAnchor;
          _measuredSpot = spot;
          _measuredSize = box.size;
        });
      }
    });
  }

  _GuideSide _guideSide(Rect? spot, double width, Size size) {
    if (spot == null) return _GuideSide.center;
    if (_steps(AppScope.of(context))[_index].spot == TourSpot.settingsPreview) {
      if (size.width - spot.right >= width + _gap + _margin) return _GuideSide.right;
      if (spot.left >= width + _gap + _margin) return _GuideSide.left;
      return _GuideSide.above;
    }
    if (size.height - spot.bottom >= 250 + _gap + _margin) return _GuideSide.below;
    if (size.width - spot.right >= width + _gap + _margin) return _GuideSide.right;
    if (spot.left >= width + _gap + _margin) return _GuideSide.left;
    return _GuideSide.above;
  }

  /// The card's top-left: beside the spot where there's room, else below or
  /// above it, kept inside the window.
  Offset _cardAt(Rect? spot, double width, Size size) {
    const height = 250.0;
    double clampX(double x) => x.clamp(_margin, math.max(_margin, size.width - width - _margin));
    double clampY(double y) => y.clamp(_margin, math.max(_margin, size.height - height - _margin));
    return switch (_guideSide(spot, width, size)) {
      _GuideSide.center => Offset((size.width - width) / 2, (size.height - height) / 2 - 20),
      _GuideSide.below => Offset(clampX(spot!.right - width), spot.bottom + _gap),
      _GuideSide.right => Offset(spot!.right + _gap, clampY(spot.top)),
      _GuideSide.left => Offset(spot!.left - _gap - width, clampY(spot.top)),
      _GuideSide.above => Offset(clampX(spot!.left), clampY(spot.top - _gap - height)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    final steps = _steps(state);
    final step = steps[_index];

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        _measure(step.spot);
        // With no spot, the light closes to a point in the middle.
        final spot = step.spot == null ? null : _spot;
        final hole = spot ?? Rect.fromCenter(center: size.center(Offset.zero), width: 0, height: 0);
        final width = spot == null ? _welcomeWidth : _cardWidth;
        _to ??= _TourGeometry(hole: hole, card: _cardAt(spot, width, size), width: width, radius: 24);
        _from ??= _to;
        final scrim = p.brightness == Brightness.dark
            ? const Color(0xFF000000).withValues(alpha: 0.58)
            : p.shadow.withValues(alpha: 0.55);

        return Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.escape) {
              _close();
            } else if (key == LogicalKeyboardKey.arrowRight ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter ||
                key == LogicalKeyboardKey.space) {
              _go(_index + 1, steps.length);
            } else if (key == LogicalKeyboardKey.arrowLeft) {
              _go(_index - 1, steps.length);
            } else {
              return KeyEventResult.ignored;
            }
            return KeyEventResult.handled;
          },
          child: AnimatedOpacity(
            opacity: _shown ? 1 : 0,
            duration: Motion.morph,
            curve: Motion.morphCurve,
            onEnd: () {
              if (!_shown) state.endTour();
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SpotlightPainter(geometry: () => _geometry, changes: _geometryChanges, scrim: scrim),
                  ),
                ),
                Positioned.fill(
                  child: ExcludeFocus(
                    child: IgnorePointer(
                      child: AnimatedSwitcher(
                        duration: Motion.morph,
                        transitionBuilder: (child, animation) => settingsTransition(context, animation, child),
                        child: step.settingsRibbon == null
                            ? const SizedBox.expand()
                            : _SettingsPreview(
                                key: const ValueKey('tour-settings'),
                                ribbon: step.settingsRibbon!,
                                geometry: () => _geometry,
                                changes: _geometryChanges,
                                scrim: scrim,
                              ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: _appearanceAnchor == null ? 32 : size.width - _appearanceAnchor!.right,
                  top: _appearanceAnchor == null ? 110 : _appearanceAnchor!.bottom + 8,
                  bottom: 24,
                  width: 330,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: ExcludeFocus(
                      child: IgnorePointer(
                        child: AnimatedSwitcher(
                          duration: Motion.morph,
                          transitionBuilder: (child, animation) => fadeMenuTransition(animation, child),
                          child: step.spot != TourSpot.appearancePreview
                              ? const SizedBox.shrink()
                              : TourTarget(
                                  key: const ValueKey('tour-appearance'),
                                  spot: TourSpot.appearancePreview,
                                  child: Material(
                                    color: p.tile,
                                    elevation: 0,
                                    shadowColor: p.shadow.withValues(alpha: 0.15),
                                    surfaceTintColor: Colors.transparent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      side: BorderSide(color: p.tileBorder),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: SingleChildScrollView(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                        child: widget.appearanceBuilder(context),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                // The tour owns input while the real panel transitions play.
                Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque)),
                AnimatedBuilder(
                  animation: _geometryChanges,
                  builder: (context, child) {
                    final frame = _geometry;
                    return Positioned(
                      key: const ValueKey('tour-guide'),
                      left: frame.card.dx,
                      top: frame.card.dy,
                      width: frame.width,
                      child: child!,
                    );
                  },
                  child: _Card(
                    index: _index,
                    count: steps.length,
                    child: FadeThrough(
                      layoutBuilder: FadeThrough.sizeToCurrent,
                      child: _StepBody(
                        key: ValueKey(_index),
                        step: step,
                        welcome: _index == 0,
                        last: _index == steps.length - 1,
                        onNext: () => _go(_index + 1, steps.length),
                        onBack: _index == 0 ? null : () => _go(_index - 1, steps.length),
                        onSkip: _close,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Each entering/exiting copy clips its shade to its own panel, even if the
/// user reverses direction before the previous transition has finished.
class _SettingsPreview extends StatefulWidget {
  const _SettingsPreview({
    super.key,
    required this.ribbon,
    required this.geometry,
    required this.changes,
    required this.scrim,
  });
  final int ribbon;
  final _TourGeometry Function() geometry;
  final Listenable changes;
  final Color scrim;

  @override
  State<_SettingsPreview> createState() => _SettingsPreviewState();
}

class _SettingsPreviewState extends State<_SettingsPreview> {
  final _panelKey = GlobalKey();

  Rect? _surface() {
    final panel = _panelKey.currentContext?.findRenderObject();
    final box = context.findRenderObject();
    if (panel is! RenderBox || box is! RenderBox || !panel.hasSize) return null;
    return MatrixUtils.transformRect(panel.getTransformTo(box), Offset.zero & panel.size);
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      SettingsDialog(tourRibbon: widget.ribbon, tourTargetKey: _panelKey),
      // Fade and scale the panel and its shade together, avoiding a full-size
      // dark ghost around a panel that is still entering.
      Positioned.fill(
        child: CustomPaint(
          painter: _SpotlightPainter(
            geometry: widget.geometry,
            changes: widget.changes,
            scrim: widget.scrim,
            surface: _surface,
          ),
        ),
      ),
    ],
  );
}

/// One clock moves both the spotlight and its guide; layout changes update
/// the destination without starting a second, trailing animation.
class _TourGeometry {
  const _TourGeometry({required this.hole, required this.card, required this.width, required this.radius});
  final Rect hole;
  final Offset card;
  final double width, radius;

  static _TourGeometry lerp(_TourGeometry a, _TourGeometry b, double t) {
    if (t <= 0) return a;
    if (t >= 1 || a == b) return b;
    return _TourGeometry(
      hole: Rect.lerp(a.hole, b.hole, t)!,
      card: Offset.lerp(a.card, b.card, t)!,
      width: a.width + (b.width - a.width) * t,
      radius: a.radius + (b.radius - a.radius) * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _TourGeometry &&
      other.hole == hole &&
      other.card == card &&
      other.width == width &&
      other.radius == radius;
  @override
  int get hashCode => Object.hash(hole, card, width, radius);
}

/// Repaints the moving light without rebuilding the menus and their content.
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({required this.geometry, required Listenable changes, required this.scrim, this.surface})
    : super(repaint: changes);
  final _TourGeometry Function() geometry;
  final Color scrim;
  final Rect? Function()? surface;

  Rect get hole => geometry().hole;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = geometry();
    canvas.save();
    if (surface != null) {
      final bounds = surface!();
      if (bounds == null) {
        canvas.restore();
        return;
      }
      canvas.clipRRect(RRect.fromRectAndRadius(bounds, const Radius.circular(24)));
    }
    final radius = math.min(frame.radius, hole.shortestSide / 2);
    // Even-odd fill avoids a path boolean operation on every animation frame.
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(RRect.fromRectAndRadius(hole, Radius.circular(radius))),
      Paint()..color = scrim,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => true;
}

/// The tour's card: a tile with the step dots along the top.
class _Card extends StatelessWidget {
  const _Card({required this.index, required this.count, required this.child});

  final int index, count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.9)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < count; i++)
                AnimatedContainer(
                  duration: Motion.morph,
                  curve: Motion.morphCurve,
                  width: i == index ? 20 : 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: i < index ? p.done : (i == index ? null : p.empty),
                    gradient: i == index ? LinearGradient(colors: p.gradient.skip(1).toList()) : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _StepBody extends StatelessWidget {
  const _StepBody({
    super.key,
    required this.step,
    required this.welcome,
    required this.last,
    required this.onNext,
    required this.onBack,
    required this.onSkip,
  });

  final _Step step;
  final bool welcome, last;
  final VoidCallback onNext, onSkip;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          step.title,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: welcome ? 30 : 22,
            fontWeight: FontWeight.w600,
            letterSpacing: welcome ? -0.9 : -0.5,
            height: 1.1,
            color: p.ink,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          step.body,
          style: TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.5, color: p.inkMuted),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            if (!last) _TextButton(label: welcome ? 'Skip' : 'Skip tour', onTap: onSkip),
            const Spacer(),
            if (onBack != null) ...[_TextButton(label: 'Back', onTap: onBack!), const SizedBox(width: 6)],
            _PillButton(label: welcome ? 'Show me around' : (last ? 'Get started' : 'Next'), onTap: onNext),
          ],
        ),
      ],
    );
  }
}

class _TextButton extends StatefulWidget {
  const _TextButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_TextButton> createState() => _TextButtonState();
}

class _TextButtonState extends State<_TextButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: p.empty.withValues(alpha: _hover ? 0.8 : 0),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            widget.label,
            style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, fontWeight: FontWeight.w600, color: p.inkMuted),
          ),
        ),
      ),
    );
  }
}

/// The step forward, filled with the theme's gradient like the other pills.
class _PillButton extends StatefulWidget {
  const _PillButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedSlide(
          offset: Offset(0, _hover ? -0.04 : 0),
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(colors: p.gradient.skip(1).toList()),
            ),
            child: Text(
              widget.label,
              style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, fontWeight: FontWeight.w600, color: p.onAccent),
            ),
          ),
        ),
      ),
    );
  }
}
