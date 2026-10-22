import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_account_cleanup.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_shortcuts.dart';
import '../support/memory_appearance_store.dart';
import '../support/widget_settle.dart';
import '../support/workspace_fixture.dart';

Account _account(int id, String username) => Account(
  instance: GitLabInstance.parse('https://example.com'),
  user: GitLabUser(id: id, username: username, name: 'Synthetic $username'),
  token: 'synthetic-test-token-$id',
);

/// A conversation that only reports its phase and its writes in flight.
final class _FakeSession extends ChangeNotifier
    implements AiChatSession, AiWriteSettlementSource {
  _FakeSession(this.origin);

  @override
  final AiChatOrigin origin;
  AiChatPhase _phase = AiChatPhase.idle;
  int stops = 0;
  List<Future<AiWriteOutcome>> writes = const [];

  @override
  AiChatPhase get phase => _phase;
  set phase(AiChatPhase value) {
    _phase = value;
    notifyListeners();
  }

  @override
  List<Future<AiWriteOutcome>> get inFlightWrites => writes;

  @override
  List<AiChatItem> get items => const [];

  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  @override
  void stop() {
    stops++;
    _phase = AiChatPhase.idle;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder _button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
);

bool _enabled(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder.first).onPressed != null;

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    AiAccountRemoval.debugReset();
    debugWriteJournalForCleanup = null;
  });
  tearDown(() {
    AiAccountRemoval.debugReset();
    debugWriteJournalForCleanup = null;
  });

  group('signed-out account list', () {
    late MemoryAccountStore store;
    late SessionController session;
    late Account saved;
    late Account other;

    Future<void> pumpLogin(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: LoginScreen(session: session),
        ),
      );
      await tester.pump();
    }

    Future<void> start(WidgetTester tester) async {
      saved = _account(7, 'tester');
      other = _account(8, 'other');
      store = MemoryAccountStore()..accounts = [saved, other];
      session = SessionController(store);
      addTearDown(session.dispose);
      await session.initialize();
      await pumpLogin(tester);
    }

    IconButton removeButton(WidgetTester tester, Account account) =>
        tester.widget<IconButton>(
          find.byKey(Key('removeAccount-${account.key}')),
        );

    ListTile tile(WidgetTester tester, Account account) => tester.widget<ListTile>(
      find.ancestor(
        of: find.byKey(Key('removeAccount-${account.key}')),
        matching: find.byType(ListTile),
      ),
    );

    testWidgets('the hold comes before the dialog; the other entry is refused; switching, removal and sign-in are disabled', (
      tester,
    ) async {
      await start(tester);
      final journal = AiWriteJournal.instance;
      final epoch = journal.proposalEpoch(saved.key);
      await tester.tap(find.byKey(Key('removeAccount-${saved.key}')));
      // Taken synchronously in the tap, before any frame shows the dialog.
      expect(journal.removalHeld(saved.key), isTrue);
      expect(journal.proposalEpoch(saved.key), epoch);
      await _frames(tester);
      expect(find.text(l10n.removeAccountKeepsRemoteToken), findsOneWidget);
      expect(AiAccountRemoval.begin(saved.key), isNull);
      expect(removeButton(tester, saved).onPressed, isNull);
      expect(removeButton(tester, other).onPressed, isNull);
      expect(tile(tester, other).onTap, isNull);
      expect(_enabled(tester, find.byKey(const Key('connectButton'))), isFalse);

      await tester.tap(find.text(l10n.cancelAction));
      await _frames(tester);
      expect(journal.removalHeld(saved.key), isFalse);
      expect(journal.proposalEpoch(saved.key), epoch + 1);
      expect(removeButton(tester, saved).onPressed, isNotNull);
      expect(tile(tester, other).onTap, isNotNull);
      expect(store.accounts, [saved, other]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unreadable journal asks for @username; a wrong name cannot confirm; the key failure keeps the account', (
      tester,
    ) async {
      final journal = AiWriteJournal(
        keys: MemoryAiJournalKeyStore()..unavailable = true,
        applicationSupport: Directory.systemTemp,
      );
      debugWriteJournalForCleanup = journal;
      await start(tester);
      final epoch = journal.proposalEpoch(saved.key);
      await tester.tap(find.byKey(Key('removeAccount-${saved.key}')));
      await _frames(tester);
      // The dialog says why a name is needed, then asks for it.
      expect(
        find.text(
          '${l10n.aiRemoveJournalUnreadable}\n\n'
          '${l10n.aiRemoveTypeUsernameDetail('@tester')}',
        ),
        findsOneWidget,
      );
      final confirm = find.widgetWithText(FilledButton, l10n.confirmAction);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '@other');
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.text(l10n.cancelAction));
      await _frames(tester);
      expect(journal.proposalEpoch(saved.key), epoch + 1);
      expect(journal.removalHeld(saved.key), isFalse);

      await tester.tap(find.byKey(Key('removeAccount-${saved.key}')));
      await _frames(tester);
      await tester.enterText(field, '@tester');
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await settleNetworkWidgets(tester);
      // The key is unavailable: the removal-start mark cannot be written, so
      // AI cleanup never starts and the account stays.
      expect(store.accounts, [saved, other]);
      expect(find.text(l10n.accountRemainsRetryRemoval), findsOneWidget);
      expect(journal.removalHeld(saved.key), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('uncertain writes are counted in the request for @username', (
      tester,
    ) async {
      final root = Directory(
        Directory.systemTemp.resolveSymbolicLinksSync(),
      ).createTempSync('packet9-uncertain-');
      addTearDown(() => root.deleteSync(recursive: true));
      final journal = AiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: root,
        processId: 'process',
      );
      debugWriteJournalForCleanup = journal;
      final account = _account(7, 'tester');
      await tester.runAsync(() async {
        await journal.recoverAfterAccountsLoaded([account.key]);
        await journal.ensureInitialized(account.key);
        await journal.prepare(
          draft: AiJournalDraft(
            executionId: 'uncertain-1',
            accountKey: account.key,
            conversationId: 'conversation',
            runId: 'run',
            operationId: 'createNote',
            writeKeys: {
              AiConflictKey([account.key, 'project:42', 'workItem', '12']),
            },
            payloadSha256: 'a' * 64,
            releaseName: '#12',
            confirmed: true,
          ),
        );
        await journal.markDispatching(executionId: 'uncertain-1');
        await journal.finish(
          executionId: 'uncertain-1',
          terminal: AiJournalState.writeUncertain,
        );
      });
      await start(tester);
      await tester.tap(find.byKey(Key('removeAccount-${saved.key}')));
      for (var round = 0; round < 40; round++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.byType(AlertDialog).evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
      expect(
        find.text(
          '${l10n.aiRemoveUncertainWrites('1')}\n\n'
          '${l10n.aiRemoveTypeUsernameDetail('@tester')}',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(l10n.cancelAction));
      await _frames(tester);
      expect(store.accounts, [saved, other]);
    });

    testWidgets('releasing the Navigator at the final dialog cancels the job; removal can start again', (
      tester,
    ) async {
      await start(tester);
      final journal = AiWriteJournal.instance;
      final epoch = journal.proposalEpoch(saved.key);
      await tester.tap(find.byKey(Key('removeAccount-${saved.key}')));
      await _frames(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      // Signing in replaces the login page and its Navigator.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await _frames(tester);
      expect(journal.removalHeld(saved.key), isFalse);
      expect(AiAccountRemoval.anyRunning, isFalse);
      expect(journal.proposalEpoch(saved.key), epoch + 1);
      expect(store.accounts, [saved, other]);
      expect(session.accounts, [saved, other]);

      await pumpLogin(tester);
      await tester.tap(find.byKey(Key('removeAccount-${saved.key}')));
      await _frames(tester);
      expect(find.text(l10n.removeAccountKeepsRemoteToken), findsOneWidget);
      await tester.tap(find.text(l10n.cancelAction));
      await _frames(tester);
      expect(journal.removalHeld(saved.key), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a job started by the other entry point disables this list until it ends', (
      tester,
    ) async {
      await start(tester);
      final job = AiAccountRemoval.begin(saved.key)!;
      final answer = Completer<bool>();
      final running = AiAccountRemoval.run(
        account: saved,
        job: job,
        session: session,
        confirm: (_) => answer.future,
        waitForInFlightWrites: () async {},
        requestCancelOnDispose: () {},
      );
      await _frames(tester);
      expect(removeButton(tester, saved).onPressed, isNull);
      expect(removeButton(tester, other).onPressed, isNull);
      expect(tile(tester, saved).onTap, isNull);
      answer.complete(false);
      await running;
      await _frames(tester);
      expect(removeButton(tester, saved).onPressed, isNotNull);
      expect(tile(tester, saved).onTap, isNotNull);
    });
  });

  test('activity counts running and approval-waiting conversations; only running ones use the three slots', () async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    final settings = AiSettingsController(MemoryAiStore());
    addTearDown(session.dispose);
    addTearDown(settings.dispose);
    addTearDown(fixture.api.close);
    await session.initialize();
    await session.connect('https://example.com/gitlab', 'synthetic-token');
    final created = <_FakeSession>[];
    final activity = AiAccountActivity();
    final registry = AccountAiRunRegistry(
      session: session,
      settings: settings,
      sessionFactory: activity.track(({
        required AiChatOrigin origin,
        required SessionController session,
        required AiSettingsController settings,
        required int Function() runningCount,
        AiChatWireClientFactory? wireClientFactory,
      }) {
        final fake = _FakeSession(origin);
        created.add(fake);
        return (session: fake, capacityChanged: () {}, dispose: fake.dispose);
      }),
    );
    activity.attach(registry);
    addTearDown(registry.dispose);
    const project = Project(id: 1, name: 'synthetic', path: 'group/synthetic');
    final running = registry.open(const AiGeneralOrigin()) as _FakeSession;
    final waiting =
        registry.open(const AiJobOrigin(project: project, jobId: 4, jobName: 'build'))
            as _FakeSession;
    final idle =
        registry.open(const AiJobOrigin(project: project, jobId: 5, jobName: 'test'))
            as _FakeSession;
    running.phase = AiChatPhase.running;
    waiting.phase = AiChatPhase.awaitingApproval;
    expect(activity.runningOrPending, 2);
    expect(registry.runningCount, 1);
    expect(activity.waitLimit, AiAccountRemoval.writeWaitLimit);

    // A released idle conversation is disposed and no longer tracked.
    registry.release(idle);
    expect(idle.disposed, isTrue);
    expect(activity.runningOrPending, 2);

    final write = Completer<AiWriteOutcome>();
    running.writes = [write.future];
    var settled = false;
    final stopping = activity.stopAndWait().then((_) => settled = true);
    expect(running.stops, 1);
    expect(waiting.stops, 1);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    write.complete(
      const AiWriteOutcome(state: AiJournalState.succeeded, reasonCode: 'ok'),
    );
    await stopping;
    expect(settled, isTrue);
  });

  group('signed-in shell', () {
    late WorkspaceFixture fixture;
    late SessionController session;
    late List<_FakeSession> created;

    AiChatSessionHandle factory({
      required AiChatOrigin origin,
      required SessionController session,
      required AiSettingsController settings,
      required int Function() runningCount,
      AiChatWireClientFactory? wireClientFactory,
    }) {
      final fake = _FakeSession(origin);
      created.add(fake);
      return (session: fake, capacityChanged: () {}, dispose: fake.dispose);
    }

    Future<_FakeSession> start(WidgetTester tester) async {
      fixture = WorkspaceFixture();
      session = controllerFor(MemoryAccountStore(), fixture.adapter);
      final settings = AiSettingsController(MemoryAiStore());
      final history = AiHistoryCoordinator(store: settings.store);
      final appearance = AppearanceController(MemoryAppearanceStore());
      final shortcuts = LauncherShortcuts(
        FakeAppShortcutHost(),
        MemoryRecentProjectStore(),
      );
      addTearDown(session.dispose);
      addTearDown(settings.dispose);
      addTearDown(history.dispose);
      addTearDown(appearance.dispose);
      addTearDown(shortcuts.dispose);
      addTearDown(fixture.api.close);
      created = [];
      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-token');
      });
      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          dynamicLight: const ColorScheme.light(),
          dynamicDark: const ColorScheme.dark(),
          buildInfoLoader: () async => const BuildInfo(
            version: '0.6.0',
            buildNumber: '6',
            commit: 'packet9',
          ),
          ai: AiControllers(settings: settings, history: history),
          aiSessionFactory: factory,
        ),
      );
      await settleNetworkWidgets(tester);
      final registry = AiRunRegistry.maybeOf(
        tester.element(find.byType(MaterialApp)),
      )!;
      final fake = registry.open(const AiGeneralOrigin()) as _FakeSession;
      fake.phase = AiChatPhase.running;
      await tester.tap(find.text(l10n.meTab));
      await settleNetworkWidgets(tester);
      return fake;
    }

    Finder addAccount() => _button(l10n.addOrReconnectAccount);

    testWidgets('removing the current account: stop dialog first; cancel keeps the run; the hold disables switching and sign-out', (
      tester,
    ) async {
      final fake = await start(tester);
      final account = session.active!;
      final journal = AiWriteJournal.instance;
      final epoch = journal.proposalEpoch(account.key);
      expect(_enabled(tester, addAccount()), isTrue);

      await tester.tap(find.byTooltip(l10n.removeAccountFromDevice));
      expect(journal.removalHeld(account.key), isTrue);
      await _frames(tester);
      expect(find.text(l10n.aiRemoveStopRunsTitle), findsOneWidget);
      expect(find.text(l10n.aiRemoveStopRunsDetail(1)), findsOneWidget);
      expect(_enabled(tester, addAccount()), isFalse);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.logout),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.text(l10n.cancelAction));
      await _frames(tester);
      expect(fake.stops, 0);
      expect(fake.phase, AiChatPhase.running);
      expect(journal.proposalEpoch(account.key), epoch);
      expect(journal.removalHeld(account.key), isFalse);
      expect(_enabled(tester, addAccount()), isTrue);

      // Stop and continue: runs stop, approvals are invalidated, and the
      // final dialog follows; cancelling it invalidates them once more.
      await tester.tap(find.byTooltip(l10n.removeAccountFromDevice));
      await _frames(tester);
      await tester.tap(find.text(l10n.aiRemoveStopRunsConfirm));
      await _frames(tester);
      expect(fake.stops, 1);
      expect(find.text(l10n.removeAccountKeepsRemoteToken), findsOneWidget);
      await tester.tap(find.text(l10n.cancelAction));
      await _frames(tester);
      expect(journal.proposalEpoch(account.key), epoch + 2);
      expect(journal.removalHeld(account.key), isFalse);
      expect(session.active?.key, account.key);
      expect(tester.takeException(), isNull);
    });

    testWidgets('releasing the Navigator at the stop dialog ends the job without an epoch change; removal can start again', (
      tester,
    ) async {
      await start(tester);
      final account = session.active!;
      final journal = AiWriteJournal.instance;
      final epoch = journal.proposalEpoch(account.key);
      await tester.tap(find.byTooltip(l10n.removeAccountFromDevice));
      await _frames(tester);
      expect(find.text(l10n.aiRemoveStopRunsTitle), findsOneWidget);
      // An account switch replaces the whole shell and its Navigator.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await _frames(tester);
      expect(journal.removalHeld(account.key), isFalse);
      expect(AiAccountRemoval.anyRunning, isFalse);
      expect(journal.proposalEpoch(account.key), epoch);
      expect(session.accounts.map((saved) => saved.key), [account.key]);
      final retry = AiAccountRemoval.begin(account.key);
      expect(retry, isNotNull);
      retry!.release(retry.token);
      expect(tester.takeException(), isNull);
    });

    testWidgets('signing out with a run: cancel stays; wait stops runs and leaves after the write settles', (
      tester,
    ) async {
      final fake = await start(tester);
      final write = Completer<AiWriteOutcome>();
      fake.writes = [write.future];
      await tester.tap(addAccount());
      await _frames(tester);
      expect(find.text(l10n.aiSwitchTitle), findsOneWidget);
      expect(find.text(l10n.aiSwitchDetail(1)), findsOneWidget);
      expect(find.text(l10n.aiSwitchNowNote), findsOneWidget);
      await tester.tap(find.text(l10n.cancelAction));
      await _frames(tester);
      expect(fake.stops, 0);
      expect(session.active, isNotNull);

      await tester.tap(addAccount());
      await _frames(tester);
      await tester.tap(find.text(l10n.aiSwitchWait));
      await _frames(tester);
      expect(fake.stops, 1);
      expect(find.text(l10n.aiRemoveWaitingWrites), findsOneWidget);
      expect(session.active, isNotNull);
      write.complete(
        const AiWriteOutcome(
          state: AiJournalState.succeeded,
          reasonCode: 'ok',
        ),
      );
      await _frames(tester);
      expect(session.active, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switch now stops runs and leaves without waiting for the write in flight', (
      tester,
    ) async {
      final fake = await start(tester);
      fake.writes = [Completer<AiWriteOutcome>().future];
      await tester.tap(addAccount());
      await _frames(tester);
      await tester.tap(find.text(l10n.aiSwitchNow));
      await _frames(tester);
      // Stopped by the guard; the new generation then disposes the registry,
      // which stops it again.
      expect(fake.stops, greaterThanOrEqualTo(1));
      expect(session.active, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
