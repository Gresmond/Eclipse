import 'dart:typed_data';

import 'package:eclipse/data/backups.dart';
import 'package:eclipse/data/copy_database.dart';
import 'package:eclipse/data/google_drive.dart';
import 'package:eclipse/data/sqlite.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_disk.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drive, in memory, with deleting for the copies.
class _Drive implements SyncDrive, CopiesDrive {
  final files = <String, ({String name, List<int> bytes, String modified})>{};
  var _next = 0;

  @override
  Future<List<DriveFile>> list() async => [
    for (final MapEntry(key: id, :value) in files.entries)
      DriveFile(id: id, name: value.name, modified: value.modified),
  ];

  @override
  Future<List<int>> download(String id) async => files[id]!.bytes;

  @override
  Future<DriveFile> upload(String name, List<int> bytes, {String? id}) async {
    final key = id ?? 'f${_next++}';
    final modified = DateTime.now().toUtc().toIso8601String();
    files[key] = (name: name, bytes: bytes, modified: modified);
    return DriveFile(id: key, name: name, modified: modified);
  }

  @override
  Future<void> delete(String id) async => files.remove(id);
}

/// Takes everything but the copies of the database, until told otherwise.
class _NoCopies extends _Drive {
  bool refusing = true;

  @override
  Future<DriveFile> upload(String name, List<int> bytes, {String? id}) {
    if (refusing && name.startsWith('backup_')) throw const DriveError('Refused');
    return super.upload(name, bytes, id: id);
  }
}

SyncService _inBrowser(Store store, SyncDrive drive) {
  final db = sqlite3.openInMemory();
  addTearDown(db.close);
  return SyncService.loadFrom(DatabaseSettings(db), DatabaseDisk(db), store, connect: (_) => drive);
}

const _account = GoogleAccount(email: 'a@b.c', id: '1', refreshToken: 'held-by-server', journalAccess: true);

