import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shared account mutation owner', () {
    test('cleaning fences mutations queued before and after cleanup', () async {
      final store = _BarrierStore();
      await store.saveAccount(
        'account',
        AiAccountRecord(historyEnabled: false),
      );
      final owner = AiAccountMutationCoordinator.forStore(store);
      store.holdNextAccountLoad();
      final stale = owner.mutate(
        'account',
        (record) => record.copyWith(historyEnabled: true),
      );
      await store.accountLoadStarted.future;

      final lease = owner.beginCleaning('account');
      final late = owner.mutate(
        'account',
        (record) => record.copyWith(retentionDays: 90),
      );
      store.releaseAccountLoad();
      await lease.run(() => store.deleteAccount('account'));

      expect(await stale, isNull);
      expect(await late, isNull);
      expect(
        (await store.loadAccount('account')).status,
        AiStoreReadStatus.absent,
      );
    });

    test('settings mutations re-read inside the shared owner', () async {
      final store = MemoryAiStore();
      final owner = AiAccountMutationCoordinator.forStore(store);
      await Future.wait(<Future<AiAccountRecord?>>[
        owner.mutate(
          'account',
          (record) => record.copyWith(historyEnabled: true),
        ),
        owner.mutate('account', (record) => record.copyWith(retentionDays: 90)),
      ]);
      final value = (await store.loadAccount('account')).value!;
      expect(value.historyEnabled, isTrue);
      expect(value.retentionDays, 90);
    });

    test('history enable then consent revoke preserves both updates', () async {
      final store = _BarrierStore();
      await _seedProviderDeletion(store.memory);
      final settings = AiSettingsController(store);
      await settings.initialize();
      await settings.loadAccount('account');
      final root = Directory.systemTemp.createTempSync('ai-store-fix1-');
      final history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(root: () async => root),
      );
      addTearDown(() {
        history.dispose();
        root.deleteSync(recursive: true);
      });
      expect(await history.load('account'), AiHistoryState.disabled);
      store.holdNextAccountLoad();
      final enable = history.enable('account');
      await store.accountLoadStarted.future;
      final revoke = settings.revokeConsent('account', 'p');
      store.releaseAccountLoad();
      await Future.wait(<Future<Object?>>[enable, revoke]);

      expect(history.state('account'), AiHistoryState.ready);
      final value = (await store.loadAccount('account')).value!;
      expect(value.historyEnabled, isTrue);
      expect(value.consents, isNot(contains('p')));
    });

    test('consent revoke then history enable preserves both updates', () async {
      final store = _BarrierStore();
      await _seedProviderDeletion(store.memory);
      final settings = AiSettingsController(store);
      await settings.initialize();
      await settings.loadAccount('account');
      final root = Directory.systemTemp.createTempSync('ai-store-fix1-');
      final history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(root: () async => root),
      );
      addTearDown(() {
        history.dispose();
        root.deleteSync(recursive: true);
      });
      expect(await history.load('account'), AiHistoryState.disabled);
      store.holdNextAccountLoad();
      final revoke = settings.revokeConsent('account', 'p');
      await store.accountLoadStarted.future;
      final enable = history.enable('account');
      store.releaseAccountLoad();
      await Future.wait(<Future<Object?>>[revoke, enable]);

      expect(history.state('account'), AiHistoryState.ready);
      final value = (await store.loadAccount('account')).value!;
      expect(value.historyEnabled, isTrue);
      expect(value.consents, isNot(contains('p')));
    });

    test('cleanup invalidates every settings-controller cache', () async {
      final store = MemoryAiStore();
      await store.saveAccount('account', AiAccountRecord(historyEnabled: true));
      final first = AiSettingsController(store);
      final second = AiSettingsController(store);
      await first.loadAccount('account');
      await second.loadAccount('account');
      final lease = AiAccountMutationCoordinator.forStore(
        store,
      ).beginCleaning('account');
      await lease.run(() => store.deleteAccount('account'));

      expect(first.accountRecord('account'), isNull);
      expect(second.accountRecord('account'), isNull);
    });

    test('history cleanup fences an in-flight settings mutation', () async {
      final store = _BarrierStore();
      await _seedProviderDeletion(store.memory);
      final settings = AiSettingsController(store);
      await settings.initialize();
      await settings.loadAccount('account');
      final root = Directory.systemTemp.createTempSync('ai-store-fix1-');
      final history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(root: () async => root),
      );
      addTearDown(() {
        history.dispose();
        root.deleteSync(recursive: true);
      });
      expect(await history.load('account'), AiHistoryState.disabled);
      expect(await history.enable('account'), AiHistoryState.ready);

      store.holdNextAccountLoad();
      final revoke = settings.revokeConsent('account', 'p');
      await store.accountLoadStarted.future;
      final clear = history.clearAccount('account');
      store.releaseAccountLoad();
      await revoke;
      await clear;

      expect(settings.accountRecord('account'), isNull);
      expect(
        (await store.loadAccount('account')).status,
        AiStoreReadStatus.absent,
      );
    });
  });

  group('secure inventory parity', () {
    test(
      'memory rejects malformed provider keys and tombstones like secure store',
      () async {
        final store = MemoryAiStore()
          ..debugPut(SecureAiStore.providerKey('p'), 'abc')
          ..debugPut(SecureAiStore.tombstoneKey('a'), '0');
        expect(
          (await store.readProviderKey('p')).failure?.kind,
          AiStoreFailureKind.malformed,
        );
        expect(
          (await store.readTombstone('a')).failure?.kind,
          AiStoreFailureKind.malformed,
        );
      },
    );

    test('malformed tombstones are skipped and reported', () async {
      final store = MemoryAiStore()
        ..debugPut(SecureAiStore.tombstoneKey('valid'), '1')
        ..debugPut('${SecureAiStore.tombstonePrefix}%%%', '1')
        ..debugPut(SecureAiStore.tombstoneKey('bad-value'), '0');
      final inventory = await readAiTombstoneInventory(store);
      expect(inventory.accountKeys, <String>['valid']);
      expect(inventory.malformedCount, 2);
    });

    test('orphan cleanup removes account records and history keys', () async {
      final store = MemoryAiStore();
      await store.saveAccount('live', AiAccountRecord());
      await store.saveAccount('orphan', AiAccountRecord());
      await store.writeHistoryKey('live', Uint8List(32));
      await store.writeHistoryKey('orphan-key', Uint8List(32));
      final result = await cleanupOrphanAiSecureData(store, <String>{'live'});
      expect(result.deletedAccountRecords, <String>['orphan']);
      expect(result.deletedHistoryKeys, <String>['orphan-key']);
      expect((await store.loadAccount('live')).isFound, isTrue);
      expect((await store.readHistoryKey('live')).isFound, isTrue);
    });
  });

  group('provider repair and validation', () {
    test('provider endpoints are validated before persistence', () async {
      final store = MemoryAiStore();
      final controller = AiSettingsController(store);
      await controller.initialize();
      await expectLater(
        controller.saveProvider(
          _provider(baseUrl: 'https://user:pass@example.test/v1'),
        ),
        throwsA(isA<AiStoreException>()),
      );
      expect(
        (await store.loadProviders()).value ?? const <AiProviderConfig>[],
        isEmpty,
      );
    });

    test('malformed provider payload and short key have reset paths', () async {
      final store = MemoryAiStore()
        ..debugPut(SecureAiStore.providersStorageKey, '{bad')
        ..debugPut(SecureAiStore.providerKey('p'), 'abc');
      await store.saveAccount(
        'account',
        AiAccountRecord(
          consents: <String, AiConsentRecord>{
            'p': AiConsentRecord(
              hash: _contract().hash,
              summary: const <String, Object?>{},
              grantedAt: DateTime.utc(2026, 10, 20),
            ),
          },
        ),
      );
      final controller = AiSettingsController(store);
      await controller.resetProviders();
      await controller.repairProviderKey('p');
      await controller.initialize();
      expect(controller.providers, isEmpty);
      expect(
        (await store.readProviderKey('p')).status,
        AiStoreReadStatus.absent,
      );
      expect((await store.loadAccount('account')).value!.consents, isEmpty);
    });

    for (final failure in <String>['saveAccount', 'deleteProviderKey']) {
      test('provider deletion resumes after $failure fails', () async {
        final store = _BarrierStore();
        await _seedProviderDeletion(store.memory);
        final controller = AiSettingsController(store);
        await controller.initialize();
        await controller.loadAccount('account');
        store.failNext = failure;

        await expectLater(controller.deleteProvider('p'), throwsA(anything));
        expect(controller.providers, isEmpty);
        expect(controller.isValid('account', _contract()), isFalse);
        expect((await store.loadProviders()).value, hasLength(1));

        final restarted = AiSettingsController(store);
        await restarted.initialize();
        expect(restarted.providers, isEmpty);
        expect(
          (await store.readProviderKey('p')).status,
          AiStoreReadStatus.absent,
        );
        expect(
          (await store.loadAccount('account')).value!.consents,
          isNot(contains('p')),
        );
        expect((await store.loadProviders()).value, isEmpty);
      });
    }

    test(
      'failed initial deletion marker keeps provider locally invalid',
      () async {
        final store = _BarrierStore();
        await _seedProviderDeletion(store.memory);
        final controller = AiSettingsController(store);
        await controller.initialize();
        await controller.loadAccount('account');
        store.failNext = 'saveProviders';

        await expectLater(controller.deleteProvider('p'), throwsA(anything));
        expect(controller.providers, isEmpty);
        expect(controller.isValid('account', _contract()), isFalse);

        await controller.initialize();
        expect(controller.providers, isEmpty);
        expect((await store.loadProviders()).value, isEmpty);
        expect(
          (await store.readProviderKey('p')).status,
          AiStoreReadStatus.absent,
        );
      },
    );

    test('final provider-list failure leaves a resumable marker', () async {
      final store = _BarrierStore();
      await _seedProviderDeletion(store.memory);
      final controller = AiSettingsController(store);
      await controller.initialize();
      store.failSaveProvidersAt = store.saveProvidersCalls + 2;

      await expectLater(controller.deleteProvider('p'), throwsA(anything));
      expect(controller.providers, isEmpty);
      expect(
        (await store.readProviderKey('p')).status,
        AiStoreReadStatus.absent,
      );
      expect((await store.loadProviders()).value, hasLength(1));

      final restarted = AiSettingsController(store);
      await restarted.initialize();
      expect((await store.loadProviders()).value, isEmpty);
    });

    test('same id recreation completes interrupted deletion first', () async {
      final store = _BarrierStore();
      await _seedProviderDeletion(store.memory);
      final controller = AiSettingsController(store);
      await controller.initialize();
      store.failNext = 'deleteProviderKey';
      await expectLater(controller.deleteProvider('p'), throwsA(anything));

      final recreated = await controller.saveProvider(
        _provider(baseUrl: 'https://new.example.test/v1'),
      );
      expect(recreated.id, 'p');
      expect(
        (await store.readProviderKey('p')).status,
        AiStoreReadStatus.absent,
      );
      expect(
        (await store.loadAccount('account')).value!.consents,
        isNot(contains('p')),
      );
    });

    test('provider delete and account cleanup cannot revive account', () async {
      final store = _BarrierStore();
      await _seedProviderDeletion(store.memory);
      final controller = AiSettingsController(store);
      await controller.initialize();
      final cleaning = AiAccountMutationCoordinator.forStore(
        store,
      ).beginCleaning('account');

      await controller.deleteProvider('p');
      await cleaning.run(() => store.deleteAccount('account'));

      expect(
        (await store.loadAccount('account')).status,
        AiStoreReadStatus.absent,
      );
    });
  });
}

