import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';

/// [child], lit with the done colour for a moment when search has just
/// opened [target] (a task's uid, a subtask's, or a journal day's key), and
/// scrolled to. A task whose subtask was opened lights only briefly.
class SearchGlow extends StatefulWidget {
  const SearchGlow({
    super.key,
    required this.target,
    this.radius = 8,
    this.over = false,
    this.delay = Duration.zero,
    required this.child,
  });

  final String? target;

  /// How long it waits before lighting: a subtask's, for its task's to go.
  final Duration delay;
  final double radius;

  /// Whether the glow lies over [child], for one that's opaque (a whole
  /// tile), rather than under it.
  final bool over;
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
  Timer? _wait;

  @override
  void dispose() {
    _wait?.cancel();
    _glow.dispose();
    super.dispose();
  }

  void _check(({String target, DateTime at})? found) {
    final target = widget.target;
    if (found == null || target == null || found.at == _shown) return;
    final parent = found.target.startsWith('$target#');
    if (found.target != target && !parent) return;
    if (DateTime.now().difference(found.at) > SearchGlow._catch) return;
    _shown = found.at;
    _glow.duration = parent ? const Duration(seconds: 1) : const Duration(seconds: 4);
    void light() {
      if (!mounted) return;
      Scrollable.ensureVisible(context, alignment: 0.3, duration: Motion.morph, curve: Motion.morphCurve);
      _glow.forward(from: 0);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _wait?.cancel();
      _wait = widget.delay == Duration.zero ? null : Timer(widget.delay, light);
      if (_wait == null) light();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => s.found);
    _check(state.found);
    final p = context.palette;
    final glow = Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _glow,
          builder: (context, _) {
            final t = _glow.value;
            // Up in 0.2 s, held to 2.5 s, then away over 1.5 s; a task
            // whose subtask was opened, in a quarter of the time.
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
    );
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: widget.over ? [widget.child, glow] : [glow, widget.child],
    );
  }
}
