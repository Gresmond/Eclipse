import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => dialogTransition(animation, child);
}
