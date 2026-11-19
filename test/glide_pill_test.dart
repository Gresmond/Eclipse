import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/fold.dart';
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

  testWidgets('SegmentedPills handles single, multi, expanded, and compact modes', (tester) async {
    var selected = 0;
    final chosen = <int>{0};
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(palettes.first),
        builder: (context, child) => ThemeMorph(target: palettes.first, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 300,
                  child: SegmentedPills(
                    labels: const ['General', 'Data'],
                    selected: selected,
                    expand: true,
                    onSelect: (i) => setState(() => selected = i),
                  ),
                ),
                SegmentedPills(
                  labels: const ['1M', '3M', 'All'],
                  selected: selected,
                  compact: true,
                  onSelect: (i) => setState(() => selected = i),
                ),
                SegmentedPills(
                  labels: const ['Mon', 'Tue', 'Wed'],
                  chosen: chosen,
                  onSelect: (i) => setState(() => chosen.contains(i) ? chosen.remove(i) : chosen.add(i)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.widgetWithText(SegmentedPills, 'General')).width, 300);
    await tester.tap(find.text('Data'));
    await tester.pumpAndSettle();
    expect(selected, 1);

    await tester.tap(find.text('Wed'));
    await tester.pumpAndSettle();
    expect(chosen, {0, 2});
  });

  testWidgets('Fold unmounts closed children when configured and snaps with reduced motion', (tester) async {
    Widget host(bool open, {Axis axis = Axis.vertical, bool removeWhenClosed = false, bool disableAnimations = false}) {
      return MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Fold(
              open: open,
              axis: axis,
              removeWhenClosed: removeWhenClosed,
              child: const SizedBox(width: 80, height: 40, child: Text('Inside')),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(host(false, axis: Axis.horizontal, removeWhenClosed: true));
    expect(find.text('Inside'), findsNothing);

    await tester.pumpWidget(host(true, axis: Axis.horizontal, removeWhenClosed: true));
    await tester.pumpAndSettle();
    expect(find.text('Inside'), findsOneWidget);
    expect(tester.getSize(find.text('Inside')).width, 80);

    await tester.pumpWidget(host(false, axis: Axis.horizontal, removeWhenClosed: true));
    await tester.pumpAndSettle();
    expect(find.text('Inside'), findsNothing);

    await tester.pumpWidget(host(true, disableAnimations: true));
    await tester.pump();
    expect(tester.getSize(find.byType(Fold)).height, 40);
    await tester.pumpWidget(host(false, disableAnimations: true));
    await tester.pump();
    expect(tester.getSize(find.byType(Fold)).height, 0);
  });
}
