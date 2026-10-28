import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_recovery_notice.dart';
import 'package:gitlab_mobile/features/ai/ai_run_notification_ui.dart';
import 'package:gitlab_mobile/features/ai/ai_run_notifications.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/security/app_lock.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/main.dart'
    show recoverAiWriteJournalAfterAccountsLoaded;
import 'package:gitlab_mobile/shared/theme.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/ai_run_notification_shell.dart'
    show FakeNotificationPlatform;
import '../support/workspace_fixture.dart';

const _a = 'https://synthetic.example/gitlab#7';
const _b = 'https://synthetic.example/gitlab#8';
const _notice = ValueKey('ai-recovery-notice');
const _ok = ValueKey('ai-recovery-ok');

AiJournalDraft _draft(String id, String account) => AiJournalDraft(
  executionId: id,
  accountKey: account,
  conversationId: 'synthetic-conversation',
  runId: 'synthetic-run',
  operationId: 'createNote',
  writeKeys: {
    AiConflictKey([account, 'project:9', 'issue:$id']),
  },
  payloadSha256: List.filled(64, 'a').join(),
  releaseName: '#3',
);

final class _Store implements AppLockStore {
  @override
  Future<bool> read() async => true;
  @override
  Future<void> write(bool enabled) async {}
}

final class _Auth implements AppLockAuthenticator {
  Completer<bool>? pending;
  @override
  Future<bool> available() async => true;
  @override
  Future<bool> authenticate(String reason) =>
      (pending = Completer<bool>()).future;
}

Widget _host(Widget child, {String tag = 'zh-TW', double scale = 1}) =>
    MaterialApp(
      theme: appTheme(Brightness.light),
      locale: tag == 'ar' ? const Locale('ar') : const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    );

