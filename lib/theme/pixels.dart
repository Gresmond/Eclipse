import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

double get _scale => WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;

/// [logical] on the nearest whole pixel of the screen. A straight edge off the
/// pixel grid blurs across two rows, which shows as a faint line beside it.
double pixelRound(double logical) => (logical * _scale).roundToDouble() / _scale;

/// [logical] on the whole pixel at or above it.
double pixelCeil(double logical) => (logical * _scale - 0.001).ceilToDouble() / _scale;

/// The centre, on the nearest whole pixel. With an odd amount of room to
/// spare, plain centring leaves what it holds on half a pixel.
class PixelCentre extends Alignment {
  const PixelCentre() : super(0, 0);

  @override
  Offset alongOffset(Offset other) => Offset(pixelRound(other.dx / 2), pixelRound(other.dy / 2));
}

/// A [Row] that leaves its children on whole pixels: [Expanded] children's
/// shares end on them too, and what follows text of any width or is centred
/// against a taller neighbour starts on one.
class PixelRow extends Row {
  const PixelRow({
    super.key,
    super.mainAxisAlignment,
    super.mainAxisSize,
    super.crossAxisAlignment,
    super.textDirection,
    super.verticalDirection,
    super.textBaseline,
    super.spacing,
    super.children,
  });

  @override
  RenderFlex createRenderObject(BuildContext context) => _RenderPixelFlex(
    direction: direction,
    mainAxisAlignment: mainAxisAlignment,
    mainAxisSize: mainAxisSize,
    crossAxisAlignment: crossAxisAlignment,
    textDirection: getEffectiveTextDirection(context),
    verticalDirection: verticalDirection,
    textBaseline: textBaseline,
    clipBehavior: clipBehavior,
    spacing: spacing,
  );
}

/// The [Column] to [PixelRow]'s [Row].
class PixelColumn extends Column {
  const PixelColumn({
    super.key,
    super.mainAxisAlignment,
    super.mainAxisSize,
    super.crossAxisAlignment,
    super.textDirection,
    super.verticalDirection,
    super.textBaseline,
    super.spacing,
    super.children,
  });

  @override
  RenderFlex createRenderObject(BuildContext context) => _RenderPixelFlex(
    direction: direction,
    mainAxisAlignment: mainAxisAlignment,
    mainAxisSize: mainAxisSize,
    crossAxisAlignment: crossAxisAlignment,
    textDirection: getEffectiveTextDirection(context),
    verticalDirection: verticalDirection,
    textBaseline: textBaseline,
    clipBehavior: clipBehavior,
    spacing: spacing,
  );
}

class _RenderPixelFlex extends RenderFlex {
  _RenderPixelFlex({
    super.direction,
    super.mainAxisAlignment,
    super.mainAxisSize,
    super.crossAxisAlignment,
    super.textDirection,
    super.verticalDirection,
    super.textBaseline,
    super.clipBehavior,
    super.spacing,
  });

  @override
  void performLayout() {
    super.performLayout();
    final across = direction == Axis.horizontal;
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as FlexParentData;
      final start = data.offset;
      final snapped = Offset(pixelRound(start.dx), pixelRound(start.dy));
      if ((data.flex ?? 0) > 0 && data.fit != FlexFit.loose) {
        final extent = across
            ? pixelRound(start.dx + child.size.width) - snapped.dx
            : pixelRound(start.dy + child.size.height) - snapped.dy;
        if (extent != (across ? child.size.width : child.size.height)) {
          child.layout(
            across
                ? child.constraints.copyWith(minWidth: extent, maxWidth: extent)
                : child.constraints.copyWith(minHeight: extent, maxHeight: extent),
            parentUsesSize: true,
          );
        }
      }
      data.offset = snapped;
      child = data.nextSibling;
    }
  }
}

/// [child], in a box grown to whole pixels: text comes in any width, and a pill
/// or button fitted to it would end part way across a pixel.
class PixelFit extends SingleChildRenderObjectWidget {
  const PixelFit({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPixelFit();
}

class _RenderPixelFit extends RenderShiftedBox {
  _RenderPixelFit() : super(null);

  Size _fit(Size size) => constraints.constrain(Size(pixelCeil(size.width), pixelCeil(size.height)));

  @override
  double computeMinIntrinsicWidth(double height) => pixelCeil(super.computeMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) => pixelCeil(super.computeMaxIntrinsicWidth(height));

  @override
  double computeMinIntrinsicHeight(double width) => pixelCeil(super.computeMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) => pixelCeil(super.computeMaxIntrinsicHeight(width));

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final size = child!.getDryLayout(constraints);
    return constraints.constrain(Size(pixelCeil(size.width), pixelCeil(size.height)));
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = _fit(child.size);
    // The extra goes equally either side, so text stays centred in a button.
    (child.parentData! as BoxParentData).offset = Offset(
      (size.width - child.size.width) / 2,
      (size.height - child.size.height) / 2,
    );
  }
}

/// [logical] on the whole pixel at or below it.
double pixelFloor(double logical) => (logical * _scale + 0.001).floorToDouble() / _scale;

/// A [Tooltip] on whole pixels: Flutter's fits its box to the text, however
/// wide that comes out, and centres it under what it's for.
class PixelTooltip extends Tooltip {
  const PixelTooltip({super.key, required String super.message, super.child});

  @override
  State<Tooltip> createState() => _PixelTooltipState();
}

class _PixelTooltipState extends State<Tooltip> {
  @override
  Widget build(BuildContext context) {
    final message = widget.message!;
    final child = widget.child ?? const SizedBox.shrink();
    if (message.isEmpty || !TooltipVisibility.of(context)) return child;
    final theme = TooltipTheme.of(context);
    final box = ConstrainedBox(
      constraints: theme.constraints ?? const BoxConstraints(minHeight: 24),
      child: Container(
        decoration: theme.decoration,
        padding: theme.padding,
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: PixelFit(
            child: Text(message, style: theme.textStyle, textAlign: theme.textAlign),
          ),
        ),
      ),
    );
    return RawTooltip(
      semanticsTooltip: message,
      tooltipBuilder: (context, animation) => FadeTransition(opacity: animation, child: box),
      hoverDelay: theme.waitDuration ?? Duration.zero,
      positionDelegate: (place) {
        final at = positionDependentBox(
          size: place.overlaySize,
          childSize: place.tooltipSize,
          target: place.target,
          verticalOffset: theme.verticalOffset ?? 24,
          preferBelow: theme.preferBelow ?? true,
        );
        return Offset(pixelRound(at.dx), pixelRound(at.dy));
      },
      ignorePointer: true,
      child: MouseRegion(cursor: MouseCursor.defer, child: child),
    );
  }
}
