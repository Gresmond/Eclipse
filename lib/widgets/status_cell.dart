import 'dart:async';

import 'fade_menu.dart';
import 'ritual_goal.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryButton, kSecondaryButton, kTertiaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/lru_cache.dart';
import 'app_dialog.dart';
import 'confirm_on_enter.dart';
import 'mark.dart';
import 'note_input.dart';
import '../theme/pixels.dart';

/// A habit-day square: left-click done, right-click not done, middle-click
/// or Alt-click other (trackpads have no middle button). Repeat the
/// same click to clear its mark.
///
/// A month shows hundreds of these at once, so each is kept to a handful of
/// widgets: one pointer listener rather than a gesture detector, and its
/// lift, dip and greying drawn by its painter rather than wrapper widgets.
class StatusCell extends StatefulWidget {
  const StatusCell({
    super.key,
    required this.day,
    required this.habit,
    this.size = 34,
    this.enabled = true,
    this.rest = false,
    this.off = false,
    this.paletteAnimation,
    this.staysThroughDays = false,
  });

  final DateTime day;
  final Habit habit;
  final double size;
  final bool enabled;

  /// A rest day (a weekend, when that's turned on): greyed while blank.
  final bool rest;

  /// A day the ritual isn't on: no square, and nothing to click. Still a
  /// cell, so a square turning off or on with the month fades like the rest.
  final bool off;

  /// Large grids repaint theme colors without rebuilding every cell.
  final ValueListenable<Palette>? paletteAnimation;

  /// This one square shows each day in turn, among things that fade through
  /// from day to day: on a new [day] the old mark and colour fade out and the
  /// new ones fade in on the same beat, the square itself staying put.
  final bool staysThroughDays;

  @override
  State<StatusCell> createState() => _StatusCellState();
}

class _StatusCellState extends State<StatusCell> with TickerProviderStateMixin {
  bool _hover = false;

  /// The buttons of the press in progress; null when not pressed.
  int? _buttons;
  Offset? _pressStart;
  Timer? _longPressTimer;
  bool get _pressed => _buttons != null;

  /// A click changes a square quickly; a new month eases it in step with
  /// the grid's morph, so a whole month of colours doesn't snap in at once.
  static const _click = (Motion.click, Motion.clickCurve);
  static const _morph = (Motion.morph, Motion.morphCurve);
  static const _day = (Motion.page, Curves.linear);
  (Duration, Curve) _change = _click;

  /// Whether the mark being moved to goes by way of a blank square.
  var _through = false;

  /// The mark being left and the one being moved to; [_progress] runs
  /// between them. Only the square's paint follows it, so a month of
  /// squares changing at once never rebuilds a widget per frame.
  _Look? _from;
  _Look? _to;
  AnimationController? _progress, _hoverAnim;
  CurvedAnimation? _curved;

  /// Lift and dip, and greying while disabled or resting: still values until they first
  /// change, so a square that's never touched holds no controller.
  AnimationController? _scale, _opacity;
  double? _scaleTarget, _opacityTarget;

