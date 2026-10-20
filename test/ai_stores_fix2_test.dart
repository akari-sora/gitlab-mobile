import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('durable provider deletion', () {
    test('another provider write cannot erase a pending marker', () async {
      final store = _FaultStore();
      await store.saveProviders(<AiProviderConfig>[
        _provider('a', 'https://a.example.test/v1'),
        _provider('b', 'https://b.example.test/v1'),
      ]);
      await store.saveProviderKey('a', 'synthetic-secret-a');
      await store.saveProviderKey('b', 'synthetic-secret-b');
      final first = AiSettingsController(store);
      await first.initialize();
      store.failNextDeleteProviderKey = true;

      await expectLater(first.deleteProvider('a'), throwsA(anything));
      await first.saveProviderKey('b', 'replacement-secret-b');
      expect(
        (await store.loadProviders()).value,
        contains(
          isA<AiProviderConfig>()
              .having((value) => value.id, 'id', 'a')
              .having(
                (value) => value.presetId,
                'presetId',
                'gitlab-mobile:deleting-provider',
              ),
        ),
      );

      final restarted = AiSettingsController(store);
      await restarted.initialize();
      expect((await store.readProviderKey('a')).isFound, isFalse);
      await restarted.saveProvider(
        _provider('a', 'https://other-recipient.example.test/v1'),
      );
      final finalRestart = AiSettingsController(store);
      await finalRestart.initialize();
      expect(finalRestart.knownProviderKeys, isNot(contains('a')));
    });

    test('startup removes an unreferenced provider key', () async {
      final store = MemoryAiStore();
      await store.saveProviderKey('orphan', 'synthetic-orphan-secret');

      await AiSettingsController(store).initialize();

      expect((await store.readProviderKey('orphan')).isFound, isFalse);
    });

    test(
      'deletion invalidates peer controller before consent cleanup',
      () async {
        final store = _FaultStore();
        await store.saveProviders(<AiProviderConfig>[
          _provider('a', 'https://a.example.test/v1'),
        ]);
        await store.saveProviderKey('a', 'synthetic-secret-a');
        await store.saveAccount(
          'account',
          AiAccountRecord(
            consents: <String, AiConsentRecord>{
              'a': AiConsentRecord(
                hash: _contract('a').hash,
                summary: const <String, Object?>{},
                grantedAt: DateTime.utc(2026, 10, 20),
              ),
            },
          ),
        );
        final first = AiSettingsController(store);
        final peer = AiSettingsController(store);
        await first.initialize();
        await peer.initialize();
        await peer.loadAccount('account');
        expect(peer.isValid('account', _contract('a')), isTrue);
        store.blockConsentClear();

        final deletion = first.deleteProvider('a');
        await store.consentClearStarted.future;
        try {
          expect(
            (await store.loadProviders()).value!.single.presetId,
            'gitlab-mobile:deleting-provider',
          );
          expect(
            (await store.loadAccount('account')).value!.consents,
            contains('a'),
          );
          expect((await store.readProviderKey('a')).isFound, isTrue);
          expect(peer.providers, isEmpty);
          expect(peer.knownProviderKeys, isNot(contains('a')));
          expect(peer.isValid('account', _contract('a')), isFalse);
        } finally {
          store.releaseConsentClear();
        }
        await deletion;
      },
    );

    test('peer cannot resurrect a completed marker after recreation', () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[
        _provider('a', 'https://a.example.test/v1'),
      ]);
      await store.saveProviderKey('a', 'synthetic-secret-a');
      final first = AiSettingsController(store);
      final peer = AiSettingsController(store);
      await first.initialize();
      await peer.initialize();

      await first.deleteProvider('a');
      await first.saveProvider(
        _provider('a', 'https://other-recipient.example.test/v1'),
      );
      await first.saveProviderKey('a', 'replacement-secret-a');
      await peer.initialize();

      expect((await store.readProviderKey('a')).value, 'replacement-secret-a');
      expect(peer.providers.single.baseUrl, contains('other-recipient'));
    });

    test(
      'stale peer write preserves a provider added by another peer',
      () async {
        final store = MemoryAiStore();
        await store.saveProviders(<AiProviderConfig>[
          _provider('a', 'https://a.example.test/v1'),
        ]);
        final first = AiSettingsController(store);
        final peer = AiSettingsController(store);
        await first.initialize();
        await peer.initialize();

        await first.saveProvider(_provider('b', 'https://b.example.test/v1'));
        await peer.saveProviderKey('a', 'synthetic-secret-a');

        expect(
          (await store.loadProviders()).value!.map((provider) => provider.id),
          containsAll(<String>['a', 'b']),
        );
      },
    );
  });

  group('secure inventory recovery', () {
    test(
      'account and history inventories skip and report malformed ids',
      () async {
        final store = MemoryAiStore()
          ..debugPut(SecureAiStore.accountKey('valid-account'), '{}')
          ..debugPut('${SecureAiStore.accountPrefix}%%%', '{}')
          ..debugPut(SecureAiStore.historyKey('valid-history'), 'bad-value')
          ..debugPut('${SecureAiStore.historyKeyPrefix}%%%', 'bad-value');

        final inventory = await readAiSecureInventory(store);

        expect(inventory.accountKeys, <String>['valid-account']);
        expect(inventory.historyKeyAccountKeys, <String>['valid-history']);
        expect(inventory.malformedAccountKeyCount, 1);
        expect(inventory.malformedHistoryKeyCount, 1);
      },
    );

    test(
      'orphan cleanup reports one failure, continues, and releases fence',
      () async {
        final store = _FaultStore();
        await store.saveAccount('a-fails', AiAccountRecord());
        await store.saveAccount('b-deletes', AiAccountRecord());
        store.failDeleteAccount = 'a-fails';

        final result = await cleanupOrphanAiSecureData(store, const <String>{});

        expect(result.failedAccounts, <String>['a-fails']);
        expect(result.deletedAccountRecords, <String>['b-deletes']);
        expect(
          AiAccountMutationCoordinator.forStore(store).isCleaning('a-fails'),
          isFalse,
        );
      },
    );
  });

  group('malformed secure values', () {
    test('malformed account record does not block provider deletion', () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[
        _provider('a', 'https://a.example.test/v1'),
      ]);
      await store.saveProviderKey('a', 'synthetic-secret-a');
      store.debugPut(SecureAiStore.accountKey('malformed'), '{bad');
      final settings = AiSettingsController(store);
      await settings.initialize();

      await settings.deleteProvider('a');

      expect(settings.providers, isEmpty);
      expect(settings.malformedAccountRecordCount, 1);
      expect((await store.readProviderKey('a')).isFound, isFalse);
    });

    test('malformed account record does not block reset', () async {
      final store = MemoryAiStore()
        ..debugPut(SecureAiStore.accountKey('malformed'), '{bad');
      await store.saveProviders(<AiProviderConfig>[
        _provider('a', 'https://a.example.test/v1'),
      ]);
      await store.saveProviderKey('a', 'synthetic-secret-a');
      final settings = AiSettingsController(store);

      await settings.resetProviders();

      expect(settings.malformedAccountRecordCount, 1);
      expect((await store.readProviderKey('a')).isFound, isFalse);
    });

    test('memory readAll skips malformed keys like secure store', () async {
      final store = MemoryAiStore()
        ..debugPut(SecureAiStore.providerKey('short'), 'abc');
      await store.saveProviderKey('valid', 'synthetic-valid-secret');

      expect(
        await store.readAllProviderKeys(<String>['short', 'valid']),
        <String, String>{'valid': 'synthetic-valid-secret'},
      );
    });

    test(
      'settings writes rejected by cleanup return a typed failure',
      () async {
        final store = MemoryAiStore();
        await store.saveProviders(<AiProviderConfig>[
          _provider('a', 'https://a.example.test/v1'),
        ]);
        final settings = AiSettingsController(store);
        await settings.initialize();
        AiAccountMutationCoordinator.forStore(store).beginCleaning('account');

        await expectLater(
          settings.grantConsent(
            'account',
            _contract('a'),
            const <String, Object?>{},
          ),
          throwsA(
            isA<AiStoreException>().having(
              (error) => error.failure.kind,
              'kind',
              AiStoreFailureKind.cleaning,
            ),
          ),
        );
      },
    );
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

