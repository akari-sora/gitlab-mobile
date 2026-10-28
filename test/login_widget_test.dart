import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'session_test.dart' show MemoryAccountStore;
import 'support/widget_settle.dart';

void main() {
  for (final width in [320.0, 412.0, 840.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('login layout width=$width text-scale=$scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final sessionStore = MemoryAccountStore();
        final session = SessionController(sessionStore, readCache: sessionStore.readCache);
        addTearDown(session.dispose);
        await session.initialize();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: LoginScreen(session: session),
          ),
        );
        expect(find.byKey(const Key('instanceField')), findsOneWidget);
        expect(find.byKey(const Key('tokenField')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const Key('connectButton')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('saved account can be removed from the login list', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = MemoryAccountStore();
    final saved = Account(
      instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
      token: 'synthetic-test-token',
    );
    store.accounts = [saved];
    final session = SessionController(store, readCache: store.readCache);
    addTearDown(session.dispose);
    await session.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: LoginScreen(session: session),
      ),
    );
    expect(find.text('@tester'), findsOneWidget);
    await tester.tap(find.byTooltip('從此裝置移除帳號'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確認'));
    await pumpUntil(tester, () => !AiAccountRemoval.anyRunning,
        description: 'login removal finishes acknowledged storage cleanup');
    await tester.pumpAndSettle();
    expect(store.accounts, isEmpty);
    expect(find.text('@tester'), findsNothing);
  });

  testWidgets('artifact cleanup failure keeps the saved login account', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = MemoryAccountStore();
    final saved = Account(
      instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
      token: 'synthetic-test-token',
    );
    store.accounts = [saved];
    final session = SessionController(store, readCache: store.readCache);
    addTearDown(session.dispose);
    Directory? root;
    final previous = artifactStorageRoot;
    addTearDown(() {
      artifactStorageRoot = previous;
      final created = root;
      if (created != null && created.existsSync()) created.deleteSync(recursive: true);
    });
    late final File archive;
    await tester.runAsync(() async {
      final created = await Directory.systemTemp.createTemp('gitlab-mobile-login-remove-');
      root = created;
      artifactStorageRoot = () async => created;
      await session.initialize();
      final directory = await jobArtifactDirectory(saved, 4, 9);
      archive = File('${directory.path}/job.zip');
      await archive.writeAsBytes([4]);
      artifactStorageRoot = () async => throw const FileSystemException('unreadable');
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: LoginScreen(session: session),
      ),
    );
    await tester.tap(find.byTooltip('從此裝置移除帳號'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確認'));
    await tester.pumpAndSettle();
    expect(store.accounts, isNotEmpty);
    expect(find.text('@tester'), findsOneWidget);
    expect(archive.existsSync(), isTrue);
    expect(find.textContaining('無法清除產物'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login hides OAuth when the instance has no Application ID', (
    tester,
  ) async {
    final sessionStore = MemoryAccountStore();
    final session = SessionController(sessionStore, readCache: sessionStore.readCache);
    addTearDown(session.dispose);
    await session.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: LoginScreen(session: session),
      ),
    );
    expect(find.byKey(const Key('oauthButton')), findsNothing);
    expect(find.text('透過 GitLab 授權登入'), findsNothing);
  });

  testWidgets('login offers OAuth only when an Application ID exists', (
    tester,
  ) async {
    final sessionStore = MemoryAccountStore();
    final session = SessionController(
      sessionStore,
      readCache: sessionStore.readCache,
      applicationIdFor: (instance) =>
          instance.base.host == 'example.com' ? 'synthetic-app-id' : null,
    );
    addTearDown(session.dispose);
    await session.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: LoginScreen(session: session),
      ),
    );
    expect(find.byKey(const Key('oauthButton')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('instanceField')),
      'https://example.com',
    );
    await tester.pump();
    expect(find.byKey(const Key('oauthButton')), findsOneWidget);
    expect(find.text('透過 GitLab 授權登入'), findsOneWidget);
  });

  group('C2e signed-out read-cache cleanup', () {
    const pending = ReadCacheCleanupState(
      operation: ReadCacheCleanupOperation.signOut,
      disposition: ReadCacheCleanupDisposition.signedOutCleanupPending,
      code: ReadCacheCleanupCode.cleanupFailed,
      clearResult: DiskClearResult(
        keyGoneConfirmed: false,
        directoryGoneConfirmed: false,
        markerDurable: false,
        complete: false,
      ),
    );

    testWidgets('a failure raised with no subscriber shows, merges, retries cleanup only', (tester) async {
      final store = MemoryAccountStore();
      final session = SessionController(store, readCache: store.readCache);
      addTearDown(session.dispose);
      await session.initialize();
      final cache = store.readCache;
      // Raised while nothing listens (between the shell and this screen).
      cache.reportCleanup(const DiskBinding(accountKey: 'synthetic#1', generation: 3), pending);
      cache.reportCleanup(const DiskBinding(accountKey: 'synthetic#2', generation: 4), pending);
      await tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));
      await tester.pump();
      expect(find.byKey(const ValueKey('signed-out-cache-notice')), findsOneWidget,
        reason: 'pending signed-out notices merge into one');
      expect(find.text('離線快取尚未清除'), findsOneWidget);
      expect(find.text('已登出，但這台裝置上的離線快取還沒清除完成。可以重試清除。'), findsOneWidget);
      expect(find.text('切換帳號'), findsNothing);
      expect(cache.controlsInstalled, isFalse, reason: 'only the authenticated shell opens the controls gate');

      await tester.ensureVisible(find.text('重試清除'));
      await tester.tap(find.text('重試清除'));
      await pumpUntil(tester, () => cache.signedOutSnapshot.isEmpty,
        description: 'both signed-out clears complete');
      await pumpUntil(tester, () => find.text('已清除離線快取').evaluate().isNotEmpty);
      expect(find.byKey(const ValueKey('signed-out-cache-notice')), findsNothing);
      expect(session.active, isNull, reason: 'a signed-out retry never reopens a session');
      expect(cache.state('synthetic#1'), isNot(ReadCacheDiskState.ready));
      expect(cache.controlsInstalled, isFalse);
    });

    testWidgets('a notice raised while the screen is open appears; other notices do not', (tester) async {
      final store = MemoryAccountStore();
      final session = SessionController(store, readCache: store.readCache);
      addTearDown(session.dispose);
      await session.initialize();
      await tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));
      expect(find.byKey(const ValueKey('signed-out-cache-notice')), findsNothing);
      store.readCache.reportCleanup(
        const DiskBinding(accountKey: 'synthetic#1', generation: 3),
        const ReadCacheCleanupState(
          operation: ReadCacheCleanupOperation.mutation,
          disposition: ReadCacheCleanupDisposition.originalOutcomePreserved,
          code: ReadCacheCleanupCode.cleanupFailed,
          clearResult: DiskClearResult(
            keyGoneConfirmed: false,
            directoryGoneConfirmed: false,
            markerDurable: false,
            complete: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('signed-out-cache-notice')), findsNothing,
        reason: 'a signed-in notice never reaches the sign-in screen');
      store.readCache.reportCleanup(const DiskBinding(accountKey: 'synthetic#1', generation: 3), pending);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('signed-out-cache-notice')), findsOneWidget);
    });
  });
}
