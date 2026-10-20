import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

void main() {
  group('FIX4 provider settings regressions', () {
    test(
      'refused reset preserves provider revision and key ownership',
      () async {
        final store = MemoryAiStore();
        final settings = AiSettingsController(store);
        await settings.initialize();
        await settings.saveProvider(
          _provider('a', 'https://a.example.test/v1'),
        );
        await settings.saveProviderKey('a', 'synthetic-secret-a');
        final edited = await settings.saveProvider(
          _provider('a', 'https://edited.example.test/v1'),
        );
        expect(edited.recipientRevision, 3);
        await settings.grantConsent(
          'a-normal',
          _contract('a', 'https://edited.example.test/v1'),
          const <String, Object?>{},
        );
        await settings.grantConsent(
          'z-fenced',
          _contract('a', 'https://edited.example.test/v1'),
          const <String, Object?>{},
        );
        final cleaning = AiAccountMutationCoordinator.forStore(
          store,
        ).beginCleaning('z-fenced');

        await expectLater(
          settings.resetProviders(),
          throwsA(
            isA<AiStoreException>().having(
              (error) => error.failure.kind,
              'kind',
              AiStoreFailureKind.cleaning,
            ),
          ),
        );

        expect(settings.providers.single.recipientRevision, 3);
        expect(settings.knownProviderKeys, contains('a'));
        expect(
          (await store.loadProviders()).value!.single.recipientRevision,
          3,
        );
        expect((await store.readProviderKey('a')).isFound, isTrue);
        expect(
          (await store.loadAccount('a-normal')).value!.consents,
          contains('a'),
        );

        final revised = await settings.saveProvider(
          _provider('a', 'https://new-recipient.example.test/v1'),
        );
        expect(revised.recipientRevision, 4);
        expect((await store.readProviderKey('a')).isFound, isTrue);

        await expectLater(
          settings.deleteProvider('a'),
          throwsA(
            isA<AiStoreException>().having(
              (error) => error.failure.kind,
              'kind',
              AiStoreFailureKind.cleaning,
            ),
          ),
        );
        final deleting = (await store.loadProviders()).value!.single;
        expect(deleting.recipientRevision, 4);
        expect(deleting.presetId, 'gitlab-mobile:deleting-provider');
        expect((await store.readProviderKey('a')).isFound, isTrue);

        cleaning.release();
        await settings.deleteProvider('a');
        expect((await store.loadProviders()).value, isEmpty);
        expect((await store.readProviderKey('a')).isFound, isFalse);
      },
    );

    test(
      'dispose waits for a write enqueued by a synchronous listener',
      () async {
        final store = _ReentrantStore();
        await store.saveProviders(<AiProviderConfig>[
          _provider('a', 'https://a.example.test/v1'),
        ]);
        await store.saveProviderKey('a', 'synthetic-secret-a');
        final settings = AiSettingsController(store);
        await settings.initialize();
        late Future<AiProviderConfig> reentrantSave;
        var started = false;
        settings.addListener(() {
          if (started || settings.providers.isNotEmpty) return;
          started = true;
          reentrantSave = settings.saveProvider(
            _provider('b', 'https://b.example.test/v1'),
          );
        });
        store.blockProvider('b');

        await settings.deleteProvider('a');
        await store.blockedSaveStarted.future;
        settings.dispose();

        expect(() => AiSettingsController(store), throwsStateError);
        store.releaseBlockedSave();
        await reentrantSave;
        await Future<void>.delayed(Duration.zero);

        final replacement = AiSettingsController(store);
        await replacement.initialize();
        final persisted = (await store.loadProviders()).value!;
        expect(persisted.map((provider) => provider.id), <String>['b']);
        expect(
          persisted,
          isNot(
            contains(
              isA<AiProviderConfig>().having(
                (provider) => provider.presetId,
                'presetId',
                'gitlab-mobile:deleting-provider',
              ),
            ),
          ),
        );
      },
    );

    test('malformed inventory count is stable across repeated reads', () async {
      final store = MemoryAiStore()
        ..debugPut(
          '${SecureAiStore.providerKeyPrefix}%%%',
          'synthetic-malformed-secret',
        )
        ..debugPut(
          '${SecureAiStore.providerKeyPrefix}***',
          'synthetic-second-malformed-secret',
        );
      final settings = AiSettingsController(store);

      await settings.initialize();
      expect(settings.malformedSecureInventoryCount, 2);

      await settings.resetProviders();
      expect(settings.malformedSecureInventoryCount, 2);
    });
  });
}

