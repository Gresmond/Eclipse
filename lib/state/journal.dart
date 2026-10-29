part of '../app_state.dart';

/// The journal: drafts saved as you type, and its copies as files on this
/// computer.
mixin _Journal on ChangeNotifier {
  Store get store;
  SyncService? get sync;
  JournalFiles? get journalFiles;
  DataFolder? get dataFolder;
  bool get closing;
  bool get _disposed;
  Future<void> flushFiles();

  int journalRevision = 0;

  /// Drive's Eclipse Journals folder is made and kept up to date, so the
  /// files on this computer can be turned off.
  bool get journalInDrive => sync != null && sync!.journalFolderLink != null && !sync!.needsJournalSignIn;

  /// Turned off on this computer only. Back on by itself whenever Drive
  /// doesn't have the journal, so there's always a copy you can read.
  late bool keepsJournalFiles = store.setting('journalFiles') != '0';

  bool get savesJournalFiles => journalFiles != null && (keepsJournalFiles || !journalInDrive);
  late bool _savesFiles;

  void setKeepsJournalFiles(bool keep) {
    saveJournalDraft();
    keepsJournalFiles = keep;
    store.setSetting('journalFiles', keep ? '1' : '0');
    if (!keep) journalFileProblem = null;
    notifyListeners();
    _checkJournalFiles();
  }

  /// Files left behind while they were off are brought up to date once
  /// they're back on.
  void _checkJournalFiles() {
    final saves = savesJournalFiles;
    if (saves == _savesFiles) return;
    _savesFiles = saves;
    if (saves) {
      unawaited(_rewriteStaleJournal());
    } else {
      store.setSetting('journalFilesStale', '1');
    }
    notifyListeners();
  }

  /// Writes every entry out again, and removes the files of days that were
  /// emptied meanwhile.
  Future<void> _rewriteStaleJournal() async {
    final files = journalFiles;
    if (files == null || store.setting('journalFilesStale') != '1') return;
    try {
      final days = <String>{};
      String? after;
      while (true) {
        if (closing || _disposed || !_savesFiles) return;
        final batch = store.journalEntries(after: after, limit: 64).toList();
        if (batch.isEmpty) break;
        for (final e in batch) {
          days.add(e.day);
          await _writeJournalFile(DateTime.parse(e.day), e.text);
        }
        after = batch.last.day;
      }
      for (final day in await files.days()) {
        if (!days.contains(dateKey(day))) await _writeJournalFile(day, '');
      }
      if (_savesFiles) store.setSetting('journalFilesStale', '0');
    } catch (e) {
      debugPrint('Rewriting journal files failed: $e');
    }
  }

  /// Keeps the journal's files in [folder] from now on, on this computer,
  /// and moves the ones already saved there. Throws if some couldn't be
  /// moved; the folder is switched all the same, and those stay put.
  Future<void> useJournalFolder(Directory folder) async {
    final files = journalFiles!;
    saveJournalDraft();
    await flushFiles();
    final old = files.dir;
    dataFolder?.useJournal(folder);
    files.dir = folder;
    journalFileProblem = null;
    notifyListeners();
    await files.moveFrom(old);
  }

  /// The journal lives in the database. Its files are a copy for reading
  /// outside the app, so one that's missing or can't be read (a Mac told
  /// no to the Documents folder) never hides an entry.
  String journalOf(DateTime day) => store.journal(dateKey(day));

  Future<void> setJournal(DateTime day, String text) {
    text = normaliseNote(text);
    store.setJournal(dateKey(day), text);
    _journalShown = (day: day, text: store.journal(dateKey(day)));
    journalRevision++;
    notifyListeners();
    return _writeJournalFile(day, text);
  }

  /// The entry the journal's editor has, as stored, by day: what typing
  /// there is on top of.
  ({DateTime day, String text})? _journalShown;

  /// The editor now has [text] as [day]'s stored entry.
  void journalShown(DateTime day, String text) => _journalShown = (day: day, text: text);

  /// Typed but not saved yet: saved a moment after typing stops, rather
  /// than on every keystroke, and at once before sync merges, a restore,
  /// or quitting.
  ({DateTime day, String text})? _draft;
  Timer? _draftTimer;

  void draftJournal(DateTime day, String text) {
    if (_draft != null && _draft!.day != day) saveJournalDraft();
    _draft = (day: day, text: text);
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), saveJournalDraft);
  }

  /// Whether [day] has typing not saved yet.
  bool hasJournalDraft(DateTime day) => _draft?.day == day;

  void saveJournalDraft() {
    _draftTimer?.cancel();
    _draftTimer = null;
    final draft = _draft;
    if (draft == null) return;
    _draft = null;
    final stored = store.journal(dateKey(draft.day));
    final shown = _journalShown?.day == draft.day ? _journalShown!.text : stored;
    // Another computer's text came in as a key was pressed, before the
    // editor showed it: both kept.
    unawaited(setJournal(draft.day, stored == shown ? draft.text : _typedOver(shown, draft.text, stored)));
  }

  /// [typed] on top of [shown], saved where [stored] replaced it meanwhile.
  static String _typedOver(String shown, String typed, String stored) {
    if (shown.trim().isNotEmpty && stored.contains(shown) && !typed.contains(stored) && !stored.contains(typed)) {
      return stored.replaceFirst(shown, typed);
    }
    return Store.keepWriting(typed, stored);
  }

  /// Why the journal's files aren't being saved, for the folder button;
  /// null while they are.
  String? journalFileProblem;

  /// Copies a day's entry to its file. A failure only means the copy is
  /// behind: the database still has it, and the next save tries again.
  Future<void> _writeJournalFile(DateTime day, String text) async {
    final files = journalFiles;
    if (files == null) return;
    if (!savesJournalFiles) {
      store.setSetting('journalFilesStale', '1');
      return;
    }
    String? problem;
    try {
      await files.write(day, text);
    } on FileSystemException catch (e) {
      debugPrint('Saving journal file failed: $e');
      // EPERM: macOS's privacy settings keep Eclipse out of Documents.
      problem = Platform.isMacOS && e.osError?.errorCode == 1
          ? "Eclipse isn’t allowed in your Documents folder, so the journal’s files aren’t being saved. "
                'Allow it in System Settings, Privacy & Security, Files and Folders.'
          : "The journal’s files couldn’t be saved (${e.osError?.message ?? e.message}).";
    }
    problem = problem == null ? null : curlyQuotes(problem);
    if (_disposed || problem == journalFileProblem) return;
    journalFileProblem = problem;
    notifyListeners();
  }

  /// Once: writes entries from before the journal moved to documents out as
  /// files. Never overwrites a file, and never runs again, so deleting a
  /// file in the folder doesn't bring it back.
  Future<void> _exportJournal() async {
    final files = journalFiles;
    if (files == null || !savesJournalFiles || store.setting('journalExported') != null) return;
    try {
      String? after;
      while (true) {
        if (closing || _disposed) return;
        final batch = store.journalEntries(after: after, limit: 64).toList();
        if (batch.isEmpty) break;
        for (final e in batch) {
          if (closing || _disposed) return;
          final day = DateTime.parse(e.day);
          if (!await files.fileFor(day).exists()) await files.write(day, e.text);
        }
        after = batch.last.day;
      }
      store.setSetting('journalExported', '1');
    } catch (e) {
      debugPrint('Exporting journal failed: $e');
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    super.dispose();
  }
}
