import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../data/updates.dart' show ReleaseFetch, ReleaseUpdater, fetchReleaseBytes, isNewer;

/// The Android side of things, over its channel.
class PhonePlatform {
  static const _channel = MethodChannel('eclipse/phone');

  static Future<void> toFront() => _channel.invokeMethod<void>('toFront');
  static Future<String?> version() => _channel.invokeMethod<String>('version');

  static Future<int?> build() async {
    final code = await _channel.invokeMethod<num>('versionCode');
    if (code == null) return null;
    final n = code.toInt();
    return n >= 100 ? n % 100 : n;
  }

  static Future<void> askNotifications() => _channel.invokeMethod<void>('askNotifications');

  /// Sets [state]'s reminders still to come as the phone's alarms, in place
  /// of those set before.
  static Future<void> schedule(AppState state) => _channel.invokeMethod<void>(
    'schedule',
    jsonEncode([
      for (final r in state.upcomingReminders())
        {'key': r.key, 'at': r.at.millisecondsSinceEpoch, 'title': r.title, 'body': r.body},
    ]),
  );

  /// Opens Android's installer on [apk]; false if it first had to ask to be
  /// allowed to, and so wants trying again.
  static Future<bool> install(String apk) async => await _channel.invokeMethod<bool>('install', apk) ?? false;
}

typedef PhoneDownload = Future<void> Function(Uri uri, File partFile);

/// Newer releases on GitHub: their Eclipse.apk, downloaded and handed to
/// Android's installer after verifying its link and checksum.
class PhoneUpdater extends ChangeNotifier {
  PhoneUpdater({
    String? installed,
    this.installedBuild,
    this.fetch = fetchReleaseBytes,
    PhoneDownload? downloadToFile,
    Future<bool> Function(String path)? install,
    Future<String?> Function()? readVersion,
    Future<int?> Function()? readBuild,
    Future<Directory> Function()? updatesDir,
    DateTime Function()? now,
  }) : _downloadToFile = downloadToFile ?? _defaultDownload,
       _install = install ?? PhonePlatform.install,
       _readVersion = readVersion ?? PhonePlatform.version,
       _readBuild = readBuild ?? PhonePlatform.build,
       _updatesDir = updatesDir ?? _defaultUpdatesDir,
       _now = now ?? DateTime.now {
    if (installed != null) _setInstalled(installed, installedBuild);
  }

  /// This copy's version; null until [check] has asked.
  String? installed;

  /// This copy's release build within [installed].
  int? installedBuild;

  final ReleaseFetch fetch;
  final PhoneDownload _downloadToFile;
  final Future<bool> Function(String path) _install;
  final Future<String?> Function() _readVersion;
  final Future<int?> Function() _readBuild;
  final Future<Directory> Function() _updatesDir;
  final DateTime Function() _now;

  /// The newer version out, if any.
  String? available;
  bool updating = false;
  String? error;
  Uri? _download;
  Uri? _sumsDownload;
  String? _sha256;
  DateTime? _checked;
  bool _checking = false;

  static final _latest = Uri.parse('https://api.github.com/repos/Gresmond/Eclipse/releases/latest');
  static final _versionFormat = RegExp(r'^\d+\.\d+\.\d+$');
  static final _digestFormat = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

  void _setInstalled(String raw, int? explicitBuild) {
    final plus = raw.indexOf('+');
    if (plus > 0) {
      installed = raw.substring(0, plus);
      installedBuild = explicitBuild ?? int.tryParse(raw.substring(plus + 1));
    } else {
      installed = raw;
      installedBuild = explicitBuild;
    }
  }

  static Future<Directory> _defaultUpdatesDir() async => Directory(p.join((await getTemporaryDirectory()).path, 'updates'));

  static bool isValidAssetUri(Uri? uri, String assetName) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.path.startsWith('/Gresmond/Eclipse/releases/download/') &&
      uri.path.endsWith('/$assetName');

