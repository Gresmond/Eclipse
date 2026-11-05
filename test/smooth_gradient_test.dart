import 'package:eclipse/widgets/smooth_gradient.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gradient = LinearGradient(colors: [Color(0xFF112233), Color(0xFF445566)]);

  test('stays smooth while animating, including to and from no gradient', () {
    const a = SmoothGradientDecoration(gradient: gradient, borderRadius: BorderRadius.all(Radius.circular(8)));
    const b = SmoothGradientDecoration(border: Border.fromBorderSide(BorderSide()));
    expect(Decoration.lerp(a, b, 0.5), isA<SmoothGradientDecoration>());
    expect(Decoration.lerp(b, a, 0.5), isA<SmoothGradientDecoration>());
  });

  testWidgets('paints a gradient as a masked layer, and a flat one directly', (tester) async {
    Future<void> pump(Gradient g) => tester.pumpWidget(
      Center(
        child: SizedBox.square(
          dimension: 40,
          child: DecoratedBox(
            decoration: SmoothGradientDecoration(
              gradient: g,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF000000)),
            ),
          ),
        ),
      ),
    );
    await pump(gradient);
    final box = find.byType(DecoratedBox);
    expect(box, paints..rrect(color: const Color(0xFFFFFFFF))..rect());
    await pump(const LinearGradient(colors: [Color(0xFF112233), Color(0xFF112233)]));
    expect(box, paints..rrect(color: const Color(0xFF112233)));
  });
}