AiConsentContract _contract(String providerId) => AiConsentContract(
  providerId: providerId,
  origin: 'https://a.example.test/v1',
  format: AiFormat.responses,
  cleartext: false,
  toolsEnabled: true,
  toolCatalogueVersion: 1,
  dataCategories: const <String>{'diff'},
  policyIdentity: 'custom',
  dataUse: AiDataUse.unknown,
  disclosureVersion: 1,
);

final class _FaultStore implements AiStore, AiStoreSecureInventory {
  final MemoryAiStore memory = MemoryAiStore();
  bool failNextDeleteProviderKey = false;
  String? failDeleteAccount;
  Completer<void> consentClearStarted = Completer<void>();
  Completer<void>? _consentClearRelease;

  void blockConsentClear() {
    consentClearStarted = Completer<void>();
    _consentClearRelease = Completer<void>();
  }

  void releaseConsentClear() => _consentClearRelease?.complete();

  @override
  Future<void> deleteProviderKey(String providerId) async {
    if (failNextDeleteProviderKey) {
      failNextDeleteProviderKey = false;
      throw StateError('injected deleteProviderKey failure');
    }
    await memory.deleteProviderKey(providerId);
  }

  @override
  Future<void> deleteAccount(String accountKey) {
    if (failDeleteAccount == accountKey) {
      failDeleteAccount = null;
      throw StateError('injected deleteAccount failure');
    }
    return memory.deleteAccount(accountKey);
  }

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) =>
      memory.loadAccount(accountKey);
  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) async {
    final release = _consentClearRelease;
    if (release != null && account.consents.isEmpty) {
      consentClearStarted.complete();
      await release.future;
      _consentClearRelease = null;
    }
    await memory.saveAccount(accountKey, account);
  }

  @override
  Future<List<String>> listAccountKeys() => memory.listAccountKeys();
  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      memory.loadProviders();
  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) =>
      memory.saveProviders(providers);
  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      memory.readProviderKey(providerId);
  @override
  Future<Map<String, String>> readAllProviderKeys(Iterable<String> ids) =>
      memory.readAllProviderKeys(ids);
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
  Future<List<String>> listProviderKeyIds() => memory.listProviderKeyIds();
  @override
  Future<List<String>> listHistoryKeyAccountKeys() =>
      memory.listHistoryKeyAccountKeys();
  @override
  Future<AiTombstoneInventory> readTombstoneInventory() =>
      memory.readTombstoneInventory();
  @override
  Future<AiSecureInventory> readSecureInventory() =>
      memory.readSecureInventory();
}