  /// Asks GitHub, at most every few hours after a successful check.
  Future<void> check() async {
    if (_checking || updating) return;
    final now = _now();
    if (_checked != null && now.difference(_checked!) < const Duration(hours: 3)) return;
    _checking = true;
    try {
      if (installed == null) {
        final raw = await _readVersion();
        if (raw != null) _setInstalled(raw, installedBuild);
      }
      if (installedBuild == null) {
        try {
          installedBuild = await _readBuild();
        } on MissingPluginException {
          // Tests pass [installed] directly without mocking the platform channel.
        }
      }
      final (status, body) = await fetch(_latest);
      if (status != 200) return;
      final release = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      _checked = now;
      final tag = release['tag_name'] as String? ?? '';
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      final assets = (release['assets'] as List? ?? const []).cast<Map<String, dynamic>>();
      final asset = assets.where((a) => a['name'] == 'Eclipse.apk').firstOrNull;
      if (installed == null || asset == null || !_versionFormat.hasMatch(version)) return;
      final build = ReleaseUpdater.releaseBuild(release) ?? 1;
      if (build < 1) return;
      final currentBuild = installedBuild ?? 1;
      final newer = isNewer(version, installed!) || (version == installed && build > currentBuild);
      if (!newer) return;
      final apkUri = Uri.tryParse(asset['browser_download_url'] as String? ?? '');
      if (!isValidAssetUri(apkUri, 'Eclipse.apk')) return;
      final digestMatch = _digestFormat.firstMatch(asset['digest'] as String? ?? '');
      final sumsAsset = assets.where((a) => a['name'] == 'SHA256SUMS').firstOrNull;
      final sumsUri = sumsAsset == null ? null : Uri.tryParse(sumsAsset['browser_download_url'] as String? ?? '');
      _download = apkUri;
      _sha256 = digestMatch?.group(1)?.toLowerCase();
      _sumsDownload = isValidAssetUri(sumsUri, 'SHA256SUMS') ? sumsUri : null;
      available = version;
      notifyListeners();
    } on Object catch (e) {
      debugPrint('Could not check for an update: $e');
    } finally {
      _checking = false;
    }
  }

  Future<String> _resolveExpectedSha256() async {
    if (_sha256 case final digest?) return digest;
    final sumsUri = _sumsDownload;
    if (sumsUri != null && isValidAssetUri(sumsUri, 'SHA256SUMS')) {
      final (status, body) = await fetch(sumsUri);
      if (status != 200) throw HttpException('Checksum download failed (HTTP $status).');
      final match = RegExp(
        r'^([0-9a-fA-F]{64})\s+\*?Eclipse\.apk$',
        multiLine: true,
      ).firstMatch(utf8.decode(body));
      if (match != null) return _sha256 = match.group(1)!.toLowerCase();
    }
    throw const FormatException('The update has no SHA-256 checksum.');
  }

  static Future<bool> _matchesSha256(File file, String expected) async {
    if (!await file.exists()) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expected;
  }

  static Future<void> _defaultDownload(Uri uri, File partFile) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      await (() async {
        var current = uri;
        late HttpClientResponse response;
        for (var redirects = 0; ; redirects++) {
          final request = await client.getUrl(current);
          request.followRedirects = false;
          response = await request.close();
          if (response.isRedirect && redirects < 5) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            await response.drain<void>();
            if (location == null) throw const HttpException('Missing redirect location');
            final next = current.resolve(location);
            if (next.scheme != 'https') {
              throw const FormatException('Update redirect must use HTTPS.');
            }
            current = next;
            continue;
          }
          break;
        }
        if (response.statusCode != 200) throw HttpException('status ${response.statusCode}');
        final sink = partFile.openWrite();
        try {
          await response.pipe(sink);
        } catch (_) {
          await sink.close();
          rethrow;
        }
      })().timeout(const Duration(minutes: 5));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> update() async {
    final download = _download;
    if (download == null || updating) return;
    updating = true;
    error = null;
    notifyListeners();
    File? part;
    try {
      if (!isValidAssetUri(download, 'Eclipse.apk')) {
        throw const FormatException('The update link is invalid.');
      }
      final expected = await _resolveExpectedSha256();
      final dir = await _updatesDir();
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'Eclipse.apk'));
      if (!await _matchesSha256(file, expected)) {
        part = File('${file.path}.part');
        if (await part.exists()) await part.delete();
        await _downloadToFile(download, part);
        if (!await _matchesSha256(part, expected)) {
          throw const FormatException('The downloaded update checksum does not match.');
        }
        await part.rename(file.path);
        part = null;
      }
      if (!await _install(file.path)) {
        error = 'Allow Eclipse to install updates in Settings, then tap Update again.';
      }
    } on Object catch (e) {
      debugPrint('Could not update: $e');
      if (part != null && await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
      error = e is FormatException ? e.message : 'Couldn’t download the update. Try again.';
    }
    updating = false;
    notifyListeners();
  }
}