void main() {
  late Directory root;
  late MemoryAiJournalKeyStore keys;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mr6c-c7-notice-');
    keys = MemoryAiJournalKeyStore();
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A previous process that died with [writes] dispatching and [prepared]
  /// only prepared per account, and this process's journal after its
  /// start-up recovery (not yet reported).
  Future<AiWriteJournal> afterDeath(
    WidgetTester tester,
    Map<String, int> writes, {
    Map<String, int> prepared = const {},
    List<String> accounts = const [_a, _b],
  }) async => (await tester.runAsync(() async {
    final old = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      processId: 'old-process',
    );
    await old.recoverAfterAccountsLoaded(accounts);
    var n = 0;
    for (final account in {...writes.keys, ...prepared.keys}) {
      await old.ensureInitialized(account);
      for (
        var i = 0;
        i < (writes[account] ?? 0) + (prepared[account] ?? 0);
        i++
      ) {
        final id = 'write-${n++}';
        await old.prepare(draft: _draft(id, account));
        if (i < (writes[account] ?? 0)) {
          await old.markDispatching(executionId: id);
        }
      }
    }
    final next = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      processId: 'next-process',
    );
    await next.recoverAfterAccountsLoaded(accounts);
    return next;
  }))!;

  Widget notice(
    AiWriteJournal journal,
    String account, {
    AppLockController? lock,
  }) => AiRecoveryNotice(
    journal: journal,
    accountKey: account,
    lock: lock,
    child: const Scaffold(body: Text('home')),
  );

  test('start-up recovery reports each finished pass to the notice', () async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    await session.initialize();
    final journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      processId: 'startup',
    );
    expect(aiJournalRecoveryPasses(journal).value, 0);
    await recoverAiWriteJournalAfterAccountsLoaded(session, journal);
    expect(aiJournalRecoveryPasses(journal).value, 1);
  });

  testWidgets('shown once after recovery, acknowledged only after the '
      'person dismisses it, nothing resent', (tester) async {
    final journal = await afterDeath(tester, {_a: 1});
    await tester.pumpWidget(_host(notice(journal, _a)));
    await tester.pumpAndSettle();
    // No finished recovery pass reported yet: nothing is read or shown.
    expect(find.byKey(_notice), findsNothing);
    markAiJournalRecovered(journal);
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsOneWidget);
    expect(find.text(l10n.aiRecoveryTitle), findsOneWidget);
    expect(find.text(l10n.aiRecoveryUncertain('1')), findsOneWidget);
    expect(find.text(l10n.aiRecoveryNoResend), findsOneWidget);
    expect(find.textContaining(l10n.aiRecoveryNotExecuted('0')), findsNothing);
    // Visible but not dismissed: still unacknowledged.
    expect(journal.recoveryResult(_a).mayNotifyInterruption, isTrue);
    await tester.tap(find.byKey(_ok));
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsNothing);
    expect(journal.recoveryResult(_a).mayNotifyInterruption, isFalse);
    // Nothing was resent or released: the write stays uncertain, isolated.
    expect(journal.entries(_a).single.state, AiJournalState.writeUncertain);
    // A later pass (or a rebuilt shell) does not show it again.
    markAiJournalRecovered(journal);
    await tester.pumpWidget(_host(notice(journal, _a), tag: 'zh-TW'));
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsNothing);
  });

  testWidgets('writes cut off before sending say nothing was sent (Codex '
      'R1)', (tester) async {
    final journal = await afterDeath(tester, {}, prepared: {_a: 2});
    final summary = journal.recoveryResult(_a);
    expect(summary.uncertainWrites, 0);
    expect(summary.notExecutedWrites, 2);
    markAiJournalRecovered(journal);
    await tester.pumpWidget(_host(notice(journal, _a)));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiRecoveryNotExecuted('2')), findsOneWidget);
    // No "check GitLab" line: nothing was sent.
    expect(find.text(l10n.aiRecoveryUncertain('2')), findsNothing);
    expect(find.text(l10n.aiRecoveryUncertain('0')), findsNothing);
    expect(journal.entries(_a).map((e) => e.state).toSet(), {
      AiJournalState.notExecuted,
    });
  });

  testWidgets('sent and unsent writes are told apart (Codex R1)', (
    tester,
  ) async {
    final journal = await afterDeath(tester, {_a: 1}, prepared: {_a: 2});
    markAiJournalRecovered(journal);
    await tester.pumpWidget(_host(notice(journal, _a)));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiRecoveryUncertain('1')), findsOneWidget);
    expect(find.text(l10n.aiRecoveryNotExecuted('2')), findsOneWidget);
    expect(find.text(l10n.aiRecoveryNoResend), findsOneWidget);
  });

  testWidgets('a notice that goes away unseen comes back', (tester) async {
    final journal = await afterDeath(tester, {_a: 1});
    markAiJournalRecovered(journal);
    await tester.pumpWidget(_host(notice(journal, _a)));
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsOneWidget);
    // The shell is replaced (account switch) before the person taps OK.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(journal.recoveryResult(_a).mayNotifyInterruption, isTrue);
    await tester.pumpWidget(_host(notice(journal, _a)));
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsOneWidget);
  });

  testWidgets('each account sees and acknowledges only its own result', (
    tester,
  ) async {
    final journal = await afterDeath(tester, {_a: 1, _b: 2});
    markAiJournalRecovered(journal);
    await tester.pumpWidget(_host(notice(journal, _a)));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiRecoveryUncertain('1')), findsOneWidget);
    await tester.tap(find.byKey(_ok));
    await tester.pumpAndSettle();
    expect(journal.recoveryResult(_a).mayNotifyInterruption, isFalse);
    expect(journal.recoveryResult(_b).mayNotifyInterruption, isTrue);
    // Switching to the other account shows its count.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host(notice(journal, _b)));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiRecoveryUncertain('2')), findsOneWidget);
    await tester.tap(find.byKey(_ok));
    await tester.pumpAndSettle();
    expect(journal.recoveryResult(_b).mayNotifyInterruption, isFalse);
  });

  testWidgets('signed-out start: nothing until an account shell exists; an '
      'account without interruptions sees nothing', (tester) async {
    final journal = await afterDeath(tester, {_b: 1});
    // Signed out: recovery finished, no account shell, nothing shown.
    markAiJournalRecovered(journal);
    await tester.pumpWidget(_host(const Scaffold(body: Text('sign in'))));
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsNothing);
    // Signing in to an account with no interruption shows nothing either.
    await tester.pumpWidget(_host(notice(journal, _a)));
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsNothing);
    expect(journal.recoveryResult(_b).mayNotifyInterruption, isTrue);
    // The account that had one sees it after signing in.
    await tester.pumpWidget(_host(notice(journal, _b)));
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsOneWidget);
  });

  testWidgets('waits for the app lock to open', (tester) async {
    final journal = await afterDeath(tester, {_a: 1});
    final auth = _Auth();
    final lock = AppLockController(store: _Store(), authenticator: auth);
    addTearDown(lock.dispose);
    await tester.runAsync(lock.start);
    expect(lock.covering, isTrue);
    markAiJournalRecovered(journal);
    await tester.pumpWidget(_host(notice(journal, _a, lock: lock)));
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsNothing);
    final unlocking = lock.unlock();
    auth.pending!.complete(true);
    await unlocking;
    await tester.pumpAndSettle();
    expect(find.byKey(_notice), findsOneWidget);
    expect(journal.recoveryResult(_a).mayNotifyInterruption, isTrue);
  });

  testWidgets('Arabic at twice the text size on a small phone', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final journal = await afterDeath(tester, {_a: 3});
    markAiJournalRecovered(journal);
    await tester.pumpWidget(_host(notice(journal, _a), tag: 'ar', scale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(_notice), findsOneWidget);
    await tester.ensureVisible(find.byKey(_ok));
    await tester.tap(find.byKey(_ok));
    await tester.pumpAndSettle();
    expect(journal.recoveryResult(_a).mayNotifyInterruption, isFalse);
  });

  group('interrupted notification after next-start recovery (Codex R1)', () {
    late FakeNotificationPlatform platform;
    setUp(() => (platform = FakeNotificationPlatform()).install());
    tearDown(() => platform.uninstall());
    final android = TargetPlatformVariant.only(TargetPlatform.android);

    /// A signed-in session whose account had [writes] interrupted.
    Future<(AiWriteJournal, String, int, AiRunNotifications)> start(
      WidgetTester tester, {
      int writes = 1,
    }) async {
      final fixture = WorkspaceFixture();
      final session = controllerFor(MemoryAccountStore(), fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);
      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-token');
      });
      final key = session.active!.key;
      final journal = await afterDeath(
        tester,
        {if (writes > 0) key: writes},
        accounts: [key],
      );
      final notifications = AiRunNotifications(text: aiRunNotificationText);
      addTearDown(notifications.dispose);
      expect(await notifications.initialize(), isTrue);
      final notifier = AiRecoveryNotifier(
        journal: journal,
        notifications: notifications,
        session: session,
      );
      addTearDown(notifier.dispose);
      return (journal, key, session.generation, notifications);
    }

    testWidgets('posted once per recovered account, generic, after the pass', (
      tester,
    ) async {
      platform.notificationsEnabled = true;
      final (journal, key, generation, _) = await start(tester);
      await tester.pump();
      expect(platform.shows, isEmpty, reason: 'no finished pass yet');
      markAiJournalRecovered(journal);
      await tester.pump();
      await tester.pump();
      expect(platform.shows, hasLength(1));
      final show = platform.shows.single;
      expect(show['title'], l10n.aiRunNoticeTitle);
      expect(show['body'], l10n.aiRunNoticeInterrupted);
      final id = show['id']! as int;
      expect(
        id,
        inInclusiveRange(
          AiRunNotifications.resultFirstId,
          AiRunNotifications.resultLastId,
        ),
      );
      // Routing only: no conversation, so a tap lands on Home and the
      // start-up notice explains it.
      final route = AiRunNotificationRoute.decode(show['payload'] as String?);
      expect(route?.generation, generation);
      expect(route?.conversationId, startsWith('recovery-'));
      expect('$show', isNot(contains(key)));
      // Posting acknowledges nothing; the in-app notice still shows.
      expect(journal.recoveryResult(key).mayNotifyInterruption, isTrue);
      markAiJournalRecovered(journal);
      await tester.pump();
      await tester.pump();
      expect(platform.shows, hasLength(1));
    }, variant: android);

    testWidgets('nothing while notifications are off', (tester) async {
      platform.notificationsEnabled = false;
      final (journal, _, _, _) = await start(tester);
      markAiJournalRecovered(journal);
      await tester.pump();
      await tester.pump();
      expect(platform.shows, isEmpty);
    }, variant: android);

    testWidgets('nothing without interrupted writes', (tester) async {
      platform.notificationsEnabled = true;
      final (journal, _, _, _) = await start(tester, writes: 0);
      markAiJournalRecovered(journal);
      await tester.pump();
      await tester.pump();
      expect(platform.shows, isEmpty);
    }, variant: android);

    testWidgets('nothing after the account summary was acknowledged', (
      tester,
    ) async {
      platform.notificationsEnabled = true;
      final (journal, key, _, _) = await start(tester);
      expect(
        journal.acknowledgeRecovery(key, journal.recoveryResult(key)),
        isTrue,
      );
      markAiJournalRecovered(journal);
      await tester.pump();
      await tester.pump();
      expect(platform.shows, isEmpty);
    }, variant: android);
  });
}
