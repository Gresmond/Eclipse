import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// As the computers' version, over the browser's fetch. It says a request
/// never arrived the same way too, so callers needn't tell them apart.
Future<(int, Uint8List)> sendHttpRequest(
  String method,
  Uri uri, {
  List<int>? body,
  String? type,
  String? bearer,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final abort = web.AbortController();
  final headers = web.Headers();
  if (bearer != null) headers.set('Authorization', 'Bearer $bearer');
  if (type != null) headers.set('Content-Type', type);
  final init = web.RequestInit(method: method, headers: headers, signal: abort.signal, cache: 'no-store');
  if (body != null) init.body = Uint8List.fromList(body).toJS;
  final timer = Timer(timeout, () => abort.abort());
  try {
    return await (() async {
      final web.Response response;
      try {
        response = await web.window.fetch(uri.toString().toJS, init).toDart;
      } on Object {
        if (!timer.isActive) rethrow;
        throw const SocketException('Couldn’t reach the server');
      }
      final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
      return (response.status, bytes);
    })().timeout(timeout);
  } finally {
    timer.cancel();
  }
}
