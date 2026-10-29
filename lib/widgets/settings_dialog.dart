import 'confirm_on_enter.dart';
import 'app_dialog.dart';

import 'package:path/path.dart' as pth;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/backups.dart';
import '../data/data_folder.dart';
import '../data/google_drive.dart';
import '../data/platform_files.dart';
import '../data/sync_service.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import 'fade_menu.dart';
import 'fade_through.dart';
import 'setting_rows.dart';
import 'welcome_tour.dart';

/// Shared by the normal modal and its welcome-tour preview.
Widget settingsTransition(BuildContext context, Animation<double> animation, Widget child) =>
    dialogTransition(animation, child);

/// Settings, in two ribbons: General, and Data. Restoring a
/// backup asks first, inline on its row. Pops with the restored [Backup],
/// or nothing.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, this.tourRibbon, this.tourTargetKey});

  /// Shows the actual panel beneath the welcome tour's interaction barrier.
  final int? tourRibbon;
  final GlobalKey? tourTargetKey;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  /// 0 for General, 1 for Data. Always opens on General.
  late int _ribbon = widget.tourRibbon ?? 0;

  late List<Backup> _backups = AppScope.of(context).backups?.list() ?? [];
  Backup? _confirming;
  bool _restoring = false;
  String? _error;

  /// Waiting on the browser for sign-in, or looking in Drive after it.
  bool _signingIn = false;
  Completer<void>? _cancelSignIn;

  /// Signed in to a Drive with another computer's data: waiting for a
  /// yes to use it.
  GoogleAccount? _joining;
  bool _remoteExists = false;

  Future<void> _signIn(SyncService sync) async {
    final cancel = _cancelSignIn = Completer<void>();
    setState(() {
      _signingIn = true;
      _error = null;
    });
    try {
      final account = await sync.signIn(cancel: cancel.future);
      if (!mounted || cancel.isCompleted) return;
      final others = await sync.look(account);
      if (!mounted || cancel.isCompleted) return;
      if ((others && !sync.isReturning(account)) || sync.needsAccountChoice(account)) {
        setState(() {
          _signingIn = false;
          _joining = account;
          _remoteExists = others;
        });
        return;
      }
      await sync.turnOn(account, join: false);
    } catch (e) {
      if (mounted && !cancel.isCompleted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _signingIn = false);
  }

  /// Signs in again so the journal can go to Drive too.
  Future<void> _signInForJournal(SyncService sync) async {
    final cancel = _cancelSignIn = Completer<void>();
    setState(() {
      _signingIn = true;
      _error = null;
    });
    try {
      await sync.signInForJournal(cancel: cancel.future);
    } catch (e) {
      if (mounted && !cancel.isCompleted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _signingIn = false);
  }

  void _stopSigningIn() {
    if (!(_cancelSignIn?.isCompleted ?? true)) _cancelSignIn!.complete();
    setState(() => _signingIn = false);
  }

  void _cancelJoin() => setState(() => _joining = null);

  Future<void> _join(SyncService sync, {bool transfer = false}) async {
    final account = _joining!;
    setState(() {
      _joining = null;
      _signingIn = true;
    });
    try {
      await sync.turnOn(account, join: !transfer, transfer: transfer);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (!mounted) return;
    setState(() {
      _signingIn = false;
      // Shows the copy saved before joining, even if the join stopped later.
      _backups = AppScope.of(context).backups?.list() ?? [];
    });
  }

  /// A folder picked to keep everything in, waiting for a yes.
  Directory? _newFolder;
  bool _moving = false;

  Future<void> _pickFolder() async {
    final state = AppScope.of(context);
    final folder = await DataFolder.pick(start: state.dataFolder!.root.parent.path);
    if (folder == null || !mounted) return;
    setState(() {
      _newFolder = folder.path == state.dataFolder!.root.path ? null : folder;
      _error = null;
    });
  }

  void _cancelMove() => setState(() => _newFolder = null);

  Future<void> _move() async {
    setState(() => _moving = true);
    try {
      await AppScope.of(context).useDataFolder(_newFolder!);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _moving = false;
        _error = 'Could not use that folder: $e';
      });
    }
  }

  /// A folder picked for the journal, waiting for a yes.
  Directory? _newJournal;

  Future<void> _pickJournal() async {
    final state = AppScope.of(context);
    final current = state.journalFiles!.dir;
    final picked = await DataFolder.pick(start: current.parent.path, title: 'Save journal entries in');
    if (picked == null || !mounted) return;
    final folder = ['Eclipse Journal', 'Eclipse Journals'].contains(pth.basename(picked.path))
        ? picked
        : Directory(pth.join(picked.path, DataFolder.journalName));
    setState(() {
      _newJournal = folder.path == current.path ? null : folder;
      _error = null;
    });
  }

  void _cancelJournalMove() => setState(() => _newJournal = null);

  /// Asks, on its row, whether to restore [b]; null stops asking.
  void _ask(Backup? b) => setState(() => _confirming = b);

  Future<void> _moveJournal() async {
    if (_moving) return;
    final folder = _newJournal!;
    setState(() => _moving = true);
    try {
      await AppScope.read(context).useJournalFolder(folder);
      if (!mounted) return;
      setState(() => _newJournal = null);
    } on FileSystemException catch (e) {
      if (!mounted) return;
      setState(() {
        _newJournal = null;
        _error =
            'Some entries couldn’t be moved, so they’re still in the old folder '
            '(${e.osError?.message ?? e.message}). New entries are saved in ${_shortPath(folder.path)}.';
      });
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  Future<void> _restore(Backup b) async {
    setState(() {
      _restoring = true;
      _error = null;
    });
    try {
      await AppScope.of(context).restore(b);
      if (mounted) Navigator.pop(context, b);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _restoring = false;
        _error = 'That copy could not be restored. Nothing was changed.';
      });
    }
  }

  @override
  void dispose() {
    if (!(_cancelSignIn?.isCompleted ?? true)) _cancelSignIn!.complete();
    super.dispose();
  }

  @override
  void didUpdateWidget(SettingsDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tourRibbon != oldWidget.tourRibbon && widget.tourRibbon != null) {
      _ribbon = widget.tourRibbon!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ConfirmOnEnter(
      onConfirm:
          _restoring ||
              _moving ||
              _signingIn ||
              _confirming != null ||
              _newFolder != null ||
              _newJournal != null ||
              _joining != null
          ? null
          : () => Navigator.pop(context),
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        backgroundColor: p.tile,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: TourTarget(
          key: widget.tourTargetKey,
          spot: widget.tourRibbon == null ? TourSpot.settings : TourSpot.settingsPreview,
          child: SizedBox(
            width: 480,
            // Scrolls when the window is too short for all of it.
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Settings',
                          style: TextStyle(fontFamily: Fonts.display, fontSize: 28, color: p.ink),
                        ),
                      ),
                      _Ribbons(
                        labels: const ['General', 'Data'],
                        selected: _ribbon,
                        onSelect: (i) => setState(() {
                          _ribbon = i;
                          _error = null;
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  AnimatedSize(
                    duration: Motion.morph,
                    curve: Motion.morphCurve,
                    alignment: Alignment.topCenter,
                    clipBehavior: Clip.none,
                    child: FadeThrough(
                      layoutBuilder: (current, previous) => Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.topLeft,
                        children: [
                          for (final w in previous) Positioned(left: 0, right: 0, top: 0, child: w),
                          ?current,
                        ],
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(_ribbon),
                        child: _ribbon == 0 ? _general(p) : _backupsAndSync(p),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Spacer(),
                      TextButton(
                        onPressed: _restoring ? null : () => Navigator.pop(context),
                        child: Text('Close', style: TextStyle(color: p.inkMuted)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

extension on _SettingsDialogState {
  /// The journal's folder, then what used to sit in the appearance menu.
  Widget _general(Palette p) {
    final state = AppScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.journalFiles != null) ...[_journalFolder(p, state.journalFiles!.dir), const SizedBox(height: 10)],
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ColoredBox(
            color: p.empty.withValues(alpha: 0.45),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                SettingSwitchRow(
                  title: 'Weekends as rest days',
                  subtitle: "Greyed out. A blank one won’t break a streak.",
                  on: state.restWeekends,
                  onTap: () => state.setRestWeekends(!state.restWeekends),
                ),
                const FadeMenuDivider(),
                const DayStartPicker(),
                const FadeMenuDivider(),
                FadeMenuRow(
                  height: 50,
                  onTap: () {
                    Navigator.pop(context);
                    state.startTour();
                  },
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Show the welcome tour',
                          style: TextStyle(
                            fontFamily: Fonts.ui,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: p.ink,
                          ),
                        ),
                      ),
                      Icon(Icons.arrow_forward_rounded, size: 18, color: p.inkMuted),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Where each day's entry is saved as a file, and a way to move them.
  Widget _journalFolder(Palette p, Directory current) {
    final state = AppScope.of(context);
    final folder = _newJournal;
    final small = TextStyle(fontFamily: Fonts.body, fontSize: 13, height: 1.45, color: p.inkMuted);
    final inDrive = state.journalInDrive;
    final off = inDrive && !state.keepsJournalFiles;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: p.empty.withValues(alpha: 0.45),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (inDrive) ...[
              const SizedBox(height: 4),
              SettingSwitchRow(
                title: 'Save the journal on this computer',
                subtitle: 'Your entries are in Eclipse Journals in your Drive either way.',
                on: !off,
                onTap: () => state.setKeepsJournalFiles(off),
              ),
            ],
            if (off)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
                child: Text(
                  'New entries aren’t saved as files here. Files already in ${_shortPath(current.path)} are left as '
                  'they were, and brought up to date if you turn this back on.',
                  style: small,
                ),
              )
            else
              Padding(
                padding: EdgeInsets.fromLTRB(16, inDrive ? 2 : 14, 12, 12),
                child: _journalFolderBody(p, current, folder, small),
              ),
          ],
        ),
      ),
    );
  }

  Widget _journalFolderBody(Palette p, Directory current, Directory? folder, TextStyle small) {
    final stopped = !AppScope.of(context).keepsJournalFiles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Journal folder',
                style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: p.ink),
              ),
            ),
            if (folder == null)
              TextButton(
                onPressed: _pickJournal,
                child: Text('Change…', style: TextStyle(color: p.accent)),
              ),
          ],
        ),
        SelectableText(
          _shortPath(current.path),
          maxLines: 1,
          style: TextStyle(fontFamily: Fonts.ui, fontSize: 12, color: p.ink),
        ),
        const SizedBox(height: 4),
        Text(
          "Each day’s entry is saved here as a file you can open without Eclipse. "
          'This computer only: your other computers keep their own folder.',
          style: small,
        ),
        if (stopped) ...[
          const SizedBox(height: 4),
          Text('Saved here again until your journal is back in your Drive.', style: small.copyWith(color: p.ink)),
        ],
        if (folder != null) ...[
          const SizedBox(height: 12),
          Text(
            'Move your entries to ${_shortPath(folder.path)} and save new ones there?',
            style: small.copyWith(color: p.ink),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _cancelJournalMove,
                child: Text('Cancel', style: TextStyle(color: p.inkMuted)),
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: p.done, foregroundColor: p.onAccent),
                onPressed: _moveJournal,
                child: const Text('Move'),
              ),
            ],
          ),
        ],
        if (_error != null && _ribbon == 0) ...[
          const SizedBox(height: 8),
          Text(curlyQuotes(_error!), style: small.copyWith(color: p.missed)),
        ],
      ],
    );
  }

  /// Saved copies to restore, where everything lives, and sync.
  Widget _backupsAndSync(Palette p) {
    final state = AppScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your data',
          style: TextStyle(fontFamily: Fonts.ui, fontSize: 16, fontWeight: FontWeight.w600, color: p.ink),
        ),
        const SizedBox(height: 14),
        if (state.dataFolder != null) ...[_dataFolder(p, state.dataFolder!)],
        if (state.sync != null) ...[
          const SizedBox(height: 10),
          TourTarget(
            spot: TourSpot.googleSync,
            child: ListenableBuilder(listenable: state.sync!, builder: (context, _) => _sync(p, state.sync!)),
          ),
        ],
        if (state.sync == null && widget.tourRibbon != null) ...[
          const SizedBox(height: 10),
          TourTarget(
            spot: TourSpot.googleSync,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: p.empty, borderRadius: BorderRadius.circular(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Google sync'),
                  const SizedBox(height: 8),
                  const Text(
                    'Sign in with the same Google account on each computer to keep your tasks, rituals and journal in sync.',
                  ),
                  const SizedBox(height: 8),
                  FilledButton(onPressed: null, child: const Text('Connect Google')),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Text(
          'Restore a copy',
          style: TextStyle(fontFamily: Fonts.ui, fontSize: 16, fontWeight: FontWeight.w600, color: p.ink),
        ),
        const SizedBox(height: 6),
        Text(
          'A copy of everything is saved each day you use the app, and the last 30 are kept.',
          style: TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.45, color: p.inkMuted),
        ),
        const SizedBox(height: 14),
        if (_backups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No backups yet.',
                style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.inkMuted),
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _backups.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (_, i) => _BackupRow(
                backup: _backups[i],
                today: state.today,
                confirming: _confirming == _backups[i],
                restoring: _restoring && _confirming == _backups[i],
                enabled: !_restoring,
                onAsk: () => _ask(_backups[i]),
                onCancel: () => _ask(null),
                onConfirm: () => _restore(_backups[i]),
              ),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            curlyQuotes(_error!),
            style: TextStyle(fontFamily: Fonts.body, fontSize: 13.5, color: p.missed),
          ),
        ],
      ],
    );
  }

  /// Where everything lives, and a way to keep it somewhere else (a synced
  /// folder, say) so it follows you to a new computer.
  Widget _dataFolder(Palette p, DataFolder data) {
    final folder = _newFolder;
    final small = TextStyle(fontFamily: Fonts.body, fontSize: 13, height: 1.45, color: p.inkMuted);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Local data',
                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: p.ink),
                ),
              ),
              if (folder == null)
                TextButton(
                  onPressed: _restoring || _moving ? null : _pickFolder,
                  child: Text('Keep it elsewhere…', style: TextStyle(color: p.accent)),
                ),
            ],
          ),
          SelectableText(
            _shortPath(data.root.path),
            maxLines: 1,
            style: TextStyle(fontFamily: Fonts.ui, fontSize: 12, color: p.ink),
          ),
          const SizedBox(height: 4),
          Text(
            'Every day, ritual and to-do since you started is kept here. '
            'Uninstalling the app leaves it in place.',
            style: small,
          ),
          if (folder != null) ...[
            const SizedBox(height: 12),
            Text(
              DataFolder.hasData(folder)
                  ? '${_shortPath(folder.path)} already has Eclipse data. Use it instead of what’s here? '
                        'What’s here stays where it is. Eclipse reopens.'
                  : 'Copy everything to ${_shortPath(folder.path)} and keep it there from now on? '
                        'The copy here stays as a spare. Eclipse reopens. In a synced folder, have Eclipse '
                        'open on one computer at a time.',
              style: small.copyWith(color: p.ink),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _moving ? null : _cancelMove,
                  child: Text('Cancel', style: TextStyle(color: p.inkMuted)),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent),
                  onPressed: _moving ? null : _move,
                  child: Text(DataFolder.hasData(folder) ? 'Use that folder' : 'Copy and reopen'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Keeping everything the same on your other computers, through a
  /// hidden folder in Google Drive.
  Widget _sync(Palette p, SyncService sync) {
    final small = TextStyle(fontFamily: Fonts.body, fontSize: 13, height: 1.45, color: p.inkMuted);

    // Saying yes to sync wears the tick's colour, even before it can be pressed.
    Widget button(String label, VoidCallback? onTap, {bool filled = false}) => filled
        ? FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: p.done,
              foregroundColor: p.onAccent,
              disabledBackgroundColor: p.done.withValues(alpha: 0.45),
              disabledForegroundColor: p.onAccent.withValues(alpha: 0.8),
            ),
            onPressed: onTap,
            child: Text(label),
          )
        : TextButton(
            onPressed: onTap,
            child: Text(label, style: TextStyle(color: onTap == null ? p.inkMuted : p.accent)),
          );

    final List<Widget> body;
    Widget? action;
    if (sync.isOn) {
      final last = sync.lastSynced;
      final status = sync.busy
          ? 'Syncing…'
          : sync.error != null
          ? 'Couldn’t sync: ${sync.error}'
          : last == null
          ? 'Waiting to sync.'
          : 'Last synced ${_ago(last)}.';
      action = button('Sync now', sync.busy ? null : () => sync.run());
      body = [
        SelectableText(
          'Signed in as ${sync.email}',
          maxLines: 1,
          style: TextStyle(fontFamily: Fonts.ui, fontSize: 12, color: p.ink),
        ),
        const SizedBox(height: 4),
        Text(
          'Changes made here go up within a minute, and changes from your other computers come down every few '
          'minutes.',
          style: small,
        ),
        Row(
          children: [
            if (sync.busy) ...[
              SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                curlyQuotes(status),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sync.error != null && !sync.busy ? small.copyWith(color: p.missed) : small,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (sync.needsJournalSignIn) ...[
          Text(
            _signingIn
                ? 'Finish signing in in your browser, then come back here.'
                : 'Sign in again to keep your journal in an Eclipse Journals folder in your Drive.',
            style: small.copyWith(color: p.ink),
          ),
        ],
        Row(
          children: [
            if (sync.journalFolderLink case final link? when !sync.needsJournalSignIn)
              button('Open Eclipse Journals in Drive', () => openExternal(link)),
            const Spacer(),
            if (sync.needsJournalSignIn)
              _signingIn
                  ? button('Cancel', _stopSigningIn)
                  : button('Sign in again', () => _signInForJournal(sync), filled: true),
            const SizedBox(width: 4),
            button('Turn off', sync.busy ? null : sync.turnOff),
          ],
        ),
      ];
    } else if (_joining case final account?) {
      body = [
        Text(
          _remoteExists
              ? 'The Drive of ${account.email} already has Eclipse data. Use it instead of this computer’s data? '
                    'A backup of this computer is saved first. Your previous Google account is left unchanged.'
              : 'Upload this computer’s Eclipse history, including its journal, to ${account.email}? '
                    'This connects a different account. Your previous Google account is left unchanged.',
          style: small.copyWith(color: p.ink),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            button('Cancel', _cancelJoin),
            const SizedBox(width: 4),
            button(
              _remoteExists ? 'Use Drive data' : 'Upload local data',
              () => _join(sync, transfer: !_remoteExists),
              filled: true,
            ),
          ],
        ),
      ];
    } else {
      final why = sync.error;
      body = [
        Text(
          _signingIn
              ? 'Finish signing in in your browser, then come back here.'
              : 'Keep everything the same on your other computers: sign in with the same Google account on each. '
                    'Eclipse keeps its data in a hidden folder in your Google Drive, with a copy of your journal in '
                    'an Eclipse Journals folder, and can’t see anything else there.',
          style: small,
        ),
        if (why != null && !_signingIn) ...[
          const SizedBox(height: 4),
          Text(curlyQuotes(why), style: small.copyWith(color: p.missed)),
        ],
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_signingIn) ...[
              button('Cancel', _stopSigningIn),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.done)),
              ),
            ] else
              button('Sign in with Google', () => _signIn(sync), filled: true),
          ],
        ),
      ];
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Sync',
                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: p.ink),
                ),
              ),
              ?action,
            ],
          ),
          ...body,
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final minutes = DateTime.now().difference(t).inMinutes;
    return switch (minutes) {
      < 1 => 'just now',
      1 => 'a minute ago',
      < 60 => '$minutes minutes ago',
      _ => 'at ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
    };
  }
}

