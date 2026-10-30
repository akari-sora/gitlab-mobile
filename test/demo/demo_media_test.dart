// A reviewer's comment with outside media, a video and a link: the demo
// renders a note instead of fetching or staging anything, and refuses to hand
// the link to the browser.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/demo/demo_app.dart';
import 'package:gitlab_mobile/features/demo/demo_data.dart';
import 'package:gitlab_mobile/features/demo/demo_runtime.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/widget_settle.dart';
import 'demo_test_support.dart';

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await settleNetworkWidgets(tester, maxCycles: 30);
}

void main() {
  testWidgets('outside media and links never leave the device', (tester) async {
    final secure = recordSecureStorage();
    final network = NoNetwork();
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = network;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    phoneView(tester);
    final runtime = (await tester.runAsync(
      () => DemoRuntime.start(ai: false),
    ))!;
    addTearDown(runtime.dispose);
    await tester.runAsync(
      () => runtime.session.api!.createNote(
        demoPlannerId,
        'issues',
        demoDefaultIssue,
        '![outside](https://example.com/a.png)\n\n'
            '<video src="https://example.com/v.mp4"></video>\n\n'
            '![clip](/mergeline-demo/pocket-planner/-/raw/main/clip.mp4)\n\n'
            '[outside page](https://example.com/page)',
      ),
    );
    await tester.pumpWidget(
      DemoApp(
        runtime: runtime,
        onExit: () async {},
        buildInfoLoader: testBuildInfo,
      ),
    );
    await settleNetworkWidgets(tester);
    await _tap(tester, find.text('Pocket Planner').first);
    await _tap(tester, find.text('議題').last);
    await _tap(
      tester,
      find.text('Tasks with an empty title can be saved').first,
    );
    await _tap(tester, find.text('討論').first);

    final notes = find.byKey(const ValueKey('snapshot-media-placeholder'));
    expect(notes, findsNWidgets(3));
    expect(
      find.descendant(of: notes, matching: find.text(l10n.demoOffline)),
      findsNWidgets(3),
    );

    await tester.ensureVisible(find.text('outside page', findRichText: true));
    await tester.pump();
    await tester.tap(find.text('outside page', findRichText: true));
    await tester.pump();
    expect(find.widgetWithText(SnackBar, l10n.demoOffline), findsOneWidget);

    expect(network.attempts, 0, reason: 'no real HTTP client was opened');
    expect(runtime.server.unhandled, isEmpty);
    expect(secure.changes, isEmpty);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('a demo that cannot start says so on the sign-in screen', (
    tester,
  ) async {
    recordSecureStorage();
    final session = controllerFor(
      MemoryAccountStore(),
      FakeAdapter((_) => jsonResponse(<Json>[])),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          session: session,
          onTryDemo: () async => throw StateError('synthetic demo failure'),
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('tryDemoButton')));
    await tester.tap(find.byKey(const Key('tryDemoButton')));
    await tester.pump();
    expect(find.textContaining(l10n.cannotReadResponse), findsOneWidget);
  });
}
