import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('older caps load with the existing output default', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final store = SecureAiStore(storage);
    await store.saveProviders([
      AiProviderConfig(
        id: 'synthetic',
        name: 'Synthetic',
        presetId: 'openai',
        baseUrl: 'https://example.test/v1',
        format: AiFormat.responses,
        model: 'synthetic-model',
        authStyle: AiAuthStyle.bearer,
        caps: AiPresets.openAi.capsFor(AiFormat.responses),
        allowLanCleartext: false,
        toolsEnabled: true,
        recipientRevision: 1,
      ),
    ]);
    final json =
        jsonDecode(
              (await storage.read(key: SecureAiStore.providersStorageKey))!,
            )
            as Map<String, dynamic>;
    final caps = json['providers'][0]['caps'] as Map<String, dynamic>;
    caps.remove('maxOutputTokens');
    await storage.write(
      key: SecureAiStore.providersStorageKey,
      value: jsonEncode(json),
    );
    final loaded = await store.loadProviders();
    expect(loaded.isFound, isTrue);
    expect(loaded.value!.single.caps.maxOutputTokens, 4096);
  });

  test(
    'explicit 512 output limit reaches the wire and rejects smaller values',
    () {
      final segment = AiSegment(
        providerId: 'synthetic',
        recipientRevision: 1,
        format: AiFormat.responses,
        model: 'synthetic-model',
        secretSetAtStart: SecretSetId.fromSecrets([]),
      );
      final plan = AiRequestPlan(
        model: 'synthetic-model',
        system: 'Synthetic system',
        segment: segment,
      maxOutputTokens: 512,
      allowSmallOutputTokens: true,
      );
      expect(
        const ResponsesFormat().encode(
          plan,
          AiPresets.openAi.capsFor(AiFormat.responses),
        )['max_output_tokens'],
        512,
      );
      expect(
        () => AiRequestPlan(
          model: 'synthetic-model',
          system: 'Synthetic system',
          segment: segment,
        maxOutputTokens: 511,
        allowSmallOutputTokens: true,
        ),
        throwsArgumentError,
      );
    },
  );
}
