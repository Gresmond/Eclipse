import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models.dart' show dateKey;
import 'app_log.dart';
import 'backups.dart';
import 'google_drive.dart';
import 'host.dart';
import 'safe_write.dart';
import 'sqlite.dart' show checkedCopyOf, copyOfDatabase, offThread;
import 'journal_drive.dart';
import 'store.dart';
import 'sync.dart';
import 'sync_disk.dart';

part 'sync_transport.dart';

/// Runs sync: copies this computer's change files up to Eclipse's hidden
/// folder in the Google Drive signed in to, everyone else's down, and
/// merges them in. Also keeps a copy of the journal in a folder there you
/// can see, Eclipse Journals.
///
/// Set up once per computer: it lives in the app's own folder, as
/// sync.json, so a restored backup or a moved data folder doesn't change it.
class SyncService extends ChangeNotifier {
  SyncService._(this._settings, SyncDisk disk, this.store, this._config, this._connect, this._signIn) {
    engine = SyncEngine(store, machine)..offset = _config['clock'] as int? ?? 0;
    folder = SyncFolder.on(disk, machine, computerName);
    journal = JournalFolder(_config, _save);
    _checkNewer();
  }

  /// [connect] and [signIn] stand in for Google in tests.
  static SyncService load(
    Directory home,
    Store store, {
    SyncDrive Function(String refreshToken)? connect,
    Future<GoogleAccount> Function({Future<void>? cancel})? signIn,
  }) => loadFrom(_FileSettings(home), FolderDisk(p.join(home.path, 'sync')), store, connect: connect, signIn: signIn);

  /// As [load], with its settings and change files kept in [settings] and
  /// [disk].
  static SyncService loadFrom(
    SyncSettings settings,
    SyncDisk disk,
    Store store, {
    SyncDrive Function(String refreshToken)? connect,
    Future<GoogleAccount> Function({Future<void>? cancel})? signIn,
  }) {
    var config = <String, dynamic>{};
    var damaged = false;
    try {
      final contents = settings.read();
      if (contents != null) {
        final json = jsonDecode(contents);
        if (json is Map<String, dynamic>) {
          config = json;
          final bad = [
            for (final MapEntry(:key, :value) in config.entries)
              if (!_fits(key, value)) key,
          ];
          damaged = bad.isNotEmpty;
          bad.forEach(config.remove);
        } else {
          damaged = true;
        }
      }
    } on Object {
      // A damaged or unreadable file: set up again.
      damaged = true;
    }
    if (damaged) settings.keepDamaged();
    if (config['machine'] is! String) {
      final random = Random.secure();
      config['machine'] = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    }
    final service = SyncService._(
      settings,
      disk,
      store,
      config,
      connect ?? AppDataFolder.new,
      signIn ?? signInWithGoogle,
    );
    if (damaged) service.error = 'Sync’s settings were damaged. Sign in again if sync is off.';
    return service;
  }

  /// Whether [value] is what sync.json's [key] holds; one that isn't is
  /// dropped, as if never set.
  static bool _fits(String key, Object? value) => switch (key) {
    'machine' ||
    'email' ||
    'accountEmail' ||
    'accountId' ||
    'refresh' ||
    'journalFolder' ||
    'journalChecked' ||
    'copied' ||
    'syncedAt' ||
    'stopped' => value is String,
    'clock' || 'pushed' => value is int,
    'journalDrive' || 'journalFill' => value is bool,
    'down' ||
    'up' ||
    'ids' ||
    'names' ||
    'journalYears' => value is Map<String, dynamic> && value.values.every((v) => v is String),
    'journalUp' =>
      value is Map<String, dynamic> &&
          value.values.every((v) => v is List && v.length == 2 && v.every((s) => s is String)),
    _ => true,
  };

  final SyncSettings _settings;
  final Store store;
  final Map<String, dynamic> _config;
  final SyncDrive Function(String refreshToken) _connect;
  final Future<GoogleAccount> Function({Future<void>? cancel}) _signIn;

  late final SyncEngine engine;
  late final SyncFolder folder;
  late final JournalFolder journal;

  String get machine => _config['machine'] as String;

