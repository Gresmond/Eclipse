import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/app_theme.dart';
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

/// Clicking anywhere in the dialog, a toggle or a button that opens one of
/// its pages, leaves the cursor in its text field.
Future<T?> showAppDialog<T>({required BuildContext context, required WidgetBuilder builder}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(
    _AppDialogRoute<T>(
      context: context,
      builder: (context) => TextFieldTapRegion(child: builder(context)),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}

class _AppDialogRoute<T> extends DialogRoute<T> {
  _AppDialogRoute({required super.context, required super.builder, required super.themes})
    : super(
        animationStyle: const AnimationStyle(duration: Motion.morph, reverseDuration: Motion.morph),
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
    final spare = size.height - child.size.height;
    if (_top == null || _room != size.height) {
      _top = spare / 2;
      _room = size.height;
    }
    _top = _top!.clamp(0.0, spare);
    (child.parentData! as BoxParentData).offset = Offset((size.width - child.size.width) / 2, _top!);
  }
}
