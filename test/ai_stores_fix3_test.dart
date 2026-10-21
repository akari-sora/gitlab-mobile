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
