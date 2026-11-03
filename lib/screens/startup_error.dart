import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' show OpenMode, sqlite3;

import '../data/store.dart' show DatabaseTooNewException;
import '../data/updates.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';

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

/// Shown in place of the app when its data can't be opened, so the window
/// says why instead of staying blank.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, this.updater, this.themeName});

  final Object error;
  final Updater? updater;

  /// The saved theme, from [savedThemeName]; Sunrise when null.
  final String? themeName;

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (busy)
          Text(updater.progressDetail, style: _body(p))
        else if (updater.error case final error?)
          Text(curlyQuotes(error), style: _body(p).copyWith(color: p.missedInk)),
        const SizedBox(height: 12),
        Row(
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
