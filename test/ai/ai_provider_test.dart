import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

void main() {
  group('provider presets', () {
    test('includes every approved preset with conservative local caps', () {
      expect(
        AiPresets.all.map((preset) => preset.id),
        containsAll(<String>[
          'openai',
          'openrouter',
          'azure-openai',
          'gemini',
          'deepseek',
          'xai',
          'ollama',
          'lm-studio',
          'anthropic',
          'opencode-go',
          'opencode-zen',
          'custom',
        ]),
      );
      expect(
        AiPresets.ollama.capsFor(AiFormat.chatCompletions).requiresKey,
        isFalse,
      );
      expect(
        AiPresets.lmStudio.capsFor(AiFormat.chatCompletions).toolChoice,
        isFalse,
      );
      expect(
        AiPresets.custom.capsFor(AiFormat.anthropicMessages).toolChoice,
        isFalse,
      );
      expect(
        AiPresets.xAi.capsFor(AiFormat.chatCompletions).toolChoice,
        isTrue,
      );
    });

    test('OpenCode routes each format and overrides the models URL', () {
      expect(
        AiPresets.openCodeGo.baseUrlFor(AiFormat.responses),
        'https://opencode.ai/inference/go/openai/v1',
      );
      expect(
        AiPresets.openCodeGo.baseUrlFor(AiFormat.anthropicMessages),
        'https://opencode.ai/inference/go/anthropic/v1',
      );
      expect(
        AiPresets.openCodeGo.modelsUrl,
        'https://opencode.ai/inference/go/v1/models',
      );
      expect(
        AiPresets.openCodeZen.modelsUrl,
        'https://opencode.ai/inference/v1/models',
      );
      expect(AiPresets.openCodeGo.modelSensitive, isTrue);
      expect(AiPresets.openCodeZen.modelsFor(AiFormat.responses), isNotEmpty);
      expect(
        AiPresets.openCodeZen.policyFor('gpt-6-luna')!.dataUse,
        AiDataUse.unknown,
      );
      expect(
        AiPresets.openCodeZen.policyFor('gpt-6-luna')!.sourceUrl,
        AiPresets.openCodeZenPolicySource,
      );
    });

    test('dated OpenCode policy table filters models by endpoint format', () {
      final responseModels = AiPresets.openCodeGo
          .modelsFor(AiFormat.responses)
          .map((policy) => policy.modelId);
      final messageModels = AiPresets.openCodeGo
          .modelsFor(AiFormat.anthropicMessages)
          .map((policy) => policy.modelId);

      expect(
        responseModels,
        containsAll(<String>['gpt-6-luna', 'muse-spark-1.3-contributor']),
      );
      expect(
        messageModels,
        containsAll(<String>['claude-haiku-5-5', 'qwen3.8-flash']),
      );
      expect(
        AiPresets.openCodeGo.policyFor('muse-spark-1.3-contributor')!.dataUse,
        AiDataUse.training,
      );
      expect(AiPresets.openCodeGo.policyFor('glm-5.3-flash')!.retentionDays, 0);
      expect(
        AiPresets.openCodeGo.policyFor('gpt-6-luna')!.checkedOn,
        '2026-10-20',
      );
      expect(
        AiPresets.openCodeGo.policyFor('gpt-5.6-luna')!.dataUse,
        AiDataUse.unknown,
      );
    });

    test('custom preset resolves its name from the current language', () {
      addTearDown(() => useLanguage(sourceLanguage));
      useLanguage(languageForTag('en')!);
      final english = AiPresets.custom.name;
      useLanguage(sourceLanguage);

      expect(english, isNot(AiPresets.custom.name));
      expect(AiPresets.custom.name, l10n.aiCustomProvider);
    });
  });

  test('consent hash is canonical and covers model data policy', () {
    AiConsentContract contract({
      required Set<String> categories,
      String? routedModel = 'gpt-6-luna',
      AiDataUse dataUse = AiDataUse.noTraining,
    }) => AiConsentContract(
      providerId: 'provider',
      origin: 'https://opencode.ai/inference/go/openai/v1',
      format: AiFormat.responses,
      cleartext: false,
      toolsEnabled: true,
      toolCatalogueVersion: 1,
      dataCategories: categories,
      policyIdentity: 'opencode-go|gpt-6-luna|2026-10-20',
      routedModel: routedModel,
      dataUse: dataUse,
      disclosureVersion: 1,
    );

    final first = contract(categories: {'source', 'diff'});
    final reordered = contract(categories: {'diff', 'source'});
    final training = contract(
      categories: {'source', 'diff'},
      routedModel: 'muse-spark-1.3-contributor',
      dataUse: AiDataUse.training,
    );
    final toolsDisabled = AiConsentContract(
      providerId: 'provider',
      origin: 'https://opencode.ai/inference/go/openai/v1',
      format: AiFormat.responses,
      cleartext: false,
      toolsEnabled: false,
      toolCatalogueVersion: 1,
      dataCategories: const {'source', 'diff'},
      policyIdentity: 'opencode-go|gpt-6-luna|2026-10-20',
      routedModel: 'gpt-6-luna',
      dataUse: AiDataUse.noTraining,
      disclosureVersion: 1,
    );

    expect(first.hash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(first.hash, reordered.hash);
    expect(first.hash, isNot(training.hash));
    expect(first.hash, isNot(toolsDisabled.hash));
    expect(() => first.dataCategories.add('comments'), throwsUnsupportedError);
  });
}
