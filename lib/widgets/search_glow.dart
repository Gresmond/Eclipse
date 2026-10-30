import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';

/// [child], lit with the done colour for a moment when search has just
/// opened [target] (a task's uid, or a journal day's key), and scrolled to.
class SearchGlow extends StatefulWidget {
  const SearchGlow({super.key, required this.target, this.radius = 8, this.bleed = 0, required this.child});

  final String? target;
  final double radius;

  /// How far the glow reaches past [child] on every side.
  final double bleed;
  final Widget child;

  /// How long after opening a newly built [SearchGlow] still lights, so
  /// one built as the day fades in catches it but a later one doesn't.
  static const _catch = Duration(milliseconds: 1500);

  @override
  State<SearchGlow> createState() => _SearchGlowState();
}

class _SearchGlowState extends State<SearchGlow> with SingleTickerProviderStateMixin {
  late final _glow = AnimationController(vsync: this, duration: const Duration(seconds: 4));
  DateTime? _shown;

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  void _check(({String target, DateTime at})? found) {
    if (found == null || found.target != widget.target || found.at == _shown) return;
    if (DateTime.now().difference(found.at) > SearchGlow._catch) return;
    _shown = found.at;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(context, alignment: 0.3, duration: Motion.morph, curve: Motion.morphCurve);
      _glow.forward(from: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => s.found);
    _check(state.found);
    final p = context.palette;
    final bleed = -widget.bleed;
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        Positioned(
          left: bleed,
          top: bleed,
          right: bleed,
          bottom: bleed,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _glow,
              builder: (context, _) {
                final t = _glow.value;
                // Up in 0.2 s, held to 2.5 s, then away over 1.5 s.
                final alpha = !_glow.isAnimating
                    ? 0.0
                    : t < 0.05
                    ? t / 0.05
                    : t < 0.625
                    ? 1.0
                    : 1 - Curves.easeInOut.transform((t - 0.625) / 0.375);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    color: p.done.withValues(alpha: 0.2 * alpha),
                  ),
                );
              },
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}
