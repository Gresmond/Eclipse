part of 'sync.dart';

/// A sync folder on disk: this computer's change files, written here, and
/// copies of the others', brought down by [Remote].
///
/// `<folder>/<computer id>/2026-10-24.json`
class SyncFolder {
  SyncFolder(this.dir, this.me, this.name);

  final Directory dir;
  final String me;

  /// This computer's name, shown on the others.
  final String name;

  Directory get mine => Directory(p.join(dir.path, me));

  /// Writes this computer's edits since [since], a file per day, away from
  /// the UI isolate. Returns whether anything was written.
  Future<bool> write(SyncEngine engine, int since) async {
    final days = engine.changesSince(since);
    if (days.isEmpty) return false;
    final root = dir.path, machine = me, computer = name;
    await Isolate.run(() => _writeDays(root, machine, computer, days));
    return true;
  }

  static void _writeDays(String root, String machine, String computer, Map<String, List<List<Object?>>> days) {
    for (final MapEntry(key: day, value: regs) in days.entries) {
      final file = File(p.join(root, machine, '$day.json'));
      file.parent.createSync(recursive: true);
      replaceSafelySync(
        file.path,
        (part) => part.writeAsStringSync(jsonEncode({'version': 1, 'name': computer, 'registers': regs}), flush: true),
      );
    }
  }

  /// Whether another computer has left any changes here.
  bool get hasOthers => computers.isNotEmpty;

  /// The other computers that have left changes here, by id.
  Set<String> get computers => {
    for (final f in _files())
      if (p.basename(f.parent.path) != me) p.basename(f.parent.path),
  };

  /// Every change file here, this computer's own too: read back, they
  /// return any of its edits the database here has lost (to a power cut,
  /// say).
  List<File> _files() {
    if (!dir.existsSync()) return [];
    return [
      for (final d in dir.listSync().whereType<Directory>())
        for (final f in d.listSync().whereType<File>())
          if (f.path.endsWith('.json')) f,
    ]..sort((a, b) => a.path.compareTo(b.path));
  }

  /// The latest edit in each computer's files here, by id.
  Map<String, int> latestSent() {
    final latest = <String, int>{};
    for (final file in _files()) {
      try {
        final json = jsonDecode(file.readAsStringSync());
        if (json is! Map || json['registers'] is! List) continue;
        final who = p.basename(file.parent.path);
        for (final r in json['registers'] as List) {
          if (r is List && r.length > 4 && r[4] is int) latest[who] = max(latest[who] ?? 0, r[4] as int);
        }
      } on FormatException {
        continue;
      }
    }
    return latest;
  }

  /// The computers, by name, whose last files read need a newer version of
  /// Eclipse; read once it's updated.
  Set<String> newer = {};

  /// The computers, by name, some of whose files couldn't be read or
  /// taken in: tried again each round.
  Set<String> unread = {};

  /// The other computers' names, by id, from the files read.
  final names = <String, String>{};

  /// Merges every file that's new or changed since it was last read.
  Map<String, String> _seen(SyncEngine engine) => {
    for (final row in engine.store.raw.select('SELECT file, stamp FROM sync_seen'))
      row['file'] as String: row['stamp'] as String,
  };

  Incoming read(SyncEngine engine) => _mergeFiles(engine, _readFiles(dir.path, me, _seen(engine)));

  /// Disk reads and JSON parsing do not compete with animation frames.
  /// Drafts are saved only after preparation, immediately before the merge.
  Future<Incoming> readAsync(SyncEngine engine, {void Function()? beforeMerge, bool Function()? canMerge}) async {
    final root = dir.path, machine = me, seen = _seen(engine);
    final prepared = await Isolate.run(() => _readFiles(root, machine, seen));
    if (canMerge != null && !canMerge()) return Incoming({}, {});
    beforeMerge?.call();
    return _mergeFiles(engine, prepared);
  }

  static _Files _readFiles(String root, String machine, Map<String, String> seen) {
    final read = _Files();
    for (final file in SyncFolder(Directory(root), machine, '')._files()) {
      final key = p.relative(file.path, from: root);
      final stat = file.statSync();
      final stamp = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
      if (seen[key] == stamp) continue;
      final who = p.basename(file.parent.path);
      // A file that can't be read (cut short, say) is skipped, never
      // stopping the rest, and tried again next time.
      try {
        final json = jsonDecode(file.readAsStringSync());
        if (json is! Map) {
          if (who != machine) read.unreadIds.add(who);
          continue;
        }
        final name = json['name'] is String ? json['name'] as String : 'another computer';
        if (who != machine) read.names[who] = name;
        // Written by a newer version of Eclipse, in a way this one can't
        // read: left until this one is updated.
        if ((json['version'] ?? 1) != 1) {
          if (who != machine) read.newer.add(name);
          continue;
        }
        if (json['registers'] is List) {
          final registers = [
            for (final row in json['registers'] as List)
              if (row is List) row.cast<Object?>().toList() else const <Object?>[],
          ];
          if (registers.every(_Reg.valid)) {
            read.batches.add((registers, who == machine ? machine : name));
            read.keys.add(key);
            read.stamps[key] = stamp;
            continue;
          }
        }
        if (who != machine) read.unread.add(name);
      } on FormatException {
        if (who != machine) read.unreadIds.add(who);
      } on FileSystemException {
        continue;
      }
    }
    return read;
  }

  Incoming _mergeFiles(SyncEngine engine, _Files prepared) {
    final _Files(:batches, :keys, :stamps) = prepared;
    newer = prepared.newer;
    names.addAll(prepared.names);
    final incoming = engine.mergeAll(batches);
    // Not marked read, so they're tried again.
    for (final i in incoming.failed) {
      stamps.remove(keys[i]);
    }
    unread = {
      ...prepared.unread,
      for (final id in prepared.unreadIds) names[id] ?? 'another computer',
      for (final i in incoming.failed)
        if (batches[i].$2 != me) batches[i].$2,
    };
    engine.store.transaction(() {
      for (final MapEntry(:key, :value) in stamps.entries) {
        engine.store.raw.execute('INSERT OR REPLACE INTO sync_seen VALUES (?, ?)', [key, value]);
      }
    });
    return incoming;
  }
}

/// What reading the change files found.
class _Files {
  final batches = <(List<List<Object?>>, String)>[];

  /// Each batch's file, by place.
  final keys = <String>[];
  final stamps = <String, String>{};
  final newer = <String>{};
  final unread = <String>{};

  /// Unread before their names were: by id.
  final unreadIds = <String>{};
  final names = <String, String>{};
}
