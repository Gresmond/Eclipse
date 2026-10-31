import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models.dart';
import 'google_drive.dart';
import 'journal_files.dart';

/// Keeps a copy of the journal in a folder in Drive you can see, Eclipse
/// Journals: one way, from Eclipse, never read back. Runs at the end of each
/// sync round; what it knows of the folder lives in sync's settings.
class JournalFolder {
  JournalFolder(this._config, this._save, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Map<String, dynamic> _config;
  final Future<void> Function() _save;
  final DateTime Function() _now;

  /// How often the folder is listed to find files deleted in Drive, which
  /// are written again: it's Eclipse's copy, as edits made there are.
  static const checkEvery = Duration(hours: 1);

  /// A day's file where Eclipse puts it, like 2026/2026-10-31.md.
  static final _dayFile = RegExp(r'^(\d{4})/((\d{4})-\d{2}-\d{2})\.md$');

  /// The day of a file at [path] in the folder, if it's one Eclipse wrote.
  static String? _dayOf(String path) {
    final match = _dayFile.firstMatch(path);
    if (match == null || match[1] != match[3]) return null;
    final day = DateTime.tryParse(match[2]!);
    return day != null && dateKey(day) == match[2] ? match[2] : null;
  }

  static const folderName = 'Eclipse Journals';

  /// Files written in one round at most, so a round stays short; the rest go
  /// in the next, half a minute on.
  static const batch = 25;

  /// Whether days were left for the next round.
  bool behind = false;

  /// The folder's id in Drive; null until it's made.
  String? get id => _config['journalFolder'] as String?;

  Map<String, dynamic> _map(String key) => (_config[key] ??= <String, dynamic>{}) as Map<String, dynamic>;

  /// Its year folders' ids, by year.
  Map<String, dynamic> get _years => _map('journalYears');

  /// Each day's file and its checksum, by day.
  Map<String, dynamic> get _up => _map('journalUp');

  void forget() {
    behind = false;
    for (final key in ['journalFolder', 'journalYears', 'journalUp', 'journalFill', 'journalChecked']) {
      _config.remove(key);
    }
  }

  /// Brings the folder up to date with the days [machine] wrote last
  /// ([writers]); the other computers see to theirs. Whoever makes the
  /// folder (the first time, or after it was deleted) fills it with every
  /// day of [texts].
  Future<void> copy(
    JournalDrive drive, {
    required String machine,
    required Map<String, String> writers,
    required Map<String, String> texts,
    required bool Function() stopped,
  }) async {
    var folder = id;
    if (folder == null || !await drive.exists(folder)) {
      forget();
      final found = await drive.findFolder(folderName);
      if (found != null && found != folder) {
        // Made by another computer, or by this one before signing out.
        final (files, years) = await drive.listJournal(found);
        _years.addAll(years);
        for (final MapEntry(key: path, value: (id, md5)) in files.entries) {
          if (_dayOf(path) case final day?) _up[day] = [id, md5];
        }
        _config['journalChecked'] = _now().toIso8601String();
        folder = found;
      } else {
        folder = await drive.makeFolder(folderName);
        _config['journalFill'] = true;
        _config['journalChecked'] = _now().toIso8601String();
      }
      _config['journalFolder'] = folder;
      await _save();
    } else if (_now().difference(DateTime.tryParse(_config['journalChecked'] as String? ?? '') ?? DateTime(0)) >=
        checkEvery) {
      // Files and year folders deleted in Drive are forgotten, to be
      // written again below.
      final (files, years) = await drive.listJournal(folder);
      _years.removeWhere((year, id) => years[year] != id);
      final there = {for (final MapEntry(key: path, value: (id, _)) in files.entries) ?_dayOf(path): id};
      _up.removeWhere((day, file) => (file as List)[0] != '' && there[day] != file[0]);
      _config['journalChecked'] = _now().toIso8601String();
      await _save();
    }
    if (stopped()) return;

    final fill = _config['journalFill'] == true;
    // A day's file and its checksum, or two blanks once it's known there's
    // none, for a day emptied.
    final up = _up, years = _years;
    const none = ['', ''];
    var written = 0;
    behind = false;
    for (final day in {...texts.keys, ...up.keys, ...writers.keys}.toList()..sort()) {
      if (stopped()) return;
      if (!fill && (writers[day] ?? machine) != machine) continue;
      final contents = JournalFiles.contents(DateTime.parse(day), texts[day] ?? '');
      final bytes = contents == null ? null : utf8.encode(contents);
      final had = (up[day] as List?)?.cast<String>();
      final same = bytes == null
          ? (had != null && had[0] == '') || (fill && had == null)
          : (had != null && had[1] == md5.convert(bytes).toString());
      if (same) {
        if (had == null) up[day] = none;
        continue;
      }
      if (written == batch) {
        behind = true;
        break;
      }
      written++;
      final year = day.substring(0, 4);
      try {
        if (bytes == null) {
          // Another computer may have written the day's file last.
          final yearFolder = years[year] as String? ?? await drive.findFolder(year, parent: folder);
          final id = had?[0] ?? (yearFolder == null ? null : (await drive.findFile('$day.md', yearFolder))?.$1);
          if (id != null) await drive.bin(id);
          up[day] = none;
          continue;
        }
        final yearFolder =
            years[year] as String? ??
            await drive.findFolder(year, parent: folder) ??
            await drive.makeFolder(year, parent: folder);
        years[year] = yearFolder;
        final id = had?[0] ?? (await drive.findFile('$day.md', yearFolder))?.$1;
        final (newId, sum) = await drive.writeFile('$day.md', yearFolder, bytes, id: id == '' ? null : id);
        up[day] = [newId, sum];
      } on DriveError catch (e) {
        if (!e.notFound) rethrow;
        // Deleted in Drive: looked for again next round.
        up.remove(day);
        years.remove(year);
        behind = true;
      }
    }
    if (!behind) _config.remove('journalFill');
    await _save();
  }
}