  bool get _disabled => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_disabled) {
      _progress?.value = 1;
      if (_scaleTarget case final s?) _scale?.value = s;
      if (_opacityTarget case final o?) _opacity?.value = o;
      _hoverAnim?.value = _hover && widget.enabled && !widget.off ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(StatusCell old) {
    super.didUpdateWidget(old);
    _change = old.day == widget.day
        ? _click
        : widget.staysThroughDays
        ? _day
        : _morph;
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _curved?.dispose();
    _progress?.dispose();
    _hoverAnim?.dispose();
    _scale?.dispose();
    _opacity?.dispose();
    super.dispose();
  }

  void _setHover(bool hover) {
    _hover = hover;
    final animation = _hoverAnim ??= AnimationController(vsync: this, duration: Motion.hover);
    if (_disabled) {
      animation.value = hover ? 1 : 0;
    } else if (hover) {
      animation.animateTo(1, curve: Motion.hoverCurve);
    } else {
      animation.animateBack(0, curve: Motion.hoverCurve);
    }
  }

  /// Eases [controller] to [target], making it on the first change.
  Animation<double> _ease(
    AnimationController? controller,
    double? from,
    double target,
    Duration duration,
    Curve curve,
    void Function(AnimationController) keep,
  ) {
    if (_disabled || duration == Duration.zero) {
      controller?.value = target;
      return controller ?? AlwaysStoppedAnimation(target);
    }
    if (from == null || from == target) return controller ?? AlwaysStoppedAnimation(target);
    final c = controller ?? AnimationController.unbounded(vsync: this, value: from);
    if (controller == null) keep(c);
    c.animateTo(target, duration: duration, curve: curve);
    return c;
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  Future<void> _showStatusMenu(BuildContext context, AppState state, HabitStatus current) async {
    if (!state.canEditDay(widget.day)) return;
    final p = context.palette;
    HabitStatus? picked;
    var clear = false;
    await showFadeMenu(
      context,
      width: 210,
      builder: (menu) {
        Widget option(IconData icon, Color color, String label, VoidCallback onTap) => FadeMenuRow(
          height: 44,
          onTap: () {
            Navigator.pop(menu);
            onTap();
          },
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(fontFamily: Fonts.ui, fontSize: 15, color: p.ink),
              ),
            ],
          ),
        );

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            option(
              Icons.check_rounded,
              p.done,
              widget.habit.target != null ? 'Log progress' : 'Done',
              () => picked = HabitStatus.done,
            ),
            option(Icons.close_rounded, p.missedInk, 'Not done', () => picked = HabitStatus.missed),
            option(Icons.remove_rounded, p.otherInk, 'Other', () => picked = HabitStatus.other),
            if (current != HabitStatus.none) ...[
              const FadeMenuDivider(),
              option(Icons.restart_alt_rounded, p.inkMuted, 'Clear mark', () => clear = true),
            ],
          ],
        );
      },
    );
    if (!context.mounted) return;
    if (clear) {
      await _selectStatus(context, state, widget.day, widget.habit, current);
    } else if (picked case final status?) {
      await _selectStatus(context, state, widget.day, widget.habit, status);
    }
  }

  void _down(PointerDownEvent event, AppState state, HabitStatus status) {
    if (!widget.enabled || _pressed) return;
    if (event.buttons & (kPrimaryButton | kSecondaryButton | kTertiaryButton) == 0) return;
    _cancelLongPress();
    _pressStart = event.localPosition;
    setState(() => _buttons = event.buttons);
    if (event.kind != PointerDeviceKind.mouse && (event.buttons & kPrimaryButton) != 0) {
      _longPressTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted || _buttons == null || !widget.enabled) return;
        setState(() => _buttons = null);
        _showStatusMenu(context, state, status);
      });
    }
  }

  void _move(PointerMoveEvent event) {
    final start = _pressStart;
    if (_longPressTimer != null && start != null && (event.localPosition - start).distance > 12) {
      _cancelLongPress();
    }
  }

  void _up(PointerUpEvent event, AppState state) {
    _cancelLongPress();
    final buttons = _buttons;
    if (buttons == null) return;
    setState(() => _buttons = null);
    // A press that slid off the square, as with a tap, does nothing.
    final size = context.size;
    if (!widget.enabled || size == null || !(Offset.zero & size).contains(event.localPosition)) return;
    final status = buttons & kSecondaryButton != 0
        ? HabitStatus.missed
        : buttons & kTertiaryButton != 0 || HardwareKeyboard.instance.isAltPressed
        ? HabitStatus.other
        : HabitStatus.done;
    _selectStatus(context, state, widget.day, widget.habit, status);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.paletteAnimation?.value ?? context.palette;
    final hasTarget = widget.habit.target != null;
    final state = AppScope.watch(
      context,
      (s) => (
        s.statusOf(widget.day, widget.habit),
        s.noteOf(widget.day, widget.habit),
        hasTarget ? s.amountOn(widget.day, widget.habit) : 0,
      ),
    );
    final status = state.statusOf(widget.day, widget.habit);
    final note = state.noteOf(widget.day, widget.habit);
    final amount = hasTarget ? state.amountOn(widget.day, widget.habit) : 0;
    final target = widget.habit.target;
    final partial = target != null && target > 0 && status == HabitStatus.none && amount > 0
        ? (amount / target).clamp(0.0, 1.0)
        : 0.0;
    final enabled = widget.enabled && !widget.off;

    final look = switch (status) {
      HabitStatus.none => const _Look(null, null),
      HabitStatus.done => _Look(p.done, Icons.check_rounded),
      HabitStatus.missed => _Look(p.missed, Icons.close_rounded),
      HabitStatus.other => _Look(p.other, Icons.remove_rounded),
    };
    if (_to == null) {
      _from = _to = look;
    } else if (look != _to) {
      // A theme change recolours at once; a new mark eases in.
      final themeOnly = look.icon == _to!.icon;
      if (_disabled) {
        _from = _to = look;
        _progress?.value = 1;
      } else {
        _from = themeOnly ? look : _to;
        _to = look;
        _through = identical(_change, _day);
        if (!themeOnly) {
          final animation = _progress ??= AnimationController(vsync: this, value: 1);
          _curved ??= CurvedAnimation(parent: animation, curve: _change.$2);
          animation.duration = _change.$1;
          _curved!.curve = _change.$2;
          animation.forward(from: 0);
        }
      }
    }

    final scaleTarget = _pressed ? 0.91 : (_hover && enabled ? 1.04 : 1.0);
    final scale = _ease(_scale, _scaleTarget, scaleTarget, Motion.hover, Motion.hoverCurve, (c) => _scale = c);
    _scaleTarget = scaleTarget;
    final opacityTarget = widget.off
        ? 0.0
        : status != HabitStatus.none
        ? 1.0
        : !enabled
        ? 0.35
        : (widget.rest ? 0.45 : 1.0);
    final opacity = _ease(
      _opacity,
      _opacityTarget,
      opacityTarget,
      identical(_change, _day) ? Motion.page : Motion.morph,
      identical(_change, _day) ? Motion.incoming : Motion.morphCurve,
      (c) => _opacity = c,
    );
    _opacityTarget = opacityTarget;

    // A note's tooltip coming or going rebuilds only this; the square's
    // animations live in this state.
    Widget cell = RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _SquarePainter(
          from: _from!,
          to: _to!,
          progress: _curved ?? kAlwaysCompleteAnimation,
          through: _through,
          partial: partial,
          hover: enabled ? (_hoverAnim ?? kAlwaysDismissedAnimation) : kAlwaysDismissedAnimation,
          scale: scale,
          opacity: opacity,
          basePalette: p,
          paletteAnimation: widget.paletteAnimation,
        ),
      ),
    );

    final unitText = widget.habit.unit;
    final progressTip = target != null && amount > 0
        ? '$amount / $target${unitText == null || unitText.isEmpty ? '' : ' $unitText'}'
        : null;
    final tip = [?progressTip, ?note].join('\n');
    if (tip.isNotEmpty && !widget.off) {
      cell = PixelTooltip(message: tip, child: cell);
    }

    if (!widget.off) {
      final label = [
        widget.habit.name,
        if (status != HabitStatus.none) status.name,
        ?progressTip,
      ].join(', ');
      cell = Semantics(
        button: enabled,
        enabled: enabled,
        label: label,
        onTap: enabled
            ? () => _selectStatus(
                context,
                state,
                widget.day,
                widget.habit,
                status == HabitStatus.done ? HabitStatus.none : HabitStatus.done,
              )
            : null,
        onLongPress: enabled ? () => _showStatusMenu(context, state, status) : null,
        child: cell,
      );
    }

    // The same widgets whether enabled or not, so a square that becomes a
    // future day (when the month changes) fades instead of jumping.
    return ExcludeSemantics(
      excluding: widget.off,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() {
          _setHover(true);
          _change = _click;
        }),
        onExit: (_) {
          _cancelLongPress();
          setState(() {
            _setHover(false);
            _buttons = null;
          });
        },
        child: Listener(
          onPointerDown: (event) => _down(event, state, status),
          onPointerMove: _move,
          onPointerUp: (event) => _up(event, state),
          onPointerCancel: (_) {
            _cancelLongPress();
            setState(() => _buttons = null);
          },
          child: cell,
        ),
      ),
    );
  }
}

