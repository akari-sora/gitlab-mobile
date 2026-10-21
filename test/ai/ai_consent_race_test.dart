import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

void main() {
  test(
    'a provider mutation queued before consent rejects the stale grant',
    () async {
      final store = _DelayedAiStore();
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);

      await settings.saveProvider(_provider());
      final staleRevision = settings.providers.single.recipientRevision;
      store.delayNextProviderSave();
      final providerSave = settings.saveProvider(
        _provider(baseUrl: 'https://changed.example.test/v1'),
      );
      await store.providerSaveStarted;

      final staleGrant = settings.grantConsent(
        _accountKey,
        _contract(),
        const <String, Object?>{'recipient': 'old'},
      );
      store.releaseProviderSave();
      await providerSave;

      expect(settings.providers.single.recipientRevision, staleRevision + 1);
      await expectLater(
        staleGrant,
        throwsA(
          isA<AiStoreException>()
              .having(
                (error) => error.failure.kind,
                'kind',
                AiStoreFailureKind.invalidValue,
              )
              .having(
                (error) => error.failure.operation,
                'operation',
                'recipientChanged',
              ),
        ),
      );

      final grantedAt = DateTime.utc(2026, 10, 21, 12);
      await settings.grantConsent(
        _accountKey,
        _contract(),
        const <String, Object?>{'recipient': 'new'},
        grantedAt: grantedAt,
      );
      final stored = (await store.loadAccount(_accountKey)).value!;
      expect(stored.consents[_providerId]?.grantedAt, grantedAt);
      expect(stored.consents[_providerId]?.summary, <String, Object?>{
        'recipient': 'new',
      });
    },
  );

  test(
    'a conditional stale revoke preserves a subsequently renewed grant',
    () async {
      final store = _DelayedAiStore();
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);

      await settings.saveProvider(_provider());
      final contract = _contract();
      final oldGrantedAt = DateTime.utc(2026, 10, 21, 10);
      await settings.grantConsent(
        _accountKey,
        contract,
        const <String, Object?>{'grant': 'old'},
        grantedAt: oldGrantedAt,
      );
      final oldRecord = (await store.loadAccount(
        _accountKey,
      )).value!.consents[_providerId]!;

      final freshGrantedAt = DateTime.utc(2026, 10, 21, 11);
      final freshGrant = settings.grantConsent(
        _accountKey,
        contract,
        const <String, Object?>{'grant': 'fresh'},
        grantedAt: freshGrantedAt,
      );
      final staleRevoke = settings.revokeConsent(
        _accountKey,
        _providerId,
        onlyIf: oldRecord,
      );
      await freshGrant;
      await staleRevoke;

      final stored = (await store.loadAccount(_accountKey)).value!;
      expect(stored.consents[_providerId]?.hash, contract.hash);
      expect(stored.consents[_providerId]?.grantedAt, freshGrantedAt);
      expect(stored.consents[_providerId]?.summary, <String, Object?>{
        'grant': 'fresh',
      });
    },
  );
}

const _accountKey = 'https://gitlab.example.test|42';
const _providerId = 'synthetic-provider';

AiProviderConfig _provider({
  String baseUrl = 'https://provider.example.test/v1',
}) => AiProviderConfig(
  id: _providerId,
  name: 'Synthetic provider',
  presetId: 'custom',
  baseUrl: baseUrl,
  format: AiFormat.responses,
  model: 'synthetic-model',
  authStyle: AiAuthStyle.bearer,
  caps: const AiCaps(tokenLimitField: AiTokenLimitField.maxOutputTokens),
  allowLanCleartext: false,
  toolsEnabled: false,
  recipientRevision: 0,
);

AiConsentContract _contract() => AiConsentContract(
  providerId: _providerId,
  origin: 'https://provider.example.test',
  format: AiFormat.responses,
  cleartext: false,
  toolsEnabled: false,
  toolCatalogueVersion: 1,
  dataCategories: const <String>{'synthetic_repository_metadata'},
  policyIdentity: 'synthetic-policy-v1',
  dataUse: AiDataUse.unknown,
  disclosureVersion: 1,
);

final class _DelayedAiStore implements AiStore {
  final MemoryAiStore _delegate = MemoryAiStore();
  var _delayProviderSave = false;
  var _providerSaveStarted = Completer<void>();
  var _providerSaveRelease = Completer<void>();

  Future<void> get providerSaveStarted => _providerSaveStarted.future;

  void delayNextProviderSave() {
    _delayProviderSave = true;
    _providerSaveStarted = Completer<void>();
    _providerSaveRelease = Completer<void>();
  }

  void releaseProviderSave() => _providerSaveRelease.complete();

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      _delegate.loadProviders();

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) async {
    if (_delayProviderSave) {
      _delayProviderSave = false;
      _providerSaveStarted.complete();
      await _providerSaveRelease.future;
    }
    await _delegate.saveProviders(providers);
  }

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      _delegate.readProviderKey(providerId);

  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) => _delegate.readAllProviderKeys(providerIds);

  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) => _delegate.saveProviderKey(
    providerId,
    key,
    acknowledgeWarning: acknowledgeWarning,
  );

  @override
  Future<void> deleteProviderKey(String providerId) =>
      _delegate.deleteProviderKey(providerId);

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) =>
      _delegate.loadAccount(accountKey);

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) =>
      _delegate.saveAccount(accountKey, account);

  @override
  Future<List<String>> listAccountKeys() => _delegate.listAccountKeys();

  @override
  Future<void> deleteAccount(String accountKey) =>
      _delegate.deleteAccount(accountKey);

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) =>
      _delegate.readHistoryKey(accountKey);

  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) =>
      _delegate.writeHistoryKey(accountKey, key);

  @override
  Future<void> deleteHistoryKey(String accountKey) =>
      _delegate.deleteHistoryKey(accountKey);

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      _delegate.readTombstone(accountKey);

  @override
  Future<void> setTombstone(String accountKey) =>
      _delegate.setTombstone(accountKey);

  @override
  Future<List<String>> listTombstones() => _delegate.listTombstones();

  @override
  Future<void> clearTombstone(String accountKey) =>
      _delegate.clearTombstone(accountKey);
}
