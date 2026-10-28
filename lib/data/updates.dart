import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'restart.dart';
import 'http_request.dart';
import 'platform_files.dart';

enum UpdateStatus {
  /// Up to date, nothing to check against, or dismissed.
  none,
  available,
  updating,
  failed,
  restarting,
}

/// Tells when a newer version of Eclipse is out, for the update card.
abstract class Updater extends ChangeNotifier {
  /// Per-user Linux releases install verified archives; source installs retain
  /// the local Git updater. Mac and Windows use release downloads.
  static Updater? forThisApp({Future<void> Function()? onRestart}) {
    final executable = Platform.resolvedExecutable;
    if (Platform.isMacOS) return ReleaseUpdater.forBundle(executable);
    if (Platform.isWindows) return ReleaseUpdater.forWindows(executable);
    if (Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null && p.isWithin(home, executable)) {
        return LinuxUpdater.forExecutable(executable, onRestart: onRestart) ??
            GitUpdater.forExecutable(executable, onRestart: onRestart);
      }
    }
    return null;
  }

  UpdateStatus status = UpdateStatus.none;

  /// The version on offer, like 1.10.2; null when that can't be told.
  String? newVersion;

  /// What the card's button says.
  String get actionLabel;

  String get progressDetail => 'Building the new version. This takes about a minute.';

  /// The last line the install script printed, when it fails.
  String? error;

  /// How often [check] is worth calling.
  Duration get checkEvery;

  Future<void> check();

  Future<void> update();

  /// Hides the card until there is something newer still.
  void dismiss();

  @protected
  void set(UpdateStatus s) {
    status = s;
    notifyListeners();
  }
}

/// The `version:` in a pubspec.yaml, without its build number.
String? pubspecVersion(String pubspec) {
  final match = RegExp(r'^version:\s*([^+\s]+)', multiLine: true).firstMatch(pubspec);
  return match?.group(1);
}

/// Whether version [a] (like 1.10.2) is later than [b].
bool isNewer(String a, String b) {
  List<int> parts(String v) => v.split('.').map((n) => int.tryParse(n) ?? 0).toList();
  final (x, y) = (parts(a), parts(b));
  for (var i = 0; i < x.length || i < y.length; i++) {
    final (m, n) = (i < x.length ? x[i] : 0, i < y.length ? y[i] : 0);
    if (m != n) return m > n;
  }
  return false;
}

/// Notices when the folder Eclipse was built from has newer commits than
/// the running copy, and rebuilds and reopens it on request.
///
/// linux/install.sh leaves a `build-info` file beside the app saying which
/// folder and commit it was built from. Without one (`flutter run`) this
/// never reports anything.
class GitUpdater extends Updater {
  GitUpdater({required this.repo, required this.installedCommit, required this.executable, this.onRestart});

  /// Reads the `build-info` beside [executable]; null when there is none.
  static GitUpdater? forExecutable(String executable, {Future<void> Function()? onRestart}) {
    final file = File(p.join(p.dirname(executable), 'build-info'));
    if (!file.existsSync()) return null;
    final info = {
      for (final line in file.readAsLinesSync())
        if (line.indexOf('=') case final i when i > 0) line.substring(0, i): line.substring(i + 1),
    };
    final (repo, commit) = (info['repo'], info['commit']);
    if (repo == null || repo.isEmpty || commit == null || commit.isEmpty) return null;
    return GitUpdater(repo: repo, installedCommit: commit, executable: executable, onRestart: onRestart);
  }

  final String repo;
  final String installedCommit;

  /// The running app, started again once the new copy is installed.
  final String executable;

  /// Runs before the app quits to reopen (closing the database).
  final Future<void> Function()? onRestart;

  @override
  String get actionLabel => 'Update';

  @override
  Duration get checkEvery => const Duration(minutes: 2);

  /// How many commits the new version adds; null when that can't be told
  /// (the installed commit was rewritten away).
  int? newCommits;

  String? _newest;
  String? _dismissed;

  Future<String?> _git(List<String> args) async {
    try {
      final r = await Process.run('git', ['-C', repo, ...args]);
      return r.exitCode == 0 ? (r.stdout as String).trim() : null;
    } on ProcessException {
      return null;
    }
  }

