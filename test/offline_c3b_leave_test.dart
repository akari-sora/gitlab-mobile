// C3b §6.7 / §8.3: every way out of the session confirms the loss of the
// account's offline projects first, before the AI guard and before anything
// stops, clears or changes the session.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/offline/offline_status.dart';
import 'package:gitlab_mobile/features/shell/account_sheet.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'offline/coordinator_regression_test.dart' as fixture;
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

/// A conversation that only reports its phase, so the AI guard asks.
final class _FakeSession extends ChangeNotifier
    implements AiChatSession, AiWriteSettlementSource {
  _FakeSession(this.origin);
  @override
  final AiChatOrigin origin;
  AiChatPhase _phase = AiChatPhase.idle;
  int stops = 0;
  @override
  AiChatPhase get phase => _phase;
  set phase(AiChatPhase value) {
    _phase = value;
    notifyListeners();
  }

  @override
  List<Future<AiWriteOutcome>> get inFlightWrites => const [];
  @override
  List<AiChatItem> get items => const [];
  @override
  void stop() {
    stops++;
    _phase = AiChatPhase.idle;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late WorkspaceFixture workspace;
  late SessionController session;
  late Directory root;

  /// Signs in, saves one synthetic offline project for that account and
  /// shows the shell with one running AI conversation.
  Future<_FakeSession> start(WidgetTester tester) async {
    workspace = WorkspaceFixture();
    session = controllerFor(MemoryAccountStore(), workspace.adapter);
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
    addTearDown(workspace.api.close);
    final owner = OfflineRepositoryCoordinator();
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-token');
      final scratch = Directory('.dart_tool/c3b/leave')
        ..createSync(recursive: true);
      root = scratch.createTempSync('case.');
      final key = session.active!.key;
      final store = SnapshotStore(
        supportRoot: root,
        accountKey: key,
        rootKey: Uint8List(32),
      );
      final date = DateTime.utc(2026, 10, 28);
      await store.writeTree(
        SnapshotTree(
          snapshotId: '0123456789abcdef0123456789abcdef',
          sha: 'a' * 40,
          subPath: '',
          entries: [],
        ),
        format: SnapshotObjectFormat.sha1,
        complete: true,
        mayCommit: () => true,
      );
      await store.writeIndex(
        SnapshotIndex(
          accountKey: key,
          lastValidatedAt: date,
          consentAt: date,
          snapshots: [
            SnapshotRecord(
              id: '0123456789abcdef0123456789abcdef',
              projectId: 42,
              projectPath: 'group/project',
              projectName: 'Project',
              defaultBranch: 'main',
              refKind: SnapshotRefKind.branch,
              refName: 'main',
              sha: 'a' * 40,
              objectFormat: SnapshotObjectFormat.sha1,
              subPath: '',
              commitTitle: 'title',
              committedAt: date,
              status: SnapshotStatus.complete,
              createdAt: date,
              savedAt: date,
              storedBytes: 2048,
            ),
          ],
        ),
        expectedRevision: store.revision,
        mayCommit: () => true,
      );
      owner.configure(
        keys: fixture.MemoryKeys(),
        supportRoot: () async => root,
        deleteDirectory: (_) async {},
      );
      owner.open(
        DiskBinding(accountKey: key, generation: session.generation),
        readOnly: true,
      );
    });
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final created = <_FakeSession>[];
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

    await tester.pumpWidget(
      AuthenticatedApp(
        session: session,
        appearance: appearance,
        shortcuts: shortcuts,
        dynamicLight: const ColorScheme.light(),
        dynamicDark: const ColorScheme.dark(),
        buildInfoLoader: () async =>
            const BuildInfo(version: '0.6.0', buildNumber: '6', commit: 'c3b'),
        ai: AiControllers(settings: settings, history: history),
        aiSessionFactory: factory,
        offlineCoordinator: owner,
      ),
    );
    await settleNetworkWidgets(tester);
    await pumpUntil(
      tester,
      () =>
          OfflineScope.maybeOf(
            tester.element(find.byType(MaterialApp)),
            listen: false,
          )?.snapshots.isNotEmpty ??
          false,
      maxCycles: 200,
      description: 'offline projects loaded',
    );
    final registry = AiRunRegistry.maybeOf(
      tester.element(find.byType(MaterialApp)),
    )!;
    final fake = registry.open(const AiGeneralOrigin()) as _FakeSession;
    fake.phase = AiChatPhase.running;
    await tester.tap(find.text(l10n.meTab));
    await settleNetworkWidgets(tester);
    return fake;
  }

  Finder button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );

  testWidgets('signing out: the offline loss is asked first, then the AI guard', (
    tester,
  ) async {
    final fake = await start(tester);
    final username = session.active!.user.username;
    await tester.tap(button(l10n.addOrReconnectAccount));
    await _frames(tester);
    expect(find.text('要刪除離線專案嗎？'), findsOneWidget);
    expect(find.textContaining('登出會刪除 @$username 的 1 個離線專案'), findsOneWidget);
    expect(find.text(l10n.aiSwitchTitle), findsNothing, reason: 'offline first');

    await tester.tap(find.text(l10n.cancelAction));
    await _frames(tester);
    expect(find.text(l10n.aiSwitchTitle), findsNothing);
    expect(fake.stops, 0, reason: 'cancel changes nothing');
    expect(session.active, isNotNull);

    await tester.tap(button(l10n.addOrReconnectAccount));
    await _frames(tester);
    await tester.tap(find.text('繼續並刪除'));
    await _frames(tester);
    expect(find.text(l10n.aiSwitchTitle), findsOneWidget);
    await tester.tap(find.text(l10n.cancelAction));
    await _frames(tester);
    expect(fake.stops, 0);
    expect(session.active, isNotNull);
  });

  testWidgets('the account sheet asks too', (tester) async {
    await start(tester);
    final context = tester.element(find.text(l10n.meTab).first);
    unawaited(showAccountSheet(context, session));
    await _frames(tester);
    await tester.tap(find.text(l10n.addOrSwitchAccount));
    await _frames(tester);
    expect(find.text('要刪除離線專案嗎？'), findsOneWidget);
    await tester.tap(find.text(l10n.cancelAction));
    await _frames(tester);
    expect(session.active, isNotNull);
  });
}
