import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

Future<String?> saveExport(String name, Uint8List bytes) async {
  if (Platform.isAndroid) {
    final dir = await getTemporaryDirectory(), file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    try {
      final saved = await const MethodChannel('eclipse/phone')
          .invokeMethod<bool>('saveExport', {'name': name, 'path': file.path});
      return saved == true ? name : null;
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
  final dir = await getDownloadsDirectory();
  if (dir == null) throw StateError('Downloads folder unavailable');
  await dir.create(recursive: true);
  final file = File('${dir.path}/$name');
  await file.create(exclusive: true);
  try {
    await file.writeAsBytes(bytes, flush: true);
  } catch (_) {
    await file.delete();
    rethrow;
  }
  return file.path;
}