  /// The Google account synced through; null while sync is off.
  String? get email => isOn ? _config['email'] as String? : null;
  bool get isOn => _config['refresh'] is String;

  /// The address of the account this computer last synced with, on or off.
  String? get accountEmail => _config['accountEmail'] as String?;

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
    final id = journal.id;
    return isOn && id != null ? 'https://drive.google.com/drive/folders/$id' : null;
  }

  SyncDrive? _drive;
  SyncDrive get _signedIn => _drive ??= _connect(_config['refresh'] as String);

  /// The number ([SyncEngine.latest]) of the newest edit already copied up.
  int get _pushed => _config['pushed'] as int? ?? 0;

  /// Each file's version last copied: other computers' by Drive's time,
  /// this one's by size and time here.
  Map<String, dynamic> _seen(String key) => (_config[key] ??= <String, dynamic>{}) as Map<String, dynamic>;

  Future<void> _saving = Future.value();

  Future<void> _save() {
    final contents = jsonEncode(_config);
    return _saving = _saving.catchError((Object _) {}).then((_) => _settings.write(contents));
  }

  /// Waits until saves so far have really been stored; only a browser, whose
  /// saves go there a moment later, needs it.
  Future<void> Function()? persist;

  /// Whether this copy of Eclipse keeps a daily copy of the database in Drive.
  bool copiesToDrive = false;

  /// Called with each round's changes from other computers, after they're
  /// in the database: to redraw, and write journal files.
  void Function(Incoming)? onIncoming;

  /// Called before merging, to save what's still being typed, so the merge
  /// takes it into account.
  void Function()? beforeMerge;

  /// Called before joining replaces everything here, to save a copy of it
  /// first. If it throws, nothing is replaced.
  void Function()? beforeJoin;

  /// Whether a daily copy of the database has gone to Drive.
  bool get hasDriveCopy => isOn && copiesToDrive && _config['copied'] is String;

  /// Called once today's copy is in Drive.
  void Function()? afterDriveCopy;

  /// Called before joining with the journal days that were here, to remove
  /// their files.
  void Function(List<String> days)? onClear;

  bool busy = false;
  DateTime? lastSynced;
  String? error;

  /// How long sync can fail before a card says so.
  static const staleAfter = Duration(days: 3);

  /// When sync last worked, kept across restarts; while it's never worked
  /// since this was first kept, when it first failed.
  DateTime? get _syncedAt => DateTime.tryParse(_config['syncedAt'] as String? ?? '');

  /// The days since sync last worked, once it's still failing after
  /// [staleAfter]; null otherwise. A computer that was off doesn't count
  /// until its first try back has failed.
  int? get staleDays {
    final since = _syncedAt;
    if (!isOn || error == null || since == null) return null;
    final gone = DateTime.now().difference(since);
    return gone < staleAfter ? null : gone.inDays;
  }

  /// Why Eclipse stopped syncing by itself; null while it hasn't.
  String? get stoppedWhy => _config['stopped'] as String?;

  /// The last failure logged, so one that repeats each round is logged once.
  String? _logged;

  void _failed(Object why) {
    if ('$why' == _logged) return;
    _logged = '$why';
    AppLog.failure('Sync failed', why);
  }

  /// The last changes that came in, for the banner; bumped with each.
  Incoming? lastIncoming;
  int incomingCount = 0;

  Timer? _timer;
  bool _stopped = false;

  /// How many [exclusive] actions are running: rounds wait until none are.
  int _paused = 0;
  DateTime _lastFull = DateTime.fromMillisecondsSinceEpoch(0);

  /// Looks every half minute: syncs at once when something changed here,
  /// and every few minutes regardless, to hear from the other computers.
  void start() {
    _timer?.cancel();
    if (!isOn || _stopped) return;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_changed || journal.behind || DateTime.now().difference(_lastFull) > const Duration(minutes: 3)) {
        unawaited(run());
      }
    });
  }

  bool get hasPendingChanges => _changed;

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

  /// The computers, by name, some of whose change files couldn't be read
  /// or taken in here: they're tried again each round.
  Set<String> unreadFrom = {};

  void _checkNewer() {
    final names = (_config['names'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    names.addAll(folder.names);
    unreadFrom = {...folder.unread};
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
        if (_stopped || !isOn) return;
        await _running;
        if (!_stopped && _changed) await run();
      })().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      AppLog.note('Sync before quitting took too long');
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// Serialize restore operations with rounds already in flight.
  Future<T> exclusive<T>(Future<T> Function() action) async {
    _paused++;
    try {
      await _running;
      return await action();
    } finally {
      _paused--;
    }
  }

  /// Pauses periodic foreground polling without stopping future syncs.
  void pauseTimer() {
    _timer?.cancel();
    _timer = null;
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
    final drive = _connect(account.refreshToken);
    final files = await drive.list();
    final disk = folder.disk;
    final there = <String>{};
    var hasOthers = false;
    for (final f in files) {
      final (who, day) = _split(f.name) ?? (null, null);
      if (who == null || day == null || !disk.holds(who, day)) continue;
      there.add(who);
      if (who != machine) hasOthers = true;
    }
    _sharesHistoryWith =
        hasSynced &&
            store.raw.select('SELECT DISTINCT origin FROM sync_reg').any((r) => there.contains(r['origin'] as String))
        ? account.identity
        : null;
    return hasOthers;
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
    if (join) beforeJoin?.call();
    folder.disk.clear();
    _config
      ..remove('driveInventory')
      ..remove('compacted')
      ..remove('down')
      ..remove('up')
      ..remove('ids');
    _drive = _connect(account.refreshToken);
    try {
      await _pull(_drive!);
    } catch (_) {
      if (!isOn) _drive = null;
      rethrow;
    }
    if (join) {
      // Nothing here goes until the others' history is all taken in: a file
      // this version can't read leaves this computer as it was.
      late final List<String> days;
      final Incoming incoming;
      try {
        incoming = store.transaction(() {
          days = engine.clearForJoining();
          final incoming = folder.read(engine);
          if (folder.newer.isNotEmpty) {
            throw const DriveError('This account’s data needs a newer version of Eclipse. Update Eclipse, then join.');
          }
          if (folder.unread.isNotEmpty) {
            throw const DriveError('Some of this account’s data couldn’t be read, so nothing here was changed.');
          }
          return incoming;
        });
      } catch (_) {
        engine.forgetCounts();
        if (!isOn) _drive = null;
        rethrow;
      }
      onClear?.call(days);
      _deliver(incoming);
    } else {
      if (switching) engine.forgetSync();
      // Back with history already shared: only edits go up, never what the
      // app did by itself meanwhile. The first computer, or one moving its
      // data to another account, sends everything as it is.
      if (hasSynced) {
        engine.adoptUnsent(folder.latestSent());
        await engine.flushGradually();
      } else {
        await engine.claimAllGradually();
      }
    }
    journal.forget();
    _config
      ..['email'] = account.email
      ..['accountEmail'] = account.email
      ..['accountId'] = account.identity
      ..['refresh'] = account.refreshToken
      ..['journalDrive'] = account.journalAccess
      ..['pushed'] = 0
      ..remove('stopped');
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
      ..['journalDrive'] = true
      ..remove('stopped');
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
    journal.forget();
    _config
      ..remove('refresh')
      ..remove('email')
      ..remove('journalDrive');
    if (error == null) {
      _config.remove('stopped');
    } else {
      _config['stopped'] = error;
    }
    await _save();
    this.error = error;
    notifyListeners();
  }

  // Each round

  Future<void>? _running;

  /// One round: everyone else's changes down and merged, ours up.
  Future<void> run() {
    if (_paused > 0 || _stopped || !isOn) return Future.value();
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
      // Whatever goes wrong taking the others' changes in, this computer's
      // own still go up.
      Object? merging;
      try {
        final incoming = await folder.readAsync(engine, beforeMerge: beforeMerge, canMerge: () => !_stopped);
        if (_stopped) return;
        _deliver(incoming);
      } catch (e) {
        merging = e;
        AppLog.failure('Taking changes in failed', e);
      }
      _checkNewer();
      engine.flush();
      final latest = engine.latest;
      // On the disk before it's recorded as sent, so a power cut can't leave
      // the others with edits this computer has lost.
      store.flushToDisk();
      await persist?.call();
      if (_stopped) return;
      await folder.write(engine, _pushed);
      if (_stopped) return;
      await _push(drive, mine);
      if (_stopped) return;
      _config['pushed'] = latest;
      await _save();
      if (_stopped) return;
      if (drive is JournalDrive && _config['journalDrive'] == true) {
        await journal.copy(
          drive as JournalDrive,
          machine: machine,
          stamp: engine.journalStamp,
          writers: engine.journalWriters,
          texts: () => {for (final e in store.journalEntries()) e.day: e.text},
          stopped: () => _stopped,
        );
        if (_stopped) return;
      }
      await _compactHistory(drive, mine);
      if (_stopped) return;
      await _copyToDrive(drive);
      if (_stopped) return;
      lastSynced = DateTime.now();
      error = merging == null ? null : '$merging';
      if (_logged != null) AppLog.note('Sync is working again');
      _logged = null;
      // Rewritten once an hour at most: this runs every few minutes.
      if (DateTime.now().difference(_syncedAt ?? DateTime(2000)) > const Duration(hours: 1)) {
        _config['syncedAt'] = lastSynced!.toIso8601String();
        await _save();
      }
    } on DriveError catch (e) {
      if (_stopped) return;
      if (e.signedOut) {
        await turnOff(error: e.message);
      } else {
        error = e.message;
      }
      _failed(e.message);
      await _noteFirstFailure();
    } catch (e) {
      if (_stopped) return;
      error = '$e';
      _failed(e);
      await _noteFirstFailure();
    } finally {
      busy = false;
      if (!_stopped) notifyListeners();
    }
  }

  /// The copies in Drive, every computer's, newest first; the copy before a
  /// restore from here comes first.
  Future<List<DriveBackup>> driveCopies() async {
    if (!isOn || !copiesToDrive) return [];
    return _copiesIn(await _signedIn.list(), machine, _config['names'] as Map<String, dynamic>? ?? const {});
  }

  /// The copies in Drive of the sign-in kept in [home], for when the data
  /// won't open and so sync can't start. Null when there's no sign-in there.
  static DriveCopies? copiesAt(Directory home, {SyncDrive Function(String refreshToken)? connect}) {
    try {
      final config = jsonDecode(_FileSettings(home).read() ?? '{}') as Map<String, dynamic>;
      final (refresh, machine) = (config['refresh'], config['machine']);
      if (refresh is! String || machine is! String) return null;
      final names = config['names'];
      return DriveCopies._(
        (connect ?? AppDataFolder.new)(refresh),
        machine,
        names is Map<String, dynamic> ? names : const {},
      );
    } on Object {
      return null;
    }
  }

  /// The database as [copy] holds it.
  Future<List<int>> fetchCopy(DriveBackup copy) => _signedIn.download(copy.id);

  /// Saves everything here to Drive, as the way back from a restore where
  /// there's no folder to keep it in.
  Future<void> copyBeforeRestore() async {
    final drive = _signedIn;
    final name = 'backup_${machine}_before-restore.db';
    final had = (await drive.list()).where((f) => f.name == name).firstOrNull;
    await drive.upload(name, copyOfDatabase(store.raw), id: had?.id);
  }

  /// Back from signing in again: whether the journal may go to Drive may
  /// have changed.
  Future<void> updateAccess({required bool journalAccess}) async {
    if (!isOn || _config['journalDrive'] == journalAccess) return;
    _config['journalDrive'] = journalAccess;
    await _save();
    notifyListeners();
  }

  /// Starts the count towards [staleAfter] for a computer that has no last
  /// time on record.
  Future<void> _noteFirstFailure() async {
    if (_syncedAt != null || !isOn) return;
    _config['syncedAt'] = DateTime.now().toIso8601String();
    await _save();
  }

  void _deliver(Incoming incoming) {
    if (incoming.isEmpty) return;
    onIncoming?.call(incoming);
    lastIncoming = incoming;
    incomingCount++;
  }
}

/// sync.json, in the app's own folder. Only this person can read it: it
/// holds the lasting sign-in.
/// The copies in Drive, reached without the database.
