import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'google_client.dart';
import 'http_request.dart';
import 'platform_files.dart';

/// Only Eclipse's own hidden folder in Drive, never anything else there,
/// and the address, to show whose Drive it is.
const _scopes = 'openid email https://www.googleapis.com/auth/drive.appdata';

final _token = Uri.parse('https://oauth2.googleapis.com/token');

/// A Google account Eclipse may use, by its lasting sign-in.
class GoogleAccount {
  const GoogleAccount({required this.email, required this.refreshToken, this.id});

  final String email;
  final String refreshToken;
  final String? id;
  String get identity => id ?? email.toLowerCase();
}

/// Something went wrong talking to Google, in words to show.
class DriveError implements Exception {
  const DriveError(this.message, {this.signedOut = false});

  final String message;

  /// The sign-in no longer works (taken back, or expired): sign in again.
  final bool signedOut;

  @override
  String toString() => message;
}

/// Signs in through the browser: opens Google's page, and waits for it to
/// come back to a one-off address on this computer with a code, which is
/// swapped for the lasting sign-in. Stops waiting when [cancel] completes.
Future<GoogleAccount> signInWithGoogle({Future<void>? cancel}) async {
  if (googleClientId.startsWith('SET-ME') || googleClientSecret == 'SET-ME') {
    throw const DriveError('Google sync is not configured for this build. Local data and backups still work.');
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final redirect = 'http://127.0.0.1:${server.port}';
    final state = _random(16), verifier = _random(48);
    final page = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': googleClientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': _scopes,
      'state': state,
      'code_challenge': base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', ''),
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': 'consent',
    });
    await openExternal(page.toString());

    final reply = Completer<Map<String, String>>();
    server.listen((request) async {
      final query = request.uri.queryParameters;
      if (query['state'] != state) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final ok = query['code'] != null;
      request.response.headers.contentType = ContentType.html;
      request.response.write(_page(ok));
      await request.response.close();
      if (!reply.isCompleted) reply.complete(query);
    });
    unawaited(
      cancel?.then((_) {
        if (!reply.isCompleted) reply.completeError(const DriveError('Sign-in cancelled.'));
      }),
    );
    final query = await reply.future.timeout(
      const Duration(minutes: 10),
      onTimeout: () => throw const DriveError('Sign-in took too long. Try again.'),
    );
    final code = query['code'];
    if (code == null) {
      throw DriveError(query['error'] == 'access_denied' ? 'Sign-in was cancelled in the browser.' : 'Google said no.');
    }

    final tokens = await _post(_token, {
      'code': code,
      'client_id': googleClientId,
      'client_secret': googleClientSecret,
      'redirect_uri': redirect,
      'grant_type': 'authorization_code',
      'code_verifier': verifier,
    });
    final refresh = tokens['refresh_token'] as String?;
    if (refresh == null) throw const DriveError('Google didn\'t give a lasting sign-in. Try again.');
    final claims = _claims(tokens['id_token'] as String?);
    final email = claims['email'] as String?;
    if (email == null) throw const DriveError('Google did not identify the account. Try signing in again.');
    return GoogleAccount(email: email, id: claims['sub'] as String?, refreshToken: refresh);
  } finally {
    await server.close(force: true);
  }
}

/// The address inside the sign-in's id token, which came straight from
/// Google, so it needn't be checked.
Map<String, dynamic> _claims(String? idToken) {
  final parts = idToken?.split('.');
  if (parts == null || parts.length < 2) return {};
  try {
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
    return claims;
  } on FormatException {
    return {};
  }
}

String _random(int bytes) {
  final random = Random.secure();
  return base64Url.encode(List.generate(bytes, (_) => random.nextInt(256))).replaceAll('=', '');
}

String _page(bool ok) =>
    '''
<!doctype html><meta charset="utf-8"><title>Eclipse</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; display: grid; place-items: center; height: 90vh; margin: 0;
         background: #f6f4f0; color: #222; }
  @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #eee; } }
  h1 { font-size: 22px; font-weight: 600; margin: 0 0 6px; }
</style>
<div><h1>${ok ? 'Signed in' : 'Not signed in'}</h1>
${ok ? 'You can close this tab and go back to Eclipse.' : 'Go back to Eclipse to try again.'}</div>
''';

