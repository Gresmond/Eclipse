import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'corner_card.dart';
import 'hover_fill.dart';

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
  final _timers = <ReminderAlert, Timer>{};

  /// Those going, still drawn while they slide away.
  final _leaving = <ReminderAlert>{};

  /// The cards drawn, in order, kept as they leave.
  final _drawn = <ReminderAlert>[];

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _time(AppState state, ReminderAlert alert) {
    _timers.remove(alert)?.cancel();
    _timers[alert] = Timer(Motion.notice, () => _hide(state, alert));
  }

  /// Slides [alert] away, then lets it go.
  void _hide(AppState state, ReminderAlert alert) {
    _timers.remove(alert)?.cancel();
    if (!mounted || !_leaving.add(alert)) return;
    setState(() {});
    Timer(Motion.morph, () {
      if (!mounted) return;
      state.hideReminderCard(alert);
      setState(() {
        _leaving.remove(alert);
        _drawn.remove(alert);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => Object.hashAll(s.reminderCards));
    for (final alert in state.reminderCards) {
      if (!_drawn.contains(alert)) {
        _drawn.add(alert);
        _time(state, alert);
      }
    }
    // Opened from the system's notification, or gone another way.
    for (final alert in [..._drawn]) {
      if (!state.reminderCards.contains(alert) && !_leaving.contains(alert)) {
        _timers.remove(alert)?.cancel();
        _drawn.remove(alert);
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final alert in _drawn)
          CornerCard(
            key: ObjectKey(alert),
            visible: !_leaving.contains(alert),
            child: _Card(
              alert: alert,
              now: state.reminderNow,
              onOpen: () {
                _hide(state, alert);
                state.openReminder(alert.uid);
              },
              onClose: () => _hide(state, alert),
              onHover: (held) => held ? _timers.remove(alert)?.cancel() : _time(state, alert),
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
    required this.onOpen,
    required this.onClose,
    required this.onHover,
  });

  final ReminderAlert alert;
  final DateTime now;
  final VoidCallback onOpen, onClose;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: Hoverable(
        onTap: onOpen,
        builder: (hover) => Container(
          width: cornerCardWidth,
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
                  alert.birthday ? Icons.celebration_rounded : Icons.notifications_rounded,
                  size: 16,
                  color: p.done,
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
                      alert.body(now),
                      style: TextStyle(fontFamily: Fonts.body, fontSize: 14, height: 1.4, color: p.inkMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Dismiss',
                onPressed: onClose,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close_rounded, size: 18, color: p.inkMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
