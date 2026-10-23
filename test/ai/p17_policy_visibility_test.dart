import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/prompts.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';

AiProviderConfig _provider() => const AiProviderConfig(
  id: 'p17',
  name: 'P17 synthetic',
  presetId: 'custom',
  baseUrl: 'https://p17.example.test/v1',
  format: AiFormat.responses,
  model: 'synthetic',
  authStyle: AiAuthStyle.none,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    requiresKey: false,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

AiWritePolicy _policy({
  int policyVersion = 2,
  int catalogueVersion = aiToolCatalogueVersion,
  Set<String> escalationRuleIds = aiProductionWriteEscalationRuleIds,
}) => AiWritePolicy(
  policyVersion: policyVersion,
  agreedCeiling: AiAutonomyLevel.bypass,
  catalogueVersion: catalogueVersion,
  operationIds: const <String>{'mergeRequest', 'createPipeline'},
  hardLineOperationIds: const <String>{'createPipeline'},
  fixedConfirmOperationIds: const <String>{'markAllTodosDone'},
  escalationRuleIds: escalationRuleIds,
  resetConfirmWindow: aiWriteResetConfirmWindow,
);

void main() {
  test('production policy uses v2 with the complete current catalogue', () {
    final policy = aiProductionWritePolicy(AiAutonomyLevel.bypass);
    expect(policy.policyVersion, 2);
    expect(policy.catalogueVersion, aiToolCatalogueVersion);
    expect(policy.escalationRuleIds, aiProductionWriteEscalationRuleIds);
    expect(policy.operationIds, {
      for (final row in productionAiLedger.modelVisible) row.operationId,
    });
    expect(
      aiMr6b1WritePolicy(AiAutonomyLevel.bypass).toCanonicalJson(),
      policy.toCanonicalJson(),
    );
  });

  test('policy v2 canonical JSON includes every prescribed escalation rule', () {
    final json = _policy().toCanonicalJson();
    expect(json['escalationRuleIds'], <String>[
      'ciConfigHardLine',
      'confidentialityLowered',
      'pipelineVariables',
      'protectedOrDefaultBranch',
      'removeSourceBranch',
      'retryOrPlayConfirmationOnly',
      'scheduleParamsUnsafe',
      'visibilityRaised',
    ]);
  });

  test(
    'policy version, catalogue version and escalation rules change consent',
    () {
      String hash(AiWritePolicy policy, {int? catalogueVersion}) =>
          aiConsentContractFor(
            _provider(),
            toolCatalogueVersion:
                catalogueVersion ?? aiToolCatalogueVersion,
            writePolicy: policy,
          ).hash;
      final current = hash(_policy());
      expect(hash(_policy(policyVersion: 1)), isNot(current));
      expect(
        hash(
          _policy(catalogueVersion: aiToolCatalogueVersion - 1),
          catalogueVersion: aiToolCatalogueVersion - 1,
        ),
        isNot(current),
      );
      expect(
        hash(_policy(escalationRuleIds: const <String>{'visibilityRaised'})),
        isNot(current),
      );
    },
  );

  test('copyWith snapshots and preserves escalation rules', () {
    final rules = <String>{'visibilityRaised'};
    final copied = _policy(escalationRuleIds: rules).copyWith();
    rules.add('pipelineVariables');
    expect(copied.escalationRuleIds, const <String>{'visibilityRaised'});
    expect(
      () => copied.escalationRuleIds.add('pipelineVariables'),
      throwsUnsupportedError,
    );
  });

  test('write prompt states the MR6b-2 model constraints', () {
    final prompt = aiWriteSystemPrompt.replaceAll('\n', ' ');
    expect(prompt, contains('exact fragment replacements only'));
    expect(
      prompt,
      contains("checks the merge request's existing changes"),
    );
    expect(
      prompt,
      contains('the app cannot determine those side effects'),
    );
  });
}
