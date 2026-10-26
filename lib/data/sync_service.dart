import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'google_drive.dart';
import 'store.dart';
import 'sync.dart';

/// Runs sync: copies this computer's change files up to Eclipse's hidden
/// folder in the Google Drive signed in to, everyone else's down, and
/// merges them in.
///
/// Set up once per computer: it lives in the app's own folder, as
/// sync.json, so a restored backup or a moved data folder doesn't change it.
class SyncService extends ChangeNotifier {
  SyncService._(this.home, this.store, this._config, this._connect, this._signIn) {
    engine = SyncEngine(store, machine);
    folder = SyncFolder(Directory(p.join(home.path, 'sync')), machine, Platform.localHostname);
  }

  /// [connect] and [signIn] stand in for Google in tests.
  static SyncService load(
    Directory home,
    Store store, {
    SyncDrive Function(String refreshToken)? connect,
    Future<GoogleAccount> Function({Future<void>? cancel})? signIn,
  }) {
    final file = File(p.join(home.path, 'sync.json'));
    var config = <String, dynamic>{};
    try {
      if (file.existsSync()) config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException {
      // A damaged file: set up again.
    }
    // From when sync went through rclone.
    config.remove('remote');
    config['accountEmail'] ??= config['email'];
    if (config['machine'] is! String) {
      final random = Random.secure();
      config['machine'] = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    }
    return SyncService._(home, store, config, connect ?? AppDataFolder.new, signIn ?? signInWithGoogle);
  }

  final Directory home;
  final Store store;
  final Map<String, dynamic> _config;
  final SyncDrive Function(String refreshToken) _connect;
  final Future<GoogleAccount> Function({Future<void>? cancel}) _signIn;

  late final SyncEngine engine;
  late final SyncFolder folder;

  String get machine => _config['machine'] as String;

  /// The Google account synced through; null while sync is off.
  String? get email => isOn ? _config['email'] as String? : null;
  bool get isOn => _config['refresh'] is String;

  /// Account identity survives signing out; sync history belongs to it.
  bool isReturning(GoogleAccount account) {
    final id = _config['accountId'] as String?;
    return id != null
        ? id == account.identity
        : (_config['accountEmail'] as String?)?.toLowerCase() == account.email.toLowerCase();
  }

  bool needsAccountChoice(GoogleAccount account) => hasSynced && !isReturning(account);

  SyncDrive? _drive;
  SyncDrive get _signedIn => _drive ??= _connect(_config['refresh'] as String);

  /// Time of the newest edit already copied up.
  int get _pushed => _config['pushed'] as int? ?? 0;

  /// Each file's version last copied: other computers' by Drive's time,
  /// this one's by size and time here.
  Map<String, dynamic> _seen(String key) => (_config[key] ??= <String, dynamic>{}) as Map<String, dynamic>;

  /// Only this person can read it: it holds the lasting sign-in.
  Future<void> _saving = Future.value();

  Future<void> _save() {
    final contents = jsonEncode(_config);
    final file = File(p.join(home.path, 'sync.json'));
    return _saving = _saving.catchError((Object _) {}).then((_) async {
      final part = File('${file.path}.part');
      await part.writeAsString(contents, flush: true);
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', ['600', part.path]);
        if (result.exitCode != 0) throw FileSystemException('Cannot protect sync credentials', part.path);
      }
      await part.rename(file.path);
    });
  }

  /// Called with each round's changes from other computers, after they're
  /// in the database: to redraw, and write journal files.
  void Function(Incoming)? onIncoming;

  /// Called before merging, to save what's still being typed, so the merge
  /// takes it into account.
  void Function()? beforeMerge;

  /// Called before joining replaces everything here, to save a copy of it
  /// first. If it throws, nothing is replaced.
  void Function()? beforeJoin;

  /// Called before joining with the journal days that were here, to remove
  /// their files.
  void Function(List<String> days)? onClear;

  bool busy = false;
  DateTime? lastSynced;
  String? error;

  /// The last changes that came in, for the banner; bumped with each.
  Incoming? lastIncoming;
  int incomingCount = 0;

  Timer? _timer;
  bool _paused = false, _stopped = false;
  DateTime _lastFull = DateTime.fromMillisecondsSinceEpoch(0);

