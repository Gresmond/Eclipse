import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/app_theme.dart';
import 'confirm_on_enter.dart';
import 'fade_through.dart';

/// A dialog whose content swaps between pages in place, sized and moved
/// exactly as Settings' tabs are: one width throughout, the old page
/// fading out as the new one fades in, and the panel easing to the new
/// one's height. Its top stays where it opened as it grows or shrinks.
/// Away from its first page, [onBack] is what Enter and Escape do.
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
          child: _KeepTop(
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
                      _PageSize(
                        page: widget.page,
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
      ),
    );
  }
}

/// Its child's size, except that a new [page] eases from the old page's
/// size to the new one's. Within a page it follows its child exactly, as
/// what changes there (a row folding away) animates itself; easing after
/// it would lag behind.
class _PageSize extends StatefulWidget {
  const _PageSize({required this.page, required this.child});

  final Object page;
  final Widget child;

  @override
  State<_PageSize> createState() => _PageSizeState();
}

class _PageSizeState extends State<_PageSize> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Motion.morph, value: 1);
  late final _curve = CurvedAnimation(parent: _controller, curve: Motion.morphCurve);

  @override
  void didUpdateWidget(_PageSize old) {
    super.didUpdateWidget(old);
    if (old.page != widget.page) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PageSizeBox(page: widget.page, animation: _curve, child: widget.child);
}

class _PageSizeBox extends SingleChildRenderObjectWidget {
  const _PageSizeBox({required this.page, required this.animation, super.child});

  final Object page;
  final Animation<double> animation;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPageSize(page, animation);

  @override
  void updateRenderObject(BuildContext context, _RenderPageSize renderObject) => renderObject.page = page;
}

class _RenderPageSize extends RenderProxyBox {
  _RenderPageSize(this._page, this._animation);

  final Animation<double> _animation;

  /// The size it eases from to a new page's.
  Size? _from;

  Object _page;
  set page(Object value) {
    if (value == _page) return;
    _page = value;
    if (hasSize) _from = size;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void performLayout() {
    final child = this.child!..layout(constraints, parentUsesSize: true);
    if (_animation.isCompleted) _from = null;
    final from = _from;
    size = constraints.constrain(from == null ? child.size : Size.lerp(from, child.size, _animation.value)!);
  }
}

/// A dialog centred when it opens, whose top then stays put as it grows
/// or shrinks, rising only as far as it must to stay on screen. Taller
/// than the screen, it fills it and scrolls.
class _KeepTop extends SingleChildRenderObjectWidget {
  const _KeepTop({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderKeepTop();
}

class _RenderKeepTop extends RenderShiftedBox {
  _RenderKeepTop() : super(null);

  double? _top;

  /// The height [_top] was centred in; a new one centres it again.
  double? _room;

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child!;
    // With no height limit the dialog is only as tall as it is.
    child.layout(constraints.loosen().copyWith(maxHeight: double.infinity), parentUsesSize: true);
    if (child.size.height > size.height) child.layout(constraints.loosen(), parentUsesSize: true);
    final spare = size.height - child.size.height;
    if (_top == null || _room != size.height) {
      _top = spare / 2;
      _room = size.height;
    }
    _top = _top!.clamp(0.0, spare);
    (child.parentData! as BoxParentData).offset = Offset((size.width - child.size.width) / 2, _top!);
  }
}
