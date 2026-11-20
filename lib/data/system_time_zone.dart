import 'dart:convert';
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

  /// Actual current UTC offset in seconds/minutes, falling back to `DateTime.now().timeZoneOffset`.
  static Duration currentOffset() => instance?.offset() ?? DateTime.now().timeZoneOffset;

  final String _path;
  String? _target;
  DateTime? _modified;
  int? _size;
  TzifZone? _zone;

  /// Active offset for the current instant.
  Duration offset({DateTime Function()? utcNow}) {
    final utc = (utcNow ?? DateTime.now)().toUtc();
    return _zone?.offsetAt(utc) ?? utc.toLocal().timeZoneOffset;
  }

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

/// Minimal parser for compiled TZif (v1/v2/v3) time zone files, including the
/// POSIX TZ footer for dates after explicit transitions or slim files.
@visibleForTesting
class TzifZone {
  TzifZone._(this._transitions, this._typeIndices, this._offsetsSeconds, [this._posix]);

  final List<int> _transitions;
  final Uint8List _typeIndices;
  final List<int> _offsetsSeconds;
  final _PosixTz? _posix;

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
    var countChar = charcnt;
    var countLeap = leapcnt;
    var countStd = ttisstdcnt;
    var countUt = ttisutcnt;

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
      countUt = data.getUint32(blockOffset + 20);
      countStd = data.getUint32(blockOffset + 24);
      countLeap = data.getUint32(blockOffset + 28);
      countTime = data.getUint32(blockOffset + 32);
      countType = data.getUint32(blockOffset + 36);
      countChar = data.getUint32(blockOffset + 40);
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

    _PosixTz? posix;
    final footerStart = pos + countChar + countLeap * leapBytes + countStd + countUt;
    if (version >= 0x32 && footerStart < bytes.length && bytes[footerStart] == 0x0A) {
      final nl = bytes.indexOf(0x0A, footerStart + 1);
      final end = nl > footerStart ? nl : bytes.length;
      if (end > footerStart + 1) {
        posix = _PosixTz.parse(utf8.decode(bytes.sublist(footerStart + 1, end), allowMalformed: true).trim());
      }
    }
    return TzifZone._(transitions, typeIndices, offsets, posix);
  }

  Duration offsetAt(DateTime utc) {
    final u = utc.toUtc();
    if (_transitions.isEmpty) {
      return _posix?.offsetAt(u) ?? Duration(seconds: _offsetsSeconds[0]);
    }
    final seconds = u.millisecondsSinceEpoch ~/ 1000;
    if (seconds < _transitions[0]) return Duration(seconds: _offsetsSeconds[0]);
    if (seconds >= _transitions.last && _posix != null) {
      return _posix.offsetAt(u);
    }
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

class _PosixTz {
  _PosixTz(this.stdOffsetSeconds, this.dstOffsetSeconds, this.start, this.end);

  final int stdOffsetSeconds;
  final int? dstOffsetSeconds;
  final _PosixRule? start, end;

  static final _pattern = RegExp(
    r'^(?:<[^>]+>|[A-Za-z]+)([+-]?\d+(?::\d{2}(?::\d{2})?)?)'
    r'(?:(?:<[^>]+>|[A-Za-z]+)([+-]?\d+(?::\d{2}(?::\d{2})?)?)?,([^,]+),([^,]+))?$',
  );

  static _PosixTz? parse(String text) {
    final m = _pattern.firstMatch(text);
    if (m == null) return null;
    // POSIX TZ offsets are west-positive (AEST-10 => +10h east of UTC).
    int? parseSignOffset(String raw) {
      final neg = raw.startsWith('-');
      final pos = raw.startsWith('+');
      final parts = (neg || pos ? raw.substring(1) : raw).split(':');
      final h = int.tryParse(parts[0]);
      final min = parts.length > 1 ? int.tryParse(parts[1]) : 0;
      final sec = parts.length > 2 ? int.tryParse(parts[2]) : 0;
      if (h == null || min == null || sec == null) return null;
      final magnitude = h * 3600 + min * 60 + sec;
      return neg ? magnitude : -magnitude;
    }

    final std = parseSignOffset(m[1]!);
    if (std == null) return null;
    if (m[3] == null || m[4] == null) return _PosixTz(std, null, null, null);
    final dst = m[2] == null ? std + 3600 : parseSignOffset(m[2]!);
    final start = _PosixRule.parse(m[3]!);
    final end = _PosixRule.parse(m[4]!);
    if (dst == null || start == null || end == null) return null;
    return _PosixTz(std, dst, start, end);
  }

  Duration offsetAt(DateTime utc) {
    if (dstOffsetSeconds == null || start == null || end == null) {
      return Duration(seconds: stdOffsetSeconds);
    }
    final year = utc.year;
    final startUtc = start!.atYear(year, stdOffsetSeconds);
    final endUtc = end!.atYear(year, dstOffsetSeconds!);
    final inDst = startUtc.isBefore(endUtc)
        ? !utc.isBefore(startUtc) && utc.isBefore(endUtc)
        : !utc.isBefore(startUtc) || utc.isBefore(endUtc);
    return Duration(seconds: inDst ? dstOffsetSeconds! : stdOffsetSeconds);
  }
}

class _PosixRule {
  _PosixRule(this.month, this.week, this.weekday, this.secondsOfDay);

  final int month, week, weekday, secondsOfDay;

  static _PosixRule? parse(String raw) {
    final slash = raw.split('/');
    final datePart = slash[0];
    if (!datePart.startsWith('M')) return null;
    final parts = datePart.substring(1).split('.');
    if (parts.length != 3) return null;
    final month = int.tryParse(parts[0]);
    final week = int.tryParse(parts[1]);
    final posixWeekday = int.tryParse(parts[2]); // 0 = Sunday .. 6 = Saturday
    if (month == null || week == null || posixWeekday == null) return null;
    if (month < 1 || month > 12 || week < 1 || week > 5 || posixWeekday < 0 || posixWeekday > 6) return null;
    var seconds = 2 * 3600;
    if (slash.length > 1) {
      final t = slash[1].split(':');
      final h = int.tryParse(t[0]);
      final m = t.length > 1 ? int.tryParse(t[1]) : 0;
      final s = t.length > 2 ? int.tryParse(t[2]) : 0;
      if (h == null || m == null || s == null) return null;
      seconds = h * 3600 + m * 60 + s;
    }
    return _PosixRule(month, week, posixWeekday == 0 ? 7 : posixWeekday, seconds);
  }

  DateTime atYear(int year, int offsetSeconds) {
    final first = DateTime.utc(year, month, 1);
    final delta = (weekday - first.weekday) % 7;
    var day = 1 + delta + (week - 1) * 7;
    final daysInMonth = DateTime.utc(year, month + 1, 0).day;
    while (day > daysInMonth) {
      day -= 7;
    }
    return DateTime.utc(year, month, day).add(Duration(seconds: secondsOfDay - offsetSeconds));
  }
}
