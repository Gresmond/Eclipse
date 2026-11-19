import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<Uint8List> vaultOperation(String method, Map<String, Uint8List> args) async {
  final crypto = web.window.crypto.subtle;
  if (method == 'derive') {
    final password = await crypto
        .importKey('raw', args['password']!.toJS, 'PBKDF2'.toJS, false, ['deriveBits'.toJS].toJS)
        .toDart;
    final params = {'name': 'PBKDF2', 'hash': 'SHA-256', 'salt': args['salt']!.toJS, 'iterations': 600000}.jsify()!;
    return (await crypto.deriveBits(params, password, 256).toDart).toDart.asUint8List();
  }
  final key = await crypto.importKey('raw', args['key']!.toJS, 'AES-GCM'.toJS, false, [method.toJS].toJS).toDart;
  final params = {
    'name': 'AES-GCM',
    'iv': args['iv']!.toJS,
    'additionalData': args['name']!.toJS,
    'tagLength': 128,
  }.jsify()!;
  final data = args['data']!.toJS;
  final output =
      await (method == 'encrypt' ? crypto.encrypt(params, key, data) : crypto.decrypt(params, key, data)).toDart;
  return (output as JSArrayBuffer).toDart.asUint8List();
}
