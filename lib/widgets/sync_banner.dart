import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/sync.dart';
import '../data/sync_service.dart';
import '../models.dart';
import '../theme/app_theme.dart';

/// A card that floats up over the bottom-right corner for a few seconds
/// when changes come in from another computer, saying where from.
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

  void _changed() {
    if (widget.sync.incomingCount == _seen) return;
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
    if (!_visible) return const SizedBox.shrink();
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
    return others.length == 1 && names.length == 1 ? others.first : 'your other computer';
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
