import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_consent_dialog.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

const _account = 'https://synthetic.example#7';
const _key1 = 'synthetic-key-one';
const _key2 = 'synthetic-key-two';

AiProviderConfig _provider({
  AiPreset? preset,
  String? url,
  bool keyless = false,
}) {
  final selected = preset ?? AiPresets.openCodeGo;
  return AiProviderConfig(
    id: 'synthetic-provider',
    name: 'Synthetic provider',
    presetId: selected.id,
    baseUrl: url ?? selected.baseUrlFor(AiFormat.responses),
    format: AiFormat.responses,
    model: 'gpt-6-luna',
    authStyle: keyless ? AiAuthStyle.none : AiAuthStyle.bearer,
    caps: AiCaps(
      tokenLimitField: AiTokenLimitField.maxOutputTokens,
      requiresKey: !keyless,
    ),
    allowLanCleartext: true,
    toolsEnabled: true,
    recipientRevision: 0,
  );
}

AiSavedConversation _conversation(String id) => AiSavedConversation(
  id: id * 32,
  updatedAt: DateTime.utc(2026, 10, 21),
  conversation: AiConversation(items: [AiUserItem(text: 'synthetic prompt')]),
);

Widget _host(Future<void> Function(BuildContext) open) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => open(context),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FIX2 I2 policy belongs to the normalized preset origin', () {
    final known = aiConsentContractFor(_provider());
    expect(known.dataUse, AiDataUse.noTraining);
    expect(known.retentionDays, 30);
    expect(known.policyUrl, AiPresets.openCodePolicySource);
    expect(
      aiConsentContractFor(
        _provider(url: 'HTTPS://OPENCODE.AI:443/inference/go/openai/v1/'),
      ).hash,
      known.hash,
    );
    for (final url in [
      'https://foreign.example/v1',
      'https://opencode.ai/inference/openai/v1',
      'https://opencode.ai:8443/inference/go/openai/v1',
      'http://127.0.0.1/inference/go/openai/v1',
    ]) {
      final custom = aiConsentContractFor(_provider(url: url));
      expect(custom.dataUse, AiDataUse.unknown, reason: url);
      expect(custom.retentionDays, isNull);
      expect(custom.policyUrl, isNull);
      expect(custom.policyIdentity, 'custom');
    }
  });

  test(
    'FIX2 m7 non-model-sensitive policies include their URL in identity',
    () {
      for (final preset in AiPresets.all.where((p) => !p.modelSensitive)) {
        if (preset == AiPresets.azure) {
          continue; // Resource placeholder, not a recipient.
        }
        final contract = aiCurrentConsentContractFor(
          _provider(
            preset: preset,
            url: preset.baseUrlFor(preset.defaultFormat),
          ),
        );
        // Only presets that support Responses match this fixture's format.
        if (!preset.formats.contains(AiFormat.responses)) continue;
        expect(contract.policyUrl, isNotNull, reason: preset.id);
        expect(contract.policyIdentity, contains(contract.policyUrl!));
        expect(contract.dataUse, AiDataUse.unknown);
        expect(contract.toolCatalogueVersion, aiToolCatalogueVersion);
        expect(contract.disclosureVersion, aiDisclosureVersion);
      }
    },
  );

  testWidgets('FIX2 I4 probe H grants the requested app-owned version', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    addTearDown(settings.dispose);
    final saved = await settings.saveProvider(_provider());
    final requested = aiConsentContractFor(
      saved,
      toolCatalogueVersion: 2,
      disclosureVersion: 2,
      dataCategories: {'source'},
    );
    bool? granted;
    await tester.pumpWidget(
      _host((context) async {
        granted = await showAiConsentDialog(
          context,
          settings,
          _account,
          requested,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.aiConsentAgreeAndSend));
    await tester.pumpAndSettle();
    expect(granted, isTrue);
    expect(settings.isValid(_account, requested), isTrue);
    expect(
      settings.isValid(_account, aiCurrentConsentContractFor(saved)),
      isFalse,
    );
    final summary = settings
        .accountRecord(_account)!
        .consents[saved.id]!
        .summary;
    expect(summary['toolCatalogueVersion'], 2);
    expect(summary['disclosureVersion'], 2);
    // Write results and attachment metadata come with tools (consent v2).
    expect(summary['dataCategories'], [
      'attachment_metadata',
      'source',
      'write_results',
    ]);
  });

  testWidgets('FIX2 I4 forged recipient hash returns false without a grant', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    addTearDown(settings.dispose);
    await settings.saveProvider(_provider());
    final forged = aiConsentContractFor(
      _provider(url: 'https://foreign.example/v1'),
    );
    bool? granted;
    await tester.pumpWidget(
      _host((context) async {
        granted = await showAiConsentDialog(
          context,
          settings,
          _account,
          forged,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(granted, isFalse);
    expect(find.text(l10n.aiConsentAgreeAndSend), findsNothing);
    expect(settings.accountRecord(_account), isNull);
  });

  testWidgets(
    'FIX2 m7 no-training record displays actual seven-day retention',
    (tester) async {
      final summary = aiConsentSummary(aiConsentContractFor(_provider()))
        ..['retentionDays'] = 7;
      await tester.pumpWidget(
        _host((context) async {
          await showAiConsentRecordDialog(
            context,
            AiConsentRecord(
              hash: 'synthetic',
              summary: summary,
              grantedAt: DateTime.utc(2026),
            ),
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(l10n.aiConsentRetentionDays),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('7'), findsOneWidget);
      expect(find.text(l10n.aiConsentRetentionNotStated), findsNothing);
    },
  );

  test('FIX2 I3 disable-enable cannot bypass pending history clear', () async {
    final root = Directory.systemTemp.createTempSync('ai-fix2-history-');
    final store = MemoryAiStore();
    final history = AiHistoryCoordinator(
      store: store,
      files: AiHistoryFileStore(root: () async => root),
    );
    addTearDown(() {
      history.dispose();
      removeAiHistoryDirectory = (directory) =>
          directory.deleteSync(recursive: true);
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await history.enable(_account);
    await history.save(_account, _conversation('a'));
    removeAiHistoryDirectory = (_) =>
        throw const FileSystemException('synthetic');
    await expectLater(history.clearHistory(_account), throwsA(anything));
    await history.disable(_account);
    expect(await history.enable(_account), AiHistoryState.readFailed);
    expect(
      await history.save(_account, _conversation('b')),
      AiHistorySaveResult.cancelled,
    );
    expect((await store.readHistoryClearMarker(_account)).value, isTrue);
    expect((await store.loadAccount(_account)).value!.historyEnabled, isFalse);
  });

  test('FIX2 I3 save checks a marker added after cached ready load', () async {
    final root = Directory.systemTemp.createTempSync('ai-fix2-write-');
    final store = MemoryAiStore();
    final history = AiHistoryCoordinator(
      store: store,
      files: AiHistoryFileStore(root: () async => root),
    );
    addTearDown(() {
      history.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await history.enable(_account);
    await store.setHistoryClearMarker(_account);
    expect(
      await history.save(_account, _conversation('a')),
      AiHistorySaveResult.cancelled,
    );
    expect(history.state(_account), AiHistoryState.readFailed);
  });

  for (final failure in ['key', 'binding', 'list']) {
    test(
      'FIX2 SH1b keyless failure at $failure keeps disk and live recipient on restart',
      () async {
        final store = _FaultStore();
        var settings = AiSettingsController(store);
        await settings.saveProviderWithKey(_provider(), key: _key1);
        final revision = settings.providers.single.recipientRevision;
        final binding = (await store.readProviderKeyBinding(
          _provider().id,
        )).value;
        store.fail = failure;
        await expectLater(
          settings.saveProviderWithKey(_provider(keyless: true)),
          throwsA(isA<AiStoreException>()),
        );
        expect(settings.providers.single.caps.requiresKey, isTrue);
        expect(
          (await store.loadProviders()).value!.single.caps.requiresKey,
          isTrue,
        );
        expect(
          (await store.loadProviders()).value!.single.authStyle,
          AiAuthStyle.bearer,
        );
        expect(settings.providers.single.recipientRevision, revision);
        expect(
          (await store.readProviderKeyBinding(_provider().id)).value,
          binding,
        );
        expect(settings.providerKeyFor(_provider()), _key1);
        settings.dispose();
        await Future<void>.delayed(Duration.zero);
        settings = AiSettingsController(store);
        addTearDown(settings.dispose);
        await settings.initialize();
        expect(settings.providers.single.caps.requiresKey, isTrue);
        expect(settings.providerKeyFor(_provider()), _key1);
      },
    );
  }

  test(
    'FIX2 SH4 failed legacy key save preserves binding revision and K1 on restart',
    () async {
      final store = _FaultStore();
      var settings = AiSettingsController(store);
      await settings.saveProviderWithKey(_provider(), key: _key1);
      final revision = settings.recipientRevision(_provider().id);
      final binding = (await store.readProviderKeyBinding(
        _provider().id,
      )).value;
      final secrets = settings.secretSetId;
      store.fail = 'write';
      await expectLater(
        settings.saveProviderKey(_provider().id, _key2),
        throwsA(isA<AiStoreException>()),
      );
      expect(settings.recipientRevision(_provider().id), revision);
      expect(settings.secretSetId, secrets);
      expect(
        (await store.readProviderKeyBinding(_provider().id)).value,
        binding,
      );
      settings.dispose();
      await Future<void>.delayed(Duration.zero);
      settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      await settings.initialize();
      expect(settings.providerKeyFor(_provider()), _key1);
      expect(settings.recipientRevision(_provider().id), revision);
    },
  );

  test(
    'FIX2 SH5 reset invalidates cache before awaiting binding deletion',
    () async {
      final store = _FaultStore();
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      await settings.saveProviderWithKey(_provider(), key: _key1);
      final secrets = settings.secretSetId;
      store.pauseBinding = Completer<void>();
      store.bindingStarted = Completer<void>();
      store.fail = 'binding';
      final reset = settings.resetProviders();
      final assertion = expectLater(reset, throwsA(isA<AiStoreException>()));
      await store.bindingStarted!.future;
      try {
        expect((await store.readProviderKey(_provider().id)).isFound, isFalse);
        expect(settings.knownProviderKeys, isEmpty);
        expect(settings.secretSetId, greaterThan(secrets));
      } finally {
        store.pauseBinding!.complete();
        await assertion;
      }
      expect(settings.knownProviderKeys, isEmpty);
    },
  );

  test('FIX2 m1 resaving keyless provider keeps recipient revision', () async {
    final settings = AiSettingsController(MemoryAiStore());
    addTearDown(settings.dispose);
    final initial = await settings.saveProvider(_provider(keyless: true));
    final again = await settings.saveProvider(_provider(keyless: true));
    expect(again.recipientRevision, initial.recipientRevision);
  });

  test(
    'FIX2 m2 mismatched credential is deleted rather than sent or retained unredacted',
    () async {
      final store = MemoryAiStore();
      var settings = AiSettingsController(store);
      await settings.saveProviderWithKey(_provider(), key: _key1);
      settings.dispose();
      await Future<void>.delayed(Duration.zero);
      await store.saveProviderKeyBinding(
        _provider().id,
        'synthetic-wrong-binding',
      );
      settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      await settings.initialize();
      expect(settings.providerKeyFor(_provider()), isNull);
      expect((await store.readProviderKey(_provider().id)).isFound, isFalse);
      expect(
        (await store.readProviderKeyBinding(_provider().id)).isFound,
        isFalse,
      );
    },
  );

  test(
    'FIX2 m8 clear-marker namespace is inventoried and orphan-cleaned',
    () async {
      final store = MemoryAiStore();
      await store.setHistoryClearMarker('orphan');
      await store.setHistoryClearMarker('retained');
      store.debugPut('${SecureAiStore.historyClearMarkerPrefix}!', '1');
      final inventory = await store.readSecureInventory();
      expect(inventory.historyClearMarkerAccountKeys, ['orphan', 'retained']);
      expect(inventory.malformedHistoryKeyCount, 1);
      final cleanup = await cleanupOrphanAiSecureData(store, {'retained'});
      expect(cleanup.failedAccounts, isEmpty);
      expect((await store.readHistoryClearMarker('orphan')).isFound, isFalse);
      expect((await store.readHistoryClearMarker('retained')).value, isTrue);
    },
  );

  test(
    'FIX2 m8 decoded legacy invalid endpoint is malformed and never published',
    () async {
      final store = MemoryAiStore();
      await store.saveProviders([_provider(url: 'not an endpoint')]);
      expect((await store.loadProviders()).isFound, isTrue);
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      await expectLater(
        settings.initialize(),
        throwsA(isA<AiStoreException>()),
      );
      expect(
        settings.initializationFailure?.kind,
        AiStoreFailureKind.malformed,
      );
      expect(settings.providers, isEmpty);
      await settings.resetProviders();
      expect(settings.initializationFailure, isNull);
      expect(settings.initialized, isTrue);
    },
  );
}

final class _FaultStore
    implements AiStore, AiProviderKeyBindingStore, AiStoreSecureInventory {
  final memory = MemoryAiStore();
  String? fail;
  Completer<void>? pauseBinding;
  Completer<void>? bindingStarted;

  void _check(String operation) {
    if (fail != operation) return;
    fail = null;
    throw AiStoreException(
      AiStoreFailure(AiStoreFailureKind.unavailable, operation),
    );
  }

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      memory.loadProviders();
  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) async {
    _check('list');
    await memory.saveProviders(providers);
  }

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      memory.readProviderKey(providerId);
  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) async {
    _check('write');
    await memory.saveProviderKey(
      providerId,
      key,
      acknowledgeWarning: acknowledgeWarning,
    );
  }

  @override
  Future<void> deleteProviderKey(String providerId) async {
    _check('key');
    await memory.deleteProviderKey(providerId);
  }

  @override
  Future<AiStoreRead<String>> readProviderKeyBinding(String providerId) =>
      memory.readProviderKeyBinding(providerId);
  @override
  Future<void> saveProviderKeyBinding(String providerId, String binding) =>
      memory.saveProviderKeyBinding(providerId, binding);
  @override
  Future<void> deleteProviderKeyBinding(String providerId) async {
    bindingStarted?.complete();
    await pauseBinding?.future;
    _check('binding');
    await memory.deleteProviderKeyBinding(providerId);
  }

  @override
  Future<AiSecureInventory> readSecureInventory() =>
      memory.readSecureInventory();
  @override
  Future<List<String>> listAccountKeys() => memory.listAccountKeys();
  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) =>
      memory.loadAccount(accountKey);
  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      memory.readTombstone(accountKey);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
