import 'package:eclipse/widgets/glide_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('glides from the frame the selection changes, and follows a tab that moves', (tester) async {
    final keys = [GlobalKey(), GlobalKey()];
    Widget bar(int selected, {double gap = 100}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: GlidePill(
          target: keys[selected],
          color: const Color(0xFF000000),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(key: keys[0], width: 50, height: 20),
              SizedBox(width: gap),
              SizedBox(key: keys[1], width: 70, height: 20),
            ],
          ),
        ),
      ),
    );
    RenderGlidePill pill() => tester.renderObject<RenderGlidePill>(find.byType(GlidePill));

    await tester.pumpWidget(bar(0));
    expect(pill().pill, const Rect.fromLTWH(0, 0, 50, 20));

    await tester.pumpWidget(bar(1));
    expect(pill().pill!.left, 0, reason: 'the click frame shows it where it was');
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));
    final moving = pill().pill!;
    expect(moving.left, inExclusiveRange(0, 150));
    expect(moving.width, inExclusiveRange(50, 70));

    await tester.pumpAndSettle();
    expect(pill().pill, const Rect.fromLTWH(150, 0, 70, 20));

    // A resize just follows along, without a glide.
    await tester.pumpWidget(bar(1, gap: 60));
    expect(pill().pill, const Rect.fromLTWH(110, 0, 70, 20));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
