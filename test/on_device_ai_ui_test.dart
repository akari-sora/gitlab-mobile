import 'dart:async';

import 'package:dio/dio.dart' show ResponseBody;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/ai/on_device_transport.dart';
import 'package:gitlab_mobile/core/ai/prompts.dart';
import 'package:gitlab_mobile/core/ai/runner.dart' show AiRunEnd;
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_consent_dialog.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_provider_editor.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_settings_page.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_ui.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/demo/demo_scope.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'package:mergeline_on_device_ai/mergeline_on_device_ai.dart';

import 'ai/release_policy_support.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';

/// Fake [MergelineOnDeviceAi] that fails the test immediately if any ML Kit
/// method ([status], [download], or [generate]) is invoked before consent has
/// been granted.
final class _ConsentGuardedOnDeviceAi extends MergelineOnDeviceAi {
  _ConsentGuardedOnDeviceAi({
    required this.isConsentGranted,
    this.supportResult = const OnDeviceSupport.likely(),
    this.statusResult = const OnDeviceStatus.available(
      modelName: 'gemini-nano',
    ),
  }) : super(isAndroid: () => true);

  final bool Function() isConsentGranted;
  OnDeviceSupport supportResult;
  OnDeviceStatus statusResult;
  Stream<OnDeviceDownloadEvent> Function()? onDownload;
  Stream<String> Function({
    required String system,
    required List<OnDeviceTurn> turns,
    int? maxOutputTokens,
    double? temperature,
  })?
  onGenerate;

  int deviceSupportCalls = 0;
  int statusCalls = 0;
  int downloadCalls = 0;
  int generateCalls = 0;
  int closeCalls = 0;
  final List<String> cancelledRequestIds = <String>[];

  void _requireConsent(String method) {
    if (!isConsentGranted()) {
      fail(
        'Privacy violation: MergelineOnDeviceAi.$method() was called before '
        'the user accepted the on-device consent dialog!',
      );
    }
  }

  @override
  Future<OnDeviceSupport> deviceSupport() async {
    deviceSupportCalls++;
    return supportResult;
  }

  @override
  Future<OnDeviceStatus> status() async {
    _requireConsent('status');
    statusCalls++;
    return statusResult;
  }

  @override
  Stream<OnDeviceDownloadEvent> download() {
    _requireConsent('download');
    downloadCalls++;
    if (onDownload != null) {
      return onDownload!();
    }
    return const Stream<OnDeviceDownloadEvent>.empty();
  }

  @override
  OnDeviceGenerationStream generate({
    required String system,
    required List<OnDeviceTurn> turns,
    int? maxOutputTokens,
    double? temperature,
    String? requestId,
    void Function(String requestId)? onRequestId,
  }) {
    _requireConsent('generate');
    generateCalls++;
    final resolvedId = requestId ?? 'fake-req-$generateCalls';
    onRequestId?.call(resolvedId);
    final stream = onGenerate != null
        ? onGenerate!(
            system: system,
            turns: turns,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
          )
        : Stream<String>.fromIterable(const <String>['On-device reply']);
    return OnDeviceGenerationStream(requestId: resolvedId, stream: stream);
  }

  @override
  Future<void> cancel(String requestId) async {
    cancelledRequestIds.add(requestId);
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

final class _FakeOnDevicePluginCall {
  _FakeOnDevicePluginCall({
    required this.requestId,
    required this.system,
    required this.turns,
  });

  final String requestId;
  final String system;
  final List<OnDeviceTurn> turns;
}

final class _FakeOnDeviceTransportPlugin implements OnDeviceAiPlugin {
  final List<_FakeOnDevicePluginCall> calls = <_FakeOnDevicePluginCall>[];
  final List<String> cancelledIds = <String>[];
  int _nextId = 1;
  Stream<String> Function(_FakeOnDevicePluginCall call)? handler;

  @override
  OnDeviceGenerationStream generate({
    required String system,
    required List<OnDeviceTurn> turns,
    int? maxOutputTokens,
    double? temperature,
  }) {
    final id = 'req-${_nextId++}';
    final call = _FakeOnDevicePluginCall(
      requestId: id,
      system: system,
      turns: List<OnDeviceTurn>.unmodifiable(turns),
    );
    calls.add(call);
    final stream = handler != null
        ? handler!(call)
        : Stream<String>.fromIterable(const <String>['On-device answer']);
    return OnDeviceGenerationStream(requestId: id, stream: stream);
  }

  @override
  Future<void> cancel(String requestId) async {
    cancelledIds.add(requestId);
  }
}

final class _ChatEnvironment {
  _ChatEnvironment(this.workspace, this.session, this.settings);
  final WorkspaceFixture workspace;
  final SessionController session;
  final AiSettingsController settings;

  void dispose() {
    settings.dispose();
    session.dispose();
  }
}

Future<_ChatEnvironment> _createChatEnvironment({
  String? repositoryText,
  Future<void> Function()? closeOnDeviceAi,
}) async {
  final workspace = WorkspaceFixture();
  final adapter = repositoryText == null
      ? workspace.adapter
      : FakeAdapter((request) {
          if (request.uri.path.endsWith('/repository/files/README.md/raw')) {
            return ResponseBody.fromString(repositoryText, 200);
          }
          return workspace.respond(request);
        });
  final accounts = MemoryAccountStore()
    ..accounts = [workspace.account]
    ..lastActive = workspace.account.key;
  final session = controllerFor(accounts, adapter);
  await session.initialize();
  final settings = AiSettingsController(
    MemoryAiStore(),
    closeOnDeviceAi: closeOnDeviceAi,
  );
  await settings.initialize();
  await settings.loadAccount(workspace.account.key);
  return _ChatEnvironment(workspace, session, settings);
}

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  home: child,
);

Widget _scopedHost(
  AiSettingsController settings,
  String accountKey,
  Widget child,
) => _host(
  AiScope(
    controllers: AiControllers(
      settings: settings,
      history: AiHistoryCoordinator.instance,
    ),
    accountKey: accountKey,
    child: child,
  ),
);

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  setUp(() {
    useLanguage(languageForTag('zh-TW')!);
  });

  group(
    '1. Pre-consent visibility from deviceSupport() only & Demo/iOS hidden',
    () {
      testWidgets(
        'on Android, deviceSupport() decides visibility and never touches '
        'status(), download(), or generate() before consent',
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          try {
            var closeCalls = 0;
            final settings = AiSettingsController(
              MemoryAiStore(),
              closeOnDeviceAi: () async => closeCalls++,
            );
            addTearDown(settings.dispose);
            await settings.initialize();
            const accountKey = 'https://gitlab.example#1';
            await settings.loadAccount(accountKey);

            final plugin = _ConsentGuardedOnDeviceAi(
              isConsentGranted: () {
                final existing = settings.providers
                    .where((p) => p.id == 'on-device')
                    .firstOrNull;
                final contract = aiConsentContractFor(
                  existing ?? AiProviderConfig.onDevice(),
                );
                return settings.isValid(accountKey, contract);
              },
            );

            await tester.pumpWidget(
              _host(
                AiProviderEditor(
                  settings: settings,
                  accountKey: accountKey,
                  onDeviceAi: plugin,
                ),
              ),
            );
            await tester.pumpAndSettle();

            expect(plugin.deviceSupportCalls, 1);
            expect(plugin.statusCalls, 0);
            expect(plugin.downloadCalls, 0);
            expect(plugin.generateCalls, 0);
            expect(
              find.byKey(
                const ValueKey('ai-preset-on-device'),
                skipOffstage: false,
              ),
              findsOneWidget,
            );

            // Selecting the on-device preset before consent shows the pre-consent
            // card and MUST NOT call status(), download(), or generate().
            final presetField = tester
                .widget<DropdownButtonFormField<AiPreset>>(
                  find.byKey(const ValueKey('ai-provider-preset')),
                );
            presetField.onChanged!(AiPresets.onDevice);
            await tester.pumpAndSettle();

            expect(plugin.statusCalls, 0);
            expect(plugin.downloadCalls, 0);
            expect(plugin.generateCalls, 0);
            expect(
              find.byKey(const ValueKey('ai-on-device-consent-required')),
              findsOneWidget,
            );
            expect(
              find.text(l10n.aiOnDeviceConsentBeforeStatus),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('ai-on-device-review-consent')),
              findsOneWidget,
            );
            // Cloud fields (URL, format, model, key, tools) are hidden.
            expect(
              find.byKey(const ValueKey('ai-provider-base-url')),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('ai-provider-api-key')),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('ai-provider-tools')),
              findsNothing,
            );
            expect(closeCalls, 0);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );

