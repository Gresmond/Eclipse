import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';
import '../theme/pixels.dart';
import '../theme/tokens.dart';
import 'app_dialog.dart' show appNavigator;
import 'corner_card.dart';
import 'fade_through.dart';

/// Over everything, dialogs too: the card naming what was just removed,
/// with Undo, in the bottom-right corner, with the other corner [cards]
/// (reminders, sync, updates) above it, and Ctrl+Z to put back the last
/// few removals (a text field's own Ctrl+Z comes first).
class UndoLayer extends StatefulWidget {
  const UndoLayer({super.key, this.cards, required this.child});

  /// The corner's other cards, stacked above the undo card.
  final Widget? cards;
  final Widget child;

  static const cardTime = Motion.notice;

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
    final media = MediaQuery.of(context);
    final narrow = media.size.width < 600;
    final pad = media.padding;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyZ, control: true): _UndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _UndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _UndoIntent(redo: true),
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): _UndoIntent(redo: true),
        SingleActivator(LogicalKeyboardKey.keyY, control: true): _UndoIntent(redo: true),
        SingleActivator(LogicalKeyboardKey.keyY, meta: true): _UndoIntent(redo: true),
      },
      child: Actions(
        actions: {_UndoIntent: _UndoAction(state)},
        child: Stack(
          children: [
            widget.child,
            Positioned(
              right: (narrow ? 16 : 32) + pad.right,
              left: narrow ? 16 + pad.left : null,
              bottom: (narrow ? 20 : 28) + pad.bottom,
              // Its own overlay, for the cards' tooltips: this sits above
              // the navigator's.
              child: Overlay.wrap(
                alwaysSizeToContent: true,
                clipBehavior: Clip.none,
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      ?widget.cards,
                      CornerCard(
                        visible: state.shownRemoval != null,
                        child: _Card(
                          label: state.shownRemoval?.label ?? '',
                          onUndo: state.undo,
                          onHover: (held) => _hold(state, held),
                        ),
                      ),
                    ],
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
  const _UndoIntent({this.redo = false});
  final bool redo;
}

class _UndoAction extends Action<_UndoIntent> {
  _UndoAction(this.state);

  final AppState state;

  static bool get _typing =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  @override
  bool isEnabled(_UndoIntent intent) {
    if (!(intent.redo ? state.canRedo : state.canUndo)) return false;
    if (_typing || state.touring || state.closing) return false;
    return !(appNavigator.currentState?.canPop() ?? false);
  }

  @override
  void invoke(_UndoIntent intent) => intent.redo ? state.redo() : state.undo();
}

class _Card extends StatelessWidget {
  const _Card({required this.label, required this.onUndo, required this.onHover});

  static const height = 52.0;

  final String label;
  final VoidCallback onUndo;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final availableWidth = math.max(0.0, MediaQuery.sizeOf(context).width - 32);
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: Container(
        constraints: BoxConstraints(minHeight: _Card.height, maxWidth: math.min(600, availableWidth)),
        padding: const EdgeInsets.fromLTRB(18, 8, 10, 8),
        decoration: BoxDecoration(
          color: p.tile,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A second removal fades its label through, the card easing to
            // its width as the header's date does.
            Flexible(
              child: PageSize(
                page: label,
                child: FadeThrough(
                  layoutBuilder: FadeThrough.pinTop,
                  child: PixelFit(
                    key: ValueKey(label),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w500, color: p.ink),
                    ),
                  ),
                ),
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
