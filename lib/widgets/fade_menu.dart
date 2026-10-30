import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'hover_fill.dart';

/// Opens [builder]'s panel under [anchor] (over it with [above]), right
/// edges lined up (left edges with [alignLeft]). It fades
/// in as one piece with a slight grow from its corner, at the speed of
/// everything else that arrives, rather than Material's row-by-row reveal.
/// A click outside, or Escape, closes it.
Future<void> showFadeMenu(
  BuildContext anchor, {
  required WidgetBuilder builder,
  double gap = 8,
  double width = 330,
  bool alignLeft = false,
  bool above = false,
}) {
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay = Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return Navigator.of(anchor).push(
    _FadeMenuRoute(
      top: above ? null : rect.bottom + gap,
      bottom: above ? overlay.size.height - rect.top + gap : null,
      left: alignLeft ? rect.left : null,
      right: alignLeft ? null : overlay.size.width - rect.right,
      width: width,
      builder: builder,
      barrierLabel: MaterialLocalizations.of(anchor).modalBarrierDismissLabel,
    ),
  );
}

/// The same entrance for a live popup and its tour preview.
Widget fadeMenuTransition(Animation<double> animation, Widget child, {Alignment alignment = Alignment.topRight}) {
  final t = animation.drive(CurveTween(curve: Motion.morphCurve));
  return FadeTransition(
    opacity: t,
    child: ScaleTransition(scale: t.drive(Tween(begin: 0.96, end: 1.0)), alignment: alignment, child: child),
  );
}

class _FadeMenuRoute extends PopupRoute<void> {
  _FadeMenuRoute({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    required this.width,
    required this.builder,
    required this.barrierLabel,
  });

  final double width;

  /// One of each pair is set: the edges the panel lines up with.
  final double? top, bottom, left, right;
  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => Motion.morph;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final p = context.palette;
    return Stack(
      children: [
        Positioned(
          top: top,
          bottom: bottom,
          left: left,
          right: right,
          width: width,
          child: Material(
            color: p.tile,
            elevation: 0,
            shadowColor: p.shadow.withValues(alpha: 0.15),
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: p.tileBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: builder(context)),
          ),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Grows from the panel's corner nearest the anchor.
    final size = MediaQuery.sizeOf(context);
    final x = left ?? size.width - right!;
    final y = top ?? size.height - bottom!;
    return fadeMenuTransition(animation, child, alignment: Alignment(2 * x / size.width - 1, 2 * y / size.height - 1));
  }
}

/// A row in a [showFadeMenu] panel, shaded on hover.
class FadeMenuRow extends StatelessWidget {
  const FadeMenuRow({super.key, required this.onTap, required this.height, required this.child, this.grows = false});

  final VoidCallback onTap;
  final double height;

  /// Treats [height] as a minimum, so a row with wrapped text gets taller.
  final bool grows;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      builder: (hover) => AnimatedContainer(
        duration: Motion.hover,
        curve: Motion.hoverCurve,
        height: grows ? null : height,
        constraints: grows ? BoxConstraints(minHeight: height) : null,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: grows ? 10 : 0),
        color: p.empty.withValues(alpha: hover ? 0.6 : 0),
        child: child,
      ),
    );
  }
}

/// A thin line between groups in a [showFadeMenu] panel.
class FadeMenuDivider extends StatelessWidget {
  const FadeMenuDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: ColoredBox(
      color: context.palette.tileBorder,
      child: const SizedBox(height: 1, width: double.infinity),
    ),
  );
}