AiConsentContract _contract() => AiConsentContract(
  providerId: 'p',
  origin: 'https://example.test/v1',
  format: AiFormat.responses,
  cleartext: false,
  toolsEnabled: true,
  toolCatalogueVersion: 1,
  dataCategories: <String>{'diff'},
  policyIdentity: 'custom',
  dataUse: AiDataUse.unknown,
  disclosureVersion: 1,
);

Future<void> _seedProviderDeletion(MemoryAiStore store) async {
  await store.saveProviders(<AiProviderConfig>[
    _provider(baseUrl: 'https://example.test/v1'),
  ]);
  await store.saveProviderKey('p', 'synthetic-secret-value');
  await store.saveAccount(
    'account',
    AiAccountRecord(
      consents: <String, AiConsentRecord>{
        'p': AiConsentRecord(
          hash: _contract().hash,
          summary: const <String, Object?>{'recipient': 'example.test'},
          grantedAt: DateTime.utc(2026, 10, 20),
        ),
      },
    ),
  );
}

AiProviderConfig _provider({required String baseUrl}) => AiProviderConfig(
  id: 'p',
  name: 'Provider',
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
  recipientRevision: 0,
);

final class _BarrierStore implements AiStore {
  final memory = MemoryAiStore();
  Completer<void> accountLoadStarted = Completer<void>();
  Completer<void>? _accountLoadRelease;
  String? failNext;
  int? failSaveProvidersAt;
  int saveProvidersCalls = 0;