      testWidgets(
        'on Android, when deviceSupport() returns unsupported, the on-device '
        'preset is hidden and ML Kit is never touched',
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          try {
            final settings = AiSettingsController(MemoryAiStore());
            addTearDown(settings.dispose);
            await settings.initialize();
            final plugin = _ConsentGuardedOnDeviceAi(
              isConsentGranted: () => false,
              supportResult: const OnDeviceSupport.unsupported(
                reason: 'aicore_missing',
              ),
            );

            await tester.pumpWidget(
              _host(
                AiProviderEditor(
                  settings: settings,
                  accountKey: 'https://gitlab.example#1',
                  onDeviceAi: plugin,
                ),
              ),
            );
            await tester.pumpAndSettle();

            expect(plugin.deviceSupportCalls, 1);
            expect(plugin.statusCalls, 0);
            expect(
              find.byKey(
                const ValueKey('ai-preset-on-device'),
                skipOffstage: false,
              ),
              findsNothing,
            );
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );

      testWidgets(
        'on iOS and in Demo mode, the on-device option is never offered even if '
        'deviceSupport() would return likely',
        (tester) async {
          final settings = AiSettingsController(MemoryAiStore());
          addTearDown(settings.dispose);
          await settings.initialize();
          final plugin = _ConsentGuardedOnDeviceAi(
            isConsentGranted: () => false,
            supportResult: const OnDeviceSupport.likely(),
          );

          // 1. iOS
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          try {
            await tester.pumpWidget(
              _host(
                AiProviderEditor(
                  settings: settings,
                  accountKey: 'https://gitlab.example#1',
                  onDeviceAi: plugin,
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              find.byKey(
                const ValueKey('ai-preset-on-device'),
                skipOffstage: false,
              ),
              findsNothing,
            );
            expect(plugin.deviceSupportCalls, 0);
            expect(plugin.statusCalls, 0);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }

          // 2. Demo mode on Android
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          try {
            await tester.pumpWidget(
              DemoScope(
                exit: () async {},
                child: _host(
                  AiProviderEditor(
                    settings: settings,
                    accountKey: 'https://gitlab.example#1',
                    onDeviceAi: plugin,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              find.byKey(
                const ValueKey('ai-preset-on-device'),
                skipOffstage: false,
              ),
              findsNothing,
            );
            expect(plugin.deviceSupportCalls, 0);
            expect(plugin.statusCalls, 0);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );
    },
  );

  group('2. Consent text and process-wide close() on revoke/delete', () {
    testWidgets(
      'on-device consent dialog shows AICore local processing, ML Kit '
      'diagnostics/installation ID disclosure, restart requirement, and '
      'ML Kit disclosure link; revoking or deleting calls close()',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          var closeCalls = 0;
          final settings = AiSettingsController(
            MemoryAiStore(),
            closeOnDeviceAi: () async => closeCalls++,
          );
          addTearDown(settings.dispose);
          await settings.initialize();
          const accountKey = 'https://gitlab.example#1';
          await settings.loadAccount(accountKey);

          final plugin = _ConsentGuardedOnDeviceAi(
            isConsentGranted: () {
              final existing = settings.providers
                  .where((p) => p.id == 'on-device')
                  .firstOrNull;
              final contract = aiConsentContractFor(
                existing ?? AiProviderConfig.onDevice(),
              );
              return settings.isValid(accountKey, contract);
            },
            statusResult: const OnDeviceStatus.available(
              modelName: 'gemini-nano',
            ),
          );

          await tester.pumpWidget(
            _scopedHost(
              settings,
              accountKey,
              AiProviderEditor(
                settings: settings,
                accountKey: accountKey,
                onDeviceAi: plugin,
              ),
            ),
          );
          await tester.pumpAndSettle();

          final presetField = tester.widget<DropdownButtonFormField<AiPreset>>(
            find.byKey(const ValueKey('ai-provider-preset')),
          );
          presetField.onChanged!(AiPresets.onDevice);
          await tester.pumpAndSettle();
          expect(plugin.statusCalls, 0);

          // Open the consent dialog from the editor.
          await tester.tap(
            find.byKey(const ValueKey('ai-on-device-review-consent')),
          );
          await tester.pumpAndSettle();

          // Its own wording: nothing is "sent" to an AI server, and the
          // internal origin is not shown as an address.
          expect(find.text(l10n.aiConsentOnDeviceTitle), findsOneWidget);
          expect(find.text(l10n.aiConsentTitle), findsNothing);
          expect(find.text(l10n.aiConsentOnDeviceRecipient), findsOneWidget);
          expect(find.text(AiPresets.onDeviceOrigin), findsNothing);
          await tester.dragUntilVisible(
            find.text(l10n.aiConsentOnDeviceDataDescription),
            find.byType(ListView).last,
            const Offset(0, -160),
          );
          expect(find.text(l10n.aiConsentOnDeviceDataHeading), findsOneWidget);
          expect(find.text(l10n.aiConsentDataHeading), findsNothing);
          expect(find.text(l10n.aiConsentDataDescription), findsNothing);

          await tester.dragUntilVisible(
            find.text(l10n.aiConsentOnDeviceStaysOnPhone),
            find.byType(ListView).last,
            const Offset(0, -160),
          );
          expect(find.text(l10n.aiConsentOnDeviceStaysOnPhone), findsOneWidget);
          expect(
            find.text(l10n.aiConsentOnDeviceMlKitTelemetry),
            findsOneWidget,
          );
          expect(
            find.text(l10n.aiConsentOnDeviceCannotStopUntilRestart),
            findsOneWidget,
          );

          await tester.dragUntilVisible(
            find.text(l10n.aiConsentOnDeviceDisclosureLinkLabel),
            find.byType(ListView).last,
            const Offset(0, -160),
          );
          expect(
            find.text(l10n.aiConsentOnDeviceDisclosureLinkLabel),
            findsOneWidget,
          );
          expect(
            find.text(
              'https://developers.google.com/ml-kit/android-data-disclosure',
            ),
            findsOneWidget,
          );

          // No cloud wording: nothing goes to a provider, so neither the
          // provider-policy sentence nor the cannot-retract box is shown.
          await tester.dragUntilVisible(
            find.text(l10n.aiConsentSelfManagedNoticeOnDevice),
            find.byType(ListView).last,
            const Offset(0, -160),
          );
          expect(find.text(l10n.aiConsentSelfManagedNotice), findsNothing);
          expect(find.text(l10n.aiConsentIrreversible), findsNothing);

          // Still 0 status calls before tapping Agree!
          expect(plugin.statusCalls, 0);

          await tester.tap(find.text(l10n.aiConsentAgree));
          await tester.pumpAndSettle();

          // Now consent is granted, so status() was called once and displays
          // Available.
          expect(plugin.statusCalls, 1);
          expect(find.text(l10n.aiOnDeviceStatusAvailable), findsOneWidget);

          // Revoking consent calls close().
          await settings.revokeConsent(accountKey, 'on-device');
          expect(closeCalls, 1);

          // Deleting the on-device provider also calls close().
          await settings.deleteProvider('on-device');
          expect(closeCalls, 2);

          // Resetting providers with an on-device one also calls close().
          await settings.saveProvider(AiProviderConfig.onDevice());
          await settings.resetProviders();
          expect(closeCalls, 3);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  group('3. Post-consent model status and download progress', () {
    testWidgets('after consent, AiProviderEditor displays downloadable status, '
        'streams download progress in MB, transitions to available, and '
        'maps unavailable reasons', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final settings = AiSettingsController(MemoryAiStore());
        addTearDown(settings.dispose);
        await settings.initialize();
        const accountKey = 'https://gitlab.example#1';
        await settings.loadAccount(accountKey);
        final saved = await settings.saveProvider(AiProviderConfig.onDevice());
        await settings.grantConsent(
          accountKey,
          aiConsentContractFor(saved),
          const <String, Object?>{'synthetic': true},
        );

        final downloadController =
            StreamController<OnDeviceDownloadEvent>.broadcast();
        addTearDown(downloadController.close);

        final plugin = _ConsentGuardedOnDeviceAi(
          isConsentGranted: () => true,
          statusResult: const OnDeviceStatus.downloadable(
            modelName: 'gemini-nano',
          ),
        )..onDownload = () => downloadController.stream;

        await tester.pumpWidget(
          _scopedHost(
            settings,
            accountKey,
            AiProviderEditor(
              settings: settings,
              provider: saved,
              accountKey: accountKey,
              onDeviceAi: plugin,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(plugin.statusCalls, 1);
        expect(find.text(l10n.aiOnDeviceStatusDownloadable), findsOneWidget);
        expect(
          find.byKey(const ValueKey('ai-on-device-download')),
          findsOneWidget,
        );

        // Tap Download button.
        await tester.tap(find.byKey(const ValueKey('ai-on-device-download')));
        await tester.pump();

        expect(plugin.downloadCalls, 1);
        expect(find.text(l10n.aiOnDeviceStatusDownloading), findsOneWidget);
        expect(
          find.byKey(const ValueKey('ai-on-device-download-progress')),
          findsOneWidget,
        );

        // Emit byte progress (12 MiB of 48 MiB).
        downloadController.add(
          const OnDeviceDownloadEvent.progress(
            bytesDownloaded: 12 * 1024 * 1024,
            bytesToDownload: 48 * 1024 * 1024,
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('ai-on-device-download-progress-text')),
          findsOneWidget,
        );
        expect(
          find.text(l10n.aiOnDeviceDownloadProgress('12.0', '48.0')),
          findsOneWidget,
        );

        // Complete the download.
        plugin.statusResult = const OnDeviceStatus.available(
          modelName: 'gemini-nano',
        );
        downloadController.add(const OnDeviceDownloadEvent.completed());
        await tester.pumpAndSettle();

        expect(find.text(l10n.aiOnDeviceStatusAvailable), findsOneWidget);

        // Verify unavailable reason mapping when status is unavailable.
        for (final (reason, expectedText) in <(String, String)>[
          ('sdk_too_old', l10n.aiOnDeviceUnavailableReasonSdkTooOld),
          ('aicore_missing', l10n.aiOnDeviceUnavailableReasonAicoreMissing),
          ('aicore_disabled', l10n.aiOnDeviceUnavailableReasonAicoreDisabled),
          (
            'insufficient_storage',
            l10n.aiOnDeviceUnavailableReasonInsufficientStorage,
          ),
          ('unsupported', l10n.aiOnDeviceUnavailableReasonUnsupported),
        ]) {
          plugin.statusResult = OnDeviceStatus.unavailable(reason: reason);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            _scopedHost(
              settings,
              accountKey,
              AiProviderEditor(
                settings: settings,
                provider: saved,
                accountKey: accountKey,
                onDeviceAi: plugin,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(expectedText), findsOneWidget, reason: reason);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group(
    '4. Chat with fake transport, aiOnDeviceSystemPrompt, and truncation notice',
    () {
      testWidgets(
        'on-device chat uses aiOnDeviceSystemPrompt, never client.transport, '
        'and renders AiNoticeKind.onDeviceContextTruncated when context is cut',
        (tester) async {
          late _ChatEnvironment env;
          late AiChatController controller;
          final fakePlugin = _FakeOnDeviceTransportPlugin()
            ..handler = (_) => Stream<String>.fromIterable(const <String>[
              '這是 ',
              'Gemini Nano 的本地摘要回覆。',
            ]);

          await tester.runAsync(() async {
            env = await _createChatEnvironment(
              repositoryText: List<String>.generate(
                500,
                (i) => 'Line $i: large repository file content for truncation.',
              ).join('\n'),
            );
            final saved = await env.settings.saveProvider(
              AiProviderConfig.onDevice(),
            );
            await env.settings.grantConsent(
              env.workspace.account.key,
              aiConversationConsentContract(
                env.settings,
                env.workspace.account.key,
                saved,
                releasePolicy: fixtureReleasePolicy,
              ),
              const <String, Object?>{'synthetic': true},
            );

            controller = AiChatController(
              releasePolicy: fixtureReleasePolicy,
              appInForeground: () => true,
              origin: AiFileOrigin(
                project: env.workspace.project,
                path: 'README.md',
                sha: WorkspaceFixture.sha,
              ),
              session: env.session,
              settings: env.settings,
              runningCount: () => 0,
              wireClientFactory:
                  ({
                    required config,
                    required apiKey,
                    required conversationId,
                  }) => AiWireClient.onDevice(
                    config: config,
                    conversationId: conversationId,
                    appVersion: 'test',
                    onDeviceTransport: OnDeviceAiTransport(plugin: fakePlugin),
                  ),
            );
            await controller.recheck();
            await controller.send('請摘要這個檔案');
          });
          addTearDown(() {
            controller.dispose();
            env.dispose();
          });

          expect(fakePlugin.calls, hasLength(1));
          final call = fakePlugin.calls.single;
          expect(
            call.system,
            aiOnDeviceSystemPrompt(
              languageTag: l10n.language.tag,
              languageName: l10n.language.name,
            ),
          );
          expect(call.system, isNot(equals(aiSystemPrompt)));
          expect(call.system, isNot(equals(aiWriteSystemPrompt)));
          expect(
            controller.items.whereType<AiNoticeItem>().map((n) => n.kind),
            contains(AiNoticeKind.onDeviceContextTruncated),
          );

          await tester.pumpWidget(_host(AiChatPage(session: controller)));
          await tester.pump();

          expect(
            find.text(l10n.aiNoticeOnDeviceContextTruncated),
            findsOneWidget,
          );
          expect(find.textContaining('Gemini Nano 的本地摘要回覆。'), findsOneWidget);
        },
      );
    },
  );

  group('5. Foreground-only background stop and Continue replacement', () {
    for (final (state, backgroundEnabled) in const [
      (AppLifecycleState.hidden, true),
      (AppLifecycleState.paused, false),
    ]) {
      testWidgets(
        '${state.name} (background service '
        '${backgroundEnabled ? 'on' : 'off'}) stops an on-device run with the '
        'foreground-only message, does not auto-retry on resume, and Continue '
        're-runs the same turn from the start and replaces the partial answer',
        (tester) async {
          late _ChatEnvironment env;
          late AiBackgroundExecution bgExecution;
          late AiChatController controller;
          var inForeground = true;
          final firstTurnStream = StreamController<String>();
          addTearDown(firstTurnStream.close);
          final fakePlugin = _FakeOnDeviceTransportPlugin();
          var turnCount = 0;
          fakePlugin.handler = (_) {
            turnCount++;
            if (turnCount == 1) {
              return firstTurnStream.stream;
            }
            return Stream<String>.fromIterable(const <String>['完整的重新產生回答。']);
          };

          await tester.runAsync(() async {
            env = await _createChatEnvironment();
            final saved = await env.settings.saveProvider(
              AiProviderConfig.onDevice(),
            );
            await env.settings.grantConsent(
              env.workspace.account.key,
              aiConversationConsentContract(
                env.settings,
                env.workspace.account.key,
                saved,
                releasePolicy: fixtureReleasePolicy,
              ),
              const <String, Object?>{'synthetic': true},
            );

            bgExecution = AiBackgroundExecution(
              backgroundEnabled: backgroundEnabled,
              accountKey: env.workspace.account.key,
              generation: env.session.generation,
              ownerApi: env.session.api!,
              isCurrent: () => true,
              appInForeground: () => inForeground,
            );

            controller = AiChatController(
              releasePolicy: fixtureReleasePolicy,
              appInForeground: () => inForeground,
              backgroundExecution: bgExecution,
              origin: const AiGeneralOrigin(),
              session: env.session,
              settings: env.settings,
              runningCount: () => 0,
              wireClientFactory:
                  ({
                    required config,
                    required apiKey,
                    required conversationId,
                  }) => AiWireClient.onDevice(
                    config: config,
                    conversationId: conversationId,
                    appVersion: 'test',
                    onDeviceTransport: OnDeviceAiTransport(plugin: fakePlugin),
                  ),
            );
            await controller.recheck();

            final sendFuture = controller.send('請問這段程式碼做什麼？');
            await _waitFor(() => fakePlugin.calls.length == 1);

            // Stream a partial answer > 256 chars so it flushes to the UI.
            firstTurnStream.add('半截回答內容'.padRight(260, '！'));
            await _waitFor(
              () => controller.items.whereType<AiAssistantItem>().any(
                (item) => item.text.startsWith('半截回答內容'),
              ),
            );

            // The app leaves the foreground.
            inForeground = false;
            bgExecution.didChangeAppLifecycleState(state);
            await sendFuture;
          });
          addTearDown(() {
            controller.dispose();
            bgExecution.dispose();
            env.dispose();
          });

          expect(controller.phase, AiChatPhase.idle);
          expect(controller.lastEnd, AiRunEnd.stopped);
          expect(controller.failure, isNull);
          expect(
            controller.executionPause?.reason,
            AiExecutionPauseReason.foregroundRequired,
          );
          expect(
            controller.resumeWarnings,
            isNot(contains(AiRunResumeWarning.possibleRebilling)),
          );
          expect(fakePlugin.cancelledIds, <String>['req-1']);

          // Returning to the foreground does not retry by itself.
          await tester.runAsync(() async {
            inForeground = true;
            bgExecution.didChangeAppLifecycleState(AppLifecycleState.resumed);
            await Future<void>.delayed(const Duration(milliseconds: 30));
          });
          expect(fakePlugin.calls, hasLength(1));
          expect(controller.canResumeRun, isTrue);

          await tester.pumpWidget(_host(AiChatPage(session: controller)));
          await tester.pump();

          expect(
            find.byKey(const ValueKey('ai-chat-run-paused')),
            findsOneWidget,
          );
          expect(find.text(l10n.aiOnDeviceForegroundOnlyTitle), findsOneWidget);
          expect(
            find.text(l10n.aiOnDeviceForegroundOnlyDetail),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('ai-chat-resume')), findsOneWidget);

          // Continue re-runs the interrupted turn from the start and
          // replaces the partial answer.
          await tester.runAsync(() async {
            await controller.resumeRun();
          });
          await tester.pump();

          expect(fakePlugin.calls, hasLength(2));
          // The same prompt again: no summary of the stopped turn.
          expect(
            fakePlugin.calls[1].turns.map((t) => (t.role, t.text)).toList(),
            fakePlugin.calls[0].turns.map((t) => (t.role, t.text)).toList(),
          );
          expect(
            controller.items.whereType<AiNoticeItem>().map((n) => n.kind),
            isNot(contains(AiNoticeKind.segmentSummary)),
          );
          final assistantItems = controller.items
              .whereType<AiAssistantItem>()
              .toList();
          expect(assistantItems, hasLength(1));
          expect(assistantItems.single.text, '完整的重新產生回答。');
          expect(controller.lastEnd, AiRunEnd.done);
          expect(controller.executionPause, isNull);
        },
      );
    }

    test('AICore refusing in the background pauses the run like a background '
        'stop, with Continue and no failure card', () async {
      final env = await _createChatEnvironment();
      addTearDown(env.dispose);
      final saved = await env.settings.saveProvider(
        AiProviderConfig.onDevice(),
      );
      await env.settings.grantConsent(
        env.workspace.account.key,
        aiConversationConsentContract(
          env.settings,
          env.workspace.account.key,
          saved,
          releasePolicy: fixtureReleasePolicy,
        ),
        const <String, Object?>{'synthetic': true},
      );
      final fakePlugin = _FakeOnDeviceTransportPlugin();
      var turn = 0;
      fakePlugin.handler = (_) => ++turn == 1
          ? Stream<String>.error(
              const OnDeviceAiException(OnDeviceAiErrorCode.backgroundBlocked),
            )
          : Stream<String>.fromIterable(const <String>['Answer']);
      final controller = AiChatController(
        releasePolicy: fixtureReleasePolicy,
        appInForeground: () => true,
        origin: const AiGeneralOrigin(),
        session: env.session,
        settings: env.settings,
        runningCount: () => 0,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) =>
                AiWireClient.onDevice(
                  config: config,
                  conversationId: conversationId,
                  appVersion: 'test',
                  onDeviceTransport: OnDeviceAiTransport(plugin: fakePlugin),
                ),
      );
      addTearDown(controller.dispose);
      await controller.recheck();

      await controller.send('Explain this');
      expect(controller.lastEnd, AiRunEnd.stopped);
      expect(controller.failure, isNull);
      expect(
        controller.executionPause?.reason,
        AiExecutionPauseReason.foregroundRequired,
      );
      expect(controller.canResumeRun, isTrue);

      await controller.resumeRun();
      expect(fakePlugin.calls, hasLength(2));
      expect(controller.lastEnd, AiRunEnd.done);
      expect(
        controller.items.whereType<AiAssistantItem>().single.text,
        'Answer',
      );
    });

    test('an on-device run never starts the background service', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('test/on_device_agent_runs');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final methods = <String>[];
      // A willing native peer: any start would be accepted and recorded.
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        final args = call.arguments as Map<Object?, Object?>;
        return call.method == 'startRuns'
            ? {
                'version': 1,
                'status': 'active',
                'permitId': 'synthetic-permit',
                'startRequestId': args['startRequestId'],
                'opSeq': args['opSeq'],
              }
            : {'version': 1, 'status': 'rejected', 'reason': 'permit_inactive'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final owner = AiBackgroundExecution(
        backgroundEnabled: true,
        accountKey: 'https://gitlab.example#1',
        generation: 1,
        ownerApi: Object(),
        isCurrent: () => true,
        appInForeground: () => true,
        channel: channel,
      );
      addTearDown(owner.dispose);
      final gate = owner.createGate(
        conversationId: () => 'on-device',
        isCurrent: () => true,
      );

      final start = await gate.beginRun(runId: 'run-1', foregroundOnly: true);
      expect(start.disposition, AiBackgroundStartDisposition.foregroundOnly);
      expect(start.failure, isNull);
      expect(gate.executionEligible, isTrue);
      expect(methods, isNot(contains('startRuns')));
      // A running on-device turn does not count as service work.
      expect(owner.serviceWorkCount, 0);

      // The same peer starts the service for a cloud run.
      final cloud = owner.createGate(
        conversationId: () => 'cloud',
        isCurrent: () => true,
      );
      await cloud.beginRun(runId: 'run-2');
      expect(methods, contains('startRuns'));
      expect(owner.serviceWorkCount, 1);
    });

    test(
      'after failed service cleanup an on-device start is unavailable',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        const channel = MethodChannel('test/on_device_agent_runs_orphan');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        // The peer refuses the start and then fails to clean it up.
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => switch (call.method) {
            'startRuns' => {
              'version': 1,
              'status': 'rejected',
              'reason': 'start_denied',
            },
            'releaseRuns' => {
              'version': 1,
              'status': 'rejected',
              'reason': 'cleanup_failed',
            },
            _ => {
              'version': 1,
              'status': 'rejected',
              'reason': 'permit_inactive',
            },
          },
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final owner = AiBackgroundExecution(
          backgroundEnabled: true,
          accountKey: 'https://gitlab.example#1',
          generation: 1,
          ownerApi: Object(),
          isCurrent: () => true,
          appInForeground: () => true,
          channel: channel,
        );
        addTearDown(owner.dispose);
        final cloud = owner.createGate(
          conversationId: () => 'cloud',
          isCurrent: () => true,
        );
        final refused = await cloud.beginRun(runId: 'run-1');
        expect(refused.disposition, AiBackgroundStartDisposition.unavailable);

        final gate = owner.createGate(
          conversationId: () => 'on-device',
          isCurrent: () => true,
        );
        final start = await gate.beginRun(runId: 'run-2', foregroundOnly: true);
        expect(start.disposition, AiBackgroundStartDisposition.unavailable);
        expect(start.failure, AiBackgroundStartFailure.cleanupFailed);
        expect(gate.executionEligible, isFalse);
      },
    );
  });

  group('6. No tools in UI and write refusal card (aiOnDeviceCannotWrite)', () {
    testWidgets(
      'on-device hides tool/write UI affordances and shows the write refusal '
      'card with cloud switch action when the user asks for a GitLab write',
      (tester) async {
        late _ChatEnvironment env;
        late AiChatController controller;
        final fakePlugin = _FakeOnDeviceTransportPlugin();

        await tester.runAsync(() async {
          env = await _createChatEnvironment();
          final onDevice = await env.settings.saveProvider(
            AiProviderConfig.onDevice(),
          );
          final cloud = await env.settings.saveProvider(
            AiProviderConfig(
              id: 'cloud-openai',
              name: 'Cloud OpenAI',
              presetId: 'openai',
              baseUrl: 'https://api.openai.com/v1',
              format: AiFormat.responses,
              model: 'gpt-5.4-mini',
              authStyle: AiAuthStyle.bearer,
              caps: AiPresets.openAi.capsFor(AiFormat.responses),
              allowLanCleartext: false,
              toolsEnabled: true,
              recipientRevision: 1,
            ),
          );
          await env.settings.setDefaultProvider(onDevice.id);
          await env.settings.grantConsent(
            env.workspace.account.key,
            aiConversationConsentContract(
              env.settings,
              env.workspace.account.key,
              onDevice,
              releasePolicy: fixtureReleasePolicy,
            ),
            const <String, Object?>{'synthetic': true},
          );
          expect(cloud.isOnDevice, isFalse);

          controller = AiChatController(
            releasePolicy: fixtureReleasePolicy,
            appInForeground: () => true,
            origin: const AiInboxOrigin(),
            session: env.session,
            settings: env.settings,
            runningCount: () => 0,
            wireClientFactory:
                ({required config, required apiKey, required conversationId}) =>
                    AiWireClient.onDevice(
                      config: config,
                      conversationId: conversationId,
                      appVersion: 'test',
                      onDeviceTransport: OnDeviceAiTransport(
                        plugin: fakePlugin,
                      ),
                    ),
          );
          await controller.recheck();
        });
        addTearDown(() {
          controller.dispose();
          env.dispose();
        });

        await tester.pumpWidget(_host(AiChatPage(session: controller)));
        await tester.pump();

        // Tool/write affordances and inbox mark-all suggestion are hidden.
        expect(find.byType(AiChatLevelButton), findsNothing);
        expect(find.byKey(const ValueKey('ai-chat-attach')), findsNothing);
        expect(find.text(l10n.aiSuggestInboxMarkAll), findsNothing);

        // Sending a write request shows the refusal card without calling the
        // model.
        await tester.runAsync(() async {
          await controller.send('Close this issue');
        });
        await tester.pump();

        expect(fakePlugin.calls, isEmpty);
        expect(
          find.byKey(const ValueKey('ai-on-device-cannot-write-card')),
          findsOneWidget,
        );
        expect(find.text(l10n.aiOnDeviceCannotWrite), findsOneWidget);
        expect(
          find.byKey(const ValueKey('ai-on-device-switch-provider')),
          findsOneWidget,
        );

        // Tapping the switch button opens the switch confirmation dialog, and
        // confirming switches to the cloud provider!
        await tester.tap(
          find.byKey(const ValueKey('ai-on-device-switch-provider')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.confirmAction));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await _waitFor(() => controller.provider?.id == 'cloud-openai');
        });
        await tester.pumpAndSettle();
        expect(controller.provider?.id, 'cloud-openai');
      },
    );

    test('write requests are imperatives; questions and reads are not', () {
      const origin = AiGeneralOrigin();
      for (final text in const [
        'Close this issue',
        'Please merge this MR',
        'Mark all my to-dos as done',
        'Post a comment saying LGTM',
        'Retry the failed job',
        'Add the bug label to this issue',
        'Thanks. Now close the issue.',
        '請合併這個 MR',
        '請關閉這個議題',
        '麻煩你關閉這個議題',
        '請幫我更新描述',
        '幫我把全部待辦標為完成',
        '幫我留言說 LGTM',
        '幫我把這個 MR 合併',
        '把這個議題關閉',
      ]) {
        expect(
          looksLikeGitLabWriteRequest(text, origin: origin),
          isTrue,
          reason: text,
        );
      }
      for (final text in [
        'Explain the open issues',
        'How do I add a label to this issue?',
        'Why did this job fail? Should I retry the pipeline?',
        'Which file should I edit to fix this job?',
        'Write a summary of this MR',
        'Update me on the pipeline status',
        'Why was this issue closed?',
        'Can you close this issue?',
        'Should I close this issue',
        'Is it safe to merge this MR',
        'Close this issue or keep it open?',
        'Comment threads here: which are unresolved?',
        '為什麼要關閉這個議題？',
        '發布說明寫了什麼？',
        '這個 MR 可以合併嗎？',
        '可以關閉這個議題嗎？',
        '修改這段程式的問題',
        '合併這個 MR 安全嗎？',
        '建立這個 issue 的人是誰？',
        '關閉這個議題之前要注意什麼？',
        '更新完成後要做什麼？',
        '請問要不要合併這個 MR',
        // A request to write text or code, not to change GitLab.
        '幫我修改這段程式碼',
        '幫我修改這個函式讓它更快',
        '幫我建立一個測試計畫',
        '幫我新增幾個測試案例',
        '幫我更新這段說明文字',
        // No explicit request: a bare verb may start a description.
        '關閉這個議題',
        '重試這個工作',
        l10n.aiSuggestJobWhy,
        l10n.aiSuggestJobFix,
        l10n.aiSuggestMrSummary,
        l10n.aiSuggestIssueNext,
        l10n.aiSuggestFileExplain,
      ]) {
        expect(
          looksLikeGitLabWriteRequest(text, origin: origin),
          isFalse,
          reason: text,
        );
      }
      // The Inbox conversation can only mark to-dos done; a question about
      // it still goes to the model.
      expect(
        looksLikeGitLabWriteRequest(
          'Clear my inbox',
          origin: const AiInboxOrigin(),
        ),
        isTrue,
      );
      expect(
        looksLikeGitLabWriteRequest(
          'What is in my inbox?',
          origin: const AiInboxOrigin(),
        ),
        isFalse,
      );
    });

    test('a read question on a page reaches the on-device model', () async {
      final env = await _createChatEnvironment();
      addTearDown(env.dispose);
      final saved = await env.settings.saveProvider(
        AiProviderConfig.onDevice(),
      );
      await env.settings.grantConsent(
        env.workspace.account.key,
        aiConversationConsentContract(
          env.settings,
          env.workspace.account.key,
          saved,
          releasePolicy: fixtureReleasePolicy,
        ),
        const <String, Object?>{'synthetic': true},
      );
      final fakePlugin = _FakeOnDeviceTransportPlugin();
      final controller = AiChatController(
        releasePolicy: fixtureReleasePolicy,
        appInForeground: () => true,
        origin: const AiGeneralOrigin(),
        session: env.session,
        settings: env.settings,
        runningCount: () => 0,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) =>
                AiWireClient.onDevice(
                  config: config,
                  conversationId: conversationId,
                  appVersion: 'test',
                  onDeviceTransport: OnDeviceAiTransport(plugin: fakePlugin),
                ),
      );
      addTearDown(controller.dispose);
      await controller.recheck();

      await controller.send('Explain the open issues');
      expect(fakePlugin.calls, hasLength(1));
      expect(
        controller.items.whereType<AiNoticeItem>().map((n) => n.kind),
        isNot(contains(AiNoticeKind.onDeviceCannotWrite)),
      );
    });
  });

  group('7. Guard recovery in AiChatController', () {
    test('an answer that trips the transport guard blocks the next send unsent '
        'with requiresNewSegment, and the send after that rebuilds from the '
        'redacted summary and recovers', () async {
      final env = await _createChatEnvironment();
      addTearDown(env.dispose);

      final saved = await env.settings.saveProvider(
        AiProviderConfig.onDevice(),
      );
      await env.settings.grantConsent(
        env.workspace.account.key,
        aiConversationConsentContract(
          env.settings,
          env.workspace.account.key,
          saved,
          releasePolicy: fixtureReleasePolicy,
        ),
        const <String, Object?>{'synthetic': true},
      );

      // A token-shaped string in the model's own answer stays in the
      // on-device replay, where the transport guard finds it next time.
      final token = 'glpat-${'A' * 24}';
      final fakePlugin = _FakeOnDeviceTransportPlugin();
      var turn = 0;
      fakePlugin.handler = (_) {
        turn++;
        return Stream<String>.fromIterable(<String>[
          turn == 1 ? 'Example token: $token' : 'Reply $turn',
        ]);
      };

      final controller = AiChatController(
        releasePolicy: fixtureReleasePolicy,
        appInForeground: () => true,
        origin: const AiGeneralOrigin(),
        session: env.session,
        settings: env.settings,
        runningCount: () => 0,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) =>
                AiWireClient.onDevice(
                  config: config,
                  conversationId: conversationId,
                  appVersion: 'test',
                  onDeviceTransport: OnDeviceAiTransport(plugin: fakePlugin),
                ),
      );
      addTearDown(controller.dispose);
      await controller.recheck();

      await controller.send('Show me an example token');
      expect(controller.failure, isNull);
      expect(fakePlugin.calls, hasLength(1));

      // The guard refuses before the plugin is called.
      await controller.send('Second question');
      expect(fakePlugin.calls, hasLength(1));
      expect(
        controller.failure,
        isA<AiFailure>()
            .having((f) => f.kind, 'kind', AiFailureKind.policyBlocked)
            .having((f) => f.notSent, 'notSent', isTrue)
            .having((f) => f.requiresNewSegment, 'requiresNewSegment', isTrue),
      );

      // The next send starts a new segment without the raw token.
      await controller.send('Third question recovers');
      expect(controller.failure, isNull);
      expect(fakePlugin.calls, hasLength(2));
      expect(
        fakePlugin.calls.last.turns.any((t) => t.text.contains(token)),
        isFalse,
      );
      expect(
        controller.items.whereType<AiNoticeItem>().map((n) => n.kind),
        contains(AiNoticeKind.segmentSummary),
      );
      expect(
        controller.items.whereType<AiAssistantItem>().last.text,
        'Reply 2',
      );
    });
  });

  group('8. Review round 1', () {
    Future<AiProviderConfig> grantOnDevice(
      _ChatEnvironment env, {
      String id = AiPresets.onDeviceId,
    }) async {
      final saved = await env.settings.saveProvider(
        AiProviderConfig.onDevice(id: id),
      );
      await env.settings.grantConsent(
        env.workspace.account.key,
        aiConversationConsentContract(
          env.settings,
          env.workspace.account.key,
          saved,
          releasePolicy: fixtureReleasePolicy,
        ),
        const <String, Object?>{'synthetic': true},
      );
      return saved;
    }

    AiChatController onDeviceController(
      _ChatEnvironment env,
      _FakeOnDeviceTransportPlugin plugin, {
      AiChatOrigin origin = const AiGeneralOrigin(),
      AiBackgroundExecution? backgroundExecution,
    }) => AiChatController(
      releasePolicy: fixtureReleasePolicy,
      appInForeground: () => true,
      backgroundExecution: backgroundExecution,
      origin: origin,
      session: env.session,
      settings: env.settings,
      runningCount: () => 0,
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) =>
              AiWireClient.onDevice(
                config: config,
                conversationId: conversationId,
                appVersion: 'test',
                onDeviceTransport: OnDeviceAiTransport(plugin: plugin),
              ),
    );

    testWidgets('declining the on-device consent keeps no provider', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final settings = AiSettingsController(
          MemoryAiStore(),
          closeOnDeviceAi: () async {},
        );
        addTearDown(settings.dispose);
        await settings.initialize();
        const accountKey = 'https://gitlab.example#1';
        await settings.loadAccount(accountKey);
        final plugin = _ConsentGuardedOnDeviceAi(isConsentGranted: () => false);
        await tester.pumpWidget(
          _scopedHost(
            settings,
            accountKey,
            AiProviderEditor(
              settings: settings,
              accountKey: accountKey,
              onDeviceAi: plugin,
            ),
          ),
        );
        await tester.pumpAndSettle();
        tester
            .widget<DropdownButtonFormField<AiPreset>>(
              find.byKey(const ValueKey('ai-provider-preset')),
            )
            .onChanged!(AiPresets.onDevice);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('ai-on-device-review-consent')),
        );
        await tester.pumpAndSettle();
        expect(settings.providers.map((p) => p.id), [AiPresets.onDeviceId]);

        await tester.tap(find.text(l10n.cancelAction));
        await tester.pumpAndSettle();

        // Not kept, so it cannot become the device default.
        expect(settings.providers, isEmpty);
        expect(plugin.statusCalls, 0);
        expect(
          find.byKey(const ValueKey('ai-on-device-review-consent')),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'a download under way is attached again on entry, with the keep-open '
      'hint, and a stream that ends without a final event re-reads the status',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final settings = AiSettingsController(
            MemoryAiStore(),
            closeOnDeviceAi: () async {},
          );
          addTearDown(settings.dispose);
          await settings.initialize();
          const accountKey = 'https://gitlab.example#1';
          await settings.loadAccount(accountKey);
          final saved = await settings.saveProvider(
            AiProviderConfig.onDevice(),
          );
          await settings.grantConsent(
            accountKey,
            aiConsentContractFor(saved),
            const <String, Object?>{'synthetic': true},
          );
          final downloads = StreamController<OnDeviceDownloadEvent>();
          final plugin = _ConsentGuardedOnDeviceAi(
            isConsentGranted: () => true,
            statusResult: const OnDeviceStatus.downloading(),
          )..onDownload = () => downloads.stream;

          await tester.pumpWidget(
            _scopedHost(
              settings,
              accountKey,
              AiProviderEditor(
                settings: settings,
                provider: saved,
                accountKey: accountKey,
                onDeviceAi: plugin,
              ),
            ),
          );
          // The indeterminate bar animates until the total is known.
          await tester.pump();
          await tester.pump();

          expect(plugin.statusCalls, 1);
          expect(plugin.downloadCalls, 1);
          expect(
            find.byKey(const ValueKey('ai-on-device-download-keep-open')),
            findsOneWidget,
          );
          downloads.add(
            const OnDeviceDownloadEvent.progress(
              bytesDownloaded: 24 * 1024 * 1024,
              bytesToDownload: 48 * 1024 * 1024,
            ),
          );
          await tester.pump();
          expect(
            find.text(l10n.aiOnDeviceDownloadProgress('24.0', '48.0')),
            findsOneWidget,
          );

          // The stream ends with no completed or failed event.
          plugin.statusResult = const OnDeviceStatus.available();
          await downloads.close();
          await tester.pumpAndSettle();
          expect(plugin.statusCalls, 2);
          expect(plugin.downloadCalls, 1);
          expect(find.text(l10n.aiOnDeviceStatusAvailable), findsOneWidget);
          expect(
            find.byKey(const ValueKey('ai-on-device-download-keep-open')),
            findsNothing,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    test('a refused write clears the interrupted answer, so Continue adds a '
        'new one below the refusal', () async {
      final env = await _createChatEnvironment();
      addTearDown(env.dispose);
      await grantOnDevice(env);
      final plugin = _FakeOnDeviceTransportPlugin();
      var turn = 0;
      plugin.handler = (_) => ++turn == 1
          ? Stream<String>.error(
              const OnDeviceAiException(OnDeviceAiErrorCode.backgroundBlocked),
            )
          : Stream<String>.fromIterable(const <String>['Answer']);
      final controller = onDeviceController(env, plugin);
      addTearDown(controller.dispose);
      await controller.recheck();

      await controller.send('Explain this');
      expect(controller.canResumeRun, isTrue);
      await controller.send('Close this issue');
      final refusal = controller.items.indexWhere(
        (item) =>
            item is AiNoticeItem &&
            item.kind == AiNoticeKind.onDeviceCannotWrite,
      );
      expect(refusal, isNonNegative);

      await controller.resumeRun();
      expect(plugin.calls, hasLength(2));
      final answer = controller.items.lastIndexWhere(
        (item) => item is AiAssistantItem && item.text == 'Answer',
      );
      expect(answer, greaterThan(refusal));
    });

    testWidgets('the truncation notice shows again in a later conversation', (
      tester,
    ) async {
      late _ChatEnvironment env;
      late AiChatController controller;
      final plugin = _FakeOnDeviceTransportPlugin();
      await tester.runAsync(() async {
        env = await _createChatEnvironment(
          repositoryText: List<String>.generate(
            500,
            (i) => 'Line $i: large repository file content for truncation.',
          ).join('\n'),
        );
        await grantOnDevice(env);
        controller = onDeviceController(
          env,
          plugin,
          origin: AiFileOrigin(
            project: env.workspace.project,
            path: 'README.md',
            sha: WorkspaceFixture.sha,
          ),
        );
        await controller.recheck();
        await controller.send('Summarize this file');
        // A changed recipient starts a new conversation and keeps the
        // earlier one on screen.
        await env.settings.saveProvider(
          AiProviderConfig.onDevice(model: 'gemini-nano-next'),
        );
        await env.settings.grantConsent(
          env.workspace.account.key,
          aiConversationConsentContract(
            env.settings,
            env.workspace.account.key,
            env.settings.providers.single,
            releasePolicy: fixtureReleasePolicy,
          ),
          const <String, Object?>{'synthetic': true},
        );
        await _waitFor(() => controller.canSend);
        await controller.send('Summarize this file again');
      });
      addTearDown(() {
        controller.dispose();
        env.dispose();
      });

      expect(plugin.calls, hasLength(2));
      expect(
        controller.items.whereType<AiNoticeItem>().map((n) => n.kind),
        containsAllInOrder(<AiNoticeKind>[
          AiNoticeKind.onDeviceContextTruncated,
          AiNoticeKind.newConversation,
          AiNoticeKind.onDeviceContextTruncated,
        ]),
      );
    });

    test('an on-device chat run never starts the background service', () async {
      const channel = MethodChannel('test/on_device_chat_agent_runs');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final methods = <String>[];
      // A willing native peer: any start would be accepted and recorded.
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        final args = call.arguments as Map<Object?, Object?>;
        return call.method == 'startRuns'
            ? {
                'version': 1,
                'status': 'active',
                'permitId': 'synthetic-permit',
                'startRequestId': args['startRequestId'],
                'opSeq': args['opSeq'],
              }
            : {'version': 1, 'status': 'rejected', 'reason': 'permit_inactive'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final env = await _createChatEnvironment();
      addTearDown(env.dispose);
      await grantOnDevice(env);
      final execution = AiBackgroundExecution(
        backgroundEnabled: true,
        accountKey: env.workspace.account.key,
        generation: env.session.generation,
        ownerApi: env.session.api!,
        isCurrent: () => true,
        appInForeground: () => true,
        channel: channel,
      );
      addTearDown(execution.dispose);
      final plugin = _FakeOnDeviceTransportPlugin();
      final controller = onDeviceController(
        env,
        plugin,
        backgroundExecution: execution,
      );
      addTearDown(controller.dispose);
      await controller.recheck();

      await controller.send('Explain this');
      expect(controller.lastEnd, AiRunEnd.done);
      expect(plugin.calls, hasLength(1));
      expect(methods, isNot(contains('startRuns')));
    });

    testWidgets('withdrawing the on-device consent on the settings page '
        'closes the model', (tester) async {
      var closeCalls = 0;
      final store = MemoryAiStore();
      final settings = AiSettingsController(
        store,
        closeOnDeviceAi: () async => closeCalls++,
      );
      final history = AiHistoryCoordinator(store: store);
      addTearDown(settings.dispose);
      addTearDown(history.dispose);
      await settings.initialize();
      const accountKey = 'https://gitlab.example#1';
      await settings.loadAccount(accountKey);
      final saved = await settings.saveProvider(AiProviderConfig.onDevice());
      final contract = aiConsentContractFor(saved);
      await settings.grantConsent(
        accountKey,
        contract,
        aiConsentSummary(contract, providerName: saved.name),
      );

      await tester.pumpWidget(
        _host(
          AiSettingsPage(
            settings: settings,
            history: history,
            accountKey: accountKey,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final revoke = find.byTooltip(l10n.aiRevokeConsent);
      await tester.ensureVisible(revoke);
      await tester.pumpAndSettle();
      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.confirmAction));
      await tester.pumpAndSettle();

      expect(closeCalls, 1);
      expect(settings.accountRecord(accountKey)?.consents, isEmpty);
    });

    test(
      'removing an account with an on-device consent closes the model',
      () async {
        var closeCalls = 0;
        final store = MemoryAiStore();
        final settings = AiSettingsController(
          store,
          closeOnDeviceAi: () async => closeCalls++,
        );
        final history = AiHistoryCoordinator(store: store);
        addTearDown(settings.dispose);
        addTearDown(history.dispose);
        await settings.initialize();
        final saved = await settings.saveProvider(AiProviderConfig.onDevice());
        final contract = aiConsentContractFor(saved);
        for (final account in ['with-on-device', 'without']) {
          await settings.loadAccount(account);
        }
        await settings.grantConsent(
          'with-on-device',
          contract,
          aiConsentSummary(contract, providerName: saved.name),
        );

        await history.clearAccount('without');
        await pumpEventQueue();
        expect(closeCalls, 0);
        await history.clearAccount('with-on-device');
        await pumpEventQueue();
        expect(closeCalls, 1);
      },
    );

    test(
      'the on-device policy date is its own; cloud consents keep theirs',
      () {
        expect(
          aiConsentContractFor(AiProviderConfig.onDevice()).policyCheckedOn,
          AiPresets.onDevicePolicyCheckedOn,
        );
        expect(AiPresets.onDevicePolicyCheckedOn, '2026-11-01');
        expect(AiPresets.policyCheckedOn, '2026-10-20');
      },
    );
  });

  group('9. Leaving the app, through the real binding and the registry', () {
    // Home on Android reports inactive, then hidden, then paused. The chat
    // is opened through the registry as in production, and both the
    // controller and the registry's execution owner read the binding's
    // lifecycle state (aiAppInForeground); nothing calls the observer.
    for (final last in const [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      testWidgets('${last.name}: the on-device answer stops with the paused '
          'card, resuming alone does nothing, and Continue completes it', (
        tester,
      ) async {
        late _ChatEnvironment env;
        late AccountAiRunRegistry registry;
        late AiChatController controller;
        final firstTurn = StreamController<String>();
        addTearDown(firstTurn.close);
        final plugin = _FakeOnDeviceTransportPlugin();
        var turns = 0;
        plugin.handler = (_) => ++turns == 1
            ? firstTurn.stream
            : Stream<String>.fromIterable(const <String>['完整的回答。']);
        // The engine reports resumed when an app starts; the test binding
        // starts without a state.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(aiAppInForeground(), isTrue);

        await tester.runAsync(() async {
          env = await _createChatEnvironment();
          final saved = await env.settings.saveProvider(
            AiProviderConfig.onDevice(),
          );
          await env.settings.grantConsent(
            env.workspace.account.key,
            aiConversationConsentContract(
              env.settings,
              env.workspace.account.key,
              saved,
              releasePolicy: fixtureReleasePolicy,
            ),
            const <String, Object?>{'synthetic': true},
          );
          registry = AccountAiRunRegistry(
            session: env.session,
            settings: env.settings,
            // The production factory, with the fixture release policy.
            sessionFactory:
                ({
                  required origin,
                  required session,
                  required settings,
                  required runningCount,
                  wireClientFactory,
                }) {
                  final chat = AiChatController(
                    releasePolicy: fixtureReleasePolicy,
                    origin: origin,
                    session: session,
                    settings: settings,
                    runningCount: runningCount,
                    wireClientFactory: wireClientFactory,
                    appInForeground: aiAppInForeground,
                    clientMayStart: aiClientMayStart(session),
                  );
                  return (
                    session: chat,
                    capacityChanged: chat.notifyCapacityChanged,
                    dispose: chat.dispose,
                  );
                },
            wireClientFactory:
                ({required config, required apiKey, required conversationId}) =>
                    AiWireClient.onDevice(
                      config: config,
                      conversationId: conversationId,
                      appVersion: 'test',
                      onDeviceTransport: OnDeviceAiTransport(plugin: plugin),
                    ),
          );
          controller = registry.open(const AiGeneralOrigin()) as AiChatController;
          await controller.recheck();

          final sending = controller.send('請解釋這段程式碼');
          await _waitFor(() => plugin.calls.length == 1);
          firstTurn.add('半截回答內容'.padRight(260, '！'));
          await _waitFor(
            () => controller.items.whereType<AiAssistantItem>().any(
              (item) => item.text.startsWith('半截回答內容'),
            ),
          );
          expect(controller.phase, AiChatPhase.running);

          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          if (last == AppLifecycleState.paused) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
          }
          await sending.timeout(const Duration(seconds: 5));
        });
        addTearDown(() {
          registry.dispose();
          env.dispose();
        });

        expect(controller.phase, AiChatPhase.idle);
        expect(controller.lastEnd, AiRunEnd.stopped);
        expect(controller.failure, isNull);
        expect(
          controller.executionPause?.reason,
          AiExecutionPauseReason.foregroundRequired,
        );
        expect(plugin.cancelledIds, <String>['req-1']);

        // Back in the foreground: nothing restarts by itself.
        await tester.runAsync(() async {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        expect(plugin.calls, hasLength(1));
        expect(controller.canResumeRun, isTrue);

        await tester.runAsync(() async {
          await controller.resumeRun();
        });
        expect(plugin.calls, hasLength(2));
        expect(controller.lastEnd, AiRunEnd.done);
        expect(controller.executionPause, isNull);
        expect(
          controller.items.whereType<AiAssistantItem>().last.text,
          '完整的回答。',
        );
      });
    }
  });

  group('10. On-device wording on the chat and settings pages', () {
    testWidgets('a page chat on-device says it reads only this page', (
      tester,
    ) async {
      late _ChatEnvironment env;
      late AiChatController controller;
      await tester.runAsync(() async {
        env = await _createChatEnvironment();
        final saved = await env.settings.saveProvider(
          AiProviderConfig.onDevice(),
        );
        await env.settings.grantConsent(
          env.workspace.account.key,
          aiConversationConsentContract(
            env.settings,
            env.workspace.account.key,
            saved,
            releasePolicy: fixtureReleasePolicy,
          ),
          const <String, Object?>{'synthetic': true},
        );
        controller = AiChatController(
          releasePolicy: fixtureReleasePolicy,
          appInForeground: () => true,
          origin: AiFileOrigin(
            project: env.workspace.project,
            path: 'README.md',
            sha: WorkspaceFixture.sha,
          ),
          session: env.session,
          settings: env.settings,
          runningCount: () => 0,
          wireClientFactory:
              ({required config, required apiKey, required conversationId}) =>
                  AiWireClient.onDevice(
                    config: config,
                    conversationId: conversationId,
                    appVersion: 'test',
                    onDeviceTransport: OnDeviceAiTransport(
                      plugin: _FakeOnDeviceTransportPlugin(),
                    ),
                  ),
        );
        await controller.recheck();
      });
      addTearDown(() {
        controller.dispose();
        env.dispose();
      });

      await tester.pumpWidget(_host(AiChatPage(session: controller)));
      await tester.pump();

      final scope = tester.widget<Text>(
        find.byKey(const ValueKey('ai-chat-empty-scope')),
      );
      expect(scope.data, l10n.aiChatEmptyOnDevice);
      expect(find.text(l10n.aiChatEmpty), findsNothing);
    });

    for (final renamed in const [false, true]) {
      testWidgets(
        renamed
            ? 'a renamed on-device provider still names its preset'
            : 'an on-device provider with its default name is named once',
        (tester) async {
          final store = MemoryAiStore();
          final settings = AiSettingsController(
            store,
            closeOnDeviceAi: () async {},
          );
          final history = AiHistoryCoordinator(store: store);
          addTearDown(settings.dispose);
          addTearDown(history.dispose);
          await settings.initialize();
          const accountKey = 'https://gitlab.example#1';
          await settings.loadAccount(accountKey);
          final saved = await settings.saveProvider(
            AiProviderConfig.onDevice(
              // The editor keeps the localized preset name by default.
              name: renamed ? 'My phone' : l10n.aiPresetOnDeviceName,
            ),
          );

          await tester.pumpWidget(
            _host(
              AiSettingsPage(
                settings: settings,
                history: history,
                accountKey: accountKey,
              ),
            ),
          );
          await tester.pumpAndSettle();

          final row = find.byKey(ValueKey('ai-provider-${saved.id}'));
          expect(
            find.descendant(of: row, matching: find.text(saved.name)),
            findsOneWidget,
          );
          // The details under the row: the preset line, then the model.
          final details = find
              .ancestor(of: find.text(saved.model), matching: find.byType(Column))
              .first;
          expect(
            find.descendant(
              of: details,
              matching: find.text(l10n.aiPresetOnDeviceName),
            ),
            renamed ? findsOneWidget : findsNothing,
          );
        },
      );
    }
  });
}
