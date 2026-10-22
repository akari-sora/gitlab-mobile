import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_log_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../support/widget_settle.dart';
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
        instance: account.instance.key,
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
        home: AiWriteLogPage(
          account: account,
          journal: journal,
          api: fixture.api,
        ),
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

    // The target links to GitLab, built from the verified instance.
    expect(
      find.byKey(ValueKey('ai-write-log-open-$uncertain')),
      findsOneWidget,
    );
    // A re-read records what it saw and keeps the lock.
    await tester.tap(find.byKey(ValueKey('ai-write-log-reread-$uncertain')));
    await settleNetworkWidgets(tester);
    await settleIo(tester);
    final observation = find.byKey(
      ValueKey('ai-write-log-observation-$uncertain'),
    );
    expect(observation, findsOneWidget);
    expect(
      tester.widget<Text>(observation).data,
      startsWith(l10n.aiRereadUnknown('').split('（').first),
    );
    expect(
      journal
          .entries(account.key)
          .firstWhere((e) => e.executionId == uncertain)
          .state,
      AiJournalState.writeUncertain,
    );
    await tester.pump(const Duration(seconds: 5));

    // Release needs the target's exact name.
    await tester.tap(find.byKey(ValueKey('ai-write-log-release-$uncertain')));
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(FilledButton, l10n.confirmAction);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    // Pasted from an Arabic interface, the name carries direction marks.
    await tester.enterText(find.byType(TextField).last, '\u2068!12\u2069');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.enterText(find.byType(TextField).last, '!13');
    await tester.pump();
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
    expect(find.text(l10n.aiWriteLogUnreadable), findsOneWidget);
    // An unreadable file can only be reset; a retry would read it again.
    expect(find.byKey(const ValueKey('ai-write-log-retry')), findsNothing);
    final reset = find.byKey(const ValueKey('ai-write-log-reset'));
    expect(reset, findsOne);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    // The dialog names the account in full and cannot count the locks.
    expect(
      find.textContaining(
        l10n.aiWriteLogResetAccount(
          account.instance.key,
          '@developer',
          '${account.user.id}',
        ),
      ),
      findsOneWidget,
    );
    expect(find.textContaining(l10n.aiWriteLogResetUnknown), findsOneWidget);
    expect(find.textContaining(l10n.aiWriteLogResetNotUndo), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '@developer');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, l10n.confirmAction));
    await settleIo(tester);
    expect(find.text(l10n.aiWriteLogEmpty), findsOneWidget);
    expect(journal.recentlyReset(account.key), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a log storage that is away for now offers a retry', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await journal.recoverAfterAccountsLoaded([account.key]);
      await journal.ensureInitialized(account.key);
      await write(AiJournalState.succeeded);
    });
    keyStore.unavailable = true;
    journal = AiWriteJournal(
      keys: keyStore,
      applicationSupport: root,
      fence: _Fence(),
      processId: 'second-process',
    );
    await open(tester);
    await settleIo(tester);
    expect(find.text(l10n.aiWriteLogUnavailable), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-write-log-reset')), findsNothing);
    keyStore.unavailable = false;
    await tester.tap(find.byKey(const ValueKey('ai-write-log-retry')));
    await settleIo(tester);
    expect(find.byKey(const ValueKey('ai-write-log-unavailable')), findsNothing);
    expect(find.text(l10n.aiWriteLogRecent), findsOneWidget);
  });

  testWidgets('a reset of a readable log counts what it unlocks', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await journal.recoverAfterAccountsLoaded([account.key]);
      await journal.ensureInitialized(account.key);
      await write(AiJournalState.writeUncertain);
      await write(AiJournalState.writeUncertain, name: '!13');
      await write(AiJournalState.succeeded, name: '!14');
    });
    await open(tester);
    await settleIo(tester);
    final reset = find.byKey(const ValueKey('ai-write-log-reset'));
    await tester.scrollUntilVisible(
      reset,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(
      find.textContaining(l10n.aiWriteLogResetReleases('2')),
      findsOneWidget,
    );
    expect(find.textContaining(l10n.aiWriteLogResetUnknown), findsNothing);
  });

  test('every journal state has words', () {
    for (final state in AiJournalState.values) {
      expect(aiJournalStateLabel(state), isNotEmpty);
    }
  });
}
