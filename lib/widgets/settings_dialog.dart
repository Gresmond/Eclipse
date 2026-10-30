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
import '../theme/tokens.dart';
import 'fade_menu.dart';
import 'fade_through.dart';
import 'setting_rows.dart';
import 'settings_search.dart';
import 'welcome_tour.dart';

part 'settings_data.dart';

/// Shared by the normal modal and its welcome-tour preview.
Widget settingsTransition(BuildContext context, Animation<double> animation, Widget child) =>
    dialogTransition(animation, child);

/// Settings, in three ribbons: General, Data, and Search. Restoring a
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
  /// 0 for General, 1 for Data, 2 for Search. Always opens on General.
  late int _ribbon = widget.tourRibbon ?? 0;

  final _search = GlobalKey<SettingsSearchState>();

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

  /// A folder picked for the journal, waiting for a yes.
  Directory? _newJournal;
  bool _moving = false;

  /// Why the journal's last move didn't fully work, shown on its card.
  String? _journalError;

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
      _journalError = null;
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
        _journalError =
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
      onConfirm: _restoring || _moving || _signingIn || _confirming != null || _newJournal != null || _joining != null
          ? null
          // Opens the first result while searching, else closes.
          : () => switch (_search.currentState) {
              final search? when _ribbon == 0 && search.searching => search.openFirst(),
              _ => Navigator.pop(context),
            },
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        backgroundColor: p.tile,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(dialogRadius)),
        child: TourTarget(
          key: widget.tourTargetKey,
          spot: widget.tourRibbon == null ? TourSpot.settings : TourSpot.settingsPreview,
          child: SizedBox(
            width: 480,
            // Scrolls when the window is too short for all of it.
            child: SingleChildScrollView(
              padding: dialogPadding,
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
                          _journalError = null;
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
                      layoutBuilder: FadeThrough.pinTop,
                      child: KeyedSubtree(
                        key: ValueKey(_ribbon),
                        child: _ribbon == 0 ? SettingsSearch(key: _search, settings: _general(p)) : _backupsAndSync(p),
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
  /// What used to sit in the appearance menu.
  Widget _general(Palette p) {
    final state = AppScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                            fontSize: 15,
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
    final small = TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.45, color: p.inkMuted);
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
                padding: EdgeInsets.fromLTRB(16, inDrive ? 2 : 8, 12, 12),
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
                style: TextStyle(fontFamily: Fonts.ui, fontSize: 15, fontWeight: FontWeight.w600, color: p.ink),
              ),
            ),
            if (folder == null)
              TextButton(
                style: _compactButton,
                onPressed: _pickJournal,
                child: Text('Change…', style: TextStyle(color: p.accent)),
              ),
          ],
        ),
        SelectableText(
          _shortPath(current.path),
          maxLines: 1,
          style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, color: p.ink),
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
        if (_journalError != null) ...[
          const SizedBox(height: 8),
          Text(curlyQuotes(_journalError!), style: small.copyWith(color: p.missed)),
        ],
      ],
    );
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
      padding: const EdgeInsets.all(4),
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
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: p.done),
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
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: Motion.morph,
                            curve: Motion.morphCurve,
                            style: TextStyle(
                              fontFamily: Fonts.ui,
                              fontSize: 14,
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
