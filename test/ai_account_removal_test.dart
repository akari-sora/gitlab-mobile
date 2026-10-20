import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'session_test.dart' show MemoryAccountStore;

void main() {
  testWidgets('AI cleanup failure keeps the account and shows the failure', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final saved = Account(
      instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
      token: 'synthetic-test-token',
    );
    final accountStore = MemoryAccountStore()..accounts = [saved];
    final session = SessionController(accountStore);
    addTearDown(session.dispose);

    late final Directory root;
    late final MemoryAiStore aiStore;
    late final AiHistoryCoordinator coordinator;
    final previousRemoval = removeAiHistoryDirectory;
    addTearDown(() {
      removeAiHistoryDirectory = previousRemoval;
      AiHistoryCoordinator.debugReset();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp(
        'gitlab-mobile-ai-remove-',
      );
      aiStore = MemoryAiStore();
      coordinator = AiHistoryCoordinator.debugReset(
        store: aiStore,
        files: AiHistoryFileStore(root: () async => root),
      );
      await session.initialize();
      final directory = await coordinator.files.directory(saved.key);
      directory.createSync(recursive: true);
    });
    var removalAttempted = false;
    removeAiHistoryDirectory = (_) {
      removalAttempted = true;
      throw const FileSystemException('synthetic AI history cleanup failure');
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: LoginScreen(session: session),
      ),
    );
    await tester.tap(find.byTooltip('從此裝置移除帳號'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確認'));
    await tester.pump();
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!removalAttempted) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('AI history removal was not attempted');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(accountStore.accounts, [saved]);
    expect(session.accounts, [saved]);
    expect(find.text('@tester'), findsOneWidget);
    expect(
      find.text(
        l10n.titleThenDetail(
          l10n.aiHistoryCleanupTitle,
          l10n.aiHistoryCleanupDetail,
        ),
      ),
      findsOneWidget,
    );
    final tombstone = await aiStore.readTombstone(saved.key);
    expect(tombstone.value, isTrue);
    expect(tester.takeException(), isNull);
  });
}
