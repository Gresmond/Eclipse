import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models.dart';

/// Journal entries as plain Markdown files, one per day, in a folder you can
/// open, read, copy or back up without the app:
/// ~/Documents/Eclipse Journals/2026/2026-10-23.md
///
/// The database holds the journal; these are a copy of it, kept up to date
/// as entries are written, synced or restored. Edits made to the files
/// themselves aren't read back, and are replaced the next time that day is
/// saved.
class JournalFiles {
  JournalFiles(this.dir);

  Directory dir;

  File fileFor(DateTime day) => File(p.join(dir.path, '${day.year}', '${dateKey(day)}.md'));

  static String _heading(DateTime day) =>
      '# ${weekdayNames[day.weekday - 1]} ${day.day} ${monthNames[day.month - 1]} ${day.year}';

  /// Moves [from] into this folder, replacing any there for the same
  /// day, then removes the year folders and this folder if that leaves them
  /// empty. Anything else in them stays where it is.
  Future<void> moveFrom(Directory from) {
    final fromPath = from.path, toPath = dir.path;
    return _pending = pending.then((_) => Isolate.run(() => _move(Directory(fromPath), Directory(toPath))));
  }

  static void _move(Directory dir, Directory to) {
    if (!dir.existsSync() || p.equals(dir.path, to.path)) return;
    final entry = RegExp(r'^\d{4}-\d{2}-\d{2}\.md$');
    for (final year in dir.listSync().whereType<Directory>()) {
      final name = p.basename(year.path);
      if (!RegExp(r'^\d{4}$').hasMatch(name)) continue;
      for (final file in year.listSync().whereType<File>()) {
        if (!entry.hasMatch(p.basename(file.path))) continue;
        final dest = File(p.join(to.path, name, p.basename(file.path)));
        dest.parent.createSync(recursive: true);
        // Copied and then removed, as a rename can't cross drives.
        file.copySync(dest.path);
        file.deleteSync();
      }
      if (year.listSync().isEmpty) year.deleteSync();
    }
    if (dir.listSync().isEmpty) dir.deleteSync();
  }

  /// The days that have a file here.
  Future<List<DateTime>> days() async {
    final found = <DateTime>[];
    if (!await dir.exists()) return found;
    final entry = RegExp(r'^\d{4}-\d{2}-\d{2}\.md$');
    await for (final file in dir.list(recursive: true)) {
      final name = p.basename(file.path);
      if (file is File && entry.hasMatch(name)) found.add(DateTime.parse(p.basenameWithoutExtension(name)));
    }
    return found;
  }

  /// Saves the day's entry; an empty entry removes its file. Written beside
  /// the file first and renamed, so a crash never leaves half an entry.
  Future<void> _pending = Future.value();
  Future<void> get pending => _pending.catchError((Object _) {});

  /// What the day's file holds; null when the entry is empty, for no file.
  static String? contents(DateTime day, String text) => text.trim().isEmpty ? null : '${_heading(day)}\n\n$text\n';

  Future<void> write(DateTime day, String text) {
    final file = fileFor(day);
    final content = contents(day, text);
    // One writer owns the .part name. Later saves always win, including
    // while an earlier write is waiting for disk or recovering from failure.
    return _pending = pending.then((_) async {
      if (content == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      await file.parent.create(recursive: true);
      final part = File('${file.path}.part');
      await part.writeAsString(content, flush: true);
      await part.rename(file.path);
    });
  }
}
