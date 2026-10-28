import 'dart:io';

import 'package:flutter/material.dart';

import '../data/updates.dart';
import '../models.dart';
import '../theme/app_theme.dart';

/// Shown in place of the app when its data can't be opened, so the window
/// says why instead of staying blank.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, this.updater});

  final Object error;
  final Updater? updater;

  /// A database written by a newer build: updating fixes it.
  bool get _tooNew => '$error'.contains('newer version of Eclipse');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eclipse',
      debugShowCheckedModeBanner: false,
      theme: themeNamed(null),
      home: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          return Scaffold(
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
                        _tooNew ? 'This copy of Eclipse is older than your data' : 'Eclipse couldn’t open your data',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _tooNew
                            ? 'A newer build has already updated your data. Update this copy to open it. '
                                  'Nothing has been changed or lost.'
                            : curlyQuotes('$error'),
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 24),
                      if (updater case final updater?)
                        ListenableBuilder(listenable: updater, builder: (context, _) => _UpdateRow(updater))
                      else
                        FilledButton(onPressed: () => exit(0), child: const Text('Quit')),
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

class _UpdateRow extends StatelessWidget {
  const _UpdateRow(this.updater);

  final Updater updater;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = updater.status == UpdateStatus.updating || updater.status == UpdateStatus.restarting;
    // A source install can always be rebuilt; a release needs one on offer.
    final canUpdate = updater is GitUpdater || updater.status == UpdateStatus.available;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (busy)
          Text(updater.progressDetail, style: theme.textTheme.bodyMedium)
        else if (updater.error case final error?)
          Text(curlyQuotes(error), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
        const SizedBox(height: 12),
        Row(
          children: [
            if (canUpdate) FilledButton(onPressed: busy ? null : updater.update, child: Text(updater.actionLabel)),
            const SizedBox(width: 12),
            TextButton(onPressed: busy ? null : () => exit(0), child: const Text('Quit')),
          ],
        ),
      ],
    );
  }
}
