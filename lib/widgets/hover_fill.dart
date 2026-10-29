import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The soft tint behind a row under the pointer. It fades its opacity
/// rather than its colour: easing a colour in from transparent passes
/// through a darker shade, which flashed as the pointer crossed rows.
class HoverFill extends StatelessWidget {
  const HoverFill({super.key, required this.hover, this.drop = 0, required this.child});

  final bool hover;

  /// How far the tint sits below the row, the row keeping its place: Matter's
  /// letters sit low in their line, so a lone line's tint drops to centre on
  /// them, as its tick box does.
  final double drop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Stack(
      // Sized by [child]; the tint just fills it.
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: drop,
          bottom: -drop,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: hover ? 1 : 0,
              duration: Motion.hover,
              curve: Motion.hoverCurve,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.empty.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
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
