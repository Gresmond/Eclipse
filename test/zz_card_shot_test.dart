import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/main.dart';

const _dir = String.fromEnvironment('SCREENSHOT_DIR');

Future<void> _fonts() async {
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

void main() {
  for (final (name, unread, newer) in [
    ('1_unread', {'Mac'}, <String>{}),
    ('2_newer', <String>{}, {'Laptop'}),
    ('3_both', {'Mac'}, {'Laptop'}),
  ]) {
    testWidgets(name, (tester) async {
      await _fonts();
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      final home = Directory.systemTemp.createTempSync('eclipse-shot');
      final store = Store.memory();
      final sync = SyncService.load(home, store)
        ..unreadFrom = unread
        ..newerFrom = newer;
      final state = AppState(store, sync: sync, clock: () => DateTime(2026, 10, 28, 10));
      await tester.pumpWidget(EclipseApp(state: state));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final view = tester.binding.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      await tester.runAsync(() async {
        final image = await layer.toImage(Offset.zero & view.size, pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$_dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox.shrink());
      sync.dispose();
    });
  }
}
