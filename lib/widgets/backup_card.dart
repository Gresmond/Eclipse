import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';
import 'corner_card.dart';

/// A card that stays in the corner when a backup couldn't be saved or the
/// data failed its check. "Not now" closes it until Eclipse next opens.
class BackupCard extends StatefulWidget {
  const BackupCard({super.key, required this.problem, required this.onSeeBackups});

  final BackupProblem? problem;
  final VoidCallback onSeeBackups;

  @override
  State<BackupCard> createState() => _BackupCardState();
}

class _BackupCardState extends State<BackupCard> {
  bool _closed = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final problem = widget.problem;
    final damaged = problem == BackupProblem.damaged;
    return CornerCard(
      visible: problem != null && !_closed,
      child: NoticeCard(
        title: damaged ? 'Your data may be damaged' : 'A backup couldn’t be saved',
        lines: [
          damaged
              ? 'Today’s check found a problem, so your older backups are being kept. '
                    'Restoring a recent copy should fix it.'
              : 'Your data looks fine, but a copy couldn’t be made. Your disk may be full. '
                    'Eclipse tries again the next time it opens.',
        ],
        actions: [
          TextButton(
            onPressed: () => setState(() => _closed = true),
            child: Text('Not now', style: TextStyle(color: p.inkMuted)),
          ),
          if (damaged)
            TextButton(
              onPressed: widget.onSeeBackups,
              child: Text('See backups', style: TextStyle(color: p.accent)),
            ),
        ],
      ),
    );
  }
}
