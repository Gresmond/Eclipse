import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
