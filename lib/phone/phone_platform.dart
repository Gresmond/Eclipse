import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../data/http_request.dart';
import '../data/updates.dart' show isNewer;

/// The Android side of things, over its channel.
class PhonePlatform {
  static const _channel = MethodChannel('eclipse/phone');

  static Future<void> toFront() => _channel.invokeMethod<void>('toFront');
  static Future<String?> version() => _channel.invokeMethod<String>('version');
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

/// Newer releases on GitHub: their Eclipse.apk, downloaded and handed to
/// Android's installer.
class PhoneUpdater extends ChangeNotifier {
  PhoneUpdater({this.installed});

  /// This copy's version; null until [check] has asked.
  String? installed;

  /// The newer version out, if any.
  String? available;
  bool updating = false;
  String? error;
  Uri? _download;
  DateTime? _checked;

  static final _latest = Uri.parse('https://api.github.com/repos/Gresmond/Eclipse/releases/latest');

  /// Asks GitHub, at most every few hours.
  Future<void> check() async {
    final now = DateTime.now();
    if (_checked != null && now.difference(_checked!) < const Duration(hours: 3)) return;
    _checked = now;
    try {
      installed ??= await PhonePlatform.version();
      final (status, body) = await sendHttpRequest('GET', _latest);
      if (status != 200) return;
      final release = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final version = (release['tag_name'] as String? ?? '').replaceFirst('v', '');
      final asset = (release['assets'] as List? ?? const []).cast<Map<String, dynamic>>().where(
        (a) => a['name'] == 'Eclipse.apk',
      );
      if (installed == null || asset.isEmpty || !isNewer(version, installed!)) return;
      _download = Uri.parse(asset.first['browser_download_url'] as String);
      available = version;
      notifyListeners();
    } on Object catch (e) {
      debugPrint('Could not check for an update: $e');
    }
  }

  Future<void> update() async {
    final download = _download;
    if (download == null || updating) return;
    updating = true;
    error = null;
    notifyListeners();
    try {
      final file = File('${(await getTemporaryDirectory()).path}/Eclipse.apk');
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(download)).close();
        if (response.statusCode != 200) throw HttpException('status ${response.statusCode}');
        await response.pipe(file.openWrite());
      } finally {
        client.close();
      }
      await PhonePlatform.install(file.path);
    } on Object catch (e) {
      debugPrint('Could not update: $e');
      error = 'Couldn’t download the update. Try again.';
    }
    updating = false;
    notifyListeners();
  }
}
