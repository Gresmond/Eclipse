import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'vault_native.dart' if (dart.library.js_interop) 'vault_web.dart';

class DriveVault {
  static const marker = 'eclipse-encryption-v1';
  static final _magic = utf8.encode('ECLIPSE-AES-GCM-1\n');
  static Uint8List random(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }

  static Future<Uint8List> derive(String passphrase, Uint8List salt) =>
      vaultOperation('derive', {'password': utf8.encode(passphrase), 'salt': salt});
  static bool sealed(List<int> bytes) {
    if (bytes.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  static Future<Uint8List> seal(Uint8List key, String name, List<int> data) async {
    final iv = random(12);
    final encrypted = await vaultOperation('encrypt', {
      'key': key,
      'iv': iv,
      'name': utf8.encode(name),
      'data': Uint8List.fromList(data),
    });
    return (BytesBuilder()
          ..add(_magic)
          ..add(iv)
          ..add(encrypted))
        .takeBytes();
  }

  static Future<Uint8List> open(Uint8List key, String name, List<int> bytes) async {
    if (!sealed(bytes) || bytes.length < _magic.length + 28) throw const FormatException('Invalid encrypted file');
    final start = _magic.length;
    return vaultOperation('decrypt', {
      'key': key,
      'iv': Uint8List.fromList(bytes.sublist(start, start + 12)),
      'name': utf8.encode(name),
      'data': Uint8List.fromList(bytes.sublist(start + 12)),
    });
  }
}
