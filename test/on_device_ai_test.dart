import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/app_text.dart';
import 'package:gitlab_mobile/core/ai/on_device_transport.dart';
import 'package:gitlab_mobile/core/ai/prompts.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/wire/on_device_wire.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:mergeline_on_device_ai/mergeline_on_device_ai.dart';

final class _FakeOnDeviceCall {
  _FakeOnDeviceCall({
    required this.requestId,
    required this.system,
    required this.turns,
    required this.maxOutputTokens,
    required this.temperature,
  });

  final String requestId;
  final String system;
  final List<OnDeviceTurn> turns;
  final int? maxOutputTokens;
  final double? temperature;
}

final class _FakeOnDeviceAiPlugin implements OnDeviceAiPlugin {
  final List<_FakeOnDeviceCall> calls = <_FakeOnDeviceCall>[];
  final List<String> cancelledRequestIds = <String>[];
  int nextId = 1;

  Stream<String> Function(_FakeOnDeviceCall call)? handler;

  @override
  OnDeviceGenerationStream generate({
    required String system,
    required List<OnDeviceTurn> turns,
    int? maxOutputTokens,
    double? temperature,
  }) {
    final requestId = 'plugin-req-${nextId++}';
    final call = _FakeOnDeviceCall(
      requestId: requestId,
      system: system,
      turns: List<OnDeviceTurn>.unmodifiable(turns),
      maxOutputTokens: maxOutputTokens,
      temperature: temperature,
    );
    calls.add(call);
    final stream = handler != null
        ? handler!(call)
        : Stream<String>.fromIterable(const <String>['Hello ', 'world!']);
    return OnDeviceGenerationStream(requestId: requestId, stream: stream);
  }

  @override
  Future<void> cancel(String requestId) async {
    cancelledRequestIds.add(requestId);
  }
}

// Stored records are validated when the settings owner loads them.
final _malformedStore = isA<AiStoreException>().having(
  (e) => e.failure.kind,
  'kind',
  AiStoreFailureKind.malformed,
);

final class _MutableSecrets implements KnownSecretsSource {
  @override
  final Set<String> current = <String>{};
}

OnDeviceAiTransport _busyThenOk(
  _FakeOnDeviceAiPlugin plugin, {
  Future<void> Function(Duration)? wait,
}) {
  var attempts = 0;
  plugin.handler = (_) => ++attempts == 1
      ? Stream<String>.error(
          const OnDeviceAiException(OnDeviceAiErrorCode.busy),
        )
      : Stream<String>.fromIterable(const <String>['late']);
  return OnDeviceAiTransport(plugin: plugin, wait: wait);
}

AiRequestPlan _plan(String text, {List<AiContextBlock> context = const []}) {
  final seg = AiSegment(
    providerId: 'on-device',
    recipientRevision: 1,
    format: AiFormat.onDevicePrompt,
    model: 'gemini-nano',
    secretSetAtStart: SecretSetId.fromSecrets(const <String>[]),
  );
  seg.setTail(AppUserEntry(text: text, context: context));
  return AiRequestPlan(
    model: 'gemini-nano',
    system: 'Sys',
    segment: seg,
    tools: const <AiToolSpec>[],
    toolChoice: AiToolChoice.auto,
    maxOutputTokens: 128,
  );
}

AiRunner _runner(
  _FakeOnDeviceAiPlugin plugin, {
  List<AiContextBlock> context = const <AiContextBlock>[],
  void Function(AiNoticeKind)? onNotice,
}) {
  final config = AiProviderConfig.onDevice();
  final client = AiWireClient.onDevice(
    config: config,
    conversationId: 'conv-0003',
    appVersion: '0.6.2',
    onDeviceTransport: OnDeviceAiTransport(plugin: plugin),
  );
  final owner = Object();
  return AiRunner(
    appInForeground: () => true,
    config: config,
    wire: client.wire,
    complete: client.complete,
    secrets: _MutableSecrets(),
    refreshSecrets: () async {},
    guard: AiRunGuard(
      expectedGeneration: 1,
      ownerApi: owner,
      generation: () => 1,
      api: () => owner,
      recipientRevision: () => 1,
      consentValid: () => true,
    ),
    system: 'Sys',
    close: client.close,
    cancelActive: client.cancelActive,
    context: context,
    onNotice: onNotice,
  );
}