AiProviderConfig _provider(String id, String baseUrl) => AiProviderConfig(
  id: id,
  name: id,
  presetId: 'custom',
  baseUrl: baseUrl,
  modelsUrl: null,
  format: AiFormat.responses,
  model: 'model',
  authStyle: AiAuthStyle.bearer,
  caps: const AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    streamUsage: true,
    toolChoice: true,
    replayChatExtras: true,
    includeEncryptedReasoning: true,
    promptCaching: true,
    requiresKey: true,
    maxRequestChars: 10000,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

AiConsentContract _contract(String providerId, String origin) =>
    AiConsentContract(
      providerId: providerId,
      origin: origin,
      format: AiFormat.responses,
      cleartext: false,
      toolsEnabled: true,
      toolCatalogueVersion: 1,
      dataCategories: const <String>{'diff'},
      policyIdentity: 'custom',
      dataUse: AiDataUse.unknown,
      disclosureVersion: 1,
    );

final class _ReentrantStore implements AiStore, AiStoreSecureInventory {
  final MemoryAiStore memory = MemoryAiStore();
  String? _blockedProviderId;
  Completer<void> blockedSaveStarted = Completer<void>();
  Completer<void>? _blockedSaveRelease;

  void blockProvider(String providerId) {
    _blockedProviderId = providerId;
    blockedSaveStarted = Completer<void>();
    _blockedSaveRelease = Completer<void>();
  }

  void releaseBlockedSave() => _blockedSaveRelease?.complete();

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) async {
    final release = _blockedSaveRelease;
    if (release != null &&
        providers.any(
          (provider) =>
              provider.id == _blockedProviderId &&
              provider.presetId != 'gitlab-mobile:deleting-provider',
        )) {
      blockedSaveStarted.complete();
      await release.future;
      _blockedSaveRelease = null;
    }
    await memory.saveProviders(providers);
  }

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      memory.loadProviders();
  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      memory.readProviderKey(providerId);
  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) => memory.readAllProviderKeys(providerIds);
  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) => memory.saveProviderKey(
    providerId,
    key,
    acknowledgeWarning: acknowledgeWarning,
  );
  @override
  Future<void> deleteProviderKey(String providerId) =>
      memory.deleteProviderKey(providerId);
  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) =>
      memory.loadAccount(accountKey);
  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) =>
      memory.saveAccount(accountKey, account);
  @override
  Future<List<String>> listProviderKeyIds() => memory.listProviderKeyIds();
  @override
  Future<List<String>> listAccountKeys() => memory.listAccountKeys();
  @override
  Future<List<String>> listHistoryKeyAccountKeys() =>
      memory.listHistoryKeyAccountKeys();
  @override
  Future<void> deleteAccount(String accountKey) =>
      memory.deleteAccount(accountKey);
  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) =>
      memory.readHistoryKey(accountKey);
  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) =>
      memory.writeHistoryKey(accountKey, key);
  @override
  Future<void> deleteHistoryKey(String accountKey) =>
      memory.deleteHistoryKey(accountKey);
  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      memory.readTombstone(accountKey);
  @override
  Future<void> setTombstone(String accountKey) =>
      memory.setTombstone(accountKey);
  @override
  Future<List<String>> listTombstones() => memory.listTombstones();
  @override
  Future<void> clearTombstone(String accountKey) =>
      memory.clearTombstone(accountKey);
  @override
  Future<AiTombstoneInventory> readTombstoneInventory() =>
      memory.readTombstoneInventory();
  @override
  Future<AiSecureInventory> readSecureInventory() =>
      memory.readSecureInventory();
}
