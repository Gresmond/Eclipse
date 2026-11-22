import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'corner_card.dart';
import 'hover_fill.dart';
import '../theme/pixels.dart';

/// A card in the bottom-right corner for each reminder that goes off while
/// the window is open, newest at the bottom. Each stays up as long as the
/// undo card does (the pointer on it holds it), or until its cross; a click
/// on it opens the task.
class ReminderCards extends StatefulWidget {
  const ReminderCards({super.key});

  @override
  State<ReminderCards> createState() => _ReminderCardsState();
}

class _ReminderCardsState extends State<ReminderCards> {
  /// Each card's timer, while it runs: none while the pointer holds it.
  final _timers = <String, Timer>{};
  final _hideTimers = <String, Timer>{};

  /// Those going, still drawn while they slide away.
  final _leaving = <String>{};

  /// The cards drawn, in order, kept as they leave.
  final _drawn = <ReminderAlert>[];

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    for (final timer in _hideTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _time(AppState state, ReminderAlert alert) {
    _timers.remove(alert.key)?.cancel();
    _timers[alert.key] = Timer(Motion.notice, () {
      if (mounted) _hide(state, alert);
    });
  }

  /// Slides [alert] away, then lets it go.
  void _hide(AppState state, ReminderAlert alert) {
    _timers.remove(alert.key)?.cancel();
    if (!mounted || !_leaving.add(alert.key)) return;
    setState(() {});
    _hideTimers.remove(alert.key)?.cancel();
    _hideTimers[alert.key] = Timer(Motion.morph, () {
      _hideTimers.remove(alert.key);
      if (!mounted) return;
      state.hideReminderCard(alert);
      setState(() {
        _leaving.remove(alert.key);
        _drawn.removeWhere((a) => a.key == alert.key);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => Object.hashAll([for (final a in s.reminderCards) (a.key, a.text)]));
    for (final alert in state.reminderCards) {
      final index = _drawn.indexWhere((a) => a.key == alert.key);
      if (index < 0) {
        _drawn.add(alert);
        _time(state, alert);
      } else if (_drawn[index].text != alert.text) {
        _drawn[index] = alert;
      }
    }
    // Opened from the system's notification, or gone another way.
    final activeKeys = {for (final a in state.reminderCards) a.key};
    for (final alert in [..._drawn]) {
      if (!activeKeys.contains(alert.key) && !_leaving.contains(alert.key)) {
        _timers.remove(alert.key)?.cancel();
        _drawn.remove(alert);
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final alert in _drawn)
          CornerCard(
            key: ValueKey(alert.key),
            visible: !_leaving.contains(alert.key),
            child: _Card(
              alert: alert,
              now: state.reminderNow,
              startHour: state.dayStartHour,
              onOpen: () {
                _hide(state, alert);
                state.openReminder(alert.uid);
              },
              onClose: () => _hide(state, alert),
              onHover: (held) {
                if (held) {
                  _timers.remove(alert.key)?.cancel();
                } else if (!_leaving.contains(alert.key)) {
                  _time(state, alert);
                }
              },
            ),
          ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.alert,
    required this.now,
    required this.startHour,
    required this.onOpen,
    required this.onClose,
    required this.onHover,
  });

  final ReminderAlert alert;
  final DateTime now;
  final int startHour;
  final VoidCallback onOpen, onClose;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: Hoverable(
        focusable: true,
        semanticLabel: '${curlyQuotes(alert.text)}, ${alert.body(now, startHour: startHour)}',
        onTap: onOpen,
        builder: (hover) => Container(
          width: cornerCardMaxWidth(context),
          padding: const EdgeInsets.fromLTRB(18, 16, 10, 16),
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
                child: Icon(
                  alert.birthday ? Icons.cake_rounded : Icons.notifications_rounded,
                  size: 16,
                  color: briefBadgeInk(p),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      curlyQuotes(alert.text),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: cornerCardTitle(p.ink),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      alert.body(now, startHour: startHour),
                      style: TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.4, color: p.inkMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              PixelTooltip(
                message: 'Dismiss',
                child: IconButton(
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close_rounded, size: Scale.dismissIcon, color: p.inkMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
