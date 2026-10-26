import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// A `flutter run` build opens the same data as the copy linux/install.sh
/// put in ~/.local/opt/eclipse. Once it has moved the database to a newer
/// format, that copy can no longer open it, so this reinstalls it from the
/// running build: a release bundle is copied as it is, a debug run builds one.
Future<void> refreshInstalledCopy(int schemaVersion) async {
  if (!Platform.isLinux) return;
  final home = Platform.environment['HOME'];
  if (home == null) return;
  final repo = sourceRepoOf(Platform.resolvedExecutable);
  if (repo == null) return;
  final installed = File(p.join(home, '.local', 'opt', 'eclipse', 'build-info'));
  if (!installed.existsSync()) return;
  if (!installedSchemaIsBehind(installed.readAsStringSync(), schemaVersion)) return;
  try {
    await Process.start(
      'bash',
      [p.join(repo, 'linux', 'install.sh'), if (kReleaseMode) '--bundle'],
      workingDirectory: repo,
      mode: ProcessStartMode.detached,
    );
  } on ProcessException {
    // The installed copy stays behind; its error screen offers a rebuild.
  }
}

/// The source folder when [executable] is a `flutter run` build inside it
/// (`build/linux/x64/<mode>/bundle/eclipse`); null for installed copies.
@visibleForTesting
String? sourceRepoOf(String executable) {
  final bundle = p.dirname(executable);
  if (File(p.join(bundle, 'build-info')).existsSync()) return null;
  final parts = p.split(bundle);
  if (parts.length < 6) return null;
  final tail = parts.sublist(parts.length - 5);
  if (tail[0] != 'build' || tail[1] != 'linux' || tail[2] != 'x64' || tail[4] != 'bundle') return null;
  final repo = p.joinAll(parts.sublist(0, parts.length - 5));
  return File(p.join(repo, 'linux', 'install.sh')).existsSync() ? repo : null;
}

/// Whether a `build-info` records an older database format than
/// [schemaVersion]. Copies from before it was recorded count as behind.
@visibleForTesting
bool installedSchemaIsBehind(String buildInfo, int schemaVersion) {
  final match = RegExp(r'^schema=(\d+)$', multiLine: true).firstMatch(buildInfo);
  final schema = match == null ? null : int.tryParse(match.group(1)!);
  return schema == null || schema < schemaVersion;
}
