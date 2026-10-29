import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/progress_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rings reveal a fixed gradient with matching rounded tips in every theme', (tester) async {
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(family['family'] as String);
      for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    await tester.binding.setSurfaceSize(Size(900, palettes.length * 90.0));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              for (final palette in palettes)
                Theme(
                  data: buildTheme(palette),
                  child: ColoredBox(
                    color: palette.tile,
                    child: Row(
                      children: [
                        for (var done = 0; done <= 8; done++)
                          SizedBox(
                            width: 100,
                            height: 90,
                            child: Center(
                              child: DefaultTextStyle(
                                style: const TextStyle(fontFamily: Fonts.body),
                                child: ProgressRing(
                                  key: ValueKey('${palette.name}/$done'),
                                  done: done,
                                  total: 8,
                                  size: 60,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;

    Color pixel(Offset position) {
      final offset = (position.dy.floor() * image.width + position.dx.floor()) * 4;
      return Color.fromARGB(255, bytes.getUint8(offset), bytes.getUint8(offset + 1), bytes.getUint8(offset + 2));
    }

    void expectColour(Color actual, Color expected) {
      for (final channel in [(actual.r, expected.r), (actual.g, expected.g), (actual.b, expected.b)]) {
        expect(channel.$1, closeTo(channel.$2, 0.04));
      }
    }

    for (final palette in palettes) {
      Offset point(int done, double fraction) {
        final center = tester.getCenter(find.byKey(ValueKey('${palette.name}/$done')));
        final angle = -math.pi / 2 + math.pi * 2 * fraction;
        return center + Offset(math.cos(angle), math.sin(angle)) * 24.5;
      }

      // At 1/8 the tip is still near the first colour, never the final one.
      expectColour(pixel(point(1, 1 / 8)), Color.lerp(palette.gradient[0], palette.gradient[1], 1 / 4)!);
      // The same position keeps its colour as the arc grows.
      expectColour(pixel(point(1, 1 / 16)), pixel(point(6, 1 / 16)));
      expectColour(pixel(point(0, 1 / 8)), palette.empty);
      expectColour(pixel(point(8, 1 / 8)), palette.gradient.last);
    }

    image.dispose();
  });
}
