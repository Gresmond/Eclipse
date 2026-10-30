import 'package:flutter/material.dart';

import '../data/updates.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import 'corner_card.dart';
import 'fade_through.dart';

/// A small card floating over the bottom-right corner when a newer version
/// is out, naming it: one click updates and reopens source/Linux installs, or
/// opens the Mac/Windows download. It floats rather than
/// taking space, so the Today view keeps fitting the window.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updater});

  final Updater updater;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updater,
    builder: (context, _) => CornerCard(
      visible: updater.status != UpdateStatus.none,
      child: _Card(updater: updater, status: updater.status),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.updater, required this.status});

  final Updater updater;
  final UpdateStatus status;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    final (String title, String? detail) = switch (status) {
      UpdateStatus.available ||
      UpdateStatus.none => ('A new version is available', updater.newVersion == null ? null : 'v${updater.newVersion}'),
      UpdateStatus.updating => ('Updating Eclipse', updater.progressDetail),
      UpdateStatus.failed => ('Couldn’t update', updater.error),
      UpdateStatus.restarting => ('Reopening…', null),
    };

    final body = Column(
      key: ValueKey(status),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: 16.5,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: p.ink,
          ),
        ),
        if (detail != null && detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            curlyQuotes(detail),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: Fonts.body, fontSize: 13.5, height: 1.4, color: p.inkMuted),
          ),
        ],
        if (status == UpdateStatus.updating || status == UpdateStatus.restarting) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(minHeight: 3, color: p.done, backgroundColor: p.empty),
          ),
        ],
        if (status == UpdateStatus.available || status == UpdateStatus.failed) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              CornerButton(
                label: status == UpdateStatus.failed ? 'Try again' : updater.actionLabel,
                filled: true,
                onTap: updater.update,
              ),
              const SizedBox(width: 8),
              CornerButton(label: 'Later', onTap: updater.dismiss),
            ],
          ),
        ],
      ],
    );

    return Container(
      width: 360,
      padding: const EdgeInsets.fromLTRB(18, 16, 20, 16),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.9)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Mark(palette: p),
          const SizedBox(width: 14),
          Expanded(
            child: AnimatedSize(
              duration: Motion.morph,
              curve: Motion.morphCurve,
              alignment: Alignment.topLeft,
              child: FadeThrough(duration: Motion.morph, layoutBuilder: FadeThrough.sizeToCurrent, child: body),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tiny eclipse in the theme's gradient: a ring of colour round a dark disc.
class _Mark extends StatelessWidget {
  const _Mark({required this.palette});

  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: SweepGradient(colors: [...palette.gradient, palette.gradient.first]),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: palette.tile),
      ),
    );
  }
}
