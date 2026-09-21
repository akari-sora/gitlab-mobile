import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'session_test.dart' show MemoryAccountStore;

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
        final session = SessionController(MemoryAccountStore());
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
    final session = SessionController(store);
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
    final session = SessionController(store);
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
    final session = SessionController(MemoryAccountStore());
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
    final session = SessionController(
      MemoryAccountStore(),
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
}
