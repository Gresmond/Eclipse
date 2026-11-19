import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

HttpClient? _pooledClient;
HttpOverrides? _pooledOverrides;

/// Number of `HttpClient` instances created by the pool; for tests.
@visibleForTesting
int debugHttpClientsCreated = 0;

HttpClient _client() {
  final current = HttpOverrides.current;
  if (_pooledClient == null || !identical(_pooledOverrides, current)) {
    _pooledClient?.close(force: true);
    _pooledOverrides = current;
    _pooledClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    debugHttpClientsCreated++;
  }
  return _pooledClient!;
}

/// Sends an HTTP request using a pooled client. One deadline covers
/// connection, headers, and the complete response body without tearing down
/// other pooled connections on timeout.
Future<(int, Uint8List)> sendHttpRequest(
  String method,
  Uri uri, {
  List<int>? body,
  String? type,
  String? bearer,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final client = _client();
  HttpClientRequest? request;
  StreamSubscription<List<int>>? subscription;
  Completer<void>? bodyDone;
  var timedOut = false;
  final completer = Completer<(int, Uint8List)>();
  final timer = Timer(timeout, () {
    timedOut = true;
    request?.abort();
    unawaited(subscription?.cancel() ?? Future<void>.value());
    if (bodyDone != null && !bodyDone!.isCompleted) bodyDone!.complete();
    if (!completer.isCompleted) {
      completer.completeError(TimeoutException('Request timed out', timeout));
    }
  });
  unawaited(() async {
    try {
      final req = request = await client.openUrl(method, uri);
      if (timedOut) {
        req.abort();
        return;
      }
      if (bearer != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      if (type != null) req.headers.set(HttpHeaders.contentTypeHeader, type);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final response = await req.close();
      if (timedOut) return;
      final bytes = BytesBuilder(copy: false);
      final done = bodyDone = Completer<void>();
      subscription = response.listen(
        bytes.add,
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
        cancelOnError: true,
      );
      await done.future;
      if (!completer.isCompleted) {
        completer.complete((response.statusCode, bytes.takeBytes()));
      }
    } catch (error, stack) {
      if (!completer.isCompleted) {
        completer.completeError(
          timedOut ? TimeoutException('Request timed out', timeout) : error,
          stack,
        );
      }
    }
  }());
  try {
    return await completer.future;
  } finally {
    timer.cancel();
  }
}

/// Streams [uri] directly to [destination] without buffering the full body in
/// memory, following up to [maxRedirects] redirects.
Future<int> downloadFile(
  Uri uri,
  File destination, {
  Duration timeout = const Duration(minutes: 5),
  int maxRedirects = 5,
  bool httpsOnlyRedirects = true,
}) async {
  final client = _client();
  HttpClientRequest? activeRequest;
  StreamSubscription<List<int>>? subscription;
  Completer<void>? activeBody;
  IOSink? sink;
  var timedOut = false;
  final completer = Completer<int>();
  final timer = Timer(timeout, () {
    timedOut = true;
    activeRequest?.abort();
    unawaited(subscription?.cancel() ?? Future<void>.value());
    if (activeBody != null && !activeBody!.isCompleted) activeBody!.complete();
    if (!completer.isCompleted) {
      completer.completeError(TimeoutException('Download timed out', timeout));
    }
  });
  unawaited(() async {
    try {
      var current = uri;
      late HttpClientResponse response;
      for (var redirects = 0; ; redirects++) {
        final req = activeRequest = await client.getUrl(current);
        if (timedOut) {
          req.abort();
          return;
        }
        req.followRedirects = false;
        response = await req.close();
        if (timedOut) return;
        if (response.isRedirect && redirects < maxRedirects) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null) throw const HttpException('Missing redirect location');
          final next = current.resolve(location);
          if (httpsOnlyRedirects && next.scheme != 'https') {
            throw const FormatException('Update redirect must use HTTPS.');
          }
          current = next;
          continue;
        }
        break;
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        if (!completer.isCompleted) completer.complete(response.statusCode);
        return;
      }
      final fileSink = sink = destination.openWrite();
      final done = activeBody = Completer<void>();
      subscription = response.listen(
        fileSink.add,
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
        cancelOnError: true,
      );
      await done.future;
      if (timedOut) {
        await fileSink.close();
        sink = null;
        return;
      }
      await fileSink.flush();
      await fileSink.close();
      sink = null;
      if (!completer.isCompleted) completer.complete(response.statusCode);
    } catch (error, stack) {
      if (sink != null) {
        try {
          await sink!.close();
        } catch (_) {}
      }
      if (!completer.isCompleted) {
        completer.completeError(
          timedOut ? TimeoutException('Download timed out', timeout) : error,
          stack,
        );
      }
    }
  }());
  try {
    return await completer.future;
  } finally {
    timer.cancel();
  }
}
