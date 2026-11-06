import 'store.dart';
import 'sync_disk.dart';

/// Only the web build keeps its data in a browser.
class BrowserData {
  static Future<BrowserData> open() => throw UnsupportedError('Not in a browser');
  static Future<void> erase() => throw UnsupportedError('Not in a browser');

  Store get store => throw UnsupportedError('Not in a browser');
  SyncDisk get disk => throw UnsupportedError('Not in a browser');
  SyncSettings get settings => throw UnsupportedError('Not in a browser');
  Future<void> persist() => throw UnsupportedError('Not in a browser');
  Future<void> close() => throw UnsupportedError('Not in a browser');
}
