import 'package:flutter/services.dart';

Future<Uint8List> vaultOperation(String method, Map<String, Uint8List> arguments) async =>
    (await const MethodChannel('eclipse/vault').invokeMethod<Uint8List>(method, arguments))!;
