import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eclipse/data/updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('per-user Linux releases', () {
    late Directory temp;
    late String home;
    late String root;
    late String source;
    late List<int> bytes;
    late Map<String, dynamic> asset;
    late Map<String, dynamic> release;
    late List<String> commands;
    late int restarts;
    late bool closed;
    const url = 'https://github.com/Gresmond/Eclipse/releases/download/v26.10.1/Eclipse.tar.zst';

    Future<ProcessResult> run(String command, List<String> args, {Map<String, String>? environment}) =>
        Process.run(command, args, environment: {'HOME': home, 'XDG_DATA_HOME': '$home/.local/share', ...?environment});

    Future<void> archive({String version = '26.10.1', String build = '36'}) async {
      File('$source/bundle/version').writeAsStringSync('$version\n');
      File('$source/bundle/package-release').writeAsStringSync('$build\n');
      final result = await Process.run('tar', [
        '--zstd',
        '-cf',
        '${temp.path}/Eclipse.tar.zst',
        '-C',
        '${temp.path}/source',
        'Eclipse',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      bytes = File('${temp.path}/Eclipse.tar.zst').readAsBytesSync();
    }

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('linux-updater-');
      // Exercise shell arguments and desktop Exec escaping with an unusual home path.
      home = '${temp.path}/home space "\$`%\\';
      root = '$home/.local/opt/eclipse-release';
      Directory(root).createSync(recursive: true);
      source = '${temp.path}/source/Eclipse';
      Directory('$source/bundle').createSync(recursive: true);
      File('/bin/true').copySync('$source/bundle/eclipse');
      await Process.run('chmod', ['+x', '$source/bundle/eclipse']);
      File('linux/install-release.sh').copySync('$source/install.sh');
      File('design/icon/eclipse.svg').copySync('$source/eclipse.svg');
      await archive();
      asset = {'name': 'Eclipse.tar.zst', 'browser_download_url': url, 'digest': 'sha256:${sha256.convert(bytes)}'};
      release = {
        'tag_name': 'v26.10.1',
        'body': '<!-- eclipse-linux-build: 36 -->',
        'assets': [asset],
      };
      commands = [];
      restarts = 0;
      closed = false;
    });
    tearDown(() => temp.deleteSync(recursive: true));

    LinuxUpdater updater({ReleaseFetch? fetch, UpdateProcess? process, int installedRelease = 35}) => LinuxUpdater(
      '26.10.1',
      installRoot: root,
      installedRelease: installedRelease,
      fetch:
          fetch ?? (uri) async => uri.path.endsWith('/latest') ? (200, utf8.encode(jsonEncode(release))) : (200, bytes),
      runProcess:
          process ??
          (command, args) async {
            commands.add(command);
            return run(command, args);
          },
      onRestart: () async => closed = true,
      restart: ({required beforeRestart, executable}) async {
        expect(executable, '$root/current/eclipse');
        expect(Directory('$root/current').existsSync(), isTrue);
        expect(Directory(root).listSync().where((f) => p.basename(f.path).startsWith('.update-')), isEmpty);
        await beforeRestart();
        restarts++;
      },
    );

    test('verified rebuild installs without elevation, keeps the running copy, drops older ones and restarts after staging cleanup', () async {
      final old = Directory('$root/releases/old')..createSync(recursive: true);
      File('${old.path}/sentinel').writeAsStringSync('running copy');
      final older = Directory('$root/releases/older')..createSync(recursive: true);
      Link('$root/current').createSync(old.path);
      final u = updater();
      await u.check();
      expect(u.status, UpdateStatus.available);
      await u.update();
      expect(u.error, isNull);
      expect(u.status, UpdateStatus.restarting);
      expect(commands, ['tar', 'bash']);
      expect(closed, isTrue);
      expect(restarts, 1);
      expect(File('$root/current/package-release').readAsStringSync().trim(), '36');
      expect(File('$root/current/user-install-root').readAsStringSync().trim(), root);
      expect(File('${old.path}/sentinel').readAsStringSync(), 'running copy');
      expect(older.existsSync(), isFalse, reason: 'releases before the running one are removed');
      expect(Directory('$root/releases').listSync(), hasLength(2));
      expect(await run('$root/current/eclipse', []).then((r) => r.exitCode), 0);
      final desktop = File('$home/.local/share/applications/dev.nicholas.productivity_app.desktop');
      expect(desktop.readAsStringSync(), contains('Exec="'));
      final validator = await Process.run('sh', ['-c', 'command -v desktop-file-validate']);
      if (validator.exitCode == 0) {
        final validation = await Process.run('desktop-file-validate', [desktop.path]);
        expect(validation.exitCode, 0, reason: '${validation.stdout}${validation.stderr}');
      }
    });

    test('installed, older, missing and unrelated downloads are not offered', () async {
      final u = updater(installedRelease: 36);
      await u.check();
      expect(u.status, UpdateStatus.none);
      release['tag_name'] = 'v26.9.9';
      await u.check();
      expect(u.status, UpdateStatus.none);
      release['tag_name'] = 'v26.10.2';
      release['assets'] = [
        {'name': 'Eclipse.dmg'},
      ];
      await u.check();
      expect(u.status, UpdateStatus.none);
      release['assets'] = [asset];
      release['body'] = '';
      await u.check();
      expect(u.status, UpdateStatus.none);
    });

    test('Later hides the build until a subsequent rebuild', () async {
      final u = updater();
      await u.check();
      u.dismiss();
      await u.check();
      expect(u.status, UpdateStatus.none);
      release['body'] = '<!-- eclipse-linux-build: 37 -->';
      await u.check();
      expect(u.status, UpdateStatus.available);
    });

    for (final fault in ['checksum', 'missing digest', 'URL', 'HTTP', 'version', 'installer']) {
      test('$fault failure leaves current installation and running app intact', () async {
        final old = Directory('$root/releases/old')..createSync(recursive: true);
        Link('$root/current').createSync(old.path);
        if (fault == 'checksum') asset['digest'] = 'sha256:${'0' * 64}';
        if (fault == 'missing digest') asset.remove('digest');
        if (fault == 'URL') asset['browser_download_url'] = 'https://example.com/Eclipse.tar.zst';
        if (fault == 'version') {
          await archive(version: '26.10.2');
          asset['digest'] = 'sha256:${sha256.convert(bytes)}';
        }
        final u = updater(
          fetch: (uri) async => uri.path.endsWith('/latest')
              ? (200, utf8.encode(jsonEncode(release)))
              : (fault == 'HTTP' ? 503 : 200, bytes),
          process: (command, args) async {
            commands.add(command);
            if (fault == 'installer' && command == 'bash') return ProcessResult(1, 1, '', 'Missing runtime libraries');
            return run(command, args);
          },
        );
        await u.check();
        await u.update();
        expect(u.status, UpdateStatus.failed);
        expect(u.error, isNotEmpty);
        expect(closed, isFalse);
        expect(restarts, 0);
        expect(Link('$root/current').targetSync(), old.path);
        expect(Directory(root).listSync().where((f) => p.basename(f.path).startsWith('.update-')), isEmpty);
        if (['checksum', 'missing digest', 'URL', 'HTTP'].contains(fault)) expect(commands, isEmpty);
      });
    }

    test('a transient download failure can be retried from the card', () async {
      var downloads = 0;
      final u = updater(
        fetch: (uri) async {
          if (uri.path.endsWith('/latest')) return (200, utf8.encode(jsonEncode(release)));
          downloads++;
          return (downloads == 1 ? 503 : 200, bytes);
        },
      );
      await u.check();
      await u.update();
      expect(u.status, UpdateStatus.failed);
      expect(closed, isFalse);
      await u.update();
      expect(u.error, isNull);
      expect(u.status, UpdateStatus.restarting);
      expect(restarts, 1);
      expect(downloads, 2);
    });

    test('missing dependency check does not switch the active release', () async {
      final old = Directory('$root/releases/old')..createSync(recursive: true);
      Link('$root/current').createSync(old.path);
      final bin = Directory('${temp.path}/bin')..createSync();
      final ldd = File('${bin.path}/ldd')..writeAsStringSync('#!/bin/sh\necho "libmissing.so => not found"\n');
      await Process.run('chmod', ['+x', ldd.path]);
      final result = await run(
        'bash',
        ['$source/install.sh'],
        environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
      );
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('libmissing.so'));
      expect(result.stderr, contains('sudo pacman -S --needed'));
      expect(Link('$root/current').targetSync(), old.path);
    });

    test('overlapping clicks do not launch multiple installs', () async {
      final gate = Completer<(int, List<int>)>();
      final u = updater(
        fetch: (uri) async => uri.path.endsWith('/latest') ? (200, utf8.encode(jsonEncode(release))) : gate.future,
      );
      await u.check();
      final installation = u.update();
      await Future<void>.delayed(Duration.zero);
      await u.update();
      expect(u.status, UpdateStatus.updating);
      gate.complete((200, bytes));
      await installation;
      expect(restarts, 1);
    });
  }, skip: !Platform.isLinux);
}
