import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

class _RemovalAccountStore extends MemoryAccountStore {
  _RemovalAccountStore(this.calls, this.completed);
  final List<String> calls;
  final Completer<void> completed;
  bool track = false;
  @override
  Future<void> save(List<Account> value) async {
    if (track) calls.add('session.remove');
    await super.save(value);
    if (track && !completed.isCompleted) completed.complete();
  }
}

class _RemovalAiStore implements AiStore {
  _RemovalAiStore(this.calls, this.recentKey, this.failed, this.completed);
  final List<String> calls;
  final String recentKey;
  final bool failed;
  final Completer<void> completed;
  final memory = MemoryAiStore();
  @override
  Future<void> setTombstone(String account) async {
    expect(await const FlutterSecureStorage().read(key: recentKey), isNull);
    calls.addAll(['clearRecentProject', 'clearAiAccountData']);
    await memory.setTombstone(account);
  }

  @override
  Future<void> deleteHistoryKey(String account) =>
      memory.deleteHistoryKey(account);
  @override
  Future<void> deleteAccount(String account) async {
    if (failed) {
      if (!completed.isCompleted) completed.complete();
      throw const FileSystemException('synthetic cleanup failure');
    }
    await memory.deleteAccount(account);
  }

  @override
  Future<void> clearTombstone(String account) => memory.clearTombstone(account);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final failed in [false, true]) {
    testWidgets('authenticated removal preserves order, failure=$failed', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('ai-auth-remove-');
      final calls = <String>[];
      final completed = Completer<void>();
      final accountStore = _RemovalAccountStore(calls, completed);
      final fixture = WorkspaceFixture();
      final session = controllerFor(accountStore, fixture.adapter);
      final appearance = AppearanceController(MemoryAppearanceStore());
      final shortcuts = LauncherShortcuts(
        FakeAppShortcutHost(),
        MemoryRecentProjectStore(),
      );
      final oldArtifactRoot = artifactStorageRoot;
      late _RemovalAiStore aiStore;
      addTearDown(() {
        artifactStorageRoot = oldArtifactRoot;
        AiHistoryCoordinator.debugReset();
        shortcuts.dispose();
        appearance.dispose();
        session.dispose();
        fixture.api.close();
        root.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        await session.initialize();
        await session.connect(
          'https://example.com/gitlab',
          'synthetic-test-token',
        );
      });
      final saved = session.active!;
      final encoded = base64Url.encode(utf8.encode(saved.key));
      final draftKey = 'draft.v2.$encoded.synthetic';
      final recentKey = 'recent_project.v1.$encoded';
      await const FlutterSecureStorage().write(
        key: draftKey,
        value: 'synthetic draft',
      );
      await const FlutterSecureStorage().write(
        key: recentKey,
        value: 'synthetic recent',
      );
      artifactStorageRoot = () async {
        expect(await const FlutterSecureStorage().read(key: draftKey), isNull);
        calls.addAll(['clearSecureDrafts', 'clearAccountArtifacts']);
        return root;
      };
      aiStore = _RemovalAiStore(calls, recentKey, failed, completed);
      AiHistoryCoordinator.debugReset(
        store: aiStore,
        files: AiHistoryFileStore(root: () async => root),
      );
      accountStore.track = true;
      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: () async => const BuildInfo(
            version: '0.0.0',
            buildNumber: '1',
            commit: 'synthetic',
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('我的'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byTooltip('從此裝置移除帳號'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認'));
      await tester.pump();
      await tester.runAsync(() => completed.future);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      // A failure may reassert the tombstone. Compare the first ordered pass.
      expect(calls.take(4), [
        'clearSecureDrafts',
        'clearAccountArtifacts',
        'clearRecentProject',
        'clearAiAccountData',
      ]);
      if (failed) {
        expect(calls, isNot(contains('session.remove')));
        expect(session.accounts, [saved]);
        expect((await aiStore.memory.readTombstone(saved.key)).value, isTrue);
        expect(
          find.text(
            l10n.titleThenDetail(
              l10n.aiHistoryCleanupTitle,
              l10n.aiHistoryCleanupDetail,
            ),
          ),
          findsOneWidget,
        );
      } else {
        expect(calls, [
          'clearSecureDrafts',
          'clearAccountArtifacts',
          'clearRecentProject',
          'clearAiAccountData',
          'session.remove',
        ]);
        expect(session.accounts, isEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
