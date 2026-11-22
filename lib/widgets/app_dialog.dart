import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/pixels.dart';
import '../theme/tokens.dart';

/// Every dialog's title: Settings' Greed heading.
TextStyle dialogTitleStyle(Palette p) =>
    TextStyle(fontFamily: Fonts.display, fontSize: 28, fontWeight: FontWeight.w400, color: p.ink);

/// The gap under a dialog's title, and the one above its buttons.
const dialogTitleGap = 20.0;
const dialogActionsGap = 14.0;

/// A dialog with a title, a body and its buttons, laid out as Settings is:
/// [dialogPadding] round it, a [dialogTitleStyle] title, and
/// [DialogDismiss] and [DialogConfirm] buttons.
class AppAlertDialog extends StatelessWidget {
  const AppAlertDialog({super.key, required this.title, this.content, required this.actions});

  final String title;
  final Widget? content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      backgroundColor: p.tile,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: EdgeInsets.fromLTRB(dialogPadding.left, dialogPadding.top, dialogPadding.right, 0),
      contentPadding: EdgeInsets.fromLTRB(dialogPadding.left, dialogTitleGap, dialogPadding.right, 0),
      actionsPadding: EdgeInsets.fromLTRB(
        dialogPadding.left,
        dialogActionsGap,
        dialogPadding.right,
        dialogPadding.bottom,
      ),
      title: Text(title, style: dialogTitleStyle(p)),
      content: content == null
          ? null
          : DefaultTextStyle.merge(
              style: TextStyle(fontFamily: Fonts.body, fontSize: 15, height: 1.45, color: p.ink),
              child: content!,
            ),
      actions: actions,
    );
  }
}

/// Every dialog's way out (Cancel, Close, Skip): plain text in muted ink.
class DialogDismiss extends StatelessWidget {
  const DialogDismiss({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(foregroundColor: context.palette.inkMuted),
    onPressed: onPressed,
    child: Text(label),
  );
}

/// Every dialog's yes: filled in the done colour, as the theme draws every
/// [FilledButton].
class DialogConfirm extends StatelessWidget {
  const DialogConfirm({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(onPressed: onPressed, child: Text(label));
}

/// A centered panel fades with the same timing as popup menus. It doesn't
/// grow: scaling a whole panel makes its text and toggles wobble.
Widget dialogTransition(Animation<double> animation, Widget child) => FadeTransition(
  opacity: animation.drive(CurveTween(curve: Motion.morphCurve)),
  child: child,
);

/// The app's navigator, for what's drawn above it: the corner cards.
final appNavigator = GlobalKey<NavigatorState>();

/// Clicking anywhere in the dialog, a toggle or a button that opens one of
/// its pages, leaves the cursor in its text field.
Future<T?> showAppDialog<T>({required BuildContext context, required WidgetBuilder builder}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(
    _AppDialogRoute<T>(
      context: context,
      builder: (context) => TextFieldTapRegion(child: builder(context)),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      disableAnimations: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
    ),
  );
}

class _AppDialogRoute<T> extends DialogRoute<T> {
  _AppDialogRoute({required super.context, required super.builder, required super.themes, required bool disableAnimations})
    : super(
        animationStyle: disableAnimations
            ? const AnimationStyle(duration: Duration.zero, reverseDuration: Duration.zero)
            : const AnimationStyle(duration: Motion.morph, reverseDuration: Motion.morph),
      );

  /// The shade fades with the panel, rather than ahead of it.
  @override
  Curve get barrierCurve => Motion.morphCurve;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => dialogTransition(animation, child);
}

/// A dialog centred when it opens, whose top then stays put as it grows
/// or shrinks, rising only as far as it must to stay on screen. Taller
/// than the screen, it fills it and scrolls.
class KeepTop extends SingleChildRenderObjectWidget {
  const KeepTop({super.key, required super.child});

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
    final spare = size - child.size as Offset;
    final centre = Offset(pixelRound(spare.dx / 2), pixelRound(spare.dy / 2));
    if (_top == null || _room != size.height) {
      _top = centre.dy;
      _room = size.height;
    }
    _top = _top!.clamp(0.0, spare.dy);
    (child.parentData! as BoxParentData).offset = Offset(centre.dx, _top!);
  }
}

/// A rounded surface grouping controls inside a dialog, matching Settings.
class DialogSection extends StatelessWidget {
  const DialogSection({super.key, this.padding = EdgeInsets.zero, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(16)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A rounded text field matching Eclipse's bespoke dialog style while keeping a
/// [TextFormField] inside for validation and form integration.
class DialogField extends StatefulWidget {
  const DialogField({
    super.key,
    required this.label,
    this.initialValue,
    this.controller,
    this.focusNode,
    this.hintText,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.inputFormatters,
    this.onChanged,
    this.onFieldSubmitted,
    this.trailing,
  });

  final String label;
  final String? initialValue;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final Widget? trailing;

  @override
  State<DialogField> createState() => _DialogFieldState();
}

class _DialogFieldState extends State<DialogField> {
  FocusNode? _ownedFocus;
  bool _focused = false;

  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  void _onFocusChanged() {
    if (!mounted) return;
    final focused = _focus.hasFocus;
    if (focused != _focused) setState(() => _focused = focused);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    _focused = _focus.hasFocus;
  }

  @override
  void didUpdateWidget(DialogField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode?.removeListener(_onFocusChanged);
      _ownedFocus?.removeListener(_onFocusChanged);
      _focus.addListener(_onFocusChanged);
      _focused = _focus.hasFocus;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _focus.requestFocus(),
      child: AnimatedContainer(
        duration: context.themed(Motion.hover),
        curve: Motion.hoverCurve,
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
        decoration: BoxDecoration(
          color: p.empty.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _focused ? p.accent : p.borderSoft),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(fontFamily: Fonts.ui, fontSize: 12, fontWeight: FontWeight.w500, color: p.inkMuted),
                  ),
                  const SizedBox(height: 3),
                  TextFormField(
                    initialValue: widget.controller == null ? widget.initialValue : null,
                    controller: widget.controller,
                    focusNode: _focus,
                    autofocus: widget.autofocus,
                    keyboardType: widget.keyboardType,
                    textCapitalization: widget.textCapitalization,
                    textInputAction: widget.textInputAction,
                    minLines: widget.minLines,
                    maxLines: widget.maxLines,
                    inputFormatters: widget.inputFormatters,
                    cursorColor: p.ink,
                    style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: widget.hintText,
                      hintStyle: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.inkMuted),
                    ),
                    onChanged: widget.onChanged,
                    onFieldSubmitted: widget.onFieldSubmitted,
                  ),
                ],
              ),
            ),
            if (widget.trailing case final trailing?) ...[const SizedBox(width: 8), trailing],
          ],
        ),
      ),
    );
  }
}