Matcher _fails(AiFailureKind kind, {bool? notSent}) => throwsA(
  isA<AiFailure>()
      .having((f) => f.kind, 'kind', kind)
      .having((f) => f.notSent, 'notSent', notSent ?? anything),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useLanguage(sourceLanguage);
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  group('1. Presets, hidden picker list, and stored records', () {
    test('AiPresets.onDevice is defined and looked up by id, '
        'but hidden from AiPresets.all', () {
      final preset = AiPresets.onDevice;
      expect(preset.id, 'on-device');
      expect(preset.defaultFormat, AiFormat.onDevicePrompt);
      expect(preset.formats, const <AiFormat>{AiFormat.onDevicePrompt});
      expect(
        preset.baseUrls[AiFormat.onDevicePrompt],
        'on-device://android-aicore',
      );
      expect(preset.defaultModel, 'gemini-nano');
      expect(preset.authStyle, AiAuthStyle.none);
      expect(preset.onDevice, isTrue);
      expect(preset.supportsTools, isFalse);

      final caps = preset.capsFor(AiFormat.onDevicePrompt);
      expect(caps.requiresKey, isFalse);
      expect(caps.toolChoice, isFalse);
      expect(caps.maxRequestChars, 12000);
      expect(caps.maxOutputTokens, 1024);

      expect(AiPresets.byId('on-device'), same(AiPresets.onDevice));
      expect(AiPresets.byId('openai'), same(AiPresets.openAi));
      expect(AiPresets.byId('nonexistent'), isNull);

      expect(
        AiPresets.all.map((p) => p.id),
        isNot(contains('on-device')),
        reason: 'on-device must stay out of picker-facing AiPresets.all in MR2',
      );
      expect(AiPresets.all.any((p) => p.onDevice), isFalse);
      expect(AiPresets.all.every((p) => p.supportsTools), isTrue);
    });

    test('stored records with on-device id load, validate, update, '
        'and delete in SecureAiStore', () async {
      const storage = FlutterSecureStorage();
      final store = SecureAiStore(storage);
      final config = AiProviderConfig.onDevice(name: 'Phone AI');
      expect(config.isOnDevice, isTrue);
      expect(config.isValidOnDevice, isTrue);

      await store.saveProviders(<AiProviderConfig>[config]);
      final loaded = await store.loadProviders();
      expect(loaded.status, AiStoreReadStatus.found);
      expect(loaded.value, hasLength(1));
      final item = loaded.value!.single;
      expect(item.id, 'on-device');
      expect(item.presetId, 'on-device');
      expect(item.name, 'Phone AI');
      expect(item.baseUrl, 'on-device://android-aicore');
      expect(item.format, AiFormat.onDevicePrompt);
      expect(item.model, 'gemini-nano');
      expect(item.authStyle, AiAuthStyle.none);
      expect(item.toolsEnabled, isFalse);
      expect(item.caps.requiresKey, isFalse);

      final settings = AiSettingsController(store);
      await settings.initialize();
      expect(settings.providers.single.id, 'on-device');

      final renamed = await settings.saveProvider(
        AiProviderConfig.onDevice(
          name: 'Renamed Phone AI',
          recipientRevision: item.recipientRevision,
        ),
      );
      expect(renamed.recipientRevision, item.recipientRevision);
      expect(settings.providers.single.name, 'Renamed Phone AI');

      await settings.deleteProvider('on-device');
      expect(settings.providers, isEmpty);
      settings.dispose();
    });
  });

  group('2. Endpoint safety (both directions)', () {
    test('AiEndpoint.parse rejects on-device://android-aicore '
        'under all flags', () {
      for (final allowLan in const <bool>[false, true]) {
        expect(
          () => AiEndpoint.parse(
            'on-device://android-aicore',
            allowLanCleartext: allowLan,
          ),
          throwsA(
            isA<AiFailure>().having(
              (f) => f.kind,
              'kind',
              AiFailureKind.policyBlocked,
            ),
          ),
        );
      }
    });

    test('non-on-device presets (including custom) reject '
        'on-device://android-aicore and AiFormat.onDevicePrompt', () async {
      final store = SecureAiStore(const FlutterSecureStorage());
      final settings = AiSettingsController(store);
      await settings.initialize();
      for (final preset in AiPresets.all) {
        final badUrlConfig = AiProviderConfig(
          id: 'bad-${preset.id}',
          name: 'Bad ${preset.id}',
          presetId: preset.id,
          baseUrl: 'on-device://android-aicore',
          format: preset.defaultFormat,
          model: 'gpt-4o',
          authStyle: preset.authStyle,
          caps: preset.capsFor(preset.defaultFormat),
          allowLanCleartext: false,
          toolsEnabled: false,
          recipientRevision: 1,
        );
        expect(badUrlConfig.isOnDevice, isFalse);
        expect(
          () => aiConsentContractFor(badUrlConfig),
          throwsA(
            isA<AiFailure>().having(
              (f) => f.kind,
              'kind',
              AiFailureKind.policyBlocked,
            ),
          ),
        );
        await expectLater(
          settings.saveProvider(badUrlConfig),
          throwsA(
            isA<AiStoreException>().having(
              (e) => e.failure.kind,
              'kind',
              AiStoreFailureKind.invalidValue,
            ),
          ),
        );
        await store.saveProviders(<AiProviderConfig>[badUrlConfig]);
        await expectLater(settings.initialize(), throwsA(_malformedStore));

        final badFormatConfig = AiProviderConfig(
          id: 'bad-fmt-${preset.id}',
          name: 'Bad Format ${preset.id}',
          presetId: preset.id,
          baseUrl: 'https://api.openai.com/v1',
          format: AiFormat.onDevicePrompt,
          model: 'gpt-4o',
          authStyle: preset.authStyle,
          caps: const AiCaps(
            tokenLimitField: AiTokenLimitField.maxOutputTokens,
            requiresKey: false,
          ),
          allowLanCleartext: false,
          toolsEnabled: false,
          recipientRevision: 1,
        );
        await expectLater(
          settings.saveProvider(badFormatConfig),
          throwsA(
            isA<AiStoreException>().having(
              (e) => e.failure.kind,
              'kind',
              AiStoreFailureKind.invalidValue,
            ),
          ),
        );
        await store.saveProviders(<AiProviderConfig>[badFormatConfig]);
        await expectLater(settings.initialize(), throwsA(_malformedStore));
      }
      settings.dispose();
    });

    test('on-device preset rejects https/http endpoints, toolsEnabled, '
        'requiresKey, and non-onDevicePrompt formats', () async {
      final store = SecureAiStore(const FlutterSecureStorage());
      final settings = AiSettingsController(store);
      await settings.initialize();
      final invalidConfigs = <AiProviderConfig>[
        AiProviderConfig(
          id: 'on-device',
          name: 'HTTPS On-Device',
          presetId: 'on-device',
          baseUrl: 'https://api.openai.com/v1',
          format: AiFormat.onDevicePrompt,
          model: 'gemini-nano',
          authStyle: AiAuthStyle.none,
          caps: AiPresets.onDevice.capsFor(AiFormat.onDevicePrompt),
          allowLanCleartext: false,
          toolsEnabled: false,
          recipientRevision: 1,
        ),
        AiProviderConfig(
          id: 'on-device',
          name: 'Tools On-Device',
          presetId: 'on-device',
          baseUrl: 'on-device://android-aicore',
          format: AiFormat.onDevicePrompt,
          model: 'gemini-nano',
          authStyle: AiAuthStyle.none,
          caps: AiPresets.onDevice.capsFor(AiFormat.onDevicePrompt),
          allowLanCleartext: false,
          toolsEnabled: true,
          recipientRevision: 1,
        ),
        AiProviderConfig(
          id: 'on-device',
          name: 'Key On-Device',
          presetId: 'on-device',
          baseUrl: 'on-device://android-aicore',
          format: AiFormat.onDevicePrompt,
          model: 'gemini-nano',
          authStyle: AiAuthStyle.none,
          caps: const AiCaps(
            tokenLimitField: AiTokenLimitField.maxOutputTokens,
            requiresKey: true,
            maxRequestChars: 12000,
            maxOutputTokens: 1024,
          ),
          allowLanCleartext: false,
          toolsEnabled: false,
          recipientRevision: 1,
        ),
        AiProviderConfig(
          id: 'on-device',
          name: 'ChatFormat On-Device',
          presetId: 'on-device',
          baseUrl: 'on-device://android-aicore',
          format: AiFormat.chatCompletions,
          model: 'gemini-nano',
          authStyle: AiAuthStyle.none,
          caps: AiPresets.onDevice.capsFor(AiFormat.onDevicePrompt),
          allowLanCleartext: false,
          toolsEnabled: false,
          recipientRevision: 1,
        ),
      ];

      for (final invalid in invalidConfigs) {
        expect(invalid.isValidOnDevice, isFalse, reason: invalid.name);
        expect(
          () => aiConsentContractFor(invalid),
          throwsA(
            isA<AiFailure>().having(
              (f) => f.kind,
              'kind',
              AiFailureKind.policyBlocked,
            ),
          ),
          reason: invalid.name,
        );
        await expectLater(
          settings.saveProvider(invalid),
          throwsA(
            isA<AiStoreException>().having(
              (e) => e.failure.kind,
              'kind',
              AiStoreFailureKind.invalidValue,
            ),
          ),
          reason: invalid.name,
        );
        await store.saveProviders(<AiProviderConfig>[invalid]);
        await expectLater(
          settings.initialize(),
          throwsA(_malformedStore),
          reason: invalid.name,
        );
      }
      settings.dispose();
    });
  });

  group('3. Consent contract, hash, and recipientRevision', () {
    test('on-device consent contract binds on-device://android-aicore, '
        'dataRetention: on_device, and AiDataUse.onDevice', () {
      final onDevice = AiProviderConfig.onDevice();
      final contract = aiConsentContractFor(onDevice);

      expect(contract.origin, 'on-device://android-aicore');
      expect(contract.format, AiFormat.onDevicePrompt);
      expect(contract.dataUse, AiDataUse.onDevice);
      expect(contract.dataRetention, 'on_device');
      expect(contract.toolsEnabled, isFalse);
      expect(contract.cleartext, isFalse);
      expect(contract.writePolicy, isNull);
      expect(contract.retentionDays, 0);
      for (final category in const <String>[
        'tool_reads',
        'write_results',
        'attachment_metadata',
      ]) {
        expect(contract.dataCategories, isNot(contains(category)));
      }

      final withoutRetention = AiConsentContract(
        providerId: contract.providerId,
        origin: contract.origin,
        format: contract.format,
        cleartext: contract.cleartext,
        toolsEnabled: contract.toolsEnabled,
        toolCatalogueVersion: contract.toolCatalogueVersion,
        dataCategories: contract.dataCategories,
        writePolicy: contract.writePolicy,
        releasePolicyIdentity: contract.releasePolicyIdentity,
        policyIdentity: contract.policyIdentity,
        routedModel: contract.routedModel,
        dataUse: contract.dataUse,
        disclosureVersion: contract.disclosureVersion,
      );
      expect(contract.hash, isNot(equals(withoutRetention.hash)));
    });

    test('consent for on-device never matches any cloud preset contract '
        'and vice versa', () async {
      final store = MemoryAiStore();
      final settings = AiSettingsController(store);
      await settings.initialize();
      const accountKey = 'https://gitlab.example#42';

      final onDevice = await settings.saveProvider(AiProviderConfig.onDevice());
      final cloud = await settings.saveProvider(
        AiProviderConfig(
          id: 'cloud-1',
          name: 'OpenAI Cloud',
          presetId: 'openai',
          baseUrl: 'https://api.openai.com/v1',
          format: AiFormat.responses,
          model: 'gpt-5.4-mini',
          authStyle: AiAuthStyle.bearer,
          caps: AiPresets.openAi.capsFor(AiFormat.responses),
          allowLanCleartext: false,
          toolsEnabled: false,
          recipientRevision: 1,
        ),
      );

      await settings.loadAccount(accountKey);
      final onDeviceContract = aiConsentContractFor(onDevice);
      final cloudContract = aiConsentContractFor(cloud);
      expect(onDeviceContract.hash, isNot(equals(cloudContract.hash)));

      await settings.grantConsent(
        accountKey,
        onDeviceContract,
        const <String, Object?>{'synthetic': true},
      );
      expect(settings.isValid(accountKey, onDeviceContract), isTrue);
      expect(settings.isValid(accountKey, cloudContract), isFalse);

      // Even if a cloud contract is constructed with the same providerId
      // ('on-device'), its hash differs and never satisfies the grant.
      final cloudSameId = AiProviderConfig(
        id: onDevice.id,
        name: 'Spoofed Cloud',
        presetId: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        format: AiFormat.responses,
        model: 'gpt-5.4-mini',
        authStyle: AiAuthStyle.bearer,
        caps: AiPresets.openAi.capsFor(AiFormat.responses),
        allowLanCleartext: false,
        toolsEnabled: false,
        recipientRevision: onDevice.recipientRevision,
      );
      final spoofedContract = aiConsentContractFor(cloudSameId);
      expect(spoofedContract.hash, isNot(equals(onDeviceContract.hash)));
      expect(settings.isValid(accountKey, spoofedContract), isFalse);
      settings.dispose();
    });

    test('renaming on-device provider keeps recipientRevision and consent; '
        'changing model or caps bumps recipientRevision and invalidates '
        'consent', () async {
      final store = SecureAiStore(const FlutterSecureStorage());
      final settings = AiSettingsController(store);
      await settings.initialize();
      const accountKey = 'https://gitlab.example#7';

      final saved = await settings.saveProvider(
        AiProviderConfig.onDevice(name: 'Initial Name'),
      );
      expect(saved.recipientRevision, 1);
      await settings.loadAccount(accountKey);
      final contract1 = aiConsentContractFor(saved);
      await settings.grantConsent(
        accountKey,
        contract1,
        const <String, Object?>{'synthetic': true},
      );
      expect(settings.isValid(accountKey, contract1), isTrue);

      final renamed = await settings.saveProvider(
        AiProviderConfig.onDevice(
          id: saved.id,
          name: 'Updated Display Name',
          recipientRevision: saved.recipientRevision,
        ),
      );
      expect(renamed.recipientRevision, 1);
      expect(
        settings.isValid(accountKey, aiConsentContractFor(renamed)),
        isTrue,
      );

      final changedCaps = await settings.saveProvider(
        AiProviderConfig.onDevice(
          id: saved.id,
          name: 'Updated Display Name',
          caps: const AiCaps(
            tokenLimitField: AiTokenLimitField.maxOutputTokens,
            requiresKey: false,
            maxRequestChars: 12000,
            maxOutputTokens: 512,
          ),
          recipientRevision: renamed.recipientRevision,
        ),
      );
      expect(changedCaps.recipientRevision, 2);

      final changedModel = await settings.saveProvider(
        AiProviderConfig.onDevice(
          id: saved.id,
          name: 'Updated Display Name',
          model: 'gemini-nano-v2',
          caps: changedCaps.caps,
          recipientRevision: changedCaps.recipientRevision,
        ),
      );
      expect(changedModel.recipientRevision, 3);
      expect(
        settings.isValid(accountKey, aiConsentContractFor(changedModel)),
        isFalse,
      );
      settings.dispose();
    });
  });

  group('4. Token estimation and <gitlab_data>-safe truncation', () {
    test('estimateOnDeviceTokens accounts for ASCII and CJK characters', () {
      expect(estimateOnDeviceTokens(''), 0);
      // 9 ASCII chars -> ceil(9 / 3) = 3 tokens.
      expect(estimateOnDeviceTokens('123456789'), 3);
      // 4 CJK runes -> ceil(4 * 1.5) = 6 tokens.
      expect(estimateOnDeviceTokens('繁體中文'), 6);
      expect(estimateOnDeviceTokens('繁體中文123456789'), 6 + 3);
    });

    test('assembleOnDevicePrompt truncates large <gitlab_data> context under '
        'kOnDeviceMaxInputTokens without cutting inside tags or nonce', () {
      final secrets = _MutableSecrets()..current.add('SECRET_TOKEN_9');
      final redactor = Redactor(secrets: secrets);
      const nonce = '0123456789abcdef0123456789abcdef';
      final body = List<String>.generate(
        600,
        (i) => 'Line $i: diff hunk +<Change_$i> & some context text.',
      ).join('\n');
      final block = AiContextBlock.fromData(
        source: 'mr_diff',
        data: AiAppText.untrusted(
          source: 'mr_diff',
          nonce: nonce,
          body: AiAppText.plain('$body\nTail <b> & SECRET_TOKEN_9'),
        ),
      );
      expect(estimateOnDeviceTokens(block.text), greaterThan(5000));

      final seg = AiSegment(
        providerId: 'on-device',
        recipientRevision: 1,
        format: AiFormat.onDevicePrompt,
        model: 'gemini-nano',
        secretSetAtStart: SecretSetId.fromSecrets(const <String>[]),
      );
      seg.setTail(
        AppUserEntry(
          text: 'Summarize this merge request diff.',
          context: <AiContextBlock>[block],
        ),
      );
      final plan = AiRequestPlan(
        model: 'gemini-nano',
        system: aiOnDeviceSystemPrompt(
          languageTag: 'zh-TW',
          languageName: '繁體中文',
        ),
        segment: seg,
        tools: const <AiToolSpec>[],
        toolChoice: AiToolChoice.auto,
        maxOutputTokens: 512,
      );

      final assembled = assembleOnDevicePrompt(plan, redactor: redactor);
      expect(assembled.contextTruncated, isTrue);
      expect(
        assembled.estimatedInputTokens,
        lessThanOrEqualTo(kOnDeviceMaxInputTokens),
      );
      expect(assembled.sentContext, hasLength(1));

      final sentText = assembled.sentContext.single.text;
      expect(
        sentText,
        startsWith('<gitlab_data source="mr_diff" nonce="$nonce">\n'),
      );
      expect(sentText, endsWith('\n</gitlab_data>'));
      expect(RegExp('<gitlab_data').allMatches(sentText), hasLength(1));
      expect(RegExp('</gitlab_data>').allMatches(sentText), hasLength(1));
      // The cut keeps the plain model: no wrapper or escapes in plain text.
      final plain = assembled.sentContext.single.plainData.plainText;
      expect(plain, startsWith('Line 0: diff hunk'));
      expect(plain, isNot(contains('<gitlab_data')));
      expect(plain, contains('+<Change_0> & some'));
      expect(sentText, contains('+&lt;Change_0&gt; &amp; some'));
      expect(plain.length, lessThan(body.length));

      // Without the conversation's redactor the assembler never cuts.
      expect(
        () => assembleOnDevicePrompt(plan),
        throwsA(
          isA<AiFailure>()
              .having((f) => f.kind, 'kind', AiFailureKind.contextTooLong)
              .having((f) => f.notSent, 'notSent', isTrue),
        ),
      );
    });

    test('assembleOnDevicePrompt drops prior turns whole and starts the '
        'kept history with a user turn', () {
      final seg = AiSegment(
        providerId: 'on-device',
        recipientRevision: 1,
        format: AiFormat.onDevicePrompt,
        model: 'gemini-nano',
        secretSetAtStart: SecretSetId.fromSecrets(const <String>[]),
      );
      Object? encode(AiEntry entry) => const OnDevicePromptFormat().encodeEntry(
        entry,
        AiPresets.onDevice.capsFor(AiFormat.onDevicePrompt),
      );
      ProviderOutputEntry answer(String text) => ProviderOutputEntry(
        AiFormat.onDevicePrompt,
        <String, Object?>{'role': 'assistant', 'content': text},
        toolCalls: const <AiToolCall>[],
      );
      seg.setTail(AppUserEntry(text: 'first question ${'x' * 11000}'));
      seg.freezeWith(answer('first answer'), encode);
      seg.setTail(AppUserEntry(text: 'second question'));
      seg.freezeWith(answer('second answer'), encode);
      seg.setTail(AppUserEntry(text: 'third question'));
      final plan = AiRequestPlan(
        model: 'gemini-nano',
        system: 'Sys',
        segment: seg,
        tools: const <AiToolSpec>[],
        toolChoice: AiToolChoice.auto,
        maxOutputTokens: 256,
      );

      final assembled = assembleOnDevicePrompt(plan);
      expect(assembled.historyDropped, isTrue);
      expect(assembled.contextTruncated, isFalse);
      // AICore answers only the first user turn of a multi-turn request, so
      // the kept history travels inside the one user turn.
      expect(
        assembled.turns.map((t) => (t.role, t.text)).toList(),
        <(OnDeviceRole, String)>[
          (
            OnDeviceRole.user,
            '<conversation_history>\n'
                '<user_turn>\nsecond question\n</user_turn>\n\n'
                '<assistant_turn>\nsecond answer\n</assistant_turn>\n'
                '</conversation_history>\n\n'
                '<user_request>\nthird question\n</user_request>',
          ),
        ],
      );
      expect(
        assembled.estimatedInputTokens,
        lessThanOrEqualTo(kOnDeviceMaxInputTokens),
      );
    });

    test('assembleOnDevicePrompt fails fast with contextTooLong when user '
        'question alone exceeds 3,400 tokens', () {
      final seg = AiSegment(
        providerId: 'on-device',
        recipientRevision: 1,
        format: AiFormat.onDevicePrompt,
        model: 'gemini-nano',
        secretSetAtStart: SecretSetId.fromSecrets(const <String>[]),
      );
      seg.setTail(AppUserEntry(text: 'a' * 12000));
      final plan = AiRequestPlan(
        model: 'gemini-nano',
        system: aiOnDeviceSystemPrompt(
          languageTag: 'en',
          languageName: 'English',
        ),
        segment: seg,
        tools: const <AiToolSpec>[],
        toolChoice: AiToolChoice.auto,
        maxOutputTokens: 256,
      );

      expect(
        () => assembleOnDevicePrompt(plan),
        throwsA(
          isA<AiFailure>()
              .having((f) => f.kind, 'kind', AiFailureKind.contextTooLong)
              .having((f) => f.notSent, 'notSent', isTrue),
        ),
      );
    });
  });

  group('5. Streaming, redaction, requestId, cancelActive vs close', () {
    test('OnDeviceAiTransport streams chunks, uses plugin-generated requestId, '
        'and distinguishes cancelActive from close', () async {
      final plugin = _FakeOnDeviceAiPlugin();
      final transport = OnDeviceAiTransport(plugin: plugin);

      final seg = AiSegment(
        providerId: 'on-device',
        recipientRevision: 1,
        format: AiFormat.onDevicePrompt,
        model: 'gemini-nano',
        secretSetAtStart: SecretSetId.fromSecrets(const <String>[]),
      );
      seg.setTail(AppUserEntry(text: 'Say hello'));
      final plan = AiRequestPlan(
        model: 'gemini-nano',
        system: 'System prompt',
        segment: seg,
        tools: const <AiToolSpec>[],
        toolChoice: AiToolChoice.auto,
        maxOutputTokens: 256,
      );

      final events = <AiEvent>[];
      final turn = await transport.complete(plan, onEvent: events.add);
      expect(plugin.calls, hasLength(1));
      expect(plugin.calls.single.requestId, 'plugin-req-1');
      expect(plugin.calls.single.system, 'System prompt');
      expect(
        events.whereType<AiTextDelta>().map((e) => e.text).toList(),
        <String>['Hello ', 'world!'],
      );
      expect(turn.output.raw, <String, Object?>{
        'role': 'assistant',
        'content': 'Hello world!',
      });

      // Now test cancelActive mid-stream: cancels plugin-req-2 and keeps
      // transport open for request 3.
      final controller2 = StreamController<String>();
      plugin.handler = (_) => controller2.stream;
      final future2 = transport.complete(plan, onEvent: (_) {});
      await Future<void>.delayed(Duration.zero);
      controller2.add('Partial ');
      await Future<void>.delayed(Duration.zero);

      transport.cancelActive();
      await expectLater(
        future2,
        throwsA(
          isA<AiFailure>()
              .having((f) => f.kind, 'kind', AiFailureKind.cancelled)
              .having((f) => f.notSent, 'notSent', isFalse),
        ),
      );
      expect(plugin.cancelledRequestIds, <String>['plugin-req-2']);
      expect(transport.isClosed, isFalse);
      await controller2.close();

      // Transport still works after cancelActive!
      plugin.handler = (_) =>
          Stream<String>.fromIterable(const <String>['Second turn works']);
      final turn3 = await transport.complete(plan);
      expect(turn3.output.raw, <String, Object?>{
        'role': 'assistant',
        'content': 'Second turn works',
      });

      // Now test close() mid-stream: cancels plugin-req-4 and marks transport
      // permanently closed without calling MergelineOnDeviceAi.close().
      final controller4 = StreamController<String>();
      plugin.handler = (_) => controller4.stream;
      final future4 = transport.complete(plan);
      await Future<void>.delayed(Duration.zero);

      transport.close();
      expect(transport.isClosed, isTrue);
      await expectLater(
        future4,
        throwsA(
          isA<AiFailure>()
              .having((f) => f.kind, 'kind', AiFailureKind.cancelled)
              .having((f) => f.notSent, 'notSent', isTrue),
        ),
      );
      expect(plugin.cancelledRequestIds, contains('plugin-req-4'));
      await controller4.close();

      // Subsequent calls on closed transport fail immediately without calling
      // plugin.generate.
      final callCountBefore = plugin.calls.length;
      await expectLater(
        transport.complete(plan),
        throwsA(
          isA<AiFailure>()
              .having((f) => f.kind, 'kind', AiFailureKind.cancelled)
              .having((f) => f.notSent, 'notSent', isTrue),
        ),
      );
      expect(plugin.calls, hasLength(callCountBefore));
    });

    test('redaction stays on for context, user message, and streamed output, '
        'and truncation raises AiNoticeKind.onDeviceContextTruncated', () async {
      final plugin = _FakeOnDeviceAiPlugin();
      const knownSecret = 'glpat-SUPERSECRETTOKEN1234567890';
      plugin.handler = (call) {
        // Verify known secret was redacted before reaching the on-device plugin!
        expect(call.system, isNot(contains(knownSecret)));
        for (final turn in call.turns) {
          expect(turn.text, isNot(contains(knownSecret)));
        }
        return Stream<String>.fromIterable(<String>[
          'Here is the summary. ',
          'Leaked token: $knownSecret.',
        ]);
      };

      final transport = OnDeviceAiTransport(plugin: plugin);
      final config = AiProviderConfig.onDevice();
      final client = AiWireClient.onDevice(
        config: config,
        conversationId: 'conv-0001',
        appVersion: '0.6.2',
        onDeviceTransport: transport,
      );
      final secrets = _MutableSecrets()..current.add(knownSecret);
      final owner = Object();
      const nonce = 'fedcba9876543210fedcba9876543210';
      final largeContext = AiAppText.untrusted(
        source: 'mr_diff',
        nonce: nonce,
        body: AiAppText.plain(
          'Secret in diff: $knownSecret\n'
          '${List<String>.generate(500, (i) => 'diff line $i content padding').join('\n')}',
        ),
      );

      final notices = <AiNoticeKind>[];
      final streamedSnapshots = <String>[];
      final runner = AiRunner(
        appInForeground: () => true,
        config: config,
        wire: client.wire,
        complete: client.complete,
        secrets: secrets,
        refreshSecrets: () async {},
        guard: AiRunGuard(
          expectedGeneration: 1,
          ownerApi: owner,
          generation: () => 1,
          api: () => owner,
          recipientRevision: () => 1,
          consentValid: () => true,
        ),
        system: aiOnDeviceSystemPrompt(
          languageTag: 'zh-TW',
          languageName: '繁體中文',
        ),
        close: client.close,
        cancelActive: client.cancelActive,
        tools: <AiToolSpec>[
          AiToolSpec(
            name: 'read_file',
            description: 'Should never be sent for on-device',
            parameters: const <String, Object?>{'type': 'object'},
          ),
        ],
        context: <AiContextBlock>[
          AiContextBlock.fromData(source: 'mr_diff', data: largeContext),
        ],
        onTextChanged: streamedSnapshots.add,
        onNotice: notices.add,
      );

      final result = await runner.run('Check token $knownSecret in this diff');
      expect(result.reason, AiRunEnd.done);
      expect(result.modelCalls, 1);
      expect(result.toolCalls, 0);
      expect(result.contextTruncated, isTrue);
      expect(notices, <AiNoticeKind>[AiNoticeKind.onDeviceContextTruncated]);
      expect(result.text, isNot(contains(knownSecret)));
      expect(result.text, contains('[REDACTED]'));
      expect(streamedSnapshots.last, isNot(contains(knownSecret)));
      expect(runner.sentContext.single.text, isNot(contains(knownSecret)));
      expect(
        runner.sentContext.single.text,
        startsWith('<gitlab_data source="mr_diff" nonce="$nonce">\n'),
      );
      expect(runner.sentContext.single.text, endsWith('\n</gitlab_data>'));
    });
  });

  group('6. BUSY retry and every OnDeviceAiErrorCode mapping', () {
    test('OnDeviceAiErrorCode.busy retries once after short back-off '
        'and succeeds on second attempt', () async {
      final plugin = _FakeOnDeviceAiPlugin();
      final backoffs = <Duration>[];
      var attempts = 0;
      plugin.handler = (_) {
        attempts++;
        if (attempts == 1) {
          return Stream<String>.error(
            const OnDeviceAiException(
              OnDeviceAiErrorCode.busy,
              debugMessage: 'AICore busy',
            ),
          );
        }
        return Stream<String>.fromIterable(const <String>['Recovered!']);
      };

      final transport = OnDeviceAiTransport(
        plugin: plugin,
        busyRetryDelay: const Duration(milliseconds: 25),
        wait: (d) async => backoffs.add(d),
      );
      final seg = AiSegment(
        providerId: 'on-device',
        recipientRevision: 1,
        format: AiFormat.onDevicePrompt,
        model: 'gemini-nano',
        secretSetAtStart: SecretSetId.fromSecrets(const <String>[]),
      );
      seg.setTail(AppUserEntry(text: 'Ping'));
      final plan = AiRequestPlan(
        model: 'gemini-nano',
        system: 'Sys',
        segment: seg,
        tools: const <AiToolSpec>[],
        toolChoice: AiToolChoice.auto,
        maxOutputTokens: 128,
      );

      final turn = await transport.complete(plan);
      expect(attempts, 2);
      expect(backoffs, <Duration>[const Duration(milliseconds: 25)]);
      expect(turn.output.raw, <String, Object?>{
        'role': 'assistant',
        'content': 'Recovered!',
      });
    });

    test('OnDeviceAiErrorCode.busy fails with AiFailureKind.onDeviceBusy '
        'when second attempt is also busy', () async {
      final plugin = _FakeOnDeviceAiPlugin();
      var attempts = 0;
      plugin.handler = (_) {
        attempts++;
        return Stream<String>.error(
          const OnDeviceAiException(
            OnDeviceAiErrorCode.busy,
            debugMessage: 'Still busy',
          ),
        );
      };

      final transport = OnDeviceAiTransport(plugin: plugin, wait: (_) async {});
      final seg = AiSegment(
        providerId: 'on-device',
        recipientRevision: 1,
        format: AiFormat.onDevicePrompt,
        model: 'gemini-nano',
        secretSetAtStart: SecretSetId.fromSecrets(const <String>[]),
      );
      seg.setTail(AppUserEntry(text: 'Ping'));
      final plan = AiRequestPlan(
        model: 'gemini-nano',
        system: 'Sys',
        segment: seg,
        tools: const <AiToolSpec>[],
        toolChoice: AiToolChoice.auto,
        maxOutputTokens: 128,
      );

      await expectLater(
        transport.complete(plan),
        throwsA(
          isA<AiFailure>().having(
            (f) => f.kind,
            'kind',
            AiFailureKind.onDeviceBusy,
          ),
        ),
      );
      expect(attempts, 2);
    });

    test('every OnDeviceAiErrorCode maps to the expected AiFailureKind '
        'and has localized title/detail in all languages', () {
      const expectedMap = <OnDeviceAiErrorCode, AiFailureKind>{
        OnDeviceAiErrorCode.backgroundBlocked:
            AiFailureKind.onDeviceForegroundOnly,
        OnDeviceAiErrorCode.busy: AiFailureKind.onDeviceBusy,
        OnDeviceAiErrorCode.quotaExceeded: AiFailureKind.onDeviceQuotaExceeded,
        OnDeviceAiErrorCode.notDownloaded: AiFailureKind.onDeviceModelNotReady,
        OnDeviceAiErrorCode.insufficientStorage:
            AiFailureKind.onDeviceModelNotReady,
        OnDeviceAiErrorCode.unsupported: AiFailureKind.onDeviceUnavailable,
        OnDeviceAiErrorCode.inputTooLong: AiFailureKind.contextTooLong,
        OnDeviceAiErrorCode.cancelled: AiFailureKind.cancelled,
        OnDeviceAiErrorCode.invalidArgument: AiFailureKind.onDeviceError,
        OnDeviceAiErrorCode.other: AiFailureKind.onDeviceError,
      };

      expect(
        expectedMap.keys.toSet(),
        equals(OnDeviceAiErrorCode.values.toSet()),
      );

      for (final entry in expectedMap.entries) {
        final failure = mapOnDeviceAiException(
          OnDeviceAiException(entry.key, debugMessage: 'test'),
          notSent: true,
        );
        expect(failure.kind, entry.value, reason: entry.key.name);
        expect(failure.notSent, isTrue, reason: entry.key.name);
      }

      for (final language in appLanguages) {
        useLanguage(language);
        for (final kind in expectedMap.values.toSet()) {
          final failure = AiFailure(kind);
          expect(failure.title.trim(), isNotEmpty, reason: language.tag);
          expect(failure.detail.trim(), isNotEmpty, reason: language.tag);
        }
        expect(
          l10n.aiNoticeOnDeviceContextTruncated.trim(),
          isNotEmpty,
          reason: language.tag,
        );
      }
      useLanguage(sourceLanguage);
    });
  });

  group('Round 1: endings, redaction guard, overflow and notices', () {
    test('a reply that ends with no text is an error, not an answer', () async {
      final plugin = _FakeOnDeviceAiPlugin()
        ..handler = (_) => const Stream<String>.empty();
      final transport = OnDeviceAiTransport(plugin: plugin);
      await expectLater(
        transport.complete(_plan('Ping')),
        _fails(AiFailureKind.onDeviceError, notSent: true),
      );
    });

    test('off Android the default plugin is never reached', () async {
      final channelCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(MergelineOnDeviceAi.methodChannelName),
            (call) async {
              channelCalls.add(call);
              return null;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(MergelineOnDeviceAi.methodChannelName),
              null,
            ),
      );
      // Test hosts are never Android.
      await expectLater(
        OnDeviceAiTransport().complete(_plan('Ping')),
        _fails(AiFailureKind.onDeviceUnavailable, notSent: true),
      );
      expect(channelCalls, isEmpty);
    });

    for (final close in <bool>[false, true]) {
      test('${close ? 'close' : 'cancelActive'} during the BUSY back-off '
          'ends the call without a retry', () async {
        final plugin = _FakeOnDeviceAiPlugin();
        final waits = <Duration>[];
        final waitStarted = Completer<void>();
        final transport = _busyThenOk(
          plugin,
          wait: (delay) {
            waits.add(delay);
            waitStarted.complete();
            return Completer<void>().future;
          },
        );
        final call = transport.complete(_plan('Ping'));
        await waitStarted.future;
        close ? transport.close() : transport.cancelActive();
        await expectLater(call, _fails(AiFailureKind.cancelled, notSent: true));
        expect(waits, <Duration>[kOnDeviceBusyRetryDelay]);
        expect(kOnDeviceBusyRetryDelay, const Duration(milliseconds: 1500));
        expect(plugin.calls, hasLength(1));
        expect(transport.isClosed, close);
      });
    }

    test(
      'a raw secret that reaches the transport is refused, not sent',
      () async {
        const known = 'synthetic-known-value-0001';
        final plugin = _FakeOnDeviceAiPlugin();
        final transport = OnDeviceAiTransport(plugin: plugin);
        // A known secret, checked with the caller's redactor.
        await expectLater(
          transport.complete(
            _plan('look at $known'),
            redactor: Redactor(secrets: _MutableSecrets()..current.add(known)),
          ),
          throwsA(
            isA<AiFailure>()
                .having((f) => f.kind, 'kind', AiFailureKind.policyBlocked)
                .having((f) => f.notSent, 'notSent', isTrue)
                .having(
                  (f) => f.requiresNewSegment,
                  'requiresNewSegment',
                  isTrue,
                ),
          ),
        );
        // A token in page context, caught by the built-in patterns alone.
        final token = 'glpat-${'A' * 24}';
        await expectLater(
          transport.complete(
            _plan(
              'Summarize',
              context: <AiContextBlock>[
                AiContextBlock.fromData(
                  source: 'issue',
                  data: AiAppText.untrusted(
                    source: 'issue',
                    nonce: '00112233445566778899aabbccddeeff',
                    body: AiAppText.plain('deploy with $token'),
                  ),
                ),
              ],
            ),
          ),
          _fails(AiFailureKind.policyBlocked, notSent: true),
        );
        expect(plugin.calls, isEmpty);
        // Already-redacted text passes unchanged.
        await transport.complete(_plan('look at [REDACTED]'));
        expect(plugin.calls, hasLength(1));
      },
    );

    test(
      'the model\'s own input limit ends as contextTooLong with a new '
      'conversation offered, and truncation is announced when it happens',
      () async {
        final plugin = _FakeOnDeviceAiPlugin()
          ..handler = (_) => Stream<String>.error(
            const OnDeviceAiException(OnDeviceAiErrorCode.inputTooLong),
          );
        final notices = <AiNoticeKind>[];
        final runner = _runner(
          plugin,
          context: <AiContextBlock>[
            AiContextBlock.fromData(
              source: 'mr_diff',
              data: AiAppText.untrusted(
                source: 'mr_diff',
                nonce: 'fedcba9876543210fedcba9876543210',
                body: AiAppText.plain('diff line\n' * 3000),
              ),
            ),
          ],
          onNotice: notices.add,
        );
        final result = await runner.run('Summarize');
        expect(plugin.calls, hasLength(1));
        expect(result.reason, AiRunEnd.contextTooLong);
        expect(result.offerRollover, isTrue);
        expect(result.failure, isNull);
        // Raised when the context was cut, although the call then failed.
        expect(notices, <AiNoticeKind>[AiNoticeKind.onDeviceContextTruncated]);
        expect(result.contextTruncated, isTrue);
      },
    );

    test('a follow-up reaches the plugin as one user turn: the earlier turns '
        'in <conversation_history>, then the new request', () async {
      // On the device AICore answered only the first user Content, so a
      // follow-up sent as [user, model, user] got the first answer again.
      final plugin = _FakeOnDeviceAiPlugin();
      var sent = 0;
      plugin.handler = (_) => Stream<String>.fromIterable(<String>[
        ++sent == 1 ? '這個 MR 新增到期日。' : 'It adds a due date.',
      ]);
      final context = <AiContextBlock>[
        AiContextBlock.fromData(
          source: 'merge_request',
          data: AiAppText.untrusted(
            source: 'merge_request',
            nonce: '0123456789abcdef0123456789abcdef',
            body: AiAppText.plain('MR !1: add a due date to tasks'),
          ),
        ),
      ];
      final runner = _runner(plugin, context: context);
      expect((await runner.run('請用繁體中文摘要這個 MR')).reason, AiRunEnd.done);
      expect(
        (await runner.run('Summarize this MR in English.')).reason,
        AiRunEnd.done,
      );

      expect(plugin.calls, hasLength(2));
      // The first request keeps its plain shape: page context, then question.
      expect(
        plugin.calls[0].turns.map((t) => (t.role, t.text)).toList(),
        <(OnDeviceRole, String)>[
          (OnDeviceRole.user, '${context.single.text}\n\n請用繁體中文摘要這個 MR'),
        ],
      );
      expect(
        plugin.calls[1].turns.map((t) => (t.role, t.text)).toList(),
        <(OnDeviceRole, String)>[
          (
            OnDeviceRole.user,
            '<conversation_history>\n'
                '${context.single.text}\n\n'
                '<user_turn>\n請用繁體中文摘要這個 MR\n</user_turn>\n\n'
                '<assistant_turn>\n這個 MR 新增到期日。\n</assistant_turn>\n'
                '</conversation_history>\n\n'
                '<user_request>\nSummarize this MR in English.\n'
                '</user_request>',
          ),
        ],
      );
      expect(
        aiOnDeviceSystemPrompt(languageTag: 'zh-TW', languageName: '繁體中文'),
        allOf(contains('<conversation_history>'), contains('<user_request>')),
      );
    });

    test('dropping older turns alone raises no page-context notice', () async {
      final notices = <AiNoticeKind>[];
      final plugin = _FakeOnDeviceAiPlugin()
        ..handler = (_) => Stream<String>.fromIterable(const <String>['ok']);
      final runner = _runner(plugin, onNotice: notices.add);
      expect((await runner.run('q1 ${'x' * 3000}')).reason, AiRunEnd.done);
      final second = await runner.run('q2 ${'y' * 9000}');
      expect(second.reason, AiRunEnd.done);
      // The first turn did not fit; its orphaned answer went with it.
      expect(plugin.calls.last.turns, hasLength(1));
      expect(plugin.calls.last.turns.single.text, startsWith('q2 '));
      expect(second.contextTruncated, isFalse);
      expect(notices, isEmpty);
    });

    test(
      'transport guard policyBlocked sets requiresNewSegment so the next '
      'send rebuilds from the redacted summary and recovers',
      () async {
        final plugin = _FakeOnDeviceAiPlugin();
        final config = AiProviderConfig.onDevice();
        final transportSecrets = _MutableSecrets();
        final runnerSecrets = _MutableSecrets();
        final transport = OnDeviceAiTransport(plugin: plugin);
        final client = AiWireClient.onDevice(
          config: config,
          conversationId: 'conv-guard-recovery',
          appVersion: '0.6.2',
          onDeviceTransport: transport,
        );
        final owner = Object();
        final runner = AiRunner(
          appInForeground: () => true,
          config: config,
          wire: client.wire,
          complete: (plan, {onEvent}) => transport.complete(
            plan,
            onEvent: onEvent,
            redactor: Redactor(secrets: transportSecrets),
          ),
          secrets: runnerSecrets,
          refreshSecrets: () async {},
          guard: AiRunGuard(
            expectedGeneration: 1,
            ownerApi: owner,
            generation: () => 1,
            api: () => owner,
            recipientRevision: () => 1,
            consentValid: () => true,
          ),
          system: 'Sys',
          close: client.close,
          cancelActive: client.cancelActive,
        );

        final first = await runner.run('First question with late-secret-xyz');
        expect(first.reason, AiRunEnd.done);
        expect(plugin.calls, hasLength(1));
        final firstSegment = runner.segment;
        expect(firstSegment, isNotNull);

        // If the transport guard catches a secret in the assembled prompt,
        // it throws policyBlocked(notSent: true, requiresNewSegment: true).
        transportSecrets.current.add('late-secret-xyz');
        final blocked = await runner.run('Second question');
        expect(blocked.reason, AiRunEnd.failed);
        expect(blocked.failure?.kind, AiFailureKind.policyBlocked);
        expect(blocked.failure?.requiresNewSegment, isTrue);
        expect(plugin.calls, hasLength(1));

        // Once the runner's live secrets also include the secret, the next
        // send starts a new segment from the redacted summary and recovers.
        runnerSecrets.current.add('late-secret-xyz');
        final recovered = await runner.run('Third question after recovery');
        expect(recovered.reason, AiRunEnd.done);
        expect(plugin.calls, hasLength(2));
        expect(runner.segment, isNot(same(firstSegment)));
        final lastCall = plugin.calls.last;
        expect(
          lastCall.turns.any((t) => t.text.contains('late-secret-xyz')),
          isFalse,
        );
        expect(
          lastCall.turns.last.text,
          contains('Third question after recovery'),
        );
      },
    );
  });

  group('7. No-tools runner and history codec', () {
    test(
      'AI summary runs once with page context only and sends no tools',
      () async {
        final plugin = _FakeOnDeviceAiPlugin()
          ..handler = (_) =>
              Stream<String>.fromIterable(const <String>['這是 ', 'MR 摘要。']);
        final config = AiProviderConfig.onDevice();
        final client = AiWireClient.onDevice(
          config: config,
          conversationId: 'conv-0002',
          appVersion: '0.6.2',
          onDeviceTransport: OnDeviceAiTransport(plugin: plugin),
        );
        final plans = <AiRequestPlan>[];
        final bound = <OnDeviceAssembledPrompt?>[];
        final owner = Object();
        final context = AiContextBlock.fromData(
          source: 'merge_request',
          data: AiAppText.untrusted(
            source: 'merge_request',
            nonce: '00112233445566778899aabbccddeeff',
            body: AiAppText.plain('Title: Improve private-project navigation'),
          ),
        );
        final notices = <AiNoticeKind>[];
        final runner = AiRunner(
          appInForeground: () => true,
          config: config,
          wire: client.wire,
          complete: (plan, {onEvent}) {
            plans.add(plan);
            bound.add(boundOnDevicePrompt(plan)?.prompt);
            return client.complete(plan, onEvent: onEvent);
          },
          secrets: _MutableSecrets(),
          refreshSecrets: () async {},
          guard: AiRunGuard(
            expectedGeneration: 1,
            ownerApi: owner,
            generation: () => 1,
            api: () => owner,
            recipientRevision: () => 1,
            consentValid: () => true,
          ),
          system: aiOnDeviceSystemPrompt(
            languageTag: 'zh-TW',
            languageName: '繁體中文',
          ),
          close: client.close,
          cancelActive: client.cancelActive,
          tools: <AiToolSpec>[
            AiToolSpec(
              name: 'read_file',
              description: 'Should never be sent for on-device',
              parameters: const <String, Object?>{'type': 'object'},
            ),
          ],
          context: <AiContextBlock>[context],
          onNotice: notices.add,
        );
        expect(runner.tools, isEmpty);

        final result = await runner.run('請摘要這個合併請求');
        expect(result.reason, AiRunEnd.done);
        expect(result.modelCalls, 1);
        expect(result.toolCalls, 0);
        expect(result.text, '這是 MR 摘要。');
        expect(result.contextTruncated, isFalse);
        expect(notices, isEmpty);
        expect(plans.single.tools, isEmpty);
        final call = plugin.calls.single;
        // The transport sent the runner's assembly; it did not assemble again.
        expect(bound.single, isNotNull);
        expect(call.turns, bound.single!.turns);
        expect(call.system, bound.single!.system);
        expect(call.system, contains('no tools'));
        expect(call.turns.single.role, OnDeviceRole.user);
        expect(call.turns.single.text, startsWith(context.text));
        expect(call.turns.single.text, endsWith('請摘要這個合併請求'));
        expect(runner.sentContext.single.text, context.text);
      },
    );

    test('history codec round-trips on-device AiAnswerSource, '
        'AiNoticeKind.onDeviceContextTruncated, and '
        'AiNoticeKind.onDeviceCannotWrite', () {
      final conversation = AiConversation(
        items: <AiChatItem>[
          AiUserItem(text: 'Summarize diff'),
          const AiNoticeItem(AiNoticeKind.onDeviceContextTruncated),
          const AiNoticeItem(AiNoticeKind.onDeviceCannotWrite),
          AiAssistantItem(
            text: 'Summary from Gemini Nano.',
            state: AiAssistantState.done,
            source: const AiAnswerSource(
              presetId: 'on-device',
              format: 'onDevicePrompt',
              model: 'gemini-nano',
            ),
          ),
        ],
      );

      final encoded =
          jsonDecode(jsonEncode(aiDisplayJson(conversation)))
              as Map<String, Object?>;
      final restored = aiDisplayFromJson(encoded);

      expect(restored.items, hasLength(4));
      final notice = restored.items[1] as AiNoticeItem;
      expect(notice.kind, AiNoticeKind.onDeviceContextTruncated);
      final refusal = restored.items[2] as AiNoticeItem;
      expect(refusal.kind, AiNoticeKind.onDeviceCannotWrite);

      final answer = restored.items[3] as AiAssistantItem;
      expect(answer.text, 'Summary from Gemini Nano.');
      expect(answer.source?.presetId, 'on-device');
      expect(answer.source?.format, 'onDevicePrompt');
      expect(answer.source?.model, 'gemini-nano');
    });
  });
}
