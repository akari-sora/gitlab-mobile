import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart'
    show AiChatWireClientFactory;
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_run_notification_ui.dart';
import 'package:gitlab_mobile/features/ai/ai_run_notifications.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/security/app_lock.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import 'fake_shortcuts.dart';
import 'memory_appearance_store.dart';
import 'widget_settle.dart';
import 'workspace_fixture.dart';

/// Words a conversation knows that must never reach a notification.
const notificationSentinels = [
  'PROJECT_SENTINEL',
  'PATH_SENTINEL',
  'TITLE_SENTINEL',
  'PROMPT_SENTINEL',
  'ANSWER_SENTINEL',
];

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

Map<String, Object?> notificationChannel(String id, {int importance = 3}) => {
  'id': id,
  'name': 'Generic channel',
  'importance': importance,
  'showBadge': true,
  'bypassDnd': false,
  'playSound': true,
  'enableLights': false,
  'enableVibration': true,
  'ledColor': 0,
};

/// The pinned plugin's Android channel. The plugin's own serialization and
/// tap handler run; only the platform side is replaced.
final class FakeNotificationPlatform {
  final calls = <MethodCall>[];
  String? launchPayload;
  Completer<void>? launchBarrier;
  Completer<void>? launchRequested;
  bool? notificationsEnabled = false;
  Completer<void>? permissionBarrier;
  List<Map<String, Object?>>? channels = [];

  /// The system's answer to the permission request; null is an error.
  bool? permission = true;

  List<Map<String, Object?>> get shows => [
    for (final call in calls)
      if (call.method == 'show')
        Map<String, Object?>.from(call.arguments as Map),
  ];

  int get permissionRequests => calls
      .where((call) => call.method == 'requestNotificationsPermission')
      .length;

  /// Every call needs the Android target: run the test with
  /// `variant: TargetPlatformVariant.only(TargetPlatform.android)`.
  void install() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  void uninstall() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null);

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    return switch (call.method) {
      'initialize' => true,
      'getNotificationAppLaunchDetails' => await _launchDetails(),
      'cancel' || 'show' => null,
      'getActiveNotifications' => const <Object?>[],
      'areNotificationsEnabled' => notificationsEnabled,
      'getNotificationChannels' => channels,
      'requestNotificationsPermission' => await _requestPermission(),
      _ => throw StateError('Unexpected platform call: ${call.method}'),
    };
  }

  Future<bool?> _requestPermission() async {
    await permissionBarrier?.future;
    return notificationsEnabled = permission;
  }

  Future<Object?> _launchDetails() async {
    final details = {
      'notificationLaunchedApp': launchPayload != null,
      if (launchPayload != null)
        'notificationResponse': _response(launchPayload!),
    };
    launchRequested?.complete();
    await launchBarrier?.future;
    return details;
  }

  Map<String, Object?> _response(String payload) => {
    'notificationId': 6200,
    'notificationResponseType': 0,
    'payload': payload,
    'actionId': null,
    'input': null,
  };

  /// A tap on a shown notification while the process runs.
  Future<void> tap(String payload) async {
    final done = Completer<void>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('didReceiveNotificationResponse', _response(payload)),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }
}

final class MemoryRunNoticeStore implements AiRunNoticeStore {
  bool asked = false;
  bool failRead = false;
  bool failWrite = false;
  int reads = 0;
  int writes = 0;

  @override
  Future<bool> readAsked() async {
    reads++;
    if (failRead) throw StateError('synthetic marker read failure');
    return asked;
  }

  @override
  Future<void> markAsked() async {
    writes++;
    if (failWrite) throw StateError('synthetic marker write failure');
    asked = true;
  }
}

String notificationPayload(String conversationId, int generation) =>
    AiRunNotificationRoute(
      conversationId: conversationId,
      generation: generation,
    ).encode();

AiWriteProposal notificationProposal(String executionId) => AiWriteProposal(
  executionId: executionId,
  operationId: 'createNote',
  tier: const AiTierDecision(
    decision: AiGateDecision.requireApproval,
    tier: AiWriteTier.t2,
    requiresTypedName: false,
    typedName: null,
    reasons: [],
  ),
  payloadDigest: 'synthetic-digest',
  previewText: 'createNote PATH_SENTINEL',
  userUtterance: 'PROMPT_SENTINEL',
  modelReason: 'ANSWER_SENTINEL',
  expiresAt: DateTime.now().add(const Duration(minutes: 30)),
  proposalEpoch: 1,
  writePolicyRevision: 1,
  consentHash: 'synthetic-consent',
  scopeRevision: 1,
  releaseName: 'TITLE_SENTINEL',
  fields: const {'body': 'ANSWER_SENTINEL'},
);

