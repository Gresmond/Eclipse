import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart' as web;

import 'app_log.dart';
import 'sqlite_web.dart' as sqlite;
import 'store.dart';
import 'sync_disk.dart';

const _name = 'eclipse';
const _marker = '/opfs-v1';
const _paths = ['/productivity.db', '/sync.db'];

/// SQLite needs synchronous reads on the UI thread. OPFS holds an atomic
/// snapshot of both databases, with an in-memory VFS for those reads.
/// Existing IndexedDB installations migrate only after the snapshot closes.
class BrowserData {
  BrowserData._(this._files, this.store, this._syncDb, this._snapshot)
    : disk = DatabaseDisk(_syncDb),
      settings = DatabaseSettings(_syncDb) {
    if (_snapshot != null) {
      for (final db in [store.raw, _syncDb]) {
        _listeners.add(db.commits.listen((_) => _changed()));
      }
    }
  }

  final VirtualFileSystem _files;
  final web.FileSystemFileHandle? _snapshot;
  final Store store;
  final CommonDatabase _syncDb;
  final SyncDisk disk;
  final SyncSettings settings;
  final _listeners = <StreamSubscription<void>>[];
  Future<void>? _writing;
  bool _dirty = false;

  static Uint8List _read(VirtualFileSystem fs, String path) {
    if (fs.xAccess(path, 0) == 0) return Uint8List(0);
    final file = fs.xOpen(Sqlite3Filename(path), SqlFlag.SQLITE_OPEN_READONLY).file;
    try {
      final bytes = Uint8List(file.xFileSize());
      file.xRead(bytes, 0);
      return bytes;
    } finally {
      file.xClose();
    }
  }

  static void _put(VirtualFileSystem fs, String path, Uint8List bytes) {
    final file = fs.xOpen(Sqlite3Filename(path), SqlFlag.SQLITE_OPEN_READWRITE | SqlFlag.SQLITE_OPEN_CREATE).file;
    try {
      file.xTruncate(0);
      file.xWrite(bytes, 0);
    } finally {
      file.xClose();
    }
  }

  static Future<void> _write(web.FileSystemFileHandle handle, VirtualFileSystem fs) async {
    // Capture both before yielding. createWritable commits on close.
    final main = _read(fs, _paths.first), sync = _read(fs, _paths.last);
    final header = ByteData(8)
      ..setUint32(0, main.length)
      ..setUint32(4, sync.length);
    final writer = await handle.createWritable().toDart;
    try {
      for (final bytes in [header.buffer.asUint8List(), main, sync]) {
        await writer.write(bytes.toJS).toDart;
      }
      await writer.close().toDart;
    } catch (_) {
      await writer.abort().toDart;
      rethrow;
    }
  }

  static Future<BrowserData> open() async {
    final wasm = await WasmSqlite3.loadFromUrlString('sqlite3.wasm');
    final legacy = await IndexedDbFileSystem.open(dbName: _name);
    final migrated = legacy.xAccess(_marker, 0) != 0;
    var registeredLegacy = false;
    VirtualFileSystem files = legacy;
    web.FileSystemFileHandle? snapshot;
    try {
      final storage = web.window.navigator.storage;
      try {
        unawaited(storage.persist().toDart.then<void>((_) {}, onError: (Object _) {}));
      } catch (_) {
        // Some browsers offer OPFS without a persistent-storage request.
      }
      final dir = await storage.getDirectory().toDart;
      final handle = await dir.getFileHandle('eclipse-v1.db', web.FileSystemGetFileOptions(create: !migrated)).toDart;
      final memory = InMemoryFileSystem();
      if (migrated) {
        final file = await handle.getFile().toDart;
        final buffer = (await file.arrayBuffer().toDart).toDart;
        final header = ByteData.view(buffer);
        final split = 8 + header.getUint32(0);
        if (split + header.getUint32(4) != buffer.lengthInBytes) {
          throw const FormatException('Incomplete Eclipse database');
        }
        _put(memory, _paths.first, buffer.asUint8List(8, split - 8));
        _put(memory, _paths.last, buffer.asUint8List(split));
      } else {
        // Open legacy SQLite first so SQLite itself recovers interrupted
        // transactions. Copy only committed contents to the new VFS.
        wasm.registerVirtualFileSystem(legacy, makeDefault: true);
        registeredLegacy = true;
        sqlite.browserFiles = legacy;
        for (final path in _paths) {
          final db = wasm.open(path);
          try {
            _put(memory, path, sqlite.copyOfDatabase(db));
          } finally {
            db.close();
          }
        }
        await _write(handle, memory);
        _put(legacy, _marker, Uint8List.fromList([1]));
        await legacy.flush();
      }
      files = memory;
      snapshot = handle;
    } catch (_) {
      // After migration a stale legacy copy must never be reopened.
      if (migrated || legacy.xAccess(_marker, 0) != 0) {
        await legacy.close();
        rethrow;
      }
    }
    if (files != legacy) {
      if (registeredLegacy) wasm.unregisterVirtualFileSystem(legacy);
      await legacy.close();
    }
    if (files != legacy || !registeredLegacy) wasm.registerVirtualFileSystem(files, makeDefault: true);
    sqlite.sqlite3 = wasm;
    sqlite.browserFiles = files;
    final data = BrowserData._(files, Store.open(_paths.first), wasm.open(_paths.last), snapshot);
    if (snapshot != null) {
      // A snapshot copies the database files. Keep committed pages there,
      // even if a future version of the memory VFS supports WAL.
      for (final db in [data.store.raw, data._syncDb]) {
        db.execute('PRAGMA journal_mode=DELETE');
      }
    }
    await data.persist();
    return data;
  }

  static Future<void> erase() async {
    final legacy = await IndexedDbFileSystem.open(dbName: _name);
    final migrated = legacy.xAccess(_marker, 0) != 0;
    await legacy.close();
    try {
      final dir = await web.window.navigator.storage.getDirectory().toDart;
      await dir.removeEntry('eclipse-v1.db').toDart;
    } catch (error) {
      final js = error as JSAny?;
      if (migrated && !(js != null && js.isA<web.DOMException>() && (js as web.DOMException).name == 'NotFoundError')) {
        rethrow;
      }
    }
    await IndexedDbFileSystem.deleteDatabase(_name);
  }

  void _changed() {
    _dirty = true;
    unawaited(_drain().catchError((Object error) => AppLog.failure('Saving browser data', error)));
  }

  Future<void> _drain() => _writing ??= _save().whenComplete(() => _writing = null);

  Future<void> _save() async {
    while (_dirty) {
      _dirty = false;
      try {
        await _write(_snapshot!, _files);
      } catch (_) {
        _dirty = true;
        rethrow;
      }
    }
  }

  Future<void> persist() async {
    store.flushToDisk();
    if (_files case final IndexedDbFileSystem legacy) {
      await legacy.flush();
    } else {
      _dirty = true;
      await _drain();
    }
  }

  Future<void> close() async {
    for (final sub in _listeners) {
      await sub.cancel();
    }
    _syncDb.close();
    if (_files case final IndexedDbFileSystem legacy) {
      await legacy.flush();
      await legacy.close();
    } else {
      await _writing;
    }
  }
}
