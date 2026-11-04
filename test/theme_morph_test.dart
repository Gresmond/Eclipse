import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/tile.dart';

void main() {
  // A widget that eases its own colours used to chase the fading theme and
  // land at the very end; now it tracks the theme frame by frame.
  testWidgets('a status pill changes colour with the theme, not after it', (tester) async {
    final name = ValueNotifier(palettes.first.name);
    await tester.pumpWidget(
      ValueListenableBuilder<String>(
        valueListenable: name,
        builder: (context, themeName, _) => MaterialApp(
          theme: themeNamed(themeName),
          themeAnimationDuration: Motion.morph,
          themeAnimationCurve: Motion.morphCurve,
          builder: (context, child) => ThemeMorph(target: paletteNamed(themeName), child: child!),
          home: const Scaffold(
            body: Center(child: StatusPill(label: '3 open')),
          ),
        ),
      ),
    );
    final to = palettes.firstWhere((p) => p.brightness != palettes.first.brightness);
    name.value = to.name;
    await tester.pump();

    for (final ms in [60, 60, 60]) {
      await tester.pump(Duration(milliseconds: ms));
      final live = Theme.of(tester.element(find.byType(StatusPill))).extension<Palette>()!;
      expect(ThemeMorph.active(tester.element(find.byType(StatusPill))), isTrue);
      final container = tester.renderObject<RenderDecoratedBox>(
        find.descendant(of: find.byType(AnimatedContainer), matching: find.byType(DecoratedBox)),
      );
      expect((container.decoration as BoxDecoration).color, live.empty.withValues(alpha: 0.6));
    }
    await tester.pumpAndSettle();
    expect(ThemeMorph.active(tester.element(find.byType(StatusPill))), isFalse);
  });
}
