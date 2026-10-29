import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'confirm_on_enter.dart';
import 'fade_through.dart';

/// A dialog whose content swaps between pages in place, sized and moved
/// exactly as Settings' tabs are: one width throughout, the old page
/// fading out as the new one fades in, and the panel easing to the new
/// one's height. Away from its first page, [onBack] is what Enter and
/// Escape do.
class PagedDialog extends StatefulWidget {
  const PagedDialog({
    super.key,
    required this.page,
    required this.width,
    required this.child,
    required this.onConfirm,
    required this.actions,
    this.onBack,
    this.backgroundColor,
    this.padding = const EdgeInsets.all(24),
    this.preserveButtons = true,
  });

  /// Which page [child] is; a new one swaps it in.
  final Object page;

  /// The width every page has, inside [padding].
  final double width;
  final Widget child;
  final VoidCallback onConfirm;
  final List<Widget> actions;

  /// Back to the page before; null on the first page.
  final VoidCallback? onBack;
  final Color? backgroundColor;

  /// Round the pages and the actions under them.
  final EdgeInsets padding;

  /// As [ConfirmOnEnter.preserveButtons].
  final bool preserveButtons;

  @override
  State<PagedDialog> createState() => _PagedDialogState();
}

class _PagedDialogState extends State<PagedDialog> {
  /// Holds the keys when the page that had them goes.
  final _focus = FocusNode(skipTraversal: true);

  @override
  void didUpdateWidget(PagedDialog old) {
    super.didUpdateWidget(old);
    if (old.page == widget.page) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final back = widget.onBack;
    return Actions(
      actions: {if (back != null) DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => back())},
      child: ConfirmOnEnter(
        onConfirm: back ?? widget.onConfirm,
        preserveButtons: widget.preserveButtons,
        child: Focus(
          focusNode: _focus,
          child: Dialog(
            clipBehavior: Clip.antiAlias,
            backgroundColor: widget.backgroundColor,
            child: SizedBox(
              width: widget.width + widget.padding.horizontal,
              // Scrolls when the window is too short for all of it.
              child: SingleChildScrollView(
                padding: widget.padding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSize(
                      duration: Motion.morph,
                      curve: Motion.morphCurve,
                      alignment: Alignment.topCenter,
                      clipBehavior: Clip.none,
                      child: FadeThrough(
                        layoutBuilder: (current, previous) => Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.topLeft,
                          children: [
                            for (final w in previous) Positioned(left: 0, right: 0, top: 0, child: w),
                            ?current,
                          ],
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(widget.page),
                          child: SizedBox(width: widget.width, child: widget.child),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OverflowBar(spacing: 8, children: widget.actions),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
