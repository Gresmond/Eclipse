import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// A small record of what happened on this computer, so a problem can be
/// looked into after the fact: start-ups, backups, updates, sync and errors.
/// It never holds what you wrote, and stays small: past [maxBytes] the file
/// becomes eclipse.log.old, replacing the one before.
class AppLog {
  AppLog._();

  static const maxBytes = 256 * 1024;

  /// Where it's written; null until [start], so tests leave nothing behind.
  static File? file;

  static void start(Directory home) => file = File(p.join(home.path, 'eclipse.log'));

  /// Something that happened.
  static void note(String what) {
    debugPrint(what);
    _write(what);
  }

  /// Something that went wrong. A [stack] names only places in the code.
  static void failure(String what, Object error, [StackTrace? stack]) {
    final line = '$what: ${clean(error)}';
    debugPrint(line);
    _write(stack == null ? line : '$line\n$stack');
  }

  /// [error]'s description without anything personal: a failed database
  /// save lists the values it was saving, and a bad file quotes its text.
  @visibleForTesting
  static String clean(Object error) {
    var text = error is FormatException ? error.message : '$error';
    text = text.replaceAll(RegExp(r'parameters:.*', dotAll: true), '');
    text = text.replaceAll(RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+'), '<email>');
    text = text.replaceAll(RegExp(r'1//[\w-]+|ya29\.[\w.-]+'), '<token>');
    text = text.trim();
    return text.length > 500 ? '${text.substring(0, 500)}…' : text;
  }

  /// Never gets in the way: a log that can't be written is just not written.
  static void _write(String line) {
    final log = file;
    if (log == null) return;
    try {
      if (log.existsSync() && log.lengthSync() > maxBytes) log.renameSync('${log.path}.old');
      log.writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append, flush: true);
    } on FileSystemException {
      // Nothing more to do.
    }
  }
}
