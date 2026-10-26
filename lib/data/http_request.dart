import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// One deadline covers connection, headers, and the complete response body.
/// Closing the client also cancels a stalled body after the deadline expires.
Future<(int, Uint8List)> sendHttpRequest(
  String method,
  Uri uri, {
  List<int>? body,
  String? type,
  String? bearer,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    return await (() async {
      final request = await client.openUrl(method, uri);
      if (bearer != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      if (type != null) request.headers.set(HttpHeaders.contentTypeHeader, type);
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close();
      final bytes = BytesBuilder(copy: false);
      await response.forEach(bytes.add);
      return (response.statusCode, bytes.takeBytes());
    })().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
