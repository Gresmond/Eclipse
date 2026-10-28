import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/oklch.dart';

/// [category]'s colour in this theme: the categories evenly round the hue
/// circle from the accent's, at the accent's lightness, so they read like
/// it on a tile. A near-colourless theme still gets enough chroma to tell
/// them apart.
Color categoryColour(Palette p, TaskCategory category) {
  final accent = Oklch.of(p.accent);
  final hue = (accent.h + category.index * 360 / TaskCategory.values.length) % 360;
  final chroma = math.min(math.max(accent.c, 0.09), Oklch.maxChroma(accent.l, hue) * 0.85);
  return Oklch(accent.l, chroma, hue).toColor();
}

/// A task's category, as a small tinted label after its name.
class CategoryLabel extends StatelessWidget {
  const CategoryLabel(this.category, {super.key});

  final TaskCategory category;

  @override
  Widget build(BuildContext context) {
    final colour = categoryColour(context.palette, category);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: colour.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
      child: Text(
        category.label,
        maxLines: 1,
        style: TextStyle(fontFamily: Fonts.ui, fontSize: 10.5, fontWeight: FontWeight.w600, color: colour),
      ),
    );
  }
}

/// A pill for [category] that's lit while [selected]: for picking a task's
/// category, or filtering by them.
class CategoryChip extends StatefulWidget {
  const CategoryChip({super.key, required this.category, required this.selected, required this.onTap});

  final TaskCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<CategoryChip> createState() => _CategoryChipState();
}

class _CategoryChipState extends State<CategoryChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final colour = categoryColour(p, widget.category);
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: selected ? 0.2 : (_hover ? 0.08 : 0)),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? colour.withValues(alpha: 0.55) : p.tileBorder),
          ),
          child: AnimatedDefaultTextStyle(
            duration: Motion.hover,
            curve: Motion.hoverCurve,
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected || _hover ? colour : p.inkMuted,
            ),
            child: Text(widget.category.label),
          ),
        ),
      ),
    );
  }
}
