import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Builds [builder] with whether the pointer is over it (or keyboard-focused
/// when [focusable]). Given [onTap], it handles the click and shows the hand
/// (unless [cursor] says otherwise).
class Hoverable extends StatefulWidget {
  const Hoverable({
    super.key,
    this.onTap,
    this.cursor,
    this.behavior,
    this.focusable = false,
    this.semanticLabel,
    required this.builder,
  });

  final VoidCallback? onTap;
  final MouseCursor? cursor;
  final HitTestBehavior? behavior;
  final bool focusable;
  final String? semanticLabel;
  final Widget Function(bool hover) builder;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(_hover || _focused);
    final tapped = widget.onTap == null && widget.behavior == null
        ? child
        : GestureDetector(behavior: widget.behavior, onTap: widget.onTap, child: child);
    final region = MouseRegion(
      cursor: widget.cursor ?? (widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click),
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: tapped,
    );
    if (!widget.focusable || widget.onTap == null) return region;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: Focus(
        onFocusChange: (focused) {
          if (_focused != focused) setState(() => _focused = focused);
        },
        onKeyEvent: (node, event) {
          if (node.hasPrimaryFocus &&
              event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.space)) {
            widget.onTap?.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: region,
      ),
    );
  }
}

/// The soft tint behind a row under the pointer. It fades its opacity
/// rather than its colour: easing a colour in from transparent passes
/// through a darker shade, which flashed as the pointer crossed rows.
class HoverFill extends StatelessWidget {
  const HoverFill({super.key, required this.hover, required this.child});

  final bool hover;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Stack(
      // Sized by [child]; the tint just fills it.
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: hover ? 1 : 0,
              duration: context.themed(Motion.hover),
              curve: Motion.hoverCurve,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.empty.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
