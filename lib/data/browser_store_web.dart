import 'package:sqlite3/wasm.dart';

import 'sqlite_web.dart' as sqlite;
import 'store.dart';
import 'sync_disk.dart';

const _name = 'eclipse';

/// Everything a browser keeps: SQLite in WebAssembly, with its files in
/// IndexedDB. The app's saves stay synchronous: they go to a copy in memory,
/// and from there to IndexedDB straight after.
class BrowserData {
  BrowserData._(this._files, this.store, this._syncDb) : disk = DatabaseDisk(_syncDb), settings = DatabaseSettings(_syncDb);

  static Future<BrowserData> open() async {
    final wasm = await WasmSqlite3.loadFromUrlString('sqlite3.wasm');
    final files = await IndexedDbFileSystem.open(dbName: _name);
    wasm.registerVirtualFileSystem(files, makeDefault: true);
    sqlite.sqlite3 = wasm;
    sqlite.browserFiles = files;
    return BrowserData._(files, Store.open('/productivity.db'), wasm.open('/sync.db'));
  }

  /// Removes it all. Nothing may have it open.
  static Future<void> erase() => IndexedDbFileSystem.deleteDatabase(_name);

  final IndexedDbFileSystem _files;
  final Store store;
  final CommonDatabase _syncDb;
  final SyncDisk disk;
  final SyncSettings settings;

  Future<void> persist() => _files.flush();

  /// Lets go of the database, once the store is closed.
  Future<void> close() async {
    _syncDb.close();
    await _files.flush();
    await _files.close();
  }
}
