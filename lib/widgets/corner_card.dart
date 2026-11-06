import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'hover_fill.dart';
import '../theme/pixels.dart';

/// A card floating in the bottom-right corner. It slides up and fades in
/// while [visible], and back down and out when not, still showing what it
/// last showed; its space closes with it, so the cards above settle rather
/// than jump. [gap] sits above it and closes with it.
class CornerCard extends StatefulWidget {
  const CornerCard({super.key, required this.visible, this.gap = 12, required this.child});

  final bool visible;
  final double gap;
  final Widget child;

  @override
  State<CornerCard> createState() => _CornerCardState();
}

class _CornerCardState extends State<CornerCard> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Motion.morph)
    ..addStatusListener((status) {
      if (status == AnimationStatus.dismissed) setState(() {});
    });
  late final _curve = CurvedAnimation(parent: _controller, curve: Motion.morphCurve);
  late final _slide = _curve.drive(Tween(begin: const Offset(0, 0.35), end: Offset.zero));
  late Widget _shown = widget.child;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _controller.forward();
  }

  @override
  void didUpdateWidget(CornerCard old) {
    super.didUpdateWidget(old);
    if (widget.visible != old.visible) widget.visible ? _controller.forward() : _controller.reverse();
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.visible) _shown = widget.child;
    if (_controller.isDismissed) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, child) =>
            Align(alignment: Alignment.bottomRight, widthFactor: 1, heightFactor: _curve.value, child: child),
        child: Padding(
          padding: EdgeInsets.only(top: widget.gap),
          child: SlideTransition(
            position: _slide,
            child: FadeTransition(opacity: _curve, child: _shown),
          ),
        ),
      ),
    );
  }
}

/// A pill button on a corner card; [filled] in the theme's done colour.
class CornerButton extends StatelessWidget {
  const CornerButton({super.key, required this.label, required this.onTap, this.filled = false});

  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      onTap: onTap,
      builder: (hover) => AnimatedContainer(
        duration: context.themed(Motion.hover),
        curve: Motion.hoverCurve,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          color: filled ? p.done : (hover ? p.empty : p.empty.withValues(alpha: 0)),
        ),
        child: PixelFit(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: filled ? p.onDone : p.inkMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// A card that says something and waits: a title, lines of text and buttons.
class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.title, required this.lines, required this.actions});

  final String title;
  final List<String> lines;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final body = TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.4, color: p.inkMuted);
    return Container(
      width: cornerCardWidth,
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(title, style: cornerCardTitle(p.ink)),
          ),
          for (final line in lines) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(line, style: body),
            ),
          ],
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: Wrap(alignment: WrapAlignment.end, children: actions),
          ),
        ],
      ),
    );
  }
}