/// A conversation the chat page can show, with approval cards. It records
/// what it was asked to do; nothing here may approve from a notification.
final class NotificationChat extends ChangeNotifier
    implements AiChatSession, AiWriteChatSession, AiRunNotificationSource {
  NotificationChat({this.id = 'conversation-1', AiChatOrigin? origin})
    : origin =
          origin ??
          const AiWorkItemOrigin(
            project: Project(
              id: 9,
              name: 'PROJECT_SENTINEL',
              path: 'PATH_SENTINEL',
            ),
            kind: AiWorkItemKind.mergeRequest,
            iid: 7,
            title: 'TITLE_SENTINEL',
          );

  @override
  String id;
  @override
  final AiChatOrigin origin;
  @override
  List<AiChatItem> items = const [
    AiAssistantItem(text: 'ANSWER_SENTINEL', state: AiAssistantState.done),
  ];
  @override
  AiChatPhase phase = AiChatPhase.awaitingApproval;
  @override
  AiChatBlocker get blocker => AiChatBlocker.none;
  @override
  List<AiProviderConfig> get providers => const [];
  @override
  AiProviderConfig? get provider => null;
  @override
  AiConsentContract? get consentRequest => null;
  @override
  UserFacingFailure? get failure => null;
  @override
  AiRunEnd? get lastEnd => null;
  @override
  bool get offerNewConversation => false;
  @override
  bool get historySaved => false;
  @override
  bool get reportNotSaved => false;
  @override
  bool get canSend => phase == AiChatPhase.idle;

  final sent = <String>[];
  final approved = <AiWriteProposal>[];
  var stops = 0;
  final _events = StreamController<AiRunNotificationEvent>.broadcast(
    sync: true,
  );

  @override
  Stream<AiRunNotificationEvent> get notificationEvents => _events.stream;

  /// Publishes [kind] the way the chat controller does.
  void emit(AiRunNotificationKind kind, int generation) => _events.add(
    AiRunNotificationEvent(
      kind: kind,
      conversationId: id,
      generation: generation,
    ),
  );

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }

  @override
  Future<void> send(String text) async => sent.add(text);
  @override
  void markReported(AiAssistantItem item) {}
  @override
  AiAssistantItem? currentOf(AiAssistantItem item) =>
      items.contains(item) ? item : null;
  @override
  Future<bool> refreshSecrets() async => true;
  @override
  void stop() => stops++;
  @override
  void startNewConversation() {}
  @override
  Future<void> useProvider(String providerId) async {}
  @override
  Future<void> recheck() async {}
  @override
  set confirmCleartext(Future<bool> Function()? callback) {}
  @override
  String displaySafe(String text) => text;
  @override
  String draftSafe(String text) => text;

  @override
  List<AiWriteProposal> proposals = [];
  @override
  AiAutonomyLevel get autonomyLevel => AiAutonomyLevel.confirmEach;
  @override
  AiAutonomyLevel get autonomyCeiling => AiAutonomyLevel.readOnly;
  @override
  Future<void> setAutonomyLevel(AiAutonomyLevel level) async {}
  @override
  Future<AiWriteOutcome> approveWrite(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  }) async {
    approved.add(proposal);
    return const AiWriteOutcome(
      state: AiJournalState.notExecuted,
      reasonCode: 'synthetic',
    );
  }

  @override
  Future<void> rejectWrite(AiWriteProposal proposal) async {}
  @override
  List<AiStoredAttachment> get attachments => const [];
  @override
  bool get canAttach => false;
  @override
  Future<AiAttachResult> attach(AiAttachmentPick pick) async =>
      const AiAttachResult(status: AiAttachStatus.stored, reasonCode: null);
  @override
  void removeAttachment(String id) {}
}

