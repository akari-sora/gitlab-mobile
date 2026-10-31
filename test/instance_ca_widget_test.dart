import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/instance_ca.dart';
import 'package:gitlab_mobile/features/auth/instance_ca_ui.dart';
import 'package:gitlab_mobile/features/auth/instance_trust.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'instance_ca_test.dart' show caFingerprint, otherCaFingerprint;
import 'instance_trust_test.dart' show HandshakeRefusingAdapter, trustingSession;
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

final class FakeCaPicker implements CaCertificatePicker {
  FakeCaPicker(this.file);
  final PickedCaFile? file;
  int picks = 0;
  @override
  Future<PickedCaFile?> pick() async {
    picks++;
    return file;
  }
}

PickedCaFile pickedFixture(String name) => PickedCaFile(
  name: name,
  bytes: Uint8List.fromList(File('test/fixtures/tls/$name').readAsBytesSync()),
);

void main() {
  const url = 'https://gitlab.example.com/gitlab';

  Future<void> signInAttempt(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('instanceField')), url);
    await tester.enterText(find.byKey(const Key('tokenField')), 'synthetic-test-token');
    await tester.tap(find.byKey(const Key('connectButton')));
    await settleNetworkWidgets(tester);
  }

  testWidgets('an untrusted certificate offers the import; confirming the '
      'fingerprint stores the CA and retries the sign-in', (tester) async {
    tester.view.physicalSize = const Size(412, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryAccountStore();
    final backing = MemoryInstanceTrustStore();
    final refusing = HandshakeRefusingAdapter();
    final session = trustingSession(store, InstanceTrust.memory(backing), refusing: refusing);
    addTearDown(session.dispose);
    await tester.runAsync(session.initialize);
    final picker = FakeCaPicker(pickedFixture('ca.der'));
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: LoginScreen(session: session, caPicker: picker),
    ));

    expect(find.byKey(const Key('importInstanceCa')), findsNothing);
    await signInAttempt(tester);
    expect(session.active, isNull);
    expect(find.textContaining('此站台的憑證不受信任'), findsOneWidget);
    final action = find.byKey(const Key('importInstanceCa'));
    expect(action, findsOneWidget);
    expect(find.text('匯入此站台的 CA 憑證'), findsOneWidget);

    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(picker.picks, 1);
    expect(find.text('信任這張 CA 憑證？'), findsOneWidget);
    expect(find.text('ca.der'), findsOneWidget);
    expect(find.byKey(const ValueKey('instance-ca-fingerprint-0')), findsOneWidget);
    expect(find.text(caFingerprint), findsOneWidget);
    expect(find.textContaining('gitlab.example.com'), findsWidgets);
    expect(backing.values, isEmpty, reason: 'nothing is stored before confirming');

    await tester.tap(find.byKey(const Key('confirmInstanceCa')));
    await settleNetworkWidgets(tester);
    expect(backing.values.keys, [instanceCaStorageKey(url)]);
    expect(session.active?.user.id, 7);
    expect(refusing.attempts, 1, reason: 'the retry used the new trust');
  });

  testWidgets('cancelling the confirmation stores nothing', (tester) async {
    tester.view.physicalSize = const Size(412, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryAccountStore();
    final backing = MemoryInstanceTrustStore();
    final session = trustingSession(store, InstanceTrust.memory(backing));
    addTearDown(session.dispose);
    await tester.runAsync(session.initialize);
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(session: session, caPicker: FakeCaPicker(pickedFixture('ca.pem'))),
    ));
    await signInAttempt(tester);
    await tester.tap(find.byKey(const Key('importInstanceCa')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await settleNetworkWidgets(tester);
    expect(backing.values, isEmpty);
    expect(session.active, isNull);
    expect(find.byKey(const Key('importInstanceCa')), findsOneWidget);
  });

  testWidgets('a private key file is refused before any confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(412, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryAccountStore();
    final backing = MemoryInstanceTrustStore();
    final session = trustingSession(store, InstanceTrust.memory(backing));
    addTearDown(session.dispose);
    await tester.runAsync(session.initialize);
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(session: session, caPicker: FakeCaPicker(pickedFixture('ca.key'))),
    ));
    await signInAttempt(tester);
    await tester.tap(find.byKey(const Key('importInstanceCa')));
    await tester.pumpAndSettle();
    expect(find.text('信任這張 CA 憑證？'), findsNothing);
    expect(find.textContaining('檔案含有私鑰'), findsOneWidget);
    expect(backing.values, isEmpty);
  });

  testWidgets('the import action follows the instance in the URL field',
      (tester) async {
    tester.view.physicalSize = const Size(412, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryAccountStore();
    final session = trustingSession(store, InstanceTrust.memory());
    addTearDown(session.dispose);
    await tester.runAsync(session.initialize);
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(session: session, caPicker: FakeCaPicker(null)),
    ));
    await signInAttempt(tester);
    expect(find.byKey(const Key('importInstanceCa')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('instanceField')), 'https://other.example.com');
    await tester.pump();
    expect(find.byKey(const Key('importInstanceCa')), findsNothing);
  });

  testWidgets('我的 shows the custom CA with its fingerprint and removes it '
      'after confirmation', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appearance = AppearanceController(MemoryAppearanceStore());
    final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
    addTearDown(appearance.dispose);
    addTearDown(shortcuts.dispose);
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(instance.key, 'synthetic-test-token');
      await session.trust.save(
        instance,
        parseCaCertificate(File('test/fixtures/tls/ca.pem').readAsBytesSync()),
      );
    });
    await tester.pumpWidget(AuthenticatedApp(
      session: session,
      appearance: appearance,
      shortcuts: shortcuts,
      buildInfoLoader: () async =>
          const BuildInfo(version: '0.3.0', buildNumber: '3', commit: 'ca'),
    ));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);

    final apiBefore = session.api;
    final generationBefore = session.generation;
    final row = find.byKey(ValueKey('instance-ca-${instance.key}'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('自訂 CA 憑證')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining(caFingerprint)),
        findsOneWidget);

    await tester.tap(find.byKey(ValueKey('remove-instance-ca-${instance.key}')));
    await tester.pumpAndSettle();
    expect(find.text('移除自訂 CA 憑證？'), findsOneWidget);
    // L5: this is the signed-in instance, so the account is checked again.
    expect(find.textContaining('移除後會立即在不使用此憑證的情況下重新驗證帳號'),
        findsOneWidget);
    expect(session.trust.certificateFor(instance), isNotNull,
        reason: 'nothing changes before confirming');
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await settleNetworkWidgets(tester);
    expect(session.trust.certificateFor(instance), isNull);
    expect(row, findsNothing);
    // A new client for the same account replaced the one built with the CA.
    expect(session.active?.instance.key, instance.key);
    expect(session.api, isNotNull);
    expect(identical(session.api, apiBefore), isFalse);
    expect(session.generation, isNot(generationBefore));
  });

  testWidgets('M1: GitLab.com shows the interception warning and no import',
      (tester) async {
    tester.view.physicalSize = const Size(412, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryAccountStore();
    final session = trustingSession(store, InstanceTrust.memory());
    addTearDown(session.dispose);
    await tester.runAsync(session.initialize);
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(session: session, caPicker: FakeCaPicker(pickedFixture('ca.pem'))),
    ));
    await tester.enterText(find.byKey(const Key('instanceField')), 'https://gitlab.com');
    await tester.enterText(find.byKey(const Key('tokenField')), 'synthetic-test-token');
    await tester.tap(find.byKey(const Key('connectButton')));
    await settleNetworkWidgets(tester);
    expect(session.active, isNull);
    expect(find.textContaining('這個網路上可能有人攔截連線'), findsOneWidget);
    expect(find.byKey(const Key('importInstanceCa')), findsNothing);
  });

  testWidgets('L1: replacing a stored CA warns and shows its fingerprint',
      (tester) async {
    tester.view.physicalSize = const Size(412, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryAccountStore();
    final trust = InstanceTrust.memory();
    final ca = parseCaCertificate(File('test/fixtures/tls/ca.pem').readAsBytesSync());
    final other =
        parseCaCertificate(File('test/fixtures/tls/other_ca.pem').readAsBytesSync());
    final instance = GitLabInstance.parse(url);
    // The server now needs `ca`; the stored CA is the other one.
    final session = trustingSession(store, trust,
        accepts: (target) => trust.certificateFor(target) == ca);
    addTearDown(session.dispose);
    await tester.runAsync(() async {
      await session.initialize();
      await trust.save(instance, other);
    });
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(session: session, caPicker: FakeCaPicker(pickedFixture('ca.pem'))),
    ));
    await signInAttempt(tester);
    await tester.tap(find.byKey(const Key('importInstanceCa')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('instance-ca-replace-warning')), findsOneWidget);
    expect(find.textContaining('這可能表示連線遭到攔截'), findsOneWidget);
    expect(
      tester.widget<SelectableText>(
          find.byKey(const ValueKey('instance-ca-current-fingerprint-0'))).data,
      otherCaFingerprint,
    );
    expect(find.text('目前的 SHA-256 指紋'), findsOneWidget);
    expect(find.text(caFingerprint), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmInstanceCa')));
    await settleNetworkWidgets(tester);
    expect(trust.certificateFor(instance), ca);
    expect(session.active?.user.id, 7);
  });

  testWidgets('L6: a CA without a saved account is listed and removable',
      (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryAccountStore();
    final trust = InstanceTrust.memory();
    final session = trustingSession(store, trust);
    addTearDown(session.dispose);
    final orphan = GitLabInstance.parse('https://orphan.example.com');
    await tester.runAsync(() async {
      await session.initialize();
      await trust.save(
        orphan,
        parseCaCertificate(File('test/fixtures/tls/ca.pem').readAsBytesSync()),
      );
    });
    expect(session.accounts, isEmpty);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: InstanceCaRows(session: session)),
    ));
    final row = find.byKey(ValueKey('instance-ca-${orphan.key}'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining('orphan.example.com')),
        findsOneWidget);
    await tester.tap(find.byKey(ValueKey('remove-instance-ca-${orphan.key}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('移除後會立即'), findsNothing, reason: 'not signed in');
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await settleNetworkWidgets(tester);
    expect(trust.certificateFor(orphan), isNull);
    expect(row, findsNothing);
    expect(find.text('已移除自訂 CA 憑證'), findsOneWidget);
  });
}
