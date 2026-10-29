import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A count whose changed digits roll like an odometer: up when it rises,
/// down when it falls. Unchanged digits stay still, and a digit gained or
/// lost at the front widens or narrows its slot smoothly, so whatever sits
/// beside the number glides rather than jumps.
class RollingNumber extends StatefulWidget {
  const RollingNumber({super.key, required this.value, required this.style, this.digits = 1});

  final int value;
  final TextStyle style;

  /// At least this many digits, leading zeros filling the rest.
  final int digits;

  @override
  State<RollingNumber> createState() => _RollingNumberState();
}

class _RollingNumberState extends State<RollingNumber> {
  /// 1 when the count last rose, -1 when it fell.
  int _direction = 1;

  /// Digit slots, kept even when empty: a digit gained at the front then
  /// widens an existing slot rather than arriving at full width, and one
  /// dropped can still roll out.
  late int _slots = math.max('${widget.value}'.length, 4);

  @override
  void didUpdateWidget(RollingNumber old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) _direction = widget.value > old.value ? 1 : -1;
    _slots = math.max('${widget.value}'.length, _slots);
  }

  @override
  Widget build(BuildContext context) {
    final digits = '${widget.value}'.padLeft(widget.digits, '0');
    // Even-width figures, so a rolling digit never nudges its neighbours.
    final style = widget.style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return ClipRect(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Keyed by place from the right, so the ones digit stays the ones
          // digit however many digits sit in front of it.
          for (var place = _slots - 1; place >= 0; place--)
            _Digit(
              key: ValueKey(place),
              digit: place < digits.length ? digits[digits.length - 1 - place] : '',
              direction: _direction,
              style: style,
            ),
        ],
      ),
    );
  }
}

class _Digit extends StatelessWidget {
  const _Digit({super.key, required this.digit, required this.direction, required this.style});

  /// Empty for a leading slot the number no longer reaches.
  final String digit;
  final int direction;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final current = ValueKey(digit);
    return AnimatedSize(
      duration: Motion.morph,
      curve: Motion.morphCurve,
      alignment: Alignment.centerRight,
      clipBehavior: Clip.none,
      child: AnimatedSwitcher(
        duration: Motion.morph,
        switchInCurve: Motion.morphCurve,
        switchOutCurve: Motion.morphCurve,
        // Only the incoming digit sizes the slot; the outgoing one rolls
        // away over it, so the slot can narrow while it leaves.
        layoutBuilder: (incoming, outgoing) => Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerRight,
          children: [
            for (final o in outgoing) Positioned(right: 0, top: 0, bottom: 0, child: o),
            ?incoming,
          ],
        ),
        transitionBuilder: (child, animation) {
          // The new digit arrives from below as the count rises and the old
          // one leaves upward; the reverse as it falls.
          final from = child.key == current ? direction.toDouble() : -direction.toDouble();
          return SlideTransition(
            position: animation.drive(Tween(begin: Offset(0, from), end: Offset.zero)),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: Text(digit, key: current, style: style),
      ),
    );
  }
}