  /// Looks every half minute: syncs at once when something changed here,
  /// and every few minutes regardless, to hear from the other computers.
  void start() {
    _timer?.cancel();
    if (!isOn || _stopped) return;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_changed || DateTime.now().difference(_lastFull) > const Duration(minutes: 3)) unawaited(run());
    });
  }

  bool get _changed => store.raw.select('SELECT 1 FROM sync_dirty LIMIT 1').isNotEmpty;

  /// Syncs unless a round started in the last 20 seconds: for when the
  /// window comes back to the front, to show the latest from elsewhere.
  void refresh() {
    if (isOn && DateTime.now().difference(_lastFull) > const Duration(seconds: 20)) unawaited(run());
  }

  /// Sends what changed here now rather than at the next look: for when
  /// the window goes to the back, as you may be switching computers.
  void sendChanges() {
    if (!_stopped && isOn && _changed) unawaited(run());
  }

  /// Syncs before the app quits, giving up after 5 seconds; what's left
  /// goes the next time it opens.
  Future<void> beforeQuit() async {
    if (_stopped) return;
    try {
      await (() async {
        await _saving;
        if (!isOn) return;
        await _running;
        if (!_stopped && _changed) await run();
      })().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      debugPrint('Sync before quitting took too long');
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// Serialize restore operations with rounds already in flight.
  Future<T> exclusive<T>(Future<T> Function() action) async {
    _paused = true;
    try {
      await _running;
      return await action();
    } finally {
      _paused = false;
    }
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  // Turning on

  /// Opens Google's sign-in in the browser and waits for it.
  Future<GoogleAccount> signIn({Future<void>? cancel}) => _signIn(cancel: cancel);

  /// Looks in [account]'s Drive before turning sync on: true if another
  /// computer already keeps its data there, to join rather than start it.
  Future<bool> look(GoogleAccount account) async {
    if (folder.dir.existsSync()) folder.dir.deleteSync(recursive: true);
    _config
      ..remove('down')
      ..remove('up');
    _drive = _connect(account.refreshToken);
    await _pull(_drive!);
    return folder.hasOthers;
  }

  /// Turns sync on with [account], after [look]. Joining replaces what's on
  /// this computer with what the others have. Otherwise this computer's
  /// data is merged with theirs (when it has synced before) or goes up as
  /// the start of it all.
  Future<void> turnOn(GoogleAccount account, {required bool join, bool transfer = false}) async {
    final switching = needsAccountChoice(account);
    if (switching && !join && !transfer) {
      throw const DriveError('Choose whether to use this account\'s data or transfer your local data first.');
    }
    beforeMerge?.call();
    if (join) {
      beforeJoin?.call();
      final days = engine.clearForJoining(); // not inside ?.call, which would skip it
      onClear?.call(days);
      _deliver(folder.read(engine));
    } else {
      if (switching) engine.forgetSync();
      engine.claimAll();
    }
    _config
      ..['email'] = account.email
      ..['accountEmail'] = account.email
      ..['accountId'] = account.identity
      ..['refresh'] = account.refreshToken
      ..['pushed'] = 0;
    error = null;
    await _save();
    notifyListeners();
    start();
    await run();
  }

  /// Whether this computer has synced before: it then merges on turning
  /// back on, rather than joining afresh.
  bool get hasSynced => store.raw.select('SELECT 1 FROM sync_reg LIMIT 1').isNotEmpty;

  /// Stops syncing and forgets the sign-in; [error] says why, when it
  /// wasn't asked for.
  Future<void> turnOff({String? error}) async {
    _timer?.cancel();
    _drive = null;
    _config
      ..remove('refresh')
      ..remove('email');
    await _save();
    this.error = error;
    notifyListeners();
  }

  /// Copies down every other computer's file that's new or changed, into
  /// the folder here, and returns this computer's own, by name.
  Future<Map<String, String>> _pull(SyncDrive drive) async {
    final down = _seen('down'), mine = <String, String>{};
    for (final f in await drive.list()) {
      final (who, day) = _split(f.name) ?? (null, null);
      if (who == null || day == null) continue;
      if (who == machine) {
        mine[f.name] = f.id;
        continue;
      }
      if (down[f.name] == f.modified) continue;
      final file = File(p.join(folder.dir.path, who, day));
      await file.parent.create(recursive: true);
      final part = File('${file.path}.part');
      await part.writeAsBytes(await drive.download(f.id), flush: true);
      await part.rename(file.path);
      down[f.name] = f.modified;
    }
    return mine;
  }

  /// Copies up this computer's files written since they last went.
  Future<void> _push(SyncDrive drive, Map<String, String> there) async {
    final up = _seen('up');
    if (!folder.mine.existsSync()) return;
    for (final f in folder.mine.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final name = '${machine}_${p.basename(f.path)}';
      final stat = f.statSync();
      final stamp = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
      if (up[name] == stamp && there.containsKey(name)) continue;
      await drive.upload(name, await f.readAsBytes(), id: there[name]);
      up[name] = stamp;
    }
  }

  /// A file in Drive's name, like a1b2c3d4e5f6a7b8_2026-10-24.json, as the
  /// computer it's from and the file it is there.
  static (String, String)? _split(String name) {
    final i = name.indexOf('_');
    if (i <= 0 || !name.endsWith('.json')) return null;
    return (name.substring(0, i), name.substring(i + 1));
  }

  // Each round

  Future<void>? _running;

  /// One round: everyone else's changes down and merged, ours up.
  Future<void> run() {
    if (_paused || _stopped || !isOn) return Future.value();
    return _running ??= _round().whenComplete(() => _running = null);
  }

  Future<void> _round() async {
    if (!isOn) return;
    _lastFull = DateTime.now();
    busy = true;
    notifyListeners();
    try {
      final drive = _signedIn;
      final mine = await _pull(drive);
      if (_stopped) return;
      final incoming = await folder.readAsync(engine, beforeMerge: beforeMerge, canMerge: () => !_stopped);
      if (_stopped) return;
      _deliver(incoming);
      engine.flush();
      final latest = engine.latest;
      await folder.write(engine, _pushed);
      if (_stopped) return;
      await _push(drive, mine);
      if (_stopped) return;
      _config['pushed'] = latest;
      await _save();
      if (_stopped) return;
      store.flushToDisk();
      lastSynced = DateTime.now();
      error = null;
    } on DriveError catch (e) {
      if (_stopped) return;
      if (e.signedOut) {
        await turnOff(error: e.message);
      } else {
        error = e.message;
      }
      debugPrint('Sync failed: ${e.message}');
    } catch (e) {
      if (_stopped) return;
      error = '$e';
      debugPrint('Sync failed: $error');
    } finally {
      busy = false;
      if (!_stopped) notifyListeners();
    }
  }

  void _deliver(Incoming incoming) {
    if (incoming.isEmpty) return;
    onIncoming?.call(incoming);
    lastIncoming = incoming;
    incomingCount++;
  }
}
