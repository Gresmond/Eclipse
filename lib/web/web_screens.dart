import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/smooth_spinner.dart';

/// A plain page of the web version, shown before the app itself or instead
/// of it: a title, what's going on, and what can be done about it.
class WebNotice extends StatelessWidget {
  const WebNotice({super.key, required this.title, this.text, this.actions = const [], this.busy = false});

  final String title;
  final String? text;
  final List<WebNoticeAction> actions;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eclipse',
      debugShowCheckedModeBanner: false,
      theme: themeNamed(null),
      home: Builder(
        builder: (context) {
          final p = context.palette;
          return Scaffold(
            backgroundColor: p.background,
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontFamily: Fonts.display,
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          color: p.ink,
                        ),
                      ),
                      if (text != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          text!,
                          style: TextStyle(fontFamily: Fonts.body, fontSize: 15, height: 1.45, color: p.inkMuted),
                        ),
                      ],
                      if (busy) ...[
                        const SizedBox(height: 20),
                        SizedBox.square(dimension: 20, child: SmoothSpinner(color: p.accent)),
                      ],
                      if (actions.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final (i, action) in actions.indexed)
                              i == 0
                                  ? FilledButton(
                                      style: FilledButton.styleFrom(backgroundColor: p.done, foregroundColor: p.onDone),
                                      onPressed: action.onPressed,
                                      child: Text(action.label),
                                    )
                                  : TextButton(onPressed: action.onPressed, child: Text(action.label)),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class WebNoticeAction {
  const WebNoticeAction(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;
}

/// Covers the app in a window too small for its layout, leaving it running
/// beneath, so nothing being typed goes.
class WindowSizeGate extends StatelessWidget {
  const WindowSizeGate({super.key, required this.child});

  final Widget child;

  static const minWidth = 720.0, minHeight = 480.0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final p = context.palette;
    final small = size.width < minWidth || size.height < minHeight;
    return Stack(
      fit: StackFit.expand,
      children: [
        Visibility(visible: !small, maintainState: true, maintainAnimation: true, maintainSize: true, child: child),
        if (small)
          ColoredBox(
            color: p.background,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Eclipse needs a bigger window. Make this one larger, or open Eclipse on a computer.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: Fonts.body,
                    fontSize: 15,
                    height: 1.45,
                    color: p.ink,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
