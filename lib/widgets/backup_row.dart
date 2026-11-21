import 'package:flutter/material.dart';

import '../data/backups.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_dialog.dart';

/// One saved copy in a list of them, with its Restore button, which asks
/// first in place.
class BackupRow extends StatelessWidget {
  const BackupRow({
    super.key,
    required this.backup,
    required this.today,
    required this.confirming,
    required this.restoring,
    required this.enabled,
    required this.onAsk,
    required this.onCancel,
    required this.onConfirm,
    this.confirmText = 'Replaces everything you have now, except journal writing.',
    this.damaged = false,
  });

  final Backup backup;
  final DateTime today;
  final bool confirming;
  final bool restoring;
  final bool enabled;
  final VoidCallback onAsk;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final String confirmText;

  /// Failed its check: shown as such, with nothing to press.
  final bool damaged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (title, subtitle) = describe(backup, today);

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontFamily: Fonts.ui, fontSize: 15, fontWeight: FontWeight.w600, color: p.ink),
        ),
        const SizedBox(height: 2),
        Text(
          damaged
              ? 'This copy is damaged.'
              : confirming
              ? confirmText
              : subtitle,
          style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: damaged ? p.missedInk : p.inkMuted),
        ),
      ],
    );
    final actions = <Widget>[
      if (damaged)
        const SizedBox.shrink()
      else if (restoring)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
        )
      else if (confirming) ...[
        DialogDismiss(label: 'Cancel', onPressed: onCancel),
        const SizedBox(width: 4),
        DialogConfirm(label: 'Restore', onPressed: onConfirm),
      ] else
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: p.accent,
            side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
          ),
          onPressed: enabled ? onAsk : null,
          child: const Text('Restore'),
        ),
    ];

    return AnimatedContainer(
      duration: context.themed(Motion.hover),
      curve: Motion.hoverCurve,
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: confirming ? p.accent.withValues(alpha: 0.08) : p.empty.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: confirming ? p.accent.withValues(alpha: 0.35) : p.borderSoft),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < 380 && confirming
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  details,
                  const SizedBox(height: 10),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
                ],
              )
            : Row(
                children: [
                  Expanded(child: details),
                  ...actions,
                ],
              ),
      ),
    );
  }

  static (String, String) describe(Backup b, DateTime today) {
    if (b.day == null) {
      final t = b.modified;
      final time = clockLabel(t.hour * 60 + t.minute);
      return (
        b.isBeforeUpdate
            ? 'Before updating'
            : b.isBeforeJoin
            ? 'Before joining sync'
            : 'Before your last restore',
        'Saved ${t.day} ${monthNames[t.month - 1]}, $time${b is DriveBackup ? ', in Google Drive' : ''}',
      );
    }
    final d = b.day!;
    final year = d.year == today.year ? '' : ' ${d.year}';
    final title = '${weekdayNames[d.weekday - 1]} ${d.day} ${monthNames[d.month - 1]}$year';
    final days = daysBetween(d, today);
    final ago = switch (days) {
      0 => b is DriveBackup ? 'Today' : 'Today, as it was when you opened the app',
      1 => 'Yesterday',
      _ => '$days days ago',
    };
    return (title, b is DriveBackup ? '$ago, in Google Drive from ${b.from}' : ago);
  }
}
