import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import '../theme/app_theme.dart';
import 'fade_through.dart';
import 'rolling_number.dart';

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
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.9), width: 1.0),
      ),
      child: child,
    );
  }
}

/// Card heading with an optional small caption on the right.
class TileHeader extends StatelessWidget {
  const TileHeader({super.key, required this.title, this.caption, this.trailing, this.trailingAtEnd = false});

  final String title;
  final String? caption;
  final Widget? trailing;

  /// Puts [trailing] at the far right, so it stays put however long the
  /// title is.
  final bool trailingAtEnd;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lead = [
      Flexible(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: 19,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
            color: p.ink,
            height: 1.2,
          ),
        ),
      ),
      if (caption != null || (trailing != null && !trailingAtEnd)) const SizedBox(width: 8),
      if (caption != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
          decoration: BoxDecoration(
            color: p.empty.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.tileBorder.withValues(alpha: 0.6), width: 0.8),
          ),
          child: _CaptionSwap(caption: caption!),
        ),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (trailingAtEnd) Expanded(child: Row(children: lead)) else ...lead,
        ?trailing,
      ],
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
  fontSize: 11.5,
  letterSpacing: 1.2,
  fontWeight: FontWeight.w600,
  color: context.palette.inkMuted,
);

class _Caption extends StatelessWidget {
  const _Caption({super.key, required this.caption});

  final String caption;

  @override
  Widget build(BuildContext context) {
    final parts = _CaptionParts(caption);
    final style = _captionStyle(context);
    final count = parts.count;
    if (count == null) return Text(parts.word, textAlign: TextAlign.center, style: style);
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
  const _CaptionSwap({required this.caption});

  final String caption;

  /// The caption's width once settled, measured as [_Caption] lays it out.
  double _width(BuildContext context) {
    final parts = _CaptionParts(caption);
    final style = _captionStyle(context);
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
          child: _Caption(key: ValueKey(_CaptionParts(caption).word), caption: caption),
        ),
      ),
    );
  }
}
