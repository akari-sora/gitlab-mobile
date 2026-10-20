import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
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

      first.dispose();
      final restarted = AiSettingsController(store);
      await restarted.initialize();
      expect((await store.readProviderKey('a')).isFound, isFalse);
      await restarted.saveProvider(
        _provider('a', 'https://other-recipient.example.test/v1'),
      );
      restarted.dispose();
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

    test('one live settings controller owns each store', () async {
      final store = MemoryAiStore();
      final first = AiSettingsController(store);
      final same = AiSettingsController(store);

      expect(identical(first, same), isTrue);
      first.dispose();
      same.dispose();

      final replacement = AiSettingsController(store);
      expect(identical(replacement, first), isFalse);
      await replacement.initialize();
    });

    test('secure-store wrappers share one live settings controller', () {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final first = AiSettingsController(SecureAiStore());
      final same = AiSettingsController(SecureAiStore());

      expect(identical(first, same), isTrue);

      first.dispose();
      same.dispose();
    });

    test(
      'dispose keeps the registry occupied until its mutation drains',
      () async {
        final store = _FaultStore();
        final first = AiSettingsController(store);
        await first.initialize();
        store.blockNextProviderSave();
        final pending = first.saveProvider(
          _provider('a', 'https://a.example.test/v1'),
        );
        await store.providerSaveStarted.future;

        first.dispose();

        expect(() => AiSettingsController(store), throwsStateError);
        store.releaseProviderSave();
        await pending;
        await Future<void>.delayed(Duration.zero);

        final replacement = AiSettingsController(store);
        expect(identical(replacement, first), isFalse);
        await replacement.initialize();
        expect(replacement.providers.map((provider) => provider.id), <String>[
          'a',
        ]);
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
    test(
      'malformed provider-key entries are skipped and reported distinctly',
      () async {
        final store = _FaultStore();
        store.memory.debugPut(
          '${SecureAiStore.providerKeyPrefix}%%%',
          'synthetic-malformed-secret',
        );
        await store.saveProviders(<AiProviderConfig>[
          _provider('a', 'https://a.example.test/v1'),
        ]);
        await store.saveProviderKey('a', 'synthetic-secret-a');
        await store.saveProviderKey('orphan', 'synthetic-orphan-secret');
        final settings = AiSettingsController(store);

        await settings.initialize();

        expect(settings.providers.map((provider) => provider.id), <String>[
          'a',
        ]);
        expect(settings.malformedSecureInventoryCount, 1);
        expect((await store.readProviderKey('a')).isFound, isTrue);
        expect((await store.readProviderKey('orphan')).isFound, isFalse);

        await settings.resetProviders();

        expect(settings.providers, isEmpty);
        expect(settings.malformedSecureInventoryCount, 1);
        expect((await store.readProviderKey('a')).isFound, isFalse);
        expect(store.deletedProviderKeys, containsAll(<String>['orphan', 'a']));
        expect(store.deletedProviderKeys, isNot(contains('%%%')));
      },
    );

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

    test(
      'a reset failing after key deletion keeps the key cache true',
      () async {
        // Round-5 review: the key was gone but still cached, so saving the
        // same key again returned early without writing it.
        final store = _FaultStore();
        await store.saveProviders(<AiProviderConfig>[
          _provider('p', 'https://p.example.test/v1'),
        ]);
        await store.saveProviderKey('p', 'synthetic-secret-p1');
        final settings = AiSettingsController(store);
        await settings.initialize();
        final secretSet = settings.secretSetId;
        store.failNextSaveProviders = true;

        await expectLater(
          settings.resetProviders(),
          throwsA(isA<AiStoreException>()),
        );

        expect((await store.readProviderKey('p')).isFound, isFalse);
        expect(settings.knownProviderKeys.containsKey('p'), isFalse);
        expect(settings.secretSetId, greaterThan(secretSet));
        await settings.saveProviderKey('p', 'synthetic-secret-p1');
        expect((await store.readProviderKey('p')).value, 'synthetic-secret-p1');
      },
    );

    test('a malformed account record is counted once', () async {
      final store = MemoryAiStore()
        ..debugPut(SecureAiStore.accountKey('malformed'), '{bad');
      await store.saveProviders(<AiProviderConfig>[
        _provider('a', 'https://a.example.test/v1'),
        _provider('b', 'https://b.example.test/v1'),
      ]);
      final settings = AiSettingsController(store);
      await settings.initialize();

      await settings.deleteProvider('a');
      await settings.resetProviders();

      expect(settings.malformedAccountRecordCount, 1);
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

    test(
      'provider deletion keeps marker and key when a fence has no tombstone',
      () async {
        final root = Directory.systemTemp.createTempSync('ai-store-fix3-');
        addTearDown(() => root.deleteSync(recursive: true));
        final store = _FaultStore();
        final settings = AiSettingsController(store);
        await settings.initialize();
        await settings.saveProvider(
          _provider('a', 'https://a.example.test/v1'),
        );
        await settings.saveProviderKey('a', 'synthetic-secret-a');
        await settings.grantConsent(
          'account',
          _contract('a'),
          const <String, Object?>{},
        );
        final history = AiHistoryCoordinator(
          store: store,
          files: AiHistoryFileStore(root: () async => root),
        );
        addTearDown(history.dispose);
        store.failSetTombstone = true;

        await expectLater(history.clearAccount('account'), throwsA(anything));
        store.failSetTombstone = false;
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

        final persisted = (await store.loadProviders()).value!;
        expect(persisted.single.presetId, 'gitlab-mobile:deleting-provider');
        expect((await store.readProviderKey('a')).isFound, isTrue);
        expect(
          (await store.loadAccount('account')).value!.consents,
          contains('a'),
        );

        settings.dispose();
        history.dispose();
        final restartedStore = _FaultStore(store.memory);
        final restarted = AiSettingsController(restartedStore);
        await restarted.initialize();
        await restarted.saveProvider(
          _provider('a', 'https://a.example.test/v1'),
        );
        await restarted.loadAccount('account');

        expect(restarted.isValid('account', _contract('a')), isFalse);
      },
    );

    test('provider deletion may skip a fenced tombstoned account', () async {
      final store = _FaultStore();
      final settings = AiSettingsController(store);
      await settings.initialize();
      await settings.saveProvider(_provider('a', 'https://a.example.test/v1'));
      await settings.saveProviderKey('a', 'synthetic-secret-a');
      await settings.grantConsent(
        'account',
        _contract('a'),
        const <String, Object?>{},
      );
      AiAccountMutationCoordinator.forStore(store).beginCleaning('account');
      await store.setTombstone('account');

      await settings.deleteProvider('a');

      expect((await store.loadProviders()).value, isEmpty);
      expect((await store.readProviderKey('a')).isFound, isFalse);
    });

    test(
      'provider reset stops at a fenced account without a tombstone',
      () async {
        final store = _FaultStore();
        final settings = AiSettingsController(store);
        await settings.initialize();
        await settings.saveProvider(
          _provider('a', 'https://a.example.test/v1'),
        );
        await settings.saveProviderKey('a', 'synthetic-secret-a');
        await settings.grantConsent(
          'account',
          _contract('a'),
          const <String, Object?>{},
        );
        final cleaning = AiAccountMutationCoordinator.forStore(
          store,
        ).beginCleaning('account');

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

        expect((await store.loadProviders()).value, hasLength(1));
        expect((await store.readProviderKey('a')).isFound, isTrue);
        expect(
          (await store.loadAccount('account')).value!.consents,
          contains('a'),
        );

        cleaning.release();
        await settings.resetProviders();
        expect((await store.loadProviders()).value, isEmpty);
        expect((await store.readProviderKey('a')).isFound, isFalse);
        expect((await store.loadAccount('account')).value!.consents, isEmpty);
      },
    );

    test('provider reset may skip a fenced tombstoned account', () async {
      final store = _FaultStore();
      final settings = AiSettingsController(store);
      await settings.initialize();
      await settings.saveProvider(_provider('a', 'https://a.example.test/v1'));
      await settings.saveProviderKey('a', 'synthetic-secret-a');
      await settings.grantConsent(
        'account',
        _contract('a'),
        const <String, Object?>{},
      );
      AiAccountMutationCoordinator.forStore(store).beginCleaning('account');
      await store.setTombstone('account');

      await settings.resetProviders();

      expect((await store.loadProviders()).value, isEmpty);
      expect((await store.readProviderKey('a')).isFound, isFalse);
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
  _FaultStore([MemoryAiStore? memory]) : memory = memory ?? MemoryAiStore();

  final MemoryAiStore memory;
  bool failNextDeleteProviderKey = false;
  bool failNextSaveProviders = false;
  bool failSetTombstone = false;
  final List<String> deletedProviderKeys = <String>[];
  Completer<void> providerSaveStarted = Completer<void>();
  Completer<void>? _providerSaveRelease;
  String? failDeleteAccount;
  Completer<void> consentClearStarted = Completer<void>();
  Completer<void>? _consentClearRelease;

  void blockConsentClear() {
    consentClearStarted = Completer<void>();
    _consentClearRelease = Completer<void>();
  }

  void releaseConsentClear() => _consentClearRelease?.complete();

  void blockNextProviderSave() {
    providerSaveStarted = Completer<void>();
    _providerSaveRelease = Completer<void>();
  }

  void releaseProviderSave() => _providerSaveRelease?.complete();

  @override
  Future<void> deleteProviderKey(String providerId) async {
    if (failNextDeleteProviderKey) {
      failNextDeleteProviderKey = false;
      throw StateError('injected deleteProviderKey failure');
    }
    deletedProviderKeys.add(providerId);
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
      _saveProviders(providers);

  Future<void> _saveProviders(List<AiProviderConfig> providers) async {
    if (failNextSaveProviders) {
      failNextSaveProviders = false;
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'saveProviders'),
      );
    }
    final release = _providerSaveRelease;
    if (release != null) {
      providerSaveStarted.complete();
      await release.future;
      _providerSaveRelease = null;
    }
    await memory.saveProviders(providers);
  }

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
  Future<void> setTombstone(String accountKey) => failSetTombstone
      ? Future<void>.sync(() {
          throw StateError('injected setTombstone failure');
        })
      : memory.setTombstone(accountKey);
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
