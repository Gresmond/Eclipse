import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:eclipse/data/dev_install.dart';
import 'package:eclipse/data/updates.dart';
import 'package:eclipse/screens/startup_error.dart';

void main() {
  test('flutter run builds are found in their source folder; installed copies are not', () {
    final repo = Directory.systemTemp.createTempSync('eclipse-repo');
    addTearDown(() => repo.deleteSync(recursive: true));
    File(p.join(repo.path, 'linux', 'install.sh')).createSync(recursive: true);
    final bundle = Directory(p.join(repo.path, 'build', 'linux', 'x64', 'release', 'bundle'))
      ..createSync(recursive: true);
    final executable = p.join(bundle.path, 'eclipse');

    expect(sourceRepoOf(executable), repo.path);
    expect(sourceRepoOf(p.join(repo.path, 'eclipse')), isNull, reason: 'not inside build/');
    File(p.join(bundle.path, 'build-info')).writeAsStringSync('repo=${repo.path}\n');
    expect(sourceRepoOf(executable), isNull, reason: 'installed by the script');
  });

  test('an installed copy is behind when it records an older format, or none', () {
    expect(installedSchemaIsBehind('repo=/r\ncommit=abc\nschema=15\n', 16), isTrue);
    expect(installedSchemaIsBehind('repo=/r\ncommit=abc\nschema=16\n', 16), isFalse);
    expect(installedSchemaIsBehind('repo=/r\ncommit=abc\n', 16), isTrue);
  });

  testWidgets('data from a newer build explains itself and offers the rebuild', (tester) async {
    final updater = GitUpdater(repo: '/repo', installedCommit: 'abc', executable: '/repo/eclipse');
    await tester.pumpWidget(
      StartupErrorApp(error: StateError('This database needs a newer version of Eclipse'), updater: updater),
    );
    expect(find.text('This copy of Eclipse is older than your data'), findsOneWidget);
    expect(find.text(updater.actionLabel), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    for (final label in [updater.actionLabel, 'Quit']) {
      await mouse.moveTo(tester.getCenter(find.text(label)));
      await tester.pump();
      expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click, reason: label);
    }
  });

  testWidgets('other failures show the error', (tester) async {
    await tester.pumpWidget(StartupErrorApp(error: const FileSystemException('Disk is full')));
    expect(find.text('Eclipse couldn\'t open your data'), findsOneWidget);
    expect(find.textContaining('Disk is full'), findsOneWidget);
    expect(find.text('Quit'), findsOneWidget);
  });
}
