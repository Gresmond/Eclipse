import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The ribbons along the top of Settings and the task dialogs: one pill, in
/// the done colour like the tab bar's, glides to the chosen one. A ribbon
/// in [disabled] is dimmed and can't be chosen.
class Ribbons extends StatelessWidget {
  const Ribbons({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelect,
    this.disabled = const {},
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;
  final Set<int> disabled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 270,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(20)),
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedAlign(
              duration: Motion.morph,
              curve: Motion.morphCurve,
              alignment: Alignment(labels.length == 1 ? 0 : -1 + 2 * selected / (labels.length - 1), 0),
              child: FractionallySizedBox(
                widthFactor: 1 / labels.length,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(17), color: p.done),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final (i, label) in labels.indexed)
                Expanded(
                  child: MouseRegion(
                    cursor: disabled.contains(i) ? MouseCursor.defer : SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: disabled.contains(i) ? null : () => onSelect(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: Motion.morph,
                            curve: Motion.morphCurve,
                            style: TextStyle(
                              fontFamily: Fonts.ui,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: i == selected
                                  ? p.onAccent
                                  : p.inkMuted.withValues(alpha: disabled.contains(i) ? 0.35 : 1),
                            ),
                            child: Text(label),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
