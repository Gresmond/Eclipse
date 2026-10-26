import 'dart:ffi';
import 'dart:io';

/// Keeps the app's local time in the system's current time zone.
///
/// On Linux the C library reads the time zone once, when the app starts, so
/// changing it (`timedatectl set-timezone`, or automatic time zone after
/// travelling) would leave a running app on the old zone, and the day would
/// turn over at the wrong hour. It does follow the TZ variable, though, so
/// [sync] points TZ at whatever /etc/localtime now links to. The runner sets
/// TZ the same way at launch (linux/runner/main.cc), so this only replaces
/// it. A zone name you set in TZ yourself is left alone.
///
/// macOS notices time zone changes by itself.
class SystemTimeZone {
  SystemTimeZone._(this._current);

  static const _localtime = '/etc/localtime';

  /// Null where the zone can't or shouldn't be followed.
  static final SystemTimeZone? instance = () {
    if (!Platform.isLinux) return null;
    final tz = Platform.environment['TZ'];
    // Unset (started some other way), or a file path as the runner sets it
    // (possibly inherited by the copy reopened after an update). People
    // setting TZ themselves write a zone name, like Europe/London.
    if (_target() == null || (tz != null && !tz.startsWith(':/'))) return null;
    return SystemTimeZone._(tz?.substring(1));
  }();

  String? _current;

  static String? _target() {
    try {
      return File(_localtime).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  /// Cheap: one readlink, and nothing more unless the zone changed.
  void sync() {
    final target = _target();
    if (target == null || target == _current) return;
    _current = target;
    _setenv('TZ', ':$target');
  }

  static void _setenv(String name, String value) {
    final libc = DynamicLibrary.process();
    final setenv = libc
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32),
          int Function(Pointer<Uint8>, Pointer<Uint8>, int)
        >('setenv');
    final tzset = libc.lookupFunction<Void Function(), void Function()>('tzset');
    final malloc = libc.lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('malloc');
    final free = libc.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('free');

    Pointer<Uint8> cString(String s) {
      final bytes = s.codeUnits; // paths under /usr/share/zoneinfo are ASCII
      final p = malloc(bytes.length + 1);
      p.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return p;
    }

    final (n, v) = (cString(name), cString(value));
    setenv(n, v, 1); // copies both
    free(n);
    free(v);
    tzset();
  }
}