  /// Looks for newer commits. Cheap: a few local git reads, no network.
  @override
  Future<void> check() async {
    if (status == UpdateStatus.updating || status == UpdateStatus.restarting) return;
    final head = await _git(['rev-parse', 'HEAD']);
    if (head == null || head == installedCommit) return;
    if (head != _newest) {
      _newest = head;
      final count = await _git(['rev-list', '--count', '$installedCommit..$head']);
      newCommits = count == null ? null : int.tryParse(count);
      final pubspec = await _git(['show', '$head:pubspec.yaml']);
      newVersion = pubspec == null ? null : pubspecVersion(pubspec);
    } else if (status == UpdateStatus.failed) {
      return; // keeps the error showing until there's something new to try
    }
    if (newCommits == 0) return; // HEAD moved back to something older
    if (head == _dismissed) return;
    set(UpdateStatus.available);
  }

  @override
  void dismiss() {
    _dismissed = _newest;
    set(UpdateStatus.none);
  }

  /// Runs the install script, then reopens the app from the new copy.
  @override
  Future<void> update() async {
    if (status == UpdateStatus.updating || status == UpdateStatus.restarting) return;
    error = null;
    set(UpdateStatus.updating);

    final output = <String>[];
    int code;
    try {
      final process = await Process.start('bash', [p.join(repo, 'linux', 'install.sh')], workingDirectory: repo);
      Future<void> collect(Stream<List<int>> stream) => stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((l) => l.trim().isNotEmpty)
          .forEach(output.add);
      await Future.wait([collect(process.stdout), collect(process.stderr)]);
      code = await process.exitCode;
    } on ProcessException catch (e) {
      output.add(e.message);
      code = -1;
    }

    if (code != 0) {
      error = output.lastWhere(
        (l) => l.toLowerCase().contains('error'),
        orElse: () => output.isEmpty ? 'The install script stopped (exit code $code).' : output.last,
      );
      set(UpdateStatus.failed);
      return;
    }

    set(UpdateStatus.restarting);
    await restartApplication(beforeRestart: onRestart ?? () async {}, executable: executable);
  }
}

/// Asks GitHub for the latest release and links to its platform download.
class ReleaseUpdater extends Updater {
  ReleaseUpdater(
    this.installedVersion, {
    this.installedRelease = 0,
    this.assetExtension = '.dmg',
    this.fetch = fetchReleaseBytes,
  });

  static ReleaseUpdater? forWindows(String executable) {
    final version = readInstalledVersion(executable);
    return version == null
        ? null
        : ReleaseUpdater(version, installedRelease: readInstalledRelease(executable), assetExtension: '.exe');
  }

  static int readInstalledRelease(String executable) {
    try {
      return int.tryParse(File(p.join(p.dirname(executable), 'package-release')).readAsStringSync().trim()) ?? 0;
    } on FileSystemException {
      return 0;
    }
  }

