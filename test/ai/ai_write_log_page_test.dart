import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_log_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../support/workspace_fixture.dart';

final class _Fence implements AiJournalAccountFence {
  @override
  bool isCleaning(String accountKey) => false;
  @override
  Future<T> run<T>(String accountKey, Future<T> Function() action) => action();
}

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  late Directory root;
  late AiWriteJournal journal;
  late MemoryAiJournalKeyStore keyStore;
  final fixture = WorkspaceFixture();
  final account = fixture.account;
  var serial = 0;

  setUp(() {
    root = Directory(
      Directory.systemTemp.resolveSymbolicLinksSync(),
    ).createTempSync('ai-write-log-');
    keyStore = MemoryAiJournalKeyStore();
    journal = AiWriteJournal(
      keys: keyStore,
      applicationSupport: root,
      fence: _Fence(),
      processId: 'process',
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<String> write(AiJournalState terminal, {String name = '!12'}) async {
    final id = 'execution-${serial++}';
    await journal.prepare(
      draft: AiJournalDraft(
        executionId: id,
        accountKey: account.key,
        conversationId: 'conversation-$id',
        runId: 'run-$id',
        operationId: 'createNote',
        writeKeys: {
          AiConflictKey([account.key, 'project:42', 'mergeRequest', id]),
        },
        dependencyKeys: const {},
        payloadSha256: 'a' * 64,
        releaseName: name,
        instance: account.instance.base.toString(),
        sessionGeneration: 1,
        normalizedTarget: name,
        lastCommitId: null,
        headSha: null,
        updatedAt: null,
        mergeCheckSummary: null,
        policyRevision: 1,
        summary: 'synthetic',
        confirmed: true,
        bypass: false,
        tier4: false,
        persistConversation: true,
        budgetHold: null,
      ),
    );
    await journal.markDispatching(executionId: id);
    await journal.finish(executionId: id, terminal: terminal);
    return id;
  }

  // The journal does real file and isolate work; let it run on the real
  // clock between frames until the page is no longer loading or busy.
  Future<void> settleIo(WidgetTester tester) async {
    for (var round = 0; round < 60; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      final loading = find
          .byType(CircularProgressIndicator)
          .evaluate()
          .isNotEmpty;
      final reset = find.byKey(const ValueKey('ai-write-log-reset'));
      final busy =
          reset.evaluate().isNotEmpty &&
          tester.widget<OutlinedButton>(reset).onPressed == null;
      if (!loading && !busy) break;
    }
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        locale: const Locale('zh', 'TW'),
        supportedLocales: const [Locale('zh', 'TW')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: AiWriteLogPage(account: account, journal: journal),
      ),
    );
    await settleIo(tester);
  }

  testWidgets('interrupted changes come first and can be released', (
    tester,
  ) async {
    late String uncertain;
    await tester.runAsync(() async {
      await journal.recoverAfterAccountsLoaded([account.key]);
      await journal.ensureInitialized(account.key);
      await write(AiJournalState.succeeded, name: '!7');
      uncertain = await write(AiJournalState.writeUncertain);
    });
    await open(tester);
    expect(find.text(l10n.aiWriteLogInterrupted), findsOneWidget);
    expect(
      find.byKey(ValueKey('ai-write-log-interrupted-$uncertain')),
      findsOne,
    );
    expect(find.textContaining(l10n.aiWriteStatusSucceeded), findsOneWidget);

    // Recording what GitLab shows keeps the lock.
    await tester.tap(find.byKey(ValueKey('ai-write-log-observe-$uncertain')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-write-log-observed-done')));
    await settleIo(tester);
    expect(
      find.text(l10n.aiWriteLogObservation(l10n.aiWriteLogObservedDone)),
      findsOneWidget,
    );

    // Release needs the target's exact name.
    await tester.tap(find.byKey(ValueKey('ai-write-log-release-$uncertain')));
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(FilledButton, l10n.confirmAction);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, '!12');
    await tester.pump();
    await tester.tap(confirm);
    await settleIo(tester);
    expect(find.text(l10n.aiWriteLogInterrupted), findsNothing);
    expect(
      journal
          .entries(account.key)
          .firstWhere((e) => e.executionId == uncertain)
          .state,
      AiJournalState.resolvedByUser,
    );
    // Let the confirmation snack bar time out.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a reset needs the @username', (tester) async {
    await tester.runAsync(() async {
      await journal.recoverAfterAccountsLoaded([account.key]);
      await journal.ensureInitialized(account.key);
      await write(AiJournalState.writeUncertain);
    });
    await open(tester);
    final reset = find.byKey(const ValueKey('ai-write-log-reset'));
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '@developer');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, l10n.confirmAction));
    await settleIo(tester);
    expect(find.text(l10n.aiWriteLogEmpty), findsOneWidget);
    expect(journal.recentlyReset(account.key), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an account with no AI changes has an empty log', (tester) async {
    await tester.runAsync(
      () => journal.recoverAfterAccountsLoaded([account.key]),
    );
    await open(tester);
    expect(find.text(l10n.aiWriteLogEmpty), findsOneWidget);
  });

  testWidgets('a log that cannot be read says so', (tester) async {
    await tester.runAsync(() async {
      await journal.recoverAfterAccountsLoaded([account.key]);
      await journal.ensureInitialized(account.key);
      await write(AiJournalState.succeeded);
    });
    // The encrypted file is damaged on disk.
    await tester.runAsync(() async {
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        file.writeAsBytesSync(List.filled(64, 7));
      }
    });
    journal = AiWriteJournal(
      keys: keyStore,
      applicationSupport: root,
      fence: _Fence(),
      processId: 'second-process',
    );
    await tester.runAsync(
      () => journal.recoverAfterAccountsLoaded([account.key]),
    );
    await open(tester);
    expect(find.byKey(const ValueKey('ai-write-log-unavailable')), findsOne);
  });

  test('every journal state has words', () {
    for (final state in AiJournalState.values) {
      expect(aiJournalStateLabel(state), isNotEmpty);
    }
  });
}
