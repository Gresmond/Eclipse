import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/main.dart';
import 'package:eclipse/models.dart';

const _dir = String.fromEnvironment('SCREENSHOT_DIR');

var _loaded = false;
Future<void> _fonts() async {
  if (_loaded) return;
  _loaded = true;
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  final icons = File('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())))).load();
}

Future<void> _shoot(WidgetTester tester, String name) async {
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(Offset.zero & view.size, pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  for (final (name, early, year) in [('left_arrow', true, 2026), ('both_arrows', true, 2025)]) {
    testWidgets(name, (tester) async {
      await _fonts();
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      final store = Store.memory();
      if (early) {
        final h = store.addHabit(2025, 1, 'Read');
        store.setEntry('2025-01-05', h.id, HabitStatus.done);
      }
      final state = AppState(store, clock: () => DateTime(2026, 10, 28));
      await tester.pumpWidget(EclipseApp(state: state));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      if (year != 2026) {
        state.shiftYear(-1);
        for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      }
      final pill = find.ancestor(of: find.text('$year').last, matching: find.byType(Container)).first;
      print('$name year=${tester.getRect(pill)} settings=${tester.getRect(find.byTooltip('Settings'))}');
      await _shoot(tester, name);
    });
  }
}
