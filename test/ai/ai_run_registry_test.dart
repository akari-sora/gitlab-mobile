import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/fake_shortcuts.dart';
import '../support/memory_appearance_store.dart';
import '../support/workspace_fixture.dart';
import '../support/widget_settle.dart';

Future<BuildInfo> _buildInfo() async =>
    const BuildInfo(version: '0.6.0', buildNumber: '6', commit: 'ai-registry');

AiProviderConfig _provider() => const AiProviderConfig(
  id: 'registry-provider',
  name: 'Synthetic registry provider',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: AiFormat.responses,
  model: 'synthetic-model',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    requiresKey: false,
  ),
  allowLanCleartext: false,
  toolsEnabled: false,
  recipientRevision: 1,
);

AiWireClient _wireClient(
  FakeAdapter adapter, {
  required AiProviderConfig config,
  required String? apiKey,
  required String conversationId,
}) => AiWireClient(
  transport: AiTransport(
    endpoint: AiEndpoint.parse(config.baseUrl, allowLanCleartext: false),
    apiKey: apiKey ?? '',
    authStyle: config.authStyle,
    adapter: adapter,
  ),
  wire: const ResponsesFormat(),
  config: config,
  conversationId: conversationId,
  appVersion: 'test',
);

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(
    condition(),
    isTrue,
    reason: 'synthetic async operation did not start',
  );
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'reuses sessions by origin key and enforces the shared run limit',
    () async {
      final fixture = WorkspaceFixture();
      final session = controllerFor(MemoryAccountStore(), fixture.adapter);
      final settings = AiSettingsController(MemoryAiStore());
      addTearDown(session.dispose);
      addTearDown(settings.dispose);
      addTearDown(fixture.api.close);
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-token');

      final created = <_FakeChatSession>[];
      AiWireClient wireFactory({
        required AiProviderConfig config,
        required String? apiKey,
        required String conversationId,
      }) => throw UnimplementedError();
      late final AccountAiRunRegistry registry;
      registry = AccountAiRunRegistry(
        session: session,
        settings: settings,
        wireClientFactory: wireFactory,
        sessionFactory:
            ({
              required origin,
              required session,
              required settings,
              required runningCount,
              wireClientFactory,
            }) {
              expect(wireClientFactory, same(wireFactory));
              final fake = _FakeChatSession(origin, runningCount);
              created.add(fake);
              return (
                session: fake,
                capacityChanged: fake.notifyCapacityChanged,
                dispose: fake.dispose,
              );
            },
      );
      addTearDown(registry.dispose);

      final first = registry.open(const AiGeneralOrigin());
      expect(registry.open(const AiGeneralOrigin()), same(first));
      final second = registry.open(
        AiJobOrigin(project: fixture.project, jobId: 1, jobName: 'one'),
      );
      final third = registry.open(
        AiJobOrigin(project: fixture.project, jobId: 2, jobName: 'two'),
      );
      final fourth = registry.open(
        AiJobOrigin(project: fixture.project, jobId: 3, jobName: 'three'),
      );
      expect(created, hasLength(4));

      await first.send('first');
      await second.send('second');
      final beforeFull = created[3].capacityNotifications;
      await third.send('third');
      await Future<void>.delayed(Duration.zero);
      expect(registry.runningCount, AiRunRegistry.maxRunning);
      // Capacity filling up rebuilds an idle page, so it can say why.
      expect(created[3].capacityNotifications, greaterThan(beforeFull));
      await fourth.send('fourth');
      expect(fourth.phase, AiChatPhase.idle);
      expect(fourth.blocker, AiChatBlocker.tooManyRunning);
      final beforeOpen = created[3].capacityNotifications;

      var firstNotifications = 0;
      var fourthNotifications = 0;
      first.addListener(() => firstNotifications++);
      fourth.addListener(() => fourthNotifications++);
      expect(first.phase, AiChatPhase.running);
      expect(created.first.disposed, isFalse);

      first.stop();
      await Future<void>.delayed(Duration.zero);
      expect(fourth.blocker, AiChatBlocker.none);
      expect(created[0].capacityNotifications, 1);
      expect(created[3].capacityNotifications, beforeOpen + 1);
      expect(firstNotifications, 2);
      expect(fourthNotifications, 1);
    },
  );

  test('release drops and disposes an empty idle session', () async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    final settings = AiSettingsController(MemoryAiStore());
    addTearDown(session.dispose);
    addTearDown(settings.dispose);
    addTearDown(fixture.api.close);
    await session.initialize();
    await session.connect('https://example.com/gitlab', 'synthetic-token');

    final created = <_FakeChatSession>[];
    var factoryBuilds = 0;
    final registry = AccountAiRunRegistry(
      session: session,
      settings: settings,
      sessionFactory:
          ({
            required origin,
            required session,
            required settings,
            required runningCount,
            wireClientFactory,
          }) {
            factoryBuilds++;
            final fake = _FakeChatSession(origin, runningCount);
            created.add(fake);
            return (
              session: fake,
              capacityChanged: fake.notifyCapacityChanged,
              dispose: fake.dispose,
            );
          },
    );
    addTearDown(registry.dispose);

    final first = registry.open(const AiGeneralOrigin());
    registry.release(first);
    expect(created.single.disposed, isTrue);

    final reopened = registry.open(const AiGeneralOrigin());
    expect(reopened, isNot(same(first)));
    expect(factoryBuilds, 2);

    // Two pages on one session: closing the first keeps it for the second.
    final again = registry.open(const AiGeneralOrigin());
    expect(again, same(reopened));
    registry.release(again);
    expect(created[1].disposed, isFalse);
    registry.release(reopened);
    expect(created[1].disposed, isTrue);
  });

  test('release keeps sessions that have items or are running', () async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    final settings = AiSettingsController(MemoryAiStore());
    addTearDown(session.dispose);
    addTearDown(settings.dispose);
    addTearDown(fixture.api.close);
    await session.initialize();
    await session.connect('https://example.com/gitlab', 'synthetic-token');

    final registry = AccountAiRunRegistry(
      session: session,
      settings: settings,
      sessionFactory:
          ({
            required origin,
            required session,
            required settings,
            required runningCount,
            wireClientFactory,
          }) {
            final fake = _FakeChatSession(origin, runningCount);
            return (
              session: fake,
              capacityChanged: fake.notifyCapacityChanged,
              dispose: fake.dispose,
            );
          },
    );
    addTearDown(registry.dispose);

    final withItems =
        registry.open(const AiGeneralOrigin()) as _FakeChatSession;
    withItems.addNotice();
    registry.release(withItems);
    expect(registry.open(const AiGeneralOrigin()), same(withItems));
    expect(withItems.disposed, isFalse);

    final running =
        registry.open(
              AiJobOrigin(project: fixture.project, jobId: 1, jobName: 'one'),
            )
            as _FakeChatSession;
    await running.send('keep running');
    registry.release(running);
    expect(
      registry.open(
        AiJobOrigin(project: fixture.project, jobId: 1, jobName: 'one'),
      ),
      same(running),
    );
    expect(running.disposed, isFalse);
  });

  test('generation change stops and disposes every live session', () async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    final settings = AiSettingsController(MemoryAiStore());
    addTearDown(session.dispose);
    addTearDown(settings.dispose);
    addTearDown(fixture.api.close);
    await session.initialize();
    await session.connect('https://example.com/gitlab', 'synthetic-token');

    final created = <_FakeChatSession>[];
    final registry = AccountAiRunRegistry(
      session: session,
      settings: settings,
      sessionFactory:
          ({
            required origin,
            required session,
            required settings,
            required runningCount,
            wireClientFactory,
          }) {
            final fake = _FakeChatSession(origin, runningCount);
            created.add(fake);
            return (
              session: fake,
              capacityChanged: fake.notifyCapacityChanged,
              dispose: fake.dispose,
            );
          },
    );
    final first = registry.open(const AiGeneralOrigin());
    registry.open(
      AiJobOrigin(project: fixture.project, jobId: 1, jobName: 'one'),
    );
    await first.send('keep running');

    await session.endSession();

    expect(registry.isDisposed, isTrue);
    expect(created, everyElement(isA<_FakeChatSession>()));
    expect(created.every((item) => item.stopCalls == 1), isTrue);
    expect(created.every((item) => item.disposed), isTrue);
    expect(() => registry.open(const AiGeneralOrigin()), throwsStateError);
  });

  test(
    'real controllers reserve three slots and generation disposal closes transports',
    () async {
      final fixture = WorkspaceFixture();
      final accounts = MemoryAccountStore()
        ..accounts = [fixture.account]
        ..lastActive = fixture.account.key;
      final session = controllerFor(accounts, fixture.adapter);
      final settings = AiSettingsController(MemoryAiStore());
      addTearDown(session.dispose);
      addTearDown(settings.dispose);
      addTearDown(fixture.api.close);
      await session.initialize();
      await settings.initialize();
      final provider = await settings.saveProvider(_provider());
      await settings.loadAccount(fixture.account.key);
      await settings.grantConsent(
        fixture.account.key,
        aiConversationConsentContract(
          settings,
          fixture.account.key,
          provider,
        ),
        const <String, Object?>{'synthetic': true},
      );

      final streams = <StreamController<Uint8List>>[];
      final adapters = <FakeAdapter>[];
      addTearDown(() async {
        for (final stream in streams) {
          if (!stream.isClosed) await stream.close();
        }
      });
      final registry = AccountAiRunRegistry(
        session: session,
        settings: settings,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) {
              final stream = StreamController<Uint8List>.broadcast();
              final adapter = FakeAdapter(
                (_) => ResponseBody(
                  stream.stream,
                  200,
                  headers: {
                    Headers.contentTypeHeader: ['text/event-stream'],
                  },
                ),
              );
              streams.add(stream);
              adapters.add(adapter);
              return _wireClient(
                adapter,
                config: config,
                apiKey: apiKey,
                conversationId: conversationId,
              );
            },
      );
      addTearDown(registry.dispose);

      final contextOrigin = AiJobOrigin(
        project: fixture.project,
        jobId: 501,
        jobName: 'analyze',
      );
      final firstContext = registry.open(contextOrigin);
      await _waitFor(() => firstContext.canSend);
      int contextReads() => fixture.adapter.requests
          .where(
            (request) => request.uri.path.endsWith('/projects/42/jobs/501'),
          )
          .length;
      expect(contextReads(), 1);
      registry.release(firstContext);

      final reopenedContext = registry.open(contextOrigin);
      expect(reopenedContext, isNot(same(firstContext)));
      await _waitFor(() => reopenedContext.canSend);
      expect(contextReads(), 2);
      registry.release(reopenedContext);

      final conversations = <AiChatSession>[
        registry.open(const AiGeneralOrigin()),
        registry.open(
          AiFileOrigin(
            project: fixture.project,
            path: '.env',
            sha: WorkspaceFixture.sha,
          ),
        ),
        registry.open(
          AiFileOrigin(
            project: fixture.project,
            path: 'keys/service.pem',
            sha: WorkspaceFixture.sha,
          ),
        ),
        registry.open(
          AiFileOrigin(
            project: fixture.project,
            path: 'deploy/id_ed25519',
            sha: WorkspaceFixture.sha,
          ),
        ),
      ];
      await _waitFor(() => conversations.every((item) => item.canSend));

      void pageListener() {}
      conversations.first.addListener(pageListener);
      final sends = <Future<void>>[
        conversations[0].send('first held run'),
        conversations[1].send('second held run'),
        conversations[2].send('third held run'),
      ];
      expect(registry.runningCount, AiRunRegistry.maxRunning);
      var fourthNotifications = 0;
      conversations[3].addListener(() => fourthNotifications++);
      expect(conversations[3].blocker, AiChatBlocker.tooManyRunning);
      expect(conversations[3].canSend, isFalse);
      expect(conversations[3].items, isEmpty);
      await _waitFor(() => adapters.length == AiRunRegistry.maxRunning);
      streams.first.add(
        Uint8List.fromList(
          utf8.encode(
            'data: ${jsonEncode({
              'type': 'response.completed',
              'response': {'output': <Object?>[]},
            })}\n\n',
          ),
        ),
      );
      await streams.first.close();
      await sends.first;
      await _waitFor(() => conversations[3].canSend);
      expect(conversations[3].blocker, AiChatBlocker.none);
      expect(fourthNotifications, greaterThan(0));
      conversations.first.removeListener(pageListener);
      expect(conversations.first.phase, AiChatPhase.idle);

      await session.endSession();
      await Future.wait(sends).timeout(const Duration(seconds: 2));
      expect(registry.isDisposed, isTrue);
      expect(adapters, hasLength(AiRunRegistry.maxRunning));
      expect(adapters.every((adapter) => adapter.closed), isTrue);
      expect(conversations.every((item) => item.items.isEmpty), isTrue);

      final lateDelta = Uint8List.fromList(
        utf8.encode(
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': 'late'})}\n\n',
        ),
      );
      for (final stream in streams) {
        if (stream.isClosed) continue;
        stream.add(lateDelta);
        await stream.close();
      }
      await Future<void>.delayed(Duration.zero);
      expect(conversations.every((item) => item.items.isEmpty), isTrue);
    },
  );

  testWidgets('injected AI scopes one registry above MaterialApp', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
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
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-token');
    });

    Widget app({AiControllers? ai}) => AuthenticatedApp(
      session: session,
      appearance: appearance,
      shortcuts: shortcuts,
      dynamicLight: const ColorScheme.light(),
      dynamicDark: const ColorScheme.dark(),
      buildInfoLoader: _buildInfo,
      ai: ai,
    );

    await tester.pumpWidget(app());
    await settleNetworkWidgets(tester);
    expect(find.byType(AiRunRegistryScope), findsNothing);

    await tester.pumpWidget(
      app(
        ai: AiControllers(settings: settings, history: history),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.byType(AiRunRegistryScope), findsOneWidget);
    expect(find.byType(AiScope), findsOneWidget);
    final materialContext = tester.element(find.byType(MaterialApp));
    expect(AiRunRegistry.maybeOf(materialContext), isA<AccountAiRunRegistry>());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

final class _FakeChatSession extends ChangeNotifier implements AiChatSession {
  _FakeChatSession(this.origin, this._runningCount);

  final int Function() _runningCount;
  var _phase = AiChatPhase.idle;
  var _blocker = AiChatBlocker.none;
  @override
  AiRunEnd? get lastEnd => null;
  var stopCalls = 0;
  var capacityNotifications = 0;
  var disposed = false;
  final _items = <AiChatItem>[];

  @override
  final AiChatOrigin origin;

  @override
  String get id => origin.key;

  @override
  List<AiChatItem> get items => List.unmodifiable(_items);

  @override
  AiChatPhase get phase => _phase;

  @override
  AiChatBlocker get blocker => _blocker;

  @override
  List<AiProviderConfig> get providers => const <AiProviderConfig>[];

  @override
  AiProviderConfig? get provider => null;

  @override
  AiConsentContract? get consentRequest => null;

  @override
  AiFailure? get failure => null;

  @override
  bool get offerNewConversation => false;

  @override
  bool get historySaved => false;
  @override
  bool get reportNotSaved => false;
  @override
  AiAssistantItem? currentOf(AiAssistantItem item) =>
      items.contains(item) ? item : null;
  @override
  Future<bool> refreshSecrets() async => true;

  @override
  bool get canSend =>
      _phase == AiChatPhase.idle && _runningCount() < AiRunRegistry.maxRunning;

  @override
  Future<void> send(String text) async {
    if (!canSend) {
      _blocker = AiChatBlocker.tooManyRunning;
      notifyListeners();
      return;
    }
    _blocker = AiChatBlocker.none;
    _phase = AiChatPhase.running;
    notifyListeners();
  }

  @override
  void stop() {
    stopCalls++;
    if (_phase == AiChatPhase.running || _phase == AiChatPhase.stopping) {
      _phase = AiChatPhase.idle;
      if (!disposed) notifyListeners();
    }
  }

  @override
  void startNewConversation() {}

  @override
  Future<void> useProvider(String providerId) async {}

  @override
  Future<void> recheck() async {
    if (_blocker == AiChatBlocker.tooManyRunning &&
        _runningCount() < AiRunRegistry.maxRunning) {
      _blocker = AiChatBlocker.none;
      notifyListeners();
    }
  }

  @override
  void markReported(AiAssistantItem item) {}

  void notifyCapacityChanged() {
    capacityNotifications++;
    if (_blocker == AiChatBlocker.tooManyRunning &&
        _runningCount() < AiRunRegistry.maxRunning) {
      _blocker = AiChatBlocker.none;
    }
    notifyListeners();
  }

  void addNotice() {
    _items.add(const AiNoticeItem(AiNoticeKind.newConversation));
    notifyListeners();
  }

  @override
  set confirmCleartext(Future<bool> Function()? callback) {}

  @override
  String displaySafe(String text) => text;
  @override
  String draftSafe(String text) => text;

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    super.dispose();
  }
}
