import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/sqlite.dart' show OpenMode, placeDatabase, removeDatabase, sqlite3;

import '../data/app_log.dart';
import '../data/backups.dart';
import '../data/journal_files.dart';
import '../data/store.dart' show DatabaseTooNewException;
import '../data/sync_service.dart';
import '../data/updates.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/pixels.dart';
import '../widgets/app_dialog.dart';
import '../widgets/backup_row.dart';

/// The theme saved in [database], if it can still be read: a database too
/// new to open usually can. Null when it can't, for Sunrise.
String? savedThemeName(String database) {
  if (!File(database).existsSync()) return null;
  try {
    final db = sqlite3.open(database, mode: OpenMode.readOnly);
    try {
      final rows = db.select("SELECT value FROM settings WHERE key = 'theme'");
      return rows.isEmpty ? null : rows.first['value'] as String?;
    } finally {
      db.close();
    }
  } catch (_) {
    return null;
  }
}

/// What the error screen needs to offer a way back from a backup.
class StartupRecovery {
  const StartupRecovery({
    required this.backups,
    required this.database,
    this.journal,
    this.driveCopies,
    required this.reopen,
  });

  final Backups backups;
  final String database;
  final JournalFiles? journal;

  /// The copies in Drive; null when not signed in.
  final DriveCopies? driveCopies;

  /// Opens Eclipse again once a copy is in place.
  final Future<void> Function() reopen;
}

/// Shown in place of the app when its data can't be opened, so the window
/// says why instead of staying blank.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, this.updater, this.themeName, this.recovery});

  final Object error;
  final Updater? updater;

  /// The saved theme, from [savedThemeName]; Sunrise when null.
  final String? themeName;

  /// Null when the backups can't be found.
  final StartupRecovery? recovery;

  /// A database written by a newer build: updating fixes it.
  bool get _tooNew => error is DatabaseTooNewException;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eclipse',
      debugShowCheckedModeBanner: false,
      theme: themeNamed(themeName),
      home: Builder(
        builder: (context) {
          final p = context.palette;
          return Scaffold(
            body: Align(
              alignment: const PixelCentre(),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                // A long error and its backups can outgrow a small window.
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: PixelColumn(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tooNew ? 'This copy of Eclipse is older than your data' : 'Eclipse couldn’t open your data',
                        style: dialogTitleStyle(p),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _tooNew
                            ? 'A newer build has already updated your data. Update this copy to open it. '
                                  'Nothing has been changed or lost.'
                            : curlyQuotes('$error'),
                        style: _body(p),
                      ),
                      if (!_tooNew && recovery != null) _RecoveryList(recovery!),
                      const SizedBox(height: 24),
                      if (updater case final updater?)
                        ListenableBuilder(listenable: updater, builder: (context, _) => _UpdateRow(updater))
                      else
                        DialogConfirm(label: 'Quit', onPressed: () => exit(0)),
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

/// The saved copies here then in Drive, newest first, to bring back in place of data that
/// won't open. What's there is put aside rather than deleted.
class _RecoveryList extends StatefulWidget {
  const _RecoveryList(this.recovery);

  final StartupRecovery recovery;

  @override
  State<_RecoveryList> createState() => _RecoveryListState();
}

class _RecoveryListState extends State<_RecoveryList> {
  late final _backups = [for (final backup in widget.recovery.backups.list()) (backup, Backups.isHealthy(backup.file))];
  List<DriveBackup> _driveCopies = const [];
  late bool _looking = widget.recovery.driveCopies != null;
  bool _driveFailed = false;
  Backup? _confirming;
  bool _restoring = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_looking) unawaited(_listDrive());
  }

  Future<void> _listDrive() async {
    List<DriveBackup> copies = const [];
    var failed = false;
    try {
      copies = await widget.recovery.driveCopies!.list();
    } catch (e) {
      failed = true;
      AppLog.failure('Couldn’t list the copies in Drive', e);
    }
    if (!mounted) return;
    setState(() {
      _driveCopies = copies;
      _driveFailed = failed;
      _looking = false;
    });
  }

  Future<void> _restore(Backup backup) async {
    setState(() {
      _restoring = true;
      _error = null;
    });
    final recovery = widget.recovery;
    try {
      if (backup is DriveBackup) {
        final path = placeDatabase(await recovery.driveCopies!.fetch(backup));
        try {
          recovery.backups.recover(Backup(File(path), backup.day), recovery.database, journal: recovery.journal);
        } finally {
          removeDatabase(path);
        }
      } else {
        recovery.backups.recover(backup, recovery.database, journal: recovery.journal);
      }
      await recovery.reopen();
    } catch (_) {
      if (mounted) {
        setState(() {
          _restoring = false;
          _error = 'That copy could not be restored. Nothing was changed.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = [..._backups, for (final copy in _driveCopies) (copy, true)];
    final note = _looking
        ? 'Looking for your backups in Google Drive…'
        : _driveFailed
        ? 'Your backups in Google Drive couldn’t be reached. Check your connection and open Eclipse again.'
        : null;
    if (rows.isEmpty && note == null) return const SizedBox.shrink();
    final p = context.palette;
    final now = DateTime.now();
    return PixelColumn(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rows.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'You can go back to a saved copy. What’s there now is set aside, not deleted, '
            'and your journal writing is kept.',
            style: _body(p),
          ),
          const SizedBox(height: 12),
          // Three days show; the rest scroll, as in Settings.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: 3 * (20 + MediaQuery.textScalerOf(context).scale(50)) + 2 * 6),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final (backup, healthy) = rows[i];
                return BackupRow(
                  backup: backup,
                  today: now,
                  damaged: !healthy,
                  confirming: _confirming == backup,
                  restoring: _restoring && _confirming == backup,
                  enabled: !_restoring,
                  confirmText: 'Sets aside what’s there and goes back to this copy.',
                  onAsk: () => setState(() => _confirming = backup),
                  onCancel: () => setState(() => _confirming = null),
                  onConfirm: () => _restore(backup),
                );
              },
            ),
          ),
        ],
        if (note != null) ...[const SizedBox(height: 12), Text(note, style: _body(p).copyWith(color: p.inkMuted))],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: _body(p).copyWith(color: p.missedInk)),
        ],
      ],
    );
  }
}

TextStyle _body(Palette p) => TextStyle(fontFamily: Fonts.body, fontSize: 15, height: 1.45, color: p.ink);

class _UpdateRow extends StatelessWidget {
  const _UpdateRow(this.updater);

  final Updater updater;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final busy = updater.status == UpdateStatus.updating || updater.status == UpdateStatus.restarting;
    // A source install can always be rebuilt; a release needs one on offer.
    final canUpdate = updater is GitUpdater || updater.status == UpdateStatus.available;
    return PixelColumn(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (busy)
          Text(updater.progressDetail, style: _body(p))
        else if (updater.error case final error?)
          Text(curlyQuotes(error), style: _body(p).copyWith(color: p.missedInk)),
        const SizedBox(height: 12),
        PixelRow(
          children: [
            if (canUpdate) DialogConfirm(label: updater.actionLabel, onPressed: busy ? null : updater.update),
            const SizedBox(width: 12),
            DialogDismiss(label: 'Quit', onPressed: busy ? null : () => exit(0)),
          ],
        ),
      ],
    );
  }
}