  static String? readInstalledVersion(String executable) {
    try {
      final version = File(p.join(p.dirname(executable), 'version')).readAsStringSync().trim();
      return RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ? version : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Reads the app's version from the Info.plist of the bundle around
  /// [executable] (Eclipse.app/Contents/MacOS/Eclipse); null without one.
  static ReleaseUpdater? forBundle(String executable) {
    try {
      final plist = File(p.join(p.dirname(p.dirname(executable)), 'Info.plist'));
      if (!plist.existsSync()) return null;
      String xml;
      if (Platform.isMacOS) {
        // plutil understands XML and binary property lists alike.
        final result = Process.runSync('/usr/bin/plutil', ['-convert', 'xml1', '-o', '-', plist.path]);
        if (result.exitCode != 0) return null;
        xml = result.stdout as String;
      } else {
        xml = plist.readAsStringSync();
      }
      final match = RegExp(r'<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>').firstMatch(xml);
      final build = RegExp(r'<key>CFBundleVersion</key>\s*<(?:string|integer)>([^<]+)</(?:string|integer)>')
          .firstMatch(xml);
      return match == null
          ? null
          : ReleaseUpdater(match.group(1)!, installedRelease: int.tryParse(build?.group(1) ?? '') ?? 0);
    } on FileSystemException {
      return null;
    } on ProcessException {
      return null;
    }
  }

  static final _latest = Uri.parse('https://api.github.com/repos/Gresmond/Eclipse/releases/latest');

  final String installedVersion;
  final int installedRelease;
  final String assetExtension;
  final ReleaseFetch fetch;

  Map<String, dynamic>? _asset;

  bool newerRelease(String version, Map<String, dynamic>? asset) =>
      isNewer(version, installedVersion) ||
      (version == installedVersion && (asset?['package_release'] as int? ?? 0) > installedRelease);

  static int? releaseBuild(Map<String, dynamic> release) => int.tryParse(
    RegExp(r'<!-- eclipse-(?:linux-)?build: (\d+) -->').firstMatch(release['body'] as String? ?? '')?.group(1) ?? '',
  );

  /// The platform download (or failing that the release page) to open.
  String? _download;

  String? _dismissed;

  String _identity(String? version, Map<String, dynamic>? asset) =>
      '$version/${asset?['name']}/${asset?['package_release'] ?? ''}';

  @override
  String get actionLabel => 'Download';

  @override
  Duration get checkEvery => const Duration(hours: 3);

  @override
  Future<void> check() async {
    if (status == UpdateStatus.updating || status == UpdateStatus.restarting) return;
    try {
      final (responseCode, bytes) = await fetch(_latest);
      if (status == UpdateStatus.updating || status == UpdateStatus.restarting) return;
      if (responseCode != 200) return;
      final release = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final tag = release['tag_name'] as String? ?? '';
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      final asset = assetForRelease(release);
      if (!newerRelease(version, asset)) return;
      final identity = _identity(version, asset);
      if (identity == _dismissed) return;
      if (status == UpdateStatus.failed && identity == _identity(newVersion, _asset)) return;
      _asset = asset;
      _download = downloadForRelease(release);
      newVersion = version;
      set(UpdateStatus.available);
    } catch (_) {
      // Offline, or GitHub didn't answer: try again next time.
    }
  }

  Map<String, dynamic>? assetForRelease(Map<String, dynamic> release) {
    final assets = (release['assets'] as List? ?? []).cast<Map<String, dynamic>>();
    final asset = assets.where((a) => (a['name'] as String? ?? '').endsWith(assetExtension)).firstOrNull;
    return asset == null ? null : {...asset, 'package_release': releaseBuild(release)};
  }

  /// Selects this platform's asset even when another platform is listed first.
  String? downloadForRelease(Map<String, dynamic> release) =>
      (assetForRelease(release)?['browser_download_url'] ?? release['html_url']) as String?;

  @override
  Future<void> update() async {
    try {
      if (_download case final url?) await openExternal(url);
      dismiss();
    } on ProcessException catch (e) {
      error = e.message;
      set(UpdateStatus.failed);
    }
  }

  @override
  void dismiss() {
    _dismissed = _identity(newVersion, _asset);
    set(UpdateStatus.none);
  }
}

typedef ReleaseFetch = Future<(int, List<int>)> Function(Uri uri);
typedef UpdateProcess = Future<ProcessResult> Function(String executable, List<String> arguments);

Future<(int, List<int>)> fetchReleaseBytes(Uri uri) => sendHttpRequest('GET', uri, timeout: const Duration(minutes: 5));

/// Installs verified prebuilt releases in a user-owned, versioned directory.
/// The installer atomically switches the launcher and keeps the running copy.
class LinuxUpdater extends ReleaseUpdater {
  LinuxUpdater(
    super.installedVersion, {
    required this.installRoot,
    super.installedRelease = 0,
    this.onRestart,
    this.runProcess = Process.run,
    this.restart = restartApplication,
    super.fetch,
  }) : super(assetExtension: '.tar.zst');

  static LinuxUpdater? forExecutable(String executable, {Future<void> Function()? onRestart}) {
    try {
      final directory = p.dirname(executable);
      final root = File(p.join(directory, 'user-install-root')).readAsStringSync().trim();
      final home = Platform.environment['HOME'];
      if (home == null || root != p.join(home, '.local', 'opt', 'eclipse-release')) return null;
      if (!p.isWithin(p.join(root, 'releases'), executable)) return null;
      final version = ReleaseUpdater.readInstalledVersion(executable);
      final build = int.tryParse(File(p.join(directory, 'package-release')).readAsStringSync().trim());
      if (version == null || build == null || build < 1) return null;
      return LinuxUpdater(version, installRoot: root, installedRelease: build, onRestart: onRestart);
    } on FileSystemException {
      return null;
    }
  }

  final String installRoot;
  final Future<void> Function()? onRestart;
  final UpdateProcess runProcess;
  final Future<void> Function({required Future<void> Function() beforeRestart, String? executable}) restart;

  @override
  String get actionLabel => 'Update';

  @override
  String get progressDetail => 'Downloading and installing Eclipse.';

  @override
  Map<String, dynamic>? assetForRelease(Map<String, dynamic> release) {
    final assets = (release['assets'] as List? ?? []).cast<Map<String, dynamic>>();
    final asset = assets.where((a) => a['name'] == 'Eclipse.tar.zst').firstOrNull;
    if (asset == null) return null;
    return {...asset, 'package_release': ReleaseUpdater.releaseBuild(release)};
  }

  @override
  String? downloadForRelease(Map<String, dynamic> release) =>
      assetForRelease(release)?['browser_download_url'] as String?;

  @override
  bool newerRelease(String version, Map<String, dynamic>? asset) {
    if (asset == null || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) return false;
    final build = asset['package_release'] as int?;
    if (build == null || build < 1) return false;
    return isNewer(version, installedVersion) || (version == installedVersion && build > installedRelease);
  }

  Future<void> _run(String command, List<String> arguments) async {
    final result = await runProcess(command, arguments);
    if (result.exitCode != 0) {
      final detail = '${result.stderr}\n${result.stdout}'.trim();
      throw ProcessException(command, [], detail.isEmpty ? 'Installation failed.' : detail, result.exitCode);
    }
  }

  @override
  Future<void> update() async {
    if (status == UpdateStatus.updating || status == UpdateStatus.restarting) return;
    final asset = _asset;
    if (asset == null || _download == null) return;
    error = null;
    set(UpdateStatus.updating);
    Directory? directory;
    try {
      final uri = Uri.parse(_download!);
      if (uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          !uri.path.startsWith('/Gresmond/Eclipse/releases/download/') ||
          !uri.path.endsWith('/Eclipse.tar.zst')) {
        throw const FormatException('The release archive URL is invalid.');
      }
      final digest = asset['digest'] as String? ?? '';
      if (!RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest)) {
        throw const FormatException('The release archive has no SHA-256 checksum.');
      }
      // Stage on the same user-owned filesystem as the installed releases.
      directory = await Directory(installRoot).createTemp('.update-');
      final archive = File(p.join(directory.path, 'Eclipse.tar.zst'));
      final (code, bytes) = await fetch(uri);
      if (code != 200) throw HttpException('Archive download failed (HTTP $code).');
      if (sha256.convert(bytes).toString() != digest.substring(7).toLowerCase()) {
        throw const FormatException('The downloaded archive checksum does not match.');
      }
      await archive.writeAsBytes(bytes, flush: true);
      await _run('tar', [
        '--zstd',
        '--extract',
        '--no-same-owner',
        '--no-same-permissions',
        '--file',
        archive.path,
        '--directory',
        directory.path,
      ]);
      final extracted = p.join(directory.path, 'Eclipse');
      final version = ReleaseUpdater.readInstalledVersion(p.join(extracted, 'bundle', 'eclipse'));
      final build = int.tryParse(await File(p.join(extracted, 'bundle', 'package-release')).readAsString());
      if (version != newVersion || build != asset['package_release']) {
        throw const FormatException('The archive version does not match the release.');
      }
      await _run('bash', [p.join(extracted, 'install.sh'), '--update', installRoot]);
      await directory.delete(recursive: true);
      directory = null;
      set(UpdateStatus.restarting);
      await restart(beforeRestart: onRestart ?? () async {}, executable: p.join(installRoot, 'current', 'eclipse'));
    } catch (e) {
      error = e is ProcessException ? e.message : e.toString();
      set(UpdateStatus.failed);
    } finally {
      if (directory != null && await directory.exists()) await directory.delete(recursive: true);
    }
  }
}
