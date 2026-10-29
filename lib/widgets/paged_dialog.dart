import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'confirm_on_enter.dart';
import 'fade_through.dart';

/// A dialog whose content swaps between pages in place, as Settings' tabs
/// do: the old page fades out, the new one fades in, and the panel eases
/// to its size. Its top stays where it first opened, centred, so it grows
/// and shrinks below. Away from its first page, [onBack] is what Enter and
/// Escape do.
class PagedDialog extends StatefulWidget {
  const PagedDialog({
    super.key,
    required this.page,
    required this.child,
    required this.onConfirm,
    required this.actions,
    this.onBack,
    this.backgroundColor,
    this.padding = const EdgeInsets.all(24),
    this.preserveButtons = true,
  });

  /// Which page [child] is; a new one swaps it in. Every page has a width
  /// of its own, as the one going out isn't held to the new one's.
  final Object page;
  final Widget child;
  final VoidCallback onConfirm;
  final List<Widget> actions;

  /// Back to the page before; null on the first page.
  final VoidCallback? onBack;
  final Color? backgroundColor;

  /// Round the pages; the actions sit under it.
  final EdgeInsets padding;

  /// As [ConfirmOnEnter.preserveButtons].
  final bool preserveButtons;

  @override
  State<PagedDialog> createState() => _PagedDialogState();
}

class _PagedDialogState extends State<PagedDialog> {
  static const _inset = EdgeInsets.symmetric(horizontal: 40, vertical: 24);
  final _panel = GlobalKey();

  /// Holds the keys when the page that had them goes.
  final _focus = FocusNode(skipTraversal: true);

  /// Where the dialog opened, centred: its top stays there after.
  double? _top;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = _panel.currentContext?.findRenderObject() as RenderBox?;
      if (!mounted || box == null) return;
      setState(() => _top = box.localToGlobal(Offset.zero).dy);
    });
  }

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
    final top = _top;
    final back = widget.onBack;
    return Actions(
      actions: {if (back != null) DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => back())},
      child: ConfirmOnEnter(
        onConfirm: back ?? widget.onConfirm,
        preserveButtons: widget.preserveButtons,
        child: Focus(
          focusNode: _focus,
          // Pinned by an outer padding, not the dialog's own inset, which
          // would slide it there: the panel only fades.
          child: Padding(
            padding: EdgeInsets.only(top: top == null ? 0 : top - _inset.top),
            child: Dialog(
              alignment: top == null ? null : Alignment.topCenter,
              insetPadding: _inset,
              clipBehavior: Clip.antiAlias,
              backgroundColor: widget.backgroundColor,
              child: Column(
                key: _panel,
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(
                    // Scrolls when the window is too short for all of it.
                    child: SingleChildScrollView(
                      padding: widget.padding,
                      child: AnimatedSize(
                        duration: Motion.morph,
                        curve: Motion.morphCurve,
                        alignment: Alignment.topCenter,
                        clipBehavior: Clip.none,
                        child: FadeThrough(
                          // The page going out keeps its own size as it fades.
                          layoutBuilder: (current, previous) => Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (final w in previous) Positioned(left: 0, top: 0, child: w),
                              ?current,
                            ],
                          ),
                          child: KeyedSubtree(key: ValueKey(widget.page), child: widget.child),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: OverflowBar(spacing: 8, children: widget.actions),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