/// What a square shows for one status: its colour (none when blank) and mark.
class _Look {
  const _Look(this.base, this.icon);

  final Color? base;
  final IconData? icon;

  @override
  bool operator ==(Object other) => other is _Look && other.base == base && other.icon == icon;

  @override
  int get hashCode => Object.hash(base, icon);
}

/// Paints a square partway from one [_Look] to another. Colours blend
/// straight across; the old mark shrinks away before the new one grows in,
/// so a tick and a cross never overlap.
class _SquarePainter extends CustomPainter {
  _SquarePainter({
    required this.from,
    required this.to,
    required this.progress,
    required this.through,
    required this.partial,
    required this.hover,
    required this.scale,
    required this.opacity,
    required this.basePalette,
    this.paletteAnimation,
  }) : super(repaint: Listenable.merge([progress, hover, scale, opacity, ?paletteAnimation]));

  final _Look from;
  final _Look to;
  final Animation<double> progress;

  /// Whether [from]'s colour eases out to a blank square as its mark does,
  /// and [to]'s in from one, rather than one turning into the other.
  final bool through;
  final double partial;
  final Animation<double> hover;

  /// Lifted on hover, dipped while pressed, about the centre.
  final Animation<double> scale;

  /// Below 1 while blank and disabled, or blank on a rest day. A marked
  /// square keeps its full colour, however old its day.
  final Animation<double> opacity;
  final Palette basePalette;
  final ValueListenable<Palette>? paletteAnimation;
  Palette get palette => paletteAnimation?.value ?? basePalette;