void main() {
  test('a database disk keeps and tells apart files as a folder does', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final disk = DatabaseDisk(db);
    expect(disk.files(), isEmpty);
    disk.writeText('pc', '2026-01-02.json', 'é');
    await disk.writeBytes('laptop', '2026-01-01.json', [1, 2]);
    expect([for (final f in disk.files()) f.key], ['laptop/2026-01-01.json', 'pc/2026-01-02.json']);
    expect(disk.readText('pc/2026-01-02.json'), 'é');
    expect(disk.readBytes('laptop/2026-01-01.json'), [1, 2]);
    expect(disk.exists('pc', '2026-01-02.json'), isTrue);
    expect(disk.exists('pc', 'other.json'), isFalse);
    final before = disk.stamp('pc/2026-01-02.json');
    // The same size: it's still seen as changed.
    disk.writeText('pc', '2026-01-02.json', 'è');
    expect(disk.stamp('pc/2026-01-02.json'), isNot(before));
    disk.clear();
    expect(disk.files(), isEmpty);
  });

  test('a browser and a computer sync through Drive, both ways', () async {
    final drive = _Drive();
    final pc = Store.memory(), browser = Store.memory();
    addTearDown(pc.close);
    addTearDown(browser.close);
    pc.setJournal('2026-01-01', 'Written on the computer');
    final first = _inBrowser(pc, drive);
    await first.look(_account);
    await first.turnOn(_account, join: false);
    expect(first.error, isNull);

    final second = _inBrowser(browser, drive);
    expect(await second.look(_account), isTrue);
    await second.turnOn(_account, join: true);
    expect(browser.journal('2026-01-01'), 'Written on the computer');

    browser.setJournal('2026-01-02', 'Written in the browser');
    await second.run();
    expect(second.error, isNull);
    await first.run();
    expect(pc.journal('2026-01-02'), 'Written in the browser');
    first.stop();
    second.stop();
  });

  test('signing in on a browser again finds its earlier edits as another computer’s', () async {
    final drive = _Drive();
    final one = Store.memory(), two = Store.memory();
    addTearDown(one.close);
    addTearDown(two.close);
    one.setJournal('2026-01-03', 'Before signing out');
    final before = _inBrowser(one, drive);
    await before.look(_account);
    await before.turnOn(_account, join: false);
    before.stop();
    // Erased: a new id and nothing here.
    final after = _inBrowser(two, drive);
    expect(after.machine, isNot(before.machine));
    expect(await after.look(_account), isTrue);
    await after.turnOn(_account, join: true);
    expect(two.journal('2026-01-03'), 'Before signing out');
    after.stop();
  });

  test('copies here are dropped once one is in Drive, and only then', () async {
    final failing = _NoCopies();
    final store = Store.memory();
    addTearDown(store.close);
    final sync = _inBrowser(store, failing)..copiesToDrive = true;
    var dropped = 0;
    sync.afterDriveCopy = () => dropped++;
    await sync.look(_account);
    await sync.turnOn(_account, join: false);
    expect(dropped, 0, reason: 'the upload failed');

    failing.refusing = false;
    await sync.run();
    expect(dropped, 1);
    expect(failing.files.values.map((f) => f.name), contains(startsWith('backup_${sync.machine}')));

    // Already up today, on another round or after an update: still dropped.
    await sync.run();
    expect(dropped, 2);
    sync.stop();
  });

  test('a copy goes to Drive once a day, keeps 30, and sync passes over them', () async {
    final drive = _Drive();
    final store = Store.memory();
    addTearDown(store.close);
    store.setJournal('2026-01-01', 'Kept');
    final sync = _inBrowser(store, drive)..copiesToDrive = true;
    await sync.look(_account);
    for (var day = 1; day <= 31; day++) {
      await drive.upload('backup_${sync.machine}_2025-01-${'$day'.padLeft(2, '0')}.db', [1]);
    }
    await drive.upload('backup_other_2025-01-01.db', [1]);
    await sync.turnOn(_account, join: false);
    expect(sync.error, isNull);

    final names = [for (final f in drive.files.values) f.name];
    final mine = names.where((n) => n.startsWith('backup_${sync.machine}')).toList();
    expect(mine, hasLength(30));
    expect(mine, isNot(contains('backup_${sync.machine}_2025-01-01.db')));
    expect(names, contains('backup_other_2025-01-01.db'));

    final copies = await sync.driveCopies();
    expect(copies.first.from, 'this computer');
    expect(copies.map((c) => c.day).whereType<DateTime>(), hasLength(31));
    final today = copies.first;
    expect(today.day, isNotNull);

    final uploads = drive.files.length;
    await sync.run();
    expect(drive.files.length, uploads, reason: 'once a day');

    // What's in Drive is a whole copy of the database.
    final path = placeDatabase(await sync.fetchCopy(today));
    addTearDown(() => removeDatabase(path));
    final copy = Store.open(path);
    addTearDown(copy.close);
    expect(copy.journal('2026-01-01'), 'Kept');

    // And nobody takes it for changes.
    final later = Store.memory();
    addTearDown(later.close);
    final joining = _inBrowser(later, drive);
    expect(await joining.look(_account), isTrue);
    await joining.turnOn(_account, join: true);
    expect(joining.error, isNull);
    expect(later.journal('2026-01-01'), 'Kept');
    sync.stop();
    joining.stop();
  });

  test('a phone, with copies off, sends none', () async {
    final drive = _Drive();
    final store = Store.memory();
    addTearDown(store.close);
    final sync = _inBrowser(store, drive);
    await sync.look(_account);
    await sync.turnOn(_account, join: false);
    expect(drive.files.values.where((f) => f.name.startsWith('backup_')), isEmpty);
    expect(await sync.driveCopies(), isEmpty);
    sync.stop();
  });

  test('copying over SQL gives what SQLite’s own backup gives', () async {
    final from = Store.memory();
    addTearDown(from.close);
    from.setJournal('2026-01-01', 'Text');
    from.setSetting('theme', 'Sunset');
    from.raw.execute('CREATE TABLE odd (a BLOB, b REAL, c)');
    from.raw.execute('INSERT INTO odd VALUES (?, ?, NULL)', [
      Uint8List.fromList([0, 1, 2]),
      1.5,
    ]);
    SyncEngine(from, 'me').flush();

    final bySql = Store.memory(), byBackup = sqlite3.openInMemory();
    addTearDown(bySql.close);
    addTearDown(byBackup.close);
    bySql.setJournal('2020-01-01', 'Gone once copied over');
    copyOver(from.raw, bySql.raw);
    await from.raw.backup(byBackup, nPage: -1).drain<void>();

    List<List<Object?>> everything(Database db) {
      final out = <List<Object?>>[
        db.select('PRAGMA user_version').first.values,
        for (final r in db.select('SELECT type, name, sql FROM sqlite_master ORDER BY type, name')) r.values,
      ];
      for (final t in db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) {
        out.addAll(db.select('SELECT * FROM "${t['name']}"').map((r) => r.values));
      }
      return out;
    }

    expect(everything(bySql.raw), everything(byBackup));
    expect(bySql.journal('2020-01-01'), '');
    expect(bySql.raw.select('PRAGMA foreign_keys').first.columnAt(0), 1);
  });

  test('a copy in Drive shows its own time', () {
    final saved = DateTime(2026, 1, 2, 3, 4);
    final copy = DriveBackup(id: 'x', name: 'n', day: null, saved: saved, from: 'laptop');
    expect(copy.modified, saved);
  });
}
