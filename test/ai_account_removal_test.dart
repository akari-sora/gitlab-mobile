import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'session_test.dart' show MemoryAccountStore;

class _RecordingJournalFiles extends AiJournalFiles {
  _RecordingJournalFiles(super.root, this.calls);

  final List<String> calls;
  bool record = false;

  @override
  Future<void> write(
    String account,
    Uint8List bytes, {
    required bool Function() mayCommit,
  }) async {
    if (record) calls.add('journal mark');
    await super.write(account, bytes, mayCommit: mayCommit);
  }
}

class _RecordingAccountStore extends MemoryAccountStore {
  _RecordingAccountStore(this.calls);
  final List<String> calls;

  @override
  Future<void> save(List<Account> value) async {
    calls.add('session save');
    await super.save(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failCache in [false, true]) {
    test(
      'read-cache removal follows recent and precedes journal; failure=$failCache',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        AiAccountRemoval.debugReset();
        final root = Directory.systemTemp.createTempSync('cache-removal-');
        final oldArtifactRoot = artifactStorageRoot;
        artifactStorageRoot = () async => root;
        final calls = <String>[];
        final account = Account(
          instance: GitLabInstance.parse('https://synthetic.example'),
          user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
          token: 'synthetic-test-token',
        );
        final store = _RecordingAccountStore(calls)..accounts = [account];
        final session = SessionController(store);
        final files = _RecordingJournalFiles(root, calls);
        final journal = AiWriteJournal(
          keys: MemoryAiJournalKeyStore(),
          applicationSupport: root,
          files: files,
          processId: 'synthetic',
        );
        addTearDown(() {
          AiAccountRemoval.debugReset();
          session.dispose();
          artifactStorageRoot = oldArtifactRoot;
          root.deleteSync(recursive: true);
        });
        await session.initialize();
        await journal.recoverAfterAccountsLoaded([account.key]);
        await journal.ensureInitialized(account.key);
        files.record = true;
        final job = AiAccountRemoval.begin(account.key, journal: journal)!;
        const clearResult = DiskClearResult(
          keyGoneConfirmed: false,
          directoryGoneConfirmed: false,
          markerDurable: false,
          complete: false,
        );
        const failure = ApiFailure.readCacheCleanup(
          ReadCacheCleanupState(
            operation: ReadCacheCleanupOperation.accountRemoval,
            disposition: ReadCacheCleanupDisposition.accountRetained,
            code: ReadCacheCleanupCode.cleanupFailed,
            clearResult: clearResult,
          ),
        );

        final result = await AiAccountRemoval.run(
          account: account,
          job: job,
          session: session,
          journal: journal,
          consultJournal: true,
          confirm: (_) async => true,
          waitForInFlightWrites: () async {},
          requestCancelOnDispose: () {},
          clearDrafts: (_) async => calls.add('drafts'),
          clearArtifacts: (_) async => calls.add('artifacts'),
          clearRecent: (_) async => calls.add('recent'),
          clearReadCacheDisk: (saved) async {
            expect(saved, same(account));
            calls.add('read cache');
            if (failCache) throw failure;
          },
          clearAi: (_) async => calls.add('AI cleanup'),
        );

        if (failCache) {
          expect(calls, ['drafts', 'artifacts', 'recent', 'read cache']);
          expect(result.status, AiRemovalStatus.notRemoved);
          expect(result.reason, 'beforeAiCleanupFailed');
          expect(result.dataState, AiRemovalDataState.untouched);
          expect(result.error, same(failure));
          expect(
            (result.error! as ApiFailure).kind,
            FailureKind.readCacheCleanup,
          );
          expect(session.accounts, [account]);
          expect(store.accounts, [account]);
        } else {
          expect(calls, [
            'drafts',
            'artifacts',
            'recent',
            'read cache',
            'journal mark',
            'AI cleanup',
            'session save',
          ]);
          expect(result.status, AiRemovalStatus.removed);
          expect(session.accounts, isEmpty);
          expect(store.accounts, isEmpty);
        }
      },
    );
  }

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
      root = await Directory.systemTemp.createTemp('gitlab-mobile-ai-remove-');
      aiStore = MemoryAiStore();
      coordinator = AiHistoryCoordinator.debugReset(
        store: aiStore,
        files: AiHistoryFileStore(root: () async => root),
      );
      await session.initialize();
      final directory = await coordinator.files.directory(saved.key);
      directory.createSync(recursive: true);
    });
    final removalAttempted = Completer<void>();
    removeAiHistoryDirectory = (_) {
      removalAttempted.complete();
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
    await tester.runAsync(() => removalAttempted.future);
    await tester.pumpAndSettle();
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
