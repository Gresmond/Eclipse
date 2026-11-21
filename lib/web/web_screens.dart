import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
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
                        SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
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
