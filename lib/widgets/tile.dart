import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'fade_through.dart';
import 'rolling_number.dart';

/// Identical hit target, icon and hover pill for card-header actions.
class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({super.key, required this.icon, required this.onPressed, this.tooltip});

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      padding: EdgeInsets.zero,
      style: ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const WidgetStatePropertyAll(Size.square(28)),
        maximumSize: const WidgetStatePropertyAll(Size.square(28)),
        shape: const WidgetStatePropertyAll(CircleBorder()),
        foregroundColor: WidgetStatePropertyAll(p.inkMuted.withValues(alpha: 0.8)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? p.empty.withValues(alpha: 0.8) : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      icon: Icon(icon, size: 16),
    );
  }
}

/// Shared status pills grow with their label instead of squeezing large counts.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, this.complete = false});

  final String label;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedContainer(
      duration: Motion.morph,
      curve: Motion.morphCurve,
      constraints: const BoxConstraints(minWidth: 76, minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: complete ? Color.lerp(p.tile, p.done, 0.16) : p.empty.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.borderSoft),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: _CaptionSwap(
          caption: label.toUpperCase(),
          style: TextStyle(
            fontFamily: Fonts.ui,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: Scale.capsSpacing,
            color: complete ? p.ink : p.inkMuted,
          ),
        ),
      ),
    );
  }
}

/// The base card surface every panel sits on.
class Tile extends StatelessWidget {
  const Tile({super.key, required this.child, this.padding = const EdgeInsets.all(24)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isDark = p.brightness == Brightness.dark;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [p.tile, isDark ? p.tile : Color.lerp(p.tile, p.background, 0.14)!],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.border, width: 1.0),
      ),
      child: child,
    );
  }
}

/// Card heading with an optional small caption on the right.
class TileHeader extends StatelessWidget {
  const TileHeader({
    super.key,
    required this.title,
    this.caption,
    this.badge,
    this.trailing,
    this.trailingAtEnd = false,
  });

  final String title;
  final String? caption;
  final Widget? badge;
  final Widget? trailing;

  /// Puts [trailing] at the far right, so it stays put however long the
  /// title is.
  final bool trailingAtEnd;

  static const _titleStyle = TextStyle(
    fontFamily: Fonts.display,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.2,
  );

  /// The title-only header's actual height, including font metric rounding.
  /// Used to align card contents even when text is enlarged.
  static double titleHeight(BuildContext context, String title) {
    final painter = TextPainter(
      text: TextSpan(text: title, style: _titleStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height < 30 ? 30 : height;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lead = [
      Flexible(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _titleStyle.copyWith(color: p.ink),
        ),
      ),
      if (caption != null || badge != null || (trailing != null && !trailingAtEnd)) const SizedBox(width: 8),
      ?badge,
      if (caption != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: p.empty.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.borderSoft),
          ),
          child: _CaptionSwap(caption: caption!),
        ),
    ];
    // Every header is as tall as one with a button, so its title sits the same
    // distance from the card's corner whatever else is in the row.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 30),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (trailingAtEnd) Expanded(child: Row(children: lead)) else ...lead,
          ?trailing,
        ],
      ),
    );
  }
}

/// A caption split into its leading count, if any, and the word after it.
class _CaptionParts {
  factory _CaptionParts(String caption) {
    final match = RegExp(r'^(\d+) (.+)$').firstMatch(caption);
    return match == null
        ? _CaptionParts._(null, caption.toUpperCase())
        : _CaptionParts._(int.parse(match[1]!), match[2]!.toUpperCase());
  }
  const _CaptionParts._(this.count, this.word);

  final int? count;
  final String word;
}

TextStyle _captionStyle(BuildContext context) => TextStyle(
  fontFamily: Fonts.ui,
  fontSize: 12,
  letterSpacing: 1.2,
  fontWeight: FontWeight.w600,
  color: context.palette.inkMuted,
);

class _Caption extends StatelessWidget {
  const _Caption({super.key, required this.caption, this.style});

  final String caption;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final parts = _CaptionParts(caption);
    final style = this.style ?? _captionStyle(context);
    final count = parts.count;
    if (count == null) {
      return Text(parts.word, textAlign: TextAlign.center, style: style);
    }
    return Semantics(
      label: caption.toUpperCase(),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RollingNumber(value: count, style: style),
          Text(' ${parts.word}', style: style),
        ],
      ),
    );
  }
}

/// The badge's caption, which the badge fits snugly. A new count rolls just
/// its digits, the badge widening or narrowing in step with them; a new
/// word fades the old one out before the new one fades in, the badge
/// easing to its width.
class _CaptionSwap extends StatelessWidget {
  const _CaptionSwap({required this.caption, this.style});

  final String caption;
  final TextStyle? style;

  /// The caption's width once settled, measured as [_Caption] lays it out.
  double _width(BuildContext context) {
    final parts = _CaptionParts(caption);
    final style = this.style ?? _captionStyle(context);
    final painter = TextPainter(
      text: TextSpan(
        children: [
          if (parts.count case final count?)
            TextSpan(
              text: '$count ',
              style: style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          TextSpan(text: parts.word, style: style),
        ],
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    // The same timing and curve as the rolling digits' slots, so the badge
    // keeps its padding exactly as they widen or narrow.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _width(context)),
      duration: Motion.morph,
      curve: Motion.morphCurve,
      builder: (context, width, child) => SizedBox(width: width, child: child),
      child: OverflowBox(
        minWidth: 0,
        maxWidth: double.infinity,
        fit: OverflowBoxFit.deferToChild,
        child: FadeThrough(
          duration: Motion.morph,
          child: _Caption(key: ValueKey(_CaptionParts(caption).word), caption: caption, style: style),
        ),
      ),
    );
  }
}