  /// Drawn at this size and scaled, so every square shares its marks.
  static const _s = 34.0;

  /// The squares' gradients by colour, shared. A theme's fade makes new
  /// ones every frame, so only the latest are kept.
  static final _gradients = LruCache<(Color, Color), Shader>(64);

  List<Color> _fill(_Look look, Color empty) {
    final base = switch (look.icon) {
      Icons.check_rounded => palette.done,
      Icons.close_rounded => palette.missed,
      Icons.remove_rounded => palette.other,
      _ => null,
    };
    return base == null ? [empty, empty] : [Color.lerp(base, Colors.white, 0.16)!, base];
  }

  Color _border(_Look l, double h) => l.base == null
      ? Color.lerp(palette.border, palette.accent.withValues(alpha: 0.35), h)!
      : Colors.white.withValues(alpha: 0.18);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final h = hover.value;
    final fade = opacity.value.clamp(0.0, 1.0);
    if (fade <= 0) return;
    if (fade < 1) {
      // The whole square fades as one, as an opacity layer would.
      canvas.saveLayer((Offset.zero & size).inflate(size.width * 0.1), Paint()..color = Color.fromRGBO(0, 0, 0, fade));
    }
    // At rest a lifted square grows by whole pixels each side, so its edges
    // stay on them.
    var grow = scale.value;
    if (grow != 1 && !scale.isAnimating) {
      final side = pixelRound(size.width * (grow - 1) / 2);
      final least = grow > 1 ? pixelCeil(0.001) : -pixelCeil(0.001);
      grow = 1 + 2 * (side == 0 ? least : side) / size.width;
    }
    if (grow != 1) {
      canvas.translate(size.width / 2, size.height / 2);
      canvas.scale(grow);
      canvas.translate(-size.width / 2, -size.height / 2);
    }
    canvas.scale(size.width / _s);
    // The edge and its inside on whole pixels, whatever size this is drawn at.
    final edge = pixelRound(size.width / _s) * _s / size.width;
    const rect = Rect.fromLTWH(0, 0, _s, _s);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(_s * 0.28));
    final empty = palette.empty.withValues(alpha: 0.55 + 0.35 * h);

    final a = _fill(from, empty), b = _fill(to, empty);
    // How far from [from], and how far to [to]: one number unless going
    // through a blank square, which is what's between them then.
    final (leaving, arriving) = through ? (1 - Motion.outgoing(t), Motion.incoming.transform(t)) : (t, t);
    Color between(Color from, Color to, Color blank) =>
        through ? Color.lerp(Color.lerp(from, blank, leaving), to, arriving)! : Color.lerp(from, to, t)!;
    final (top, bottom) = (between(a[0], b[0], empty), between(a[1], b[1], empty));
    // A month repaints hundreds of squares, in only a few colours: a blank
    // one needs no gradient, and the others share theirs.
    final fill = Paint();
    if (top == bottom) {
      fill.color = top;
    } else {
      fill.shader = _gradients.putIfAbsent(
        (top, bottom),
        () => LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [top, bottom],
        ).createShader(rect),
      );
    }
    // Impeller on Linux leaves a gradient's edge jagged, so a solid square in
    // about the same colour gives the smooth edge, with the gradient inside it.
    if (top == bottom) {
      canvas.drawRRect(rrect, fill);
    } else {
      canvas.drawRRect(rrect, Paint()..color = Color.lerp(top, bottom, 0.5)!);
      canvas.drawRRect(rrect.deflate(edge), fill);
    }
    if (partial > 0 && from.base == null && to.base == null) {
      final y = _s * (1 - partial);
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRect(
        Rect.fromLTWH(0, y, _s, _s - y),
        Paint()..color = palette.done.withValues(alpha: 0.28),
      );
      canvas.drawLine(
        Offset(0, y),
        Offset(_s, y),
        Paint()
          ..color = palette.done
          ..strokeWidth = edge,
      );
      canvas.restore();
    }
    canvas.drawRRect(
      rrect.deflate(edge / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = edge
        ..color = between(_border(from, h), _border(to, h), _border(const _Look(null, null), h)),
    );

    // The old mark eases out, then the new one grows in.
    const centre = Offset(_s / 2, _s / 2);
    if (from.icon case final icon? when icon != to.icon) {
      paintMark(canvas, centre, icon, _s * 0.54, palette.onAccent, Motion.outgoing(t));
    }
    if (to.icon case final icon?) {
      paintMark(
        canvas,
        centre,
        icon,
        _s * 0.54,
        palette.onAccent,
        from.icon == icon ? 1 : Motion.incoming.transform(t),
      );
    }
    // A faint plus on a blank square under the pointer.
    final blank = (from.base == null ? 1 - t : 0) + (to.base == null ? t : 0);
    paintMark(canvas, centre, Icons.add_rounded, _s * 0.45, palette.inkMuted.withValues(alpha: 0.4), h * blank);
    if (fade < 1) canvas.restore();
  }

  @override
  bool shouldRepaint(_SquarePainter old) =>
      old.from != from ||
      old.to != to ||
      old.partial != partial ||
      old.basePalette != basePalette ||
      old.paletteAnimation != paletteAnimation ||
      old.progress != progress ||
      old.through != through ||
      old.hover != hover ||
      old.scale != scale ||
      old.opacity != opacity;
}

