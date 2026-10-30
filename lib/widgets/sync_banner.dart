import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/sync.dart';
import '../data/sync_service.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'corner_card.dart';

/// A card that floats up over the bottom-right corner for a few seconds
/// when changes come in from another computer, saying where from. Otherwise,
/// cards that stay there until done or closed: one while some changes from
/// another computer are waiting (they need a newer version, or couldn't be
/// read), and one asking to sign in again while the sign-in is from before
/// the journal went to Drive.
class SyncBanner extends StatefulWidget {
  const SyncBanner({super.key, required this.sync});

  final SyncService sync;

  @override
  State<SyncBanner> createState() => _SyncBannerState();
}

class _SyncBannerState extends State<SyncBanner> {
  late int _seen = widget.sync.incomingCount;
  Incoming? _shown;
  bool _visible = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.sync.addListener(_changed);
  }

  @override
  void dispose() {
    widget.sync.removeListener(_changed);
    _hide?.cancel();
    super.dispose();
  }

  /// The waiting card, closed until Eclipse next opens.
  bool _waitingClosed = false;

  /// The sign-in card: closed for now, waiting on the browser, or why
  /// signing in didn't work.
  bool _askClosed = false, _signingIn = false;
  String? _askError;
  Completer<void>? _cancel;

  Future<void> _signIn() async {
    final cancel = _cancel = Completer<void>();
    setState(() {
      _signingIn = true;
      _askError = null;
    });
    try {
      await widget.sync.signInForJournal(cancel: cancel.future);
    } catch (e) {
      if (mounted && !cancel.isCompleted) setState(() => _askError = '$e');
    }
    if (mounted) setState(() => _signingIn = false);
  }

  /// Stops waiting on the browser, or closes the card for now.
  void _close() {
    if (!(_cancel?.isCompleted ?? true)) _cancel!.complete();
    setState(() {
      _askClosed = !_signingIn;
      _signingIn = false;
    });
  }

  void _changed() {
    if (widget.sync.incomingCount == _seen) {
      setState(() {}); // the sign-in card may come or go
      return;
    }
    _seen = widget.sync.incomingCount;
    final incoming = widget.sync.lastIncoming!;
    setState(() {
      _shown = incoming;
      _visible = true;
    });
    _hide?.cancel();
    // Longer when both journal texts were kept: there's more to read.
    _hide = Timer(incoming.keptBoth.isEmpty ? Motion.notice : Motion.notice * 2, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final sync = widget.sync;
    // The waiting and sign-in cards make way while changes are shown.
    final waiting = !_visible && !_waitingClosed && (sync.newerFrom.isNotEmpty || sync.unreadFrom.isNotEmpty);
    final ask = !_visible && !_askClosed && sync.needsJournalSignIn;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        CornerCard(
          visible: waiting,
          child: _WaitingCard(
            newerFrom: sync.newerFrom,
            unreadFrom: sync.unreadFrom,
            onClose: () => setState(() => _waitingClosed = true),
          ),
        ),
        CornerCard(
          visible: ask,
          child: _AskCard(signingIn: _signingIn, error: _askError, onSignIn: _signIn, onClose: _close),
        ),
        CornerCard(
          visible: _visible && shown != null,
          child: shown == null
              ? const SizedBox.shrink()
              : MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => setState(() => _visible = false),
                    child: _Card(incoming: shown),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.incoming});

  final Incoming incoming;

  /// The other computer's name, unless it's the same as this one's (two
  /// installs of the same setup), when it can't tell them apart.
  static String _from(Set<String> names) {
    final others = names.where((n) => n != Platform.localHostname).toList();
    return others.length == 1 && names.length == 1 ? curlyQuotes(others.first) : 'your other computer';
  }

  static String _day(String key) {
    final d = DateTime.parse(key);
    return '${d.day} ${monthNames[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final n = incoming.changes;
    final kept = incoming.keptBoth.toList()..sort();
    final detail = kept.isEmpty
        ? '$n ${n == 1 ? 'change' : 'changes'} brought in.'
        : 'Both computers wrote in the journal for ${kept.map(_day).join(', ')}, so both are kept, '
              'one after the other.';

    return Container(
      width: cornerCardWidth,
      padding: const EdgeInsets.fromLTRB(18, 16, 20, 16),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(shape: BoxShape.circle, color: p.done.withValues(alpha: 0.16)),
            child: Icon(Icons.sync_rounded, size: 16, color: p.done),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Updated from ${_from(incoming.from)}',
                  style: TextStyle(
                    fontFamily: Fonts.display,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.4, color: p.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks to sign in again, so the journal can go to Drive too.
class _AskCard extends StatelessWidget {
  const _AskCard({required this.signingIn, required this.error, required this.onSignIn, required this.onClose});

  final bool signingIn;
  final String? error;
  final VoidCallback onSignIn, onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: cornerCardWidth,
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              'Keep your journal in Drive',
              style: TextStyle(
                fontFamily: Fonts.display,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: p.ink,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              signingIn
                  ? 'Finish signing in in your browser, then come back here.'
                  : (error == null ? null : curlyQuotes(error!)) ??
                        'Sign in again to keep your journal in an Eclipse Journals folder in your Drive.',
              style: TextStyle(
                fontFamily: Fonts.body,
                fontSize: 14,
                height: 1.4,
                color: error != null && !signingIn ? p.missed : p.inkMuted,
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: onClose,
                  child: Text(signingIn ? 'Cancel' : 'Not now', style: TextStyle(color: p.inkMuted)),
                ),
                if (!signingIn)
                  TextButton(
                    onPressed: onSignIn,
                    child: Text('Sign in again', style: TextStyle(color: p.accent)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Says some changes from another computer are waiting: they need a newer
/// version of Eclipse, or their files couldn't be read here.
class _WaitingCard extends StatelessWidget {
  const _WaitingCard({required this.newerFrom, required this.unreadFrom, required this.onClose});

  final Set<String> newerFrom, unreadFrom;
  final VoidCallback onClose;

  /// "Laptop", "Laptop and PC", "Laptop, PC and Mac".
  static String names(Set<String> names) {
    final list = [for (final n in names) curlyQuotes(n)]..sort();
    return list.length == 1 ? list.single : '${list.sublist(0, list.length - 1).join(', ')} and ${list.last}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final newer = newerFrom.isNotEmpty, unread = unreadFrom.isNotEmpty;
    final title = newer && unread
        ? 'Some changes are waiting'
        : newer
        ? 'Some changes need an update'
        : 'Some changes couldn’t be read';
    final body = TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.4, color: p.inkMuted);
    return Container(
      width: cornerCardWidth,
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              title,
              style: TextStyle(
                fontFamily: Fonts.display,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: p.ink,
              ),
            ),
          ),
          if (newer) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Some changes from ${names(newerFrom)} need a newer version of Eclipse. '
                'They come in once you update.',
                style: body,
              ),
            ),
          ],
          if (unread) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Some changes from ${names(unreadFrom)} couldn’t be read, so they’re waiting. '
                'Your own changes still go to your other computers.',
                style: body,
              ),
            ),
          ],
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: onClose,
                  child: Text('Not now', style: TextStyle(color: p.inkMuted)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
