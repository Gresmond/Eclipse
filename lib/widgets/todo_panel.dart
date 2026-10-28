import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'appear.dart';
import 'confirm_on_enter.dart';
import 'day_toggles.dart';
import 'fade_menu.dart';
import 'fade_through.dart';
import 'hover_fill.dart';
import 'mark.dart';
import 'note_input.dart';
import 'setting_rows.dart';
import 'sleep_time.dart';
import 'smooth_task_scroll.dart';
import 'task_motion.dart';
import 'tile.dart';
import 'time_wheel.dart';

part 'day_lists.dart';
part 'task_row.dart';
part 'task_editor.dart';

class _TaskDrag {
  _TaskDrag(this.scope, this.item, this.day);
  VoidCallback? onFinished;
  VoidCallback? onAccepted;
  Future<void> Function()? fadeForNesting;
  VoidCallback? restoreAfterNesting;
  bool nesting = false;
  final TodoScope scope;
  final TodoItem item;
  final DateTime day;
}

/// Identical circular pills, visible only while the individual icon is hovered.
class _TaskAction extends StatelessWidget {
  const _TaskAction({required this.tooltip, required this.icon, required this.onPressed});

  static const size = 24.0;

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 14),
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      style: ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const WidgetStatePropertyAll(Size(size, size)),
        shape: const WidgetStatePropertyAll(CircleBorder()),
        foregroundColor: WidgetStatePropertyAll(p.inkMuted),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? p.empty.withValues(alpha: 0.8) : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    );
  }
}

/// One task in a day's list: it ticks, edits and nests the same way
/// wherever it's shown.
class TaskRow extends StatelessWidget {
  const TaskRow({
    super.key,
    required this.scope,
    required this.item,
    required this.day,
    this.readOnly = false,
    this.fadeIn = false,
    this.arriving = false,
    this.leaving = false,
    this.onRemove,
  });

  final TodoScope scope;
  final TodoItem item;

  /// The day whose lists it's from: today, or a past day looked back on.
  final DateTime day;
  final bool readOnly;

  /// Fades in: just added.
  final bool fadeIn;

  /// Just come from another day, shown unticked at the bottom until it
  /// settles into place.
  final bool arriving;

  /// Removed, closing up.
  final bool leaving;

  /// Removes it; by default straight from its list.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    return _TodoRow(
      scope: scope,
      item: item,
      day: day,
      readOnly: readOnly,
      fadeIn: fadeIn,
      arriving: arriving,
      leaving: leaving,
      onRemove: onRemove ?? () => state.removeTodo(scope, item, day: day),
    );
  }
}
