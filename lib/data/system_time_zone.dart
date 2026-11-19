import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Keeps the app's local time aligned with `/etc/localtime` on Linux without
/// mutating process-wide environment variables (`TZ`) at runtime.
class SystemTimeZone {
  SystemTimeZone._(this._path);

  static const _localtime = '/etc/localtime';

  /// Null when not on Linux or when the user set `TZ` themselves.
  static final SystemTimeZone? instance = () {
    if (!Platform.isLinux) return null;
    final tz = Platform.environment['TZ'];
    if (tz != null && tz.isNotEmpty) return null;
    return SystemTimeZone._(_localtime);
  }();

  @visibleForTesting
  factory SystemTimeZone.forPath(String path) => SystemTimeZone._(path);

  /// Current wall-clock time in the system's active time zone.
  static DateTime now() => instance?.currentTime() ?? DateTime.now();

  final String _path;
  String? _target;
  DateTime? _modified;
  int? _size;
  TzifZone? _zone;

  /// Reads `/etc/localtime` again if its symlink target or file metadata changed.
  void sync() {
    try {
      final file = File(_path);
      final target = file.resolveSymbolicLinksSync();
      final resolved = File(target);
      final stat = resolved.statSync();
      if (target == _target && stat.modified == _modified && stat.size == _size && _zone != null) {
        return;
      }
      final parsed = TzifZone.parse(resolved.readAsBytesSync());
      if (parsed == null) return;
      _target = target;
      _modified = stat.modified;
      _size = stat.size;
      _zone = parsed;
    } on FileSystemException {
      // Missing or temporarily replaced file: keep the last known zone.
    }
  }

  /// Current local wall-clock time, shifted if `/etc/localtime` has changed
  /// since startup so `DateTime.now()`'s cached C-library zone differs.
  DateTime currentTime({DateTime Function()? utcNow}) {
    final utc = (utcNow ?? DateTime.now)().toUtc();
    final zone = _zone;
    if (zone == null) return utc.toLocal();
    final targetOffset = zone.offsetAt(utc);
    final local = utc.toLocal();
    if (local.timeZoneOffset == targetOffset) return local;
    final shifted = utc.add(targetOffset);
    return DateTime(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }
}

/// Minimal parser for compiled TZif (v1/v2/v3) time zone files.
@visibleForTesting
class TzifZone {
  TzifZone._(this._transitions, this._typeIndices, this._offsetsSeconds);

  final List<int> _transitions;
  final Uint8List _typeIndices;
  final List<int> _offsetsSeconds;

  static TzifZone? parse(Uint8List bytes) {
    if (bytes.length < 44 ||
        bytes[0] != 0x54 ||
        bytes[1] != 0x5A ||
        bytes[2] != 0x69 ||
        bytes[3] != 0x66) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    final version = bytes[4];
    final ttisutcnt = data.getUint32(20);
    final ttisstdcnt = data.getUint32(24);
    final leapcnt = data.getUint32(28);
    final timecnt = data.getUint32(32);
    final typecnt = data.getUint32(36);
    final charcnt = data.getUint32(40);

    var blockOffset = 0;
    var timeBytes = 4;
    var leapBytes = 8;
    var countTime = timecnt;
    var countType = typecnt;

    if (version >= 0x32) {
      final v1Size =
          44 + timecnt * 4 + timecnt + typecnt * 6 + charcnt + leapcnt * 8 + ttisstdcnt + ttisutcnt;
      if (bytes.length < v1Size + 44) return null;
      if (bytes[v1Size] != 0x54 ||
          bytes[v1Size + 1] != 0x5A ||
          bytes[v1Size + 2] != 0x69 ||
          bytes[v1Size + 3] != 0x66) {
        return null;
      }
      blockOffset = v1Size;
      timeBytes = 8;
      leapBytes = 12;
      countTime = data.getUint32(blockOffset + 32);
      countType = data.getUint32(blockOffset + 36);
    }

    if (countType == 0) return null;
    final cursorStart = blockOffset + 44;
    final needed = cursorStart + countTime * timeBytes + countTime + countType * 6;
    if (bytes.length < needed) return null;

    var pos = cursorStart;
    final transitions = List<int>.filled(countTime, 0);
    for (var i = 0; i < countTime; i++) {
      transitions[i] = timeBytes == 8 ? data.getInt64(pos) : data.getInt32(pos);
      pos += timeBytes;
    }
    final typeIndices = Uint8List.fromList(bytes.sublist(pos, pos + countTime));
    if (typeIndices.any((t) => t >= countType)) return null;
    pos += countTime;

    final offsets = List<int>.filled(countType, 0);
    for (var i = 0; i < countType; i++) {
      offsets[i] = data.getInt32(pos);
      pos += 6;
    }
    // Unused leap seconds length retained in case footer parsing is added later.
    assert(leapBytes > 0);
    return TzifZone._(transitions, typeIndices, offsets);
  }

  Duration offsetAt(DateTime utc) {
    if (_transitions.isEmpty) return Duration(seconds: _offsetsSeconds[0]);
    final seconds = utc.toUtc().millisecondsSinceEpoch ~/ 1000;
    if (seconds < _transitions[0]) return Duration(seconds: _offsetsSeconds[0]);
    var lo = 0;
    var hi = _transitions.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_transitions[mid] <= seconds) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return Duration(seconds: _offsetsSeconds[_typeIndices[lo]]);
  }
}