Future<void> _selectStatus(BuildContext context, AppState state, DateTime day, Habit habit, HabitStatus status) async {
  if (!state.canEditDay(day)) return;
  if (status==HabitStatus.done && habit.target!=null) return enterRitualAmount(context,day,habit);
  if (state.selectStatus(day, habit, status) != HabitStatus.other) return;
  final note = await showAppDialog<String>(
    context: context,
    builder: (_) => _NoteDialog(habit: habit, initial: state.noteOf(day, habit)),
  );
  if (note != null && state.canEditDay(day)) state.setNote(day, habit, note);
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.habit, this.initial});

  final Habit habit;
  final String? initial;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ConfirmOnEnter(
      onConfirm: () => Navigator.pop(context, _controller.text),
      child: Dialog(
        backgroundColor: p.tile,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(dialogRadius)),
        child: SizedBox(
          width: 480,
          child: Padding(
            padding: dialogPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.habit.name.toUpperCase(), style: capsLabel(p.otherInk)),
                const SizedBox(height: 8),
                Text('What happened?', style: dialogTitleStyle(p)),
                const SizedBox(height: 18),
                TextField(
                  inputFormatters: const [NoteInputFormatter()],
                  controller: _controller,
                  autofocus: true,
                  maxLines: 3,
                  minLines: 2,
                  // Enter saves; long notes still wrap onto more lines.
                  textInputAction: TextInputAction.done,
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
                  decoration: InputDecoration(
                    hintText: 'Optional note',
                    hintStyle: TextStyle(color: p.inkMuted),
                    filled: true,
                    fillColor: p.empty,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (v) => Navigator.pop(context, v),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DialogDismiss(label: 'Skip', onPressed: () => Navigator.pop(context)),
                    const SizedBox(width: 6),
                    DialogConfirm(label: 'Save note', onPressed: () => Navigator.pop(context, _controller.text)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
