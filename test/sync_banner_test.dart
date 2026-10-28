import 'dart:io';

import 'package:eclipse/data/store.dart';
import 'package:eclipse/data/sync.dart';
import 'package:eclipse/data/sync_service.dart';
import 'package:eclipse/theme/app_theme.dart';
import 'package:eclipse/widgets/sync_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('only incoming changes show a banner, even while sync is busy', (tester) async {
    final home = Directory.systemTemp.createTempSync('eclipse-sync-banner');
    final store = Store.memory();
    final sync = SyncService.load(home, store);
    addTearDown(() {
      sync.dispose();
      store.close();
      home.deleteSync(recursive: true);
    });

    Future<void> mount() => tester.pumpWidget(
      MaterialApp(
        theme: themeNamed(null),
        home: Scaffold(body: SyncBanner(sync: sync)),
      ),
    );

    // Mounting during a routine round must also stay quiet.
    sync.busy = true;
    await mount();
    expect(find.byType(Container), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    for (final busy in [false, true, false]) {
      sync.busy = busy;
      // Exercise the notifications sent at the start/end of sync rounds.
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      sync.notifyListeners();
      await tester.pump();
      expect(find.byType(Container), findsNothing);
    }

    sync.busy = true;
    sync.lastIncoming = Incoming({('journal', '2026-10-24'), ('journal', '2026-10-25')}, {'Remote laptop'});
    sync.incomingCount++;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    sync.notifyListeners();
    await tester.pump();
    expect(find.text('Updated from Remote laptop'), findsOneWidget);
    expect(find.text('2 changes brought in.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    sync.busy = false;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    sync.notifyListeners();
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Updated from Remote laptop'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Updated from Remote laptop'), findsNothing);

    // Later local activity must not replay the previous incoming card.
    sync.busy = true;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    sync.notifyListeners();
    await tester.pump();
    expect(find.byType(Container), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a sign-in from before the journal went to Drive asks to sign in again, until put off', (tester) async {
    final home = Directory.systemTemp.createTempSync('eclipse-sync-ask');
    File('${home.path}/sync.json').writeAsStringSync('{"refresh": "old", "email": "me@example.com"}');
    final store = Store.memory();
    final sync = SyncService.load(home, store);
    addTearDown(() {
      sync.dispose();
      store.close();
      home.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: themeNamed(null),
        home: Scaffold(body: SyncBanner(sync: sync)),
      ),
    );
    expect(find.text('Keep your journal in Drive'), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(find.text('Keep your journal in Drive'), findsNothing);
  });

  testWidgets('changes waiting on another computer show in one card, until put off', (tester) async {
    final home = Directory.systemTemp.createTempSync('eclipse-sync-waiting');
    final store = Store.memory();
    final sync = SyncService.load(home, store);
    addTearDown(() {
      sync.dispose();
      store.close();
      home.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: themeNamed(null),
        home: Scaffold(body: SyncBanner(sync: sync)),
      ),
    );
    expect(find.byType(Container), findsNothing);

    sync.unreadFrom = {'Mac'};
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    sync.notifyListeners();
    await tester.pump();
    expect(find.text('Some changes couldn’t be read'), findsOneWidget);
    expect(
      find.text(
        'Some changes from Mac couldn’t be read, so they’re waiting. Your own changes still go to your other computers.',
      ),
      findsOneWidget,
    );

    sync.newerFrom = {'Laptop'};
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    sync.notifyListeners();
    await tester.pump();
    expect(find.text('Some changes are waiting'), findsOneWidget);
    expect(find.textContaining('need a newer version of Eclipse'), findsOneWidget);
    expect(find.textContaining('couldn’t be read, so'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(find.text('Some changes are waiting'), findsNothing);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    sync.notifyListeners();
    await tester.pump();
    expect(find.text('Some changes are waiting'), findsNothing, reason: 'until Eclipse next opens');
  });
}
