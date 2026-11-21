part of 'todo_panel.dart';

class _Check extends StatefulWidget {
  const _Check({required this.done, required this.hover, required this.pressed});

  final bool done;
  final bool hover;
  final bool pressed;

  @override
  State<_Check> createState() => _CheckState();
}

class _CheckState extends State<_Check> with TickerProviderStateMixin {
  late final _fill = AnimationController(vsync: this, duration: Motion.click, value: widget.done ? 1 : 0);
  late final _curved = CurvedAnimation(parent: _fill, curve: Motion.clickCurve);
  late final _hover = AnimationController(vsync: this, duration: Motion.hover);

  bool get _disabled => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void didUpdateWidget(_Check old) {
    super.didUpdateWidget(old);
    if (widget.done != old.done) {
      if (_disabled) {
        _fill.value = widget.done ? 1 : 0;
      } else {
        widget.done ? _fill.forward() : _fill.reverse();
      }
    }
    if (widget.hover != old.hover) {
      if (_disabled) {
        _hover.value = widget.hover ? 1 : 0;
      } else {
        widget.hover ? _hover.animateTo(1, curve: Motion.hoverCurve) : _hover.animateBack(0, curve: Motion.hoverCurve);
      }
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _fill.dispose();
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: PressScale(
        hover: widget.hover,
        pressed: widget.pressed,
        lift: 1.06,
        dip: 0.88,
        child: CustomPaint(
          size: Size.square(MediaQuery.textScalerOf(context).scale(20)),
          painter: _CheckPainter(fill: _curved, hover: _hover, palette: context.palette),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.fill, required this.hover, required this.palette})
    : super(repaint: Listenable.merge([fill, hover]));

  final Animation<double> fill;
  final Animation<double> hover;
  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final t = fill.value;
    final h = hover.value;
    final centre = size.center(Offset.zero);
    final r = size.width / 2;

    // The ring fades as the fill arrives, so there's never a hard swap.
    final ring = Color.lerp(p.inkMuted.withValues(alpha: 0.38), p.accent.withValues(alpha: 0.6), h)!;
    // A filled ring: a stroked circle comes out jagged under Impeller on Linux.
    final outer = RRect.fromRectAndRadius(Rect.fromCircle(center: centre, radius: r), Radius.circular(r));
    canvas.drawDRRect(outer, outer.deflate(1.5), Paint()..color = ring.withValues(alpha: ring.a * (1 - t)));
    if (t > 0) {
      canvas.drawCircle(centre, r, Paint()..color = p.done.withValues(alpha: t));
    }

    // The tick grows in after the fill, as on a ritual square.
    paintMark(canvas, centre, Icons.check_rounded, size.width * 0.65, p.onAccent, Motion.incoming.transform(t));
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.palette != palette || old.fill != fill || old.hover != hover;
}

/// A subtask being dragged to a new place in its task.
class _SubtaskDrag {
  const _SubtaskDrag(this.itemId, this.index);
  final int itemId;
  final int index;
}

/// A subtask, laid out, tinted and ticked as a task row is.
class _SubtaskRow extends StatefulWidget {
  const _SubtaskRow({
    required this.done,
    required this.text,
    this.note,
    required this.number,
    required this.readOnly,
    required this.onToggle,
    required this.onEdit,
    required this.onNote,
    required this.onRemove,
  });

  final bool done;
  final String text;
  final String? note;

  /// Its place in a numbered list.
  final int? number;
  final bool readOnly;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onNote;
  final VoidCallback onRemove;

  @override
  State<_SubtaskRow> createState() => _SubtaskRowState();
}

class _SubtaskRowState extends State<_SubtaskRow> with _HoverUnlessDragging {
  bool _pressed = false;
  bool _actions = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final done = widget.done;
    return Focus(
      canRequestFocus: !widget.readOnly,
      descendantsAreFocusable: !widget.readOnly,
      onFocusChange: (focused) {
        if (_focused != focused) {
          setState(() {
            _focused = focused;
            if (focused && !widget.readOnly) _actions = true;
          });
        }
      },
      onKeyEvent: widget.readOnly
          ? null
          : (node, event) {
              if (node.hasPrimaryFocus &&
                  event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.space)) {
                widget.onToggle();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
      child: MouseRegion(
        cursor: widget.readOnly ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: widget.readOnly ? null : (_) => setState(() => _pointer = _actions = true),
        onExit: widget.readOnly
            ? null
            : (_) => setState(() {
                _pointer = false;
                _pressed = false;
              }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.readOnly ? null : (_) => setState(() => _pressed = true),
          onTapUp: widget.readOnly ? null : (_) => setState(() => _pressed = false),
          onTapCancel: widget.readOnly ? null : () => setState(() => _pressed = false),
          onTap: widget.readOnly ? null : widget.onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: HoverFill(
              hover: _hover,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    _Check(done: done, hover: _hover, pressed: _pressed),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AnimatedDefaultTextStyle(
                        duration: context.themed(Motion.click),
                        curve: Motion.clickCurve,
                        style: TextStyle(
                          fontFamily: Fonts.body,
                          fontSize: 15,
                          height: 1.35,
                          color: done ? p.inkMuted : p.ink,
                          decoration: done ? TextDecoration.lineThrough : null,
                          decorationColor: p.inkMuted.withValues(alpha: 0.45),
                        ),
                        // One paragraph, as a task's time and name, so the
                        // number keeps the text's baseline at any scale; two
                        // round to the pixel apart.
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  if (widget.number case final number?)
                                    TextSpan(text: '$number. ', style: _timeStyle(p).copyWith(height: 1.35)),
                                  TextSpan(text: widget.text),
                                ],
                              ),
                            ),
                            if (widget.note case final note?)
                              _NoteLine(note, onTap: widget.readOnly ? null : widget.onNote),
                          ],
                        ),
                      ),
                    ),
                    if (!widget.readOnly)
                      IgnorePointer(
                        ignoring: !_hover,
                        child: ExcludeFocus(
                          excluding: !_hover,
                          child: AnimatedOpacity(
                            opacity: _hover ? 1 : 0,
                            duration: context.themed(Motion.hover),
                            curve: Motion.hoverCurve,
                            onEnd: () {
                              if (mounted && !_hover) {
                                setState(() => _actions = false);
                              }
                            },
                            child: !_actions
                                // The two buttons' room, so the text never reflows.
                                ? const SizedBox(width: 2 * _TaskAction.size, height: _TaskAction.size)
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _TaskAction(
                                        tooltip: 'Edit subtask',
                                        icon: Icons.edit_rounded,
                                        onPressed: widget.onEdit,
                                      ),
                                      _TaskAction(
                                        tooltip: 'Remove subtask',
                                        icon: Icons.close_rounded,
                                        onPressed: widget.onRemove,
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A task's or subtask's note under its name, muted and never struck
/// through, up to three lines. Clicking it opens it.
class _NoteLine extends StatelessWidget {
  const _NoteLine(this.note, {this.onTap});

  final String note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(
      fontFamily: Fonts.body,
      fontSize: 12,
      height: 1.35,
      color: p.inkMuted,
      decoration: TextDecoration.none,
    );
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          // The icon centred on the first line, the lines after it lined up
          // under the first.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: style.fontSize! * style.height! * MediaQuery.textScalerOf(context).scale(1),
                child: Center(child: Icon(Icons.notes_rounded, size: 12, color: p.inkMuted)),
              ),
              const SizedBox(width: 4),
              Flexible(child: Text(note, maxLines: 3, overflow: TextOverflow.ellipsis, style: style)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line over a task's name: its weekday further ahead, its time and
/// where it is, joined with dots, and Birthday for one.
class _Caption extends StatelessWidget {
  const _Caption({this.weekday, this.time, this.location, this.birthday = false, this.gap = false});

  final String? weekday;
  final int? time;
  final String? location;
  final bool birthday;

  /// A gap under it even without a weekday, as over a birthday further ahead.
  final bool gap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final plain = TextStyle(fontFamily: Fonts.ui, fontSize: 12, color: p.inkMuted);
    final dot = Text('  ·  ', style: plain);
    final (weekday, time, location) = (this.weekday, this.time, this.location);
    final timeStyle = _taskTimeStyle(p).copyWith(height: 1.35);
    final scaler = MediaQuery.textScalerOf(context);
    double width(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    return Padding(
      // A weekday heads a task further ahead with a gap under it.
      padding: EdgeInsets.only(bottom: weekday == null && !gap ? 0 : 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The weekday and time are always whole, the location giving way
          // first, unless the card can't even hold those two.
          final dots = [weekday, time, location ?? (birthday ? '' : null)].nonNulls.length - 1;
          final whole =
              (weekday == null ? 0 : width(weekday, plain)) +
              (time == null ? 0 : width(clockLabel(time), timeStyle)) +
              (dots < 1 ? 0 : dots * width('  ·  ', plain)) +
              // The glyph before what gives way.
              (location != null || birthday ? scaler.scale(19) : 0);
          Widget part(Widget text) => whole > constraints.maxWidth ? Flexible(child: text) : text;
          return Row(
            children: [
              if (weekday != null) part(Text(weekday, maxLines: 1, overflow: TextOverflow.ellipsis, style: plain)),
              if (time != null) ...[
                if (weekday != null) dot,
                part(Text(clockLabel(time), maxLines: 1, overflow: TextOverflow.ellipsis, style: timeStyle)),
              ],
              if (location != null) ...[
                if (weekday != null || time != null) dot,
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Icon(Icons.place_rounded, size: 12, color: p.inkMuted),
                ),
                Flexible(
                  child: Text(
                    location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: plain.copyWith(height: 1.35, decoration: TextDecoration.none),
                  ),
                ),
              ],
              if (birthday) ...[
                if (weekday != null || time != null || location != null) dot,
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: Icon(_birthdayIcon, size: 14, color: p.inkMuted),
                ),
                Flexible(
                  child: Text('Birthday', maxLines: 1, overflow: TextOverflow.ellipsis, style: plain),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