/// Posts a form to Google and returns its answer, or throws in words.
Future<Map<String, dynamic>> _post(Uri uri, Map<String, String> form) async {
  final (status, body) = await _send(
    'POST',
    uri,
    body: utf8.encode(Uri(queryParameters: form).query),
    type: 'application/x-www-form-urlencoded',
  );
  final json = _decode(body);
  if (status == 200) return json;
  if (json['error'] == 'invalid_grant') {
    throw const DriveError('Google signed Eclipse out. Sign in again.', signedOut: true);
  }
  throw DriveError('Google said: ${json['error_description'] ?? json['error'] ?? 'error $status'}');
}

Map<String, dynamic> _decode(List<int> body) {
  try {
    return jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
  } on FormatException {
    return {};
  }
}

Future<(int, Uint8List)> _send(String method, Uri uri, {List<int>? body, String? type, String? bearer}) async {
  try {
    return await sendHttpRequest(method, uri, body: body, type: type, bearer: bearer);
  } on SocketException {
    throw const DriveError('Can\'t reach Google. Are you online?');
  } on HandshakeException {
    throw const DriveError('Can\'t reach Google. Are you online?');
  } on TimeoutException {
    throw const DriveError('Google took too long to answer.');
  }
}

/// A file in the folder.
class DriveFile {
  const DriveFile({required this.id, required this.name, required this.modified});

  final String id;
  final String name;

  /// Changes whenever the file does: to tell whether it's new.
  final String modified;
}

/// The folder each computer's change files go in. In Drive it's the hidden
/// folder only Eclipse can see; tests use one in memory.
abstract class SyncDrive {
  Future<List<DriveFile>> list();
  Future<List<int>> download(String id);

  /// Writes [name], over the file [id] when it's already there.
  Future<void> upload(String name, List<int> bytes, {String? id});
}

/// Eclipse's hidden app folder in the Drive of the account signed in.
class AppDataFolder implements SyncDrive {
  AppDataFolder(this.refreshToken);

  final String refreshToken;
  String? _access;
  DateTime _expires = DateTime(0);

  Future<String> _bearer() async {
    if (_access != null && DateTime.now().isBefore(_expires)) return _access!;
    final tokens = await _post(_token, {
      'client_id': googleClientId,
      'client_secret': googleClientSecret,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    });
    _expires = DateTime.now().add(Duration(seconds: (tokens['expires_in'] as num? ?? 3600).toInt() - 120));
    return _access = tokens['access_token'] as String;
  }

  /// Sends with the sign-in, once more with a fresh one if it had run out.
  Future<Uint8List> _call(String method, Uri uri, {List<int>? body, String? type}) async {
    for (var attempt = 0; ; attempt++) {
      final (status, bytes) = await _send(method, uri, body: body, type: type, bearer: await _bearer());
      if (status == 401 && attempt == 0) {
        _access = null;
        continue;
      }
      if (status >= 200 && status < 300) return bytes;
      final error = _decode(bytes)['error'];
      final message = error is Map ? error['message'] : null;
      throw DriveError('Google Drive said: ${message ?? 'error $status'}');
    }
  }

  @override
  Future<List<DriveFile>> list() async {
    final files = <DriveFile>[];
    String? page;
    do {
      final json = _decode(
        await _call(
          'GET',
          Uri.https('www.googleapis.com', '/drive/v3/files', {
            'spaces': 'appDataFolder',
            'fields': 'nextPageToken,files(id,name,modifiedTime)',
            'pageSize': '1000',
            'pageToken': ?page,
          }),
        ),
      );
      for (final f in (json['files'] as List? ?? []).cast<Map<String, dynamic>>()) {
        files.add(DriveFile(id: f['id'] as String, name: f['name'] as String, modified: f['modifiedTime'] as String));
      }
      page = json['nextPageToken'] as String?;
    } while (page != null);
    return files;
  }

  @override
  Future<List<int>> download(String id) =>
      _call('GET', Uri.https('www.googleapis.com', '/drive/v3/files/$id', {'alt': 'media'}));

  @override
  Future<void> upload(String name, List<int> bytes, {String? id}) async {
    if (id != null) {
      await _call(
        'PATCH',
        Uri.https('www.googleapis.com', '/upload/drive/v3/files/$id', {'uploadType': 'media'}),
        body: bytes,
        type: 'application/json',
      );
      return;
    }
    const boundary = 'eclipse-sync-boundary';
    final body = BytesBuilder()
      ..add(
        utf8.encode(
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode({
            'name': name,
            'parents': ['appDataFolder'],
          })}\r\n'
          '--$boundary\r\nContent-Type: application/json\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--'));
    await _call(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {'uploadType': 'multipart'}),
      body: body.takeBytes(),
      type: 'multipart/related; boundary=$boundary',
    );
  }
}
