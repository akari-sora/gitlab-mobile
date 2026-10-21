import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

AiProviderConfig _provider({bool keyless = false}) => AiProviderConfig(
  id: 'synthetic-provider',
  name: 'Synthetic provider',
  presetId: AiPresets.custom.id,
  baseUrl: 'https://synthetic.example/v1',
  format: AiFormat.responses,
  model: 'synthetic-model',
  authStyle: keyless ? AiAuthStyle.none : AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    requiresKey: !keyless,
  ),
  allowLanCleartext: false,
  toolsEnabled: false,
  recipientRevision: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final operation in <String>[
    'saveProviders',
    'deleteProviderKeyBinding',
  ]) {
    test('FIX4 failed keyless $operation restores a live-only key', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = _FaultStorage();
      final store = SecureAiStore(storage);
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      final existing = await settings.saveProviderWithKey(
        _provider(),
        key: 'synthetic-key-one',
      );
      final providers = settings.providers;
      final keys = settings.knownProviderKeys;
      final secrets = settings.secretSetId;
      final persisted = await storage.read(
        key: SecureAiStore.providersStorageKey,
      );
      await store.deleteProviderKey(existing.id);
      expect(
        (await store.readProviderKey(existing.id)).status,
        AiStoreReadStatus.absent,
      );
      expect(settings.providerKeyFor(existing), 'synthetic-key-one');
      final observedKeys = <Map<String, String>>[];
      final observedSecrets = <int>[];
      settings.addListener(() {
        observedKeys.add(settings.knownProviderKeys);
        observedSecrets.add(settings.secretSetId);
      });
      if (operation == 'saveProviders') {
        storage.failNextWrite = SecureAiStore.providersStorageKey;
      } else {
        storage.failNextDelete = SecureAiStore.providerKeyBindingKey(
          existing.id,
        );
      }

      await expectLater(
        settings.saveProviderWithKey(_provider(keyless: true)),
        throwsA(
          isA<AiStoreException>()
              .having(
                (error) => error.failure.kind,
                'kind',
                AiStoreFailureKind.unavailable,
              )
              .having(
                (error) => error.failure.operation,
                'operation',
                operation,
              ),
        ),
      );

      expect(settings.knownProviderKeys, keys);
      expect(settings.providerKeyFor(existing), 'synthetic-key-one');
      expect(settings.providers, same(providers));
      expect(settings.providers.single.caps.requiresKey, isTrue);
      expect(
        await storage.read(key: SecureAiStore.providersStorageKey),
        persisted,
      );
      expect(
        (await store.readProviderKey(existing.id)).status,
        AiStoreReadStatus.absent,
      );
      expect(settings.secretSetId, secrets + 2);
      expect(observedKeys, <Map<String, String>>[<String, String>{}, keys]);
      expect(observedSecrets, <int>[secrets + 1, secrets + 2]);
    });
  }

  test(
    'FIX3 keyless commit clears a live key whose durable slot is absent',
    () async {
      final store = MemoryAiStore();
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      await settings.saveProviderWithKey(_provider(), key: 'synthetic-key-one');
      expect(settings.knownProviderKeys[_provider().id], 'synthetic-key-one');
      final secrets = settings.secretSetId;
      await store.deleteProviderKey(_provider().id);
      expect((await store.readProviderKey(_provider().id)).isFound, isFalse);

      await settings.saveProviderWithKey(_provider(keyless: true));

      expect(settings.providers.single.caps.requiresKey, isFalse);
      expect(
        (await store.loadProviders()).value!.single.caps.requiresKey,
        isFalse,
      );
      expect(settings.knownProviderKeys, isEmpty);
      expect(settings.secretSetId, secrets + 1);
      expect(
        (await store.readProviderKeyBinding(_provider().id)).isFound,
        isFalse,
      );
      expect((await store.readProviderKey(_provider().id)).isFound, isFalse);
    },
  );
}

final class _FaultStorage extends FlutterSecureStorage {
  String? failNextWrite;
  String? failNextDelete;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failNextWrite) {
      failNextWrite = null;
      throw StateError('synthetic provider-list write failure');
    }
    await super.write(key: key, value: value);
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failNextDelete) {
      failNextDelete = null;
      throw StateError('synthetic binding delete failure');
    }
    await super.delete(key: key);
  }
}
