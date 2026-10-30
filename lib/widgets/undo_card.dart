import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';
import 'corner_card.dart';

/// Over everything, dialogs too: the card naming what was just removed,
/// with Undo, in the bottom-right corner, and Ctrl+Z to put back the last
/// few removals (a text field's own Ctrl+Z comes first).
class UndoLayer extends StatefulWidget {
  const UndoLayer({super.key, required this.child});

  final Widget child;

  static const cardTime = Duration(seconds: 6);

  @override
  State<UndoLayer> createState() => _UndoLayerState();
}

class _UndoLayerState extends State<UndoLayer> {
  Removal? _timed;
  Timer? _timer;
  bool _held = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Gives the card [UndoLayer.cardTime] from now, unless the pointer is on it.
  void _time(AppState state) {
    _timer?.cancel();
    final removal = _timed;
    if (_held || removal == null) return;
    _timer = Timer(UndoLayer.cardTime, () => state.hideUndoCard(removal));
  }

  void _hold(AppState state, bool held) {
    _held = held;
    _time(state);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => s.shownRemoval);
    if (!identical(state.shownRemoval, _timed)) {
      _timed = state.shownRemoval;
      _time(state);
    }
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyZ, control: true): _UndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _UndoIntent(),
      },
      child: Actions(
        actions: {_UndoIntent: _UndoAction(state)},
        child: Stack(
          children: [
            widget.child,
            Positioned(
              right: 32,
              bottom: 28,
              child: Material(
                type: MaterialType.transparency,
                child: CornerCard(
                  visible: state.shownRemoval != null,
                  gap: 0,
                  child: _Card(
                    label: state.shownRemoval?.label ?? '',
                    onUndo: state.undo,
                    onHover: (held) => _hold(state, held),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _UndoAction extends Action<_UndoIntent> {
  _UndoAction(this.state);

  final AppState state;

  static bool get _typing =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  @override
  bool isEnabled(_UndoIntent intent) => state.canUndo && !_typing;

  @override
  void invoke(_UndoIntent intent) => state.undo();
}

class _Card extends StatelessWidget {
  const _Card({required this.label, required this.onUndo, required this.onHover});

  final String label;
  final VoidCallback onUndo;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: Container(
        height: UndoCardSpace.height,
        constraints: const BoxConstraints(maxWidth: 600),
        padding: const EdgeInsets.fromLTRB(18, 0, 10, 0),
        decoration: BoxDecoration(
          color: p.tile,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.tileBorder.withValues(alpha: 0.9)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: Fonts.ui, fontSize: 14.5, fontWeight: FontWeight.w500, color: p.ink),
              ),
            ),
            const SizedBox(width: 16),
            CornerButton(label: 'Undo', filled: true, onTap: onUndo),
          ],
        ),
      ),
    );
  }
}

/// Room under the other corner cards for the undo card while it shows,
/// so they move up out of its way rather than sit under it.
class UndoCardSpace extends StatelessWidget {
  const UndoCardSpace({super.key});

  static const height = 52.0;

  @override
  Widget build(BuildContext context) {
    final shown = AppScope.watch(context, (s) => s.shownRemoval != null).shownRemoval != null;
    return AnimatedContainer(duration: Motion.morph, curve: Motion.morphCurve, height: shown ? height + 12 : 0);
  }
}
