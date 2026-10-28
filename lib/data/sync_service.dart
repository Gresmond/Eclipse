import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'google_drive.dart';
import 'journal_files.dart';
import 'store.dart';
import 'sync.dart';

/// Runs sync: copies this computer's change files up to Eclipse's hidden
/// folder in the Google Drive signed in to, everyone else's down, and
/// merges them in. Also keeps a copy of the journal in a folder there you
/// can see, Eclipse Journals.
///
/// Set up once per computer: it lives in the app's own folder, as
/// sync.json, so a restored backup or a moved data folder doesn't change it.
class SyncService extends ChangeNotifier {
  SyncService._(this.home, this.store, this._config, this._connect, this._signIn) {
    engine = SyncEngine(store, machine)..offset = _config['clock'] as int? ?? 0;
    folder = SyncFolder(Directory(p.join(home.path, 'sync')), machine, Platform.localHostname);
    _checkNewer();
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
  /// A computer that hasn't synced yet isn't returning, whatever the
  /// account: it joins like a new one.
  bool isReturning(GoogleAccount account) {
    if (!hasSynced) return false;
    if (_sharesHistoryWith == account.identity) return true;
    final id = _config['accountId'] as String?;
    return id != null
        ? id == account.identity
        : (_config['accountEmail'] as String?)?.toLowerCase() == account.email.toLowerCase();
  }

  /// The account [look] found already holds history this computer shares,
  /// though sync's settings here don't say so (they were lost, the data
  /// folder kept): signing in merges, never replaces.
  String? _sharesHistoryWith;

  bool needsAccountChoice(GoogleAccount account) => hasSynced && !isReturning(account);

  /// Signed in from before the journal went to Drive too: signing in again
  /// lets it.
  bool get needsJournalSignIn => isOn && _config['journalDrive'] != true;

  /// The journal's folder in Drive, to open in the browser; null until it's
  /// made.
  String? get journalFolderLink {
    final id = _config['journalFolder'] as String?;
    return isOn && id != null ? 'https://drive.google.com/drive/folders/$id' : null;
  }

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
      if (_changed || _journalBehind || DateTime.now().difference(_lastFull) > const Duration(minutes: 3)) {
        unawaited(run());
      }
    });
  }

  bool get _changed => store.raw.select('SELECT 1 FROM sync_dirty LIMIT 1').isNotEmpty || engine.latest > _pushed;

  /// Records what was just changed here as edits, at the time they were
  /// made: sent at the next round, even if that's days away offline. Not
  /// before the first sign-in, which takes everything as it is.
  void recordEdits() {
    if (hasSynced) engine.flush();
  }

  /// The computers, by name, some of whose changes need a newer version of
  /// Eclipse to show here.
  Set<String> newerFrom = {};

  void _checkNewer() {
    final names = (_config['names'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    names.addAll(folder.names);
    newerFrom = {
      ...folder.newer,
      for (final id in engine.newerOrigins)
        if (id != machine) names[id] as String? ?? 'another computer',
    };
  }

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
      ..remove('up')
      ..remove('ids');
    _drive = _connect(account.refreshToken);
    final mine = await _pull(_drive!);
    final there = {...folder.computers, if (mine.isNotEmpty) machine};
    _sharesHistoryWith =
        hasSynced &&
            store.raw.select('SELECT DISTINCT origin FROM sync_reg').any((r) => there.contains(r['origin'] as String))
        ? account.identity
        : null;
    return folder.hasOthers;
  }

  /// Turns sync on with [account], after [look]. Joining replaces what's on
  /// this computer with what the others have. Otherwise this computer's
  /// data is merged with theirs (when it has synced before) or goes up as
  /// the start of it all.
  Future<void> turnOn(GoogleAccount account, {required bool join, bool transfer = false}) async {
    final switching = needsAccountChoice(account);
    if (switching && !join && !transfer) {
      throw const DriveError('Choose whether to use this account’s data or transfer your local data first.');
    }
    beforeMerge?.call();
    if (join) {
      beforeJoin?.call();
      final days = engine.clearForJoining(); // not inside ?.call, which would skip it
      onClear?.call(days);
      _deliver(folder.read(engine));
    } else {
      if (switching) engine.forgetSync();
      // Back with history already shared: only edits go up, never what the
      // app did by itself meanwhile. The first computer, or one moving its
      // data to another account, sends everything as it is.
      if (hasSynced) {
        engine
          ..adoptUnsent(folder.latestSent())
          ..flush();
      } else {
        engine.claimAll();
      }
    }
    _forgetJournalFolder();
    _config
      ..['email'] = account.email
      ..['accountEmail'] = account.email
      ..['accountId'] = account.identity
      ..['refresh'] = account.refreshToken
      ..['journalDrive'] = account.journalAccess
      ..['pushed'] = 0;
    error = null;
    await _save();
    notifyListeners();
    start();
    await run();
  }

  /// Signs in again with the same account, for a sign-in that lets the
  /// journal go to Drive too. Sync carries on as it was.
  Future<void> signInForJournal({Future<void>? cancel}) async {
    final account = await _signIn(cancel: cancel);
    if (!isOn) return;
    if (!isReturning(account)) throw DriveError('Sign in with ${email ?? 'the account you sync with'}.');
    if (!account.journalAccess) {
      throw const DriveError('Google wasn’t asked to let Eclipse make the journal’s folder. Tick it when signing in.');
    }
    _config
      ..['refresh'] = account.refreshToken
      ..['journalDrive'] = true;
    _drive = null;
    error = null;
    await _save();
    notifyListeners();
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
    _forgetJournalFolder();
    _config
      ..remove('refresh')
      ..remove('email')
      ..remove('journalDrive');
    await _save();
    this.error = error;
    notifyListeners();
  }

  /// Copies down every other computer's file that's new or changed, into
  /// the folder here, and returns this computer's own, by name. Its own
  /// come down only when the copy here is gone (after signing in again,
  /// say), so any of its edits the database here lost come back.
  Future<Map<String, String>> _pull(SyncDrive drive) async {
    final down = _seen('down'), ids = _seen('ids'), mine = <String, String>{};
    final files = await drive.list(), seen = <String, dynamic>{}, copies = <String, int>{};
    for (final f in files) {
      copies[f.name] = (copies[f.name] ?? 0) + 1;
    }
    for (final f in files) {
      final (who, day) = _split(f.name) ?? (null, null);
      if (who == null || day == null) continue;
      // Two files of one name (Drive's list lagged behind a new one): each
      // is read.
      final file = File(
        p.join(folder.dir.path, who, copies[f.name]! > 1 ? '${p.basenameWithoutExtension(day)}~${f.id}.json' : day),
      );
      if (who == machine) {
        if (mine[f.name] == null || f.id == ids[f.name]) mine[f.name] = f.id;
        if (await file.exists()) continue;
      } else if (down[f.id] == f.modified && await file.exists()) {
        seen[f.id] = f.modified;
        continue;
      }
      final bytes = await drive.download(f.id);
      try {
        jsonDecode(utf8.decode(bytes));
      } on FormatException {
        continue; // cut short: fetched again next round
      }
      await file.parent.create(recursive: true);
      final part = File('${file.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(file.path);
      if (who != machine) seen[f.id] = f.modified;
    }
    // By id, as names can repeat; files gone from Drive are forgotten.
    _config['down'] = seen;
    return mine;
  }

  /// Copies up this computer's files written since they last went. A file
  /// made here is remembered, so one Drive doesn't list yet isn't made twice.
  Future<void> _push(SyncDrive drive, Map<String, String> there) async {
    final up = _seen('up'), ids = _seen('ids');
    if (!folder.mine.existsSync()) return;
    for (final f in folder.mine.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json') || p.basename(f.path).contains('~')) continue;
      final name = '${machine}_${p.basename(f.path)}';
      final stat = f.statSync();
      final stamp = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
      if (up[name] == stamp && there.containsKey(name)) continue;
      final bytes = await f.readAsBytes(), id = there[name] ?? ids[name] as String?;
      final sent = DateTime.now();
      DriveFile made;
      try {
        made = await drive.upload(name, bytes, id: id);
      } on DriveError catch (e) {
        if (!e.notFound || id == null) rethrow;
        made = await drive.upload(name, bytes); // deleted from Drive: made again
      }
      _timed(sent, made.modified);
      ids[name] = made.id;
      up[name] = stamp;
    }
  }

  /// Puts this computer's clock right by Google's, from a file just written:
  /// Drive stamps it with its own time. Within a second is network time
  /// doing its job, and left alone.
  void _timed(DateTime sent, String modified) {
    final server = DateTime.tryParse(modified), back = DateTime.now();
    if (server == null || back.difference(sent) > const Duration(seconds: 10)) return;
    final behind = server.millisecondsSinceEpoch - (sent.millisecondsSinceEpoch + back.millisecondsSinceEpoch) ~/ 2;
    engine.offset = _config['clock'] = behind.abs() < 1000 ? 0 : behind;
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
      engine.flush();
      final drive = _signedIn;
      final mine = await _pull(drive);
      if (_stopped) return;
      final incoming = await folder.readAsync(engine, beforeMerge: beforeMerge, canMerge: () => !_stopped);
      if (_stopped) return;
      _deliver(incoming);
      _checkNewer();
      engine.flush();
      final latest = engine.latest;
      // On the disk before it's recorded as sent, so a power cut can't leave
      // the others with edits this computer has lost.
      store.flushToDisk();
      await folder.write(engine, _pushed);
      if (_stopped) return;
      await _push(drive, mine);
      if (_stopped) return;
      _config['pushed'] = latest;
      await _save();
      if (_stopped) return;
      if (drive is JournalDrive && _config['journalDrive'] == true) {
        await _copyJournal(drive as JournalDrive);
        if (_stopped) return;
      }
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

  // The journal's folder

  static const journalFolderName = 'Eclipse Journals';

  /// Files written to the journal's folder in one round at most, so a
  /// round stays short; the rest go in the next, half a minute on.
  static const journalBatch = 25;
  bool _journalBehind = false;

  /// What this computer knows of the journal's folder in Drive: its id,
  /// its year folders' and each day's file, with its checksum.
  Map<String, dynamic> get _journalYears => _seen('journalYears');
  Map<String, dynamic> get _journalUp => _seen('journalUp');

  void _forgetJournalFolder() {
    _journalBehind = false;
    for (final key in ['journalFolder', 'journalYears', 'journalUp', 'journalFill']) {
      _config.remove(key);
    }
  }

  /// Brings the journal's folder up to date with the days this computer
  /// wrote last; the other computers see to theirs. Whoever makes the
  /// folder (the first time, or after it was deleted) fills it with every
  /// day.
  Future<void> _copyJournal(JournalDrive drive) async {
    var folder = _config['journalFolder'] as String?;
    if (folder == null || !await drive.exists(folder)) {
      _forgetJournalFolder();
      final found = await drive.findFolder(journalFolderName);
      if (found != null && found != folder) {
        // Made by another computer, or by this one before signing out.
        final (files, years) = await drive.listJournal(found);
        _journalYears.addAll(years);
        for (final MapEntry(key: path, value: (id, md5)) in files.entries) {
          final name = p.basenameWithoutExtension(path);
          if (path == '${name.substring(0, 4)}/$name.md') _journalUp[name] = [id, md5];
        }
        folder = found;
      } else {
        folder = await drive.makeFolder(journalFolderName);
        _config['journalFill'] = true;
      }
      _config['journalFolder'] = folder;
      await _save();
    }
    if (_stopped) return;

    final fill = _config['journalFill'] == true;
    final writers = engine.journalWriters();
    final texts = {for (final e in store.journalEntries()) e.day: e.text};
    // A day's file and its checksum, or two blanks once it's known there's
    // none, for a day emptied.
    final up = _journalUp, years = _journalYears;
    const none = ['', ''];
    var written = 0;
    _journalBehind = false;
    for (final day in {...texts.keys, ...up.keys, ...writers.keys}.toList()..sort()) {
      if (_stopped) return;
      if (!fill && (writers[day] ?? machine) != machine) continue;
      final contents = JournalFiles.contents(DateTime.parse(day), texts[day] ?? '');
      final bytes = contents == null ? null : utf8.encode(contents);
      final had = (up[day] as List?)?.cast<String>();
      final same = bytes == null
          ? (had != null && had[0] == '') || (fill && had == null)
          : (had != null && had[1] == md5.convert(bytes).toString());
      if (same) {
        if (had == null) up[day] = none;
        continue;
      }
      if (written == journalBatch) {
        _journalBehind = true;
        break;
      }
      written++;
      final year = day.substring(0, 4);
      try {
        if (bytes == null) {
          // Another computer may have written the day's file last.
          final yearFolder = years[year] as String? ?? await drive.findFolder(year, parent: folder);
          final id = had?[0] ?? (yearFolder == null ? null : (await drive.findFile('$day.md', yearFolder))?.$1);
          if (id != null) await drive.bin(id);
          up[day] = none;
          continue;
        }
        final yearFolder =
            years[year] as String? ??
            await drive.findFolder(year, parent: folder) ??
            await drive.makeFolder(year, parent: folder);
        years[year] = yearFolder;
        final id = had?[0] ?? (await drive.findFile('$day.md', yearFolder))?.$1;
        final (newId, sum) = await drive.writeFile('$day.md', yearFolder, bytes, id: id == '' ? null : id);
        up[day] = [newId, sum];
      } on DriveError catch (e) {
        if (!e.notFound) rethrow;
        // Deleted in Drive: looked for again next round.
        up.remove(day);
        years.remove(year);
        _journalBehind = true;
      }
    }
    if (!_journalBehind) _config.remove('journalFill');
    await _save();
  }

  void _deliver(Incoming incoming) {
    if (incoming.isEmpty) return;
    onIncoming?.call(incoming);
    lastIncoming = incoming;
    incomingCount++;
  }
}