  void _fail(String operation) {
    if (failNext != operation) return;
    failNext = null;
    throw StateError('Injected $operation failure');
  }

  void holdNextAccountLoad() {
    accountLoadStarted = Completer<void>();
    _accountLoadRelease = Completer<void>();
  }

  void releaseAccountLoad() => _accountLoadRelease?.complete();

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) async {
    final release = _accountLoadRelease;
    if (release != null) {
      accountLoadStarted.complete();
      await release.future;
      _accountLoadRelease = null;
    }
    return memory.loadAccount(accountKey);
  }

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) {
    _fail('saveAccount');
    return memory.saveAccount(accountKey, account);
  }

  @override
  Future<void> deleteAccount(String accountKey) =>
      memory.deleteAccount(accountKey);
  @override
  Future<List<String>> listAccountKeys() => memory.listAccountKeys();
  @override
  Future<void> clearTombstone(String accountKey) =>
      memory.clearTombstone(accountKey);
  @override
  Future<void> deleteHistoryKey(String accountKey) =>
      memory.deleteHistoryKey(accountKey);
  @override
  Future<void> deleteProviderKey(String providerId) {
    _fail('deleteProviderKey');
    return memory.deleteProviderKey(providerId);
  }

  @override
  Future<List<String>> listTombstones() => memory.listTombstones();
  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      memory.loadProviders();
  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) => memory.readAllProviderKeys(providerIds);
  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) =>
      memory.readHistoryKey(accountKey);
  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      memory.readProviderKey(providerId);
  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      memory.readTombstone(accountKey);
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
  Future<void> saveProviders(List<AiProviderConfig> providers) {
    saveProvidersCalls += 1;
    if (saveProvidersCalls == failSaveProvidersAt) {
      failSaveProvidersAt = null;
      throw StateError('Injected saveProviders failure');
    }
    _fail('saveProviders');
    return memory.saveProviders(providers);
  }

  @override
  Future<void> setTombstone(String accountKey) =>
      memory.setTombstone(accountKey);
  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) =>
      memory.writeHistoryKey(accountKey, key);
}
