import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/sync.dart';
import '../data/sync_service.dart';
import '../models.dart';
import '../theme/app_theme.dart';

/// A card that floats up over the bottom-right corner for a few seconds
/// when changes come in from another computer, saying where from. While
/// the sign-in is from before the journal went to Drive, a card asking to
/// sign in again stays there instead, until done or closed.
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
    _hide = Timer(Duration(seconds: incoming.keptBoth.isEmpty ? 6 : 12), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (!_visible) {
      if (_askClosed || !widget.sync.needsJournalSignIn) return const SizedBox.shrink();
      return _AskCard(signingIn: _signingIn, error: _askError, onSignIn: _signIn, onClose: _close);
    }
    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : const Offset(0, 0.35),
        duration: Motion.morph,
        curve: Motion.morphCurve,
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: Motion.morph,
          curve: Motion.morphCurve,
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
      ),
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
      width: 340,
      padding: const EdgeInsets.fromLTRB(18, 16, 20, 16),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.9)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(shape: BoxShape.circle, color: p.done.withValues(alpha: 0.16)),
            child: Icon(Icons.sync_rounded, size: 17, color: p.done),
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
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 12.5, height: 1.4, color: p.inkMuted),
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
      width: 340,
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.9)),
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
                fontSize: 15.5,
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
                fontSize: 12.5,
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