String _shortPath(String path) {
  final home = Platform.environment['HOME'];
  return home != null && path.startsWith(home) ? '~${path.substring(home.length)}' : path;
}

class _BackupRow extends StatelessWidget {
  const _BackupRow({
    required this.backup,
    required this.today,
    required this.confirming,
    required this.restoring,
    required this.enabled,
    required this.onAsk,
    required this.onCancel,
    required this.onConfirm,
  });

  final Backup backup;
  final DateTime today;
  final bool confirming;
  final bool restoring;
  final bool enabled;
  final VoidCallback onAsk;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (title, subtitle) = _describe(backup, today);

    return AnimatedContainer(
      duration: Motion.hover,
      curve: Motion.hoverCurve,
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: confirming ? p.accent.withValues(alpha: 0.08) : p.empty.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: confirming ? p.accent.withValues(alpha: 0.35) : p.tileBorder.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: p.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  confirming ? 'Replaces everything you have now, except journal writing.' : subtitle,
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 12.5, color: p.inkMuted),
                ),
              ],
            ),
          ),
          if (restoring)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.done)),
            )
          else if (confirming) ...[
            TextButton(
              onPressed: onCancel,
              child: Text('Cancel', style: TextStyle(color: p.inkMuted)),
            ),
            const SizedBox(width: 4),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent),
              onPressed: onConfirm,
              child: const Text('Restore'),
            ),
          ] else
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: p.accent,
                side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
              ),
              onPressed: enabled ? onAsk : null,
              child: const Text('Restore'),
            ),
        ],
      ),
    );
  }

  static (String, String) _describe(Backup b, DateTime today) {
    if (b.day == null) {
      final t = b.modified;
      final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      return (
        b.isBeforeJoin ? 'Before joining sync' : 'Before your last restore',
        'Saved ${t.day} ${monthNames[t.month - 1]}, $time',
      );
    }
    final d = b.day!;
    final year = d.year == today.year ? '' : ' ${d.year}';
    final title = '${weekdayNames[d.weekday - 1]} ${d.day} ${monthNames[d.month - 1]}$year';
    final days = DateTime.utc(
      today.year,
      today.month,
      today.day,
    ).difference(DateTime.utc(d.year, d.month, d.day)).inDays;
    final ago = switch (days) {
      0 => 'Today, as it was when you opened the app',
      1 => 'Yesterday',
      _ => '$days days ago',
    };
    return (title, ago);
  }
}

/// The ribbons along the top of Settings: one pill, in the done colour like
/// the tab bar's, glides to the chosen one.
class _Ribbons extends StatelessWidget {
  const _Ribbons({required this.labels, required this.selected, required this.onSelect});

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 270,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(20)),
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedAlign(
              duration: Motion.morph,
              curve: Motion.morphCurve,
              alignment: Alignment(labels.length == 1 ? 0 : -1 + 2 * selected / (labels.length - 1), 0),
              child: FractionallySizedBox(
                widthFactor: 1 / labels.length,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(17), color: p.done),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final (i, label) in labels.indexed)
                Expanded(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onSelect(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: Motion.morph,
                            curve: Motion.morphCurve,
                            style: TextStyle(
                              fontFamily: Fonts.ui,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: i == selected ? p.onAccent : p.inkMuted,
                            ),
                            child: Text(label),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
