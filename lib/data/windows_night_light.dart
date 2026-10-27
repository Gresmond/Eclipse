import 'dart:ffi';
import 'dart:typed_data';

/// Whether Windows Night light is on. Windows has no API for it, so this
/// reads the record Windows keeps it in: an undocumented registry blob,
/// unchanged since Windows 10 1703. The blob is an outer "CB\1\0" record
/// holding an inner one, and the inner record starts with an extra `10 00`
/// field while Night light is on (including its fade in and out).
class WindowsNightLight {
  static const _key =
      r'Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current'
      r'\default$windows.data.bluelightreduction.bluelightreductionstate'
      r'\windows.data.bluelightreduction.bluelightreductionstate';

  /// Null when it can't be read: Night light never touched on this account
  /// (Windows writes the record on first use), or a format this doesn't know.
  static Future<bool?> isOn() async => parse(_read());

  static bool? parse(Uint8List? data) {
    if (data == null || !_headerAt(data, 0)) return null;
    for (var i = 4; i + 5 < data.length; i++) {
      if (_headerAt(data, i)) return data[i + 4] == 0x10 && data[i + 5] == 0x00;
    }
    return null;
  }

  static bool _headerAt(Uint8List data, int i) =>
      i + 3 < data.length && data[i] == 0x43 && data[i + 1] == 0x42 && data[i + 2] == 0x01 && data[i + 3] == 0x00;

  // HKEY_CURRENT_USER is (HKEY)(LONG)0x80000001, sign-extended to pointer width.
  static final _currentUser = 0x80000001.toSigned(32);
  static const _binaryOnly = 0x08; // RRF_RT_REG_BINARY
  static const _zeroInit = 0x40; // LMEM_ZEROINIT

  static final _advapi = DynamicLibrary.open('advapi32.dll');
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _regGetValue = _advapi
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Uint16>,
          Pointer<Uint16>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Uint8>,
          Pointer<Uint32>,
        ),
        int Function(int, Pointer<Uint16>, Pointer<Uint16>, int, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>)
      >('RegGetValueW');
  static final _localAlloc = _kernel
      .lookupFunction<Pointer<Uint8> Function(Uint32, IntPtr), Pointer<Uint8> Function(int, int)>('LocalAlloc');
  static final _localFree = _kernel
      .lookupFunction<Pointer<Uint8> Function(Pointer<Uint8>), Pointer<Uint8> Function(Pointer<Uint8>)>('LocalFree');

  static Uint8List? _read() {
    const capacity = 4096; // the blob is around 40 bytes
    Pointer<Uint16> wide(String s) {
      // Zeroed, so the terminator is already there.
      final p = _localAlloc(_zeroInit, (s.length + 1) * 2).cast<Uint16>();
      p.asTypedList(s.length).setAll(0, s.codeUnits);
      return p;
    }

    final key = wide(_key), value = wide('Data');
    final buffer = _localAlloc(_zeroInit, capacity);
    final size = _localAlloc(_zeroInit, 4).cast<Uint32>()..value = capacity;
    try {
      final status = _regGetValue(_currentUser, key, value, _binaryOnly, nullptr, buffer, size);
      return status == 0 ? Uint8List.fromList(buffer.asTypedList(size.value)) : null;
    } finally {
      for (final p in [key.cast<Uint8>(), value.cast<Uint8>(), buffer, size.cast<Uint8>()]) {
        _localFree(p);
      }
    }
  }
}