/// A conversation whose phase is idle while its run is paused: like the
/// controller, it reports back protection through [AiExecutionChatSession]
/// rather than through its phase.
final class PausedNotificationChat extends NotificationChat
    implements AiExecutionChatSession {
  PausedNotificationChat() {
    phase = AiChatPhase.idle;
  }

  /// Whether a paused run keeps the conversation protected.
  bool paused = false;

  @override
  int get backProtectedCount => paused ? 1 : 0;
  @override
  int get serviceWorkCount => 0;
  @override
  AiChatExecutionStatus get executionStatus => paused
      ? AiChatExecutionStatus.paused
      : AiChatExecutionStatus.foregroundOnly;
}

/// A signed-in shell with AI, its registry and the run-notification gate,
/// built the way `main.dart` builds them.
final class NotificationShell {
  NotificationShell._(
    this.session,
    this.notifications,
    this.gate,
    this.chat,
    this._app,
  );

  final Widget Function({Key? key}) _app;
  final SessionController session;
  final AiRunNotifications notifications;
  final AiRunNotificationGate gate;
  final NotificationChat chat;

  int get generation => session.generation;

  AiRunRegistry registry(WidgetTester tester) =>
      AiRunRegistry.maybeOf(tester.element(find.byType(MaterialApp)))!;

  /// Replaces the shell, as an account switch does (`main.dart` keys it on
  /// the generation): the new shell is built before the old one goes away.
  Future<void> replaceShell(WidgetTester tester, Key key) async {
    await tester.pumpWidget(_app(key: key));
    await settleNetworkWidgets(tester);
  }

  /// Puts [chat] in the registry, as a chat page that opened it would.
  NotificationChat openChat(WidgetTester tester) {
    final opened = registry(tester).open(chat.origin);
    expect(opened, same(chat));
    return chat;
  }

  static Future<NotificationShell> start(
    WidgetTester tester, {
    required FakeNotificationPlatform platform,
    AppLockController? lock,
    bool initializeBeforeShell = true,
    MethodChannel? aiRunsChannel,
    NotificationChat? withChat,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    final settings = AiSettingsController(MemoryAiStore());
    final history = AiHistoryCoordinator(store: settings.store);
    final appearance = AppearanceController(MemoryAppearanceStore());
    final shortcuts = LauncherShortcuts(
      FakeAppShortcutHost(),
      MemoryRecentProjectStore(),
    );
    final notifications = AiRunNotifications(text: aiRunNotificationText);
    final gate = AiRunNotificationGate(notifications, lock: lock);
    final chat =
        withChat ?? (NotificationChat()
          ..proposals = [notificationProposal('exec-1')]);
    // Registered first, so it runs after the shell and registry are gone.
    addTearDown(chat.dispose);
    addTearDown(session.dispose);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    addTearDown(appearance.dispose);
    addTearDown(shortcuts.dispose);
    addTearDown(fixture.api.close);
    addTearDown(notifications.dispose);
    addTearDown(gate.dispose);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-token');
    });
    if (initializeBeforeShell) {
      // As main.dart does at start, before any shell exists.
      expect(await notifications.initialize(), isTrue);
    }
    Widget app({Key? key}) => AuthenticatedApp(
      key: key,
      session: session,
      appearance: appearance,
      shortcuts: shortcuts,
      dynamicLight: const ColorScheme.light(),
      dynamicDark: const ColorScheme.dark(),
      buildInfoLoader: () async => const BuildInfo(
        version: '0.6.0',
        buildNumber: '6',
        commit: 'mr6c-c3',
      ),
      lock: lock,
      ai: AiControllers(settings: settings, history: history),
      aiSessionFactory:
          ({
            required AiChatOrigin origin,
            required SessionController session,
            required AiSettingsController settings,
            required int Function() runningCount,
            AiChatWireClientFactory? wireClientFactory,
          }) => (session: chat, capacityChanged: () {}, dispose: () {}),
      runNotifications: gate,
      aiRunsChannel: aiRunsChannel,
    );
    await tester.pumpWidget(app());
    await settleNetworkWidgets(tester);
    return NotificationShell._(session, notifications, gate, chat, app);
  }
}

/// The root destination the shell shows.
int selectedDestination(WidgetTester tester) {
  final bar = find.byType(NavigationBar);
  if (bar.evaluate().isNotEmpty) {
    return tester.widget<NavigationBar>(bar).selectedIndex;
  }
  return tester
      .widget<NavigationRail>(find.byType(NavigationRail))
      .selectedIndex!;
}
