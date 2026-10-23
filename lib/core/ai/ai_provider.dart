import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../l10n/l10n.dart';
import 'ai_endpoint.dart';
import 'tools/tool_catalogue_version.dart' show aiToolCatalogueVersion;
import 'tools/write_levels.dart';

export 'tools/write_levels.dart';

export 'tools/tool_catalogue_version.dart' show aiToolCatalogueVersion;

enum AiFormat { chatCompletions, responses, anthropicMessages }

enum AiAuthStyle { bearer, apiKey, xApiKey, none }

enum AiTokenLimitField { maxTokens, maxCompletionTokens, maxOutputTokens }

enum AiDataUse { noTraining, training, unknown }

const aiProductionWriteEscalationRuleIds = <String>{
  'protectedOrDefaultBranch',
  'removeSourceBranch',
  'ciConfigHardLine',
  'pipelineVariables',
  'scheduleParamsUnsafe',
  'visibilityRaised',
  'confidentialityLowered',
  'retryOrPlayConfirmationOnly',
};

AiAutonomyLevel effectiveCeiling({
  required AiAutonomyLevel ceiling,
  required AiAutonomyLevel agreedCeiling,
}) => ceiling.index < agreedCeiling.index ? ceiling : agreedCeiling;

final class AiWritePolicy {
  const AiWritePolicy({
    required this.policyVersion,
    required this.agreedCeiling,
    required this.catalogueVersion,
    required this.operationIds,
    required this.hardLineOperationIds,
    required this.fixedConfirmOperationIds,
    this.escalationRuleIds = const <String>{},
    required this.resetConfirmWindow,
  });

  final int policyVersion;
  final AiAutonomyLevel agreedCeiling;
  final int catalogueVersion;
  final Set<String> operationIds;
  final Set<String> hardLineOperationIds;
  final Set<String> fixedConfirmOperationIds;
  final Set<String> escalationRuleIds;
  final Duration resetConfirmWindow;

  /// Snapshots caller-owned sets before a contract freezes its hash.
  AiWritePolicy copyWith({
    AiAutonomyLevel? agreedCeiling,
    int? catalogueVersion,
  }) {
    final ceiling = agreedCeiling ?? this.agreedCeiling;
    return AiWritePolicy(
      policyVersion: policyVersion,
      agreedCeiling: ceiling,
      catalogueVersion: catalogueVersion ?? this.catalogueVersion,
      operationIds: Set.unmodifiable(
        ceiling == AiAutonomyLevel.readOnly ? <String>{} : operationIds,
      ),
      hardLineOperationIds: Set.unmodifiable(hardLineOperationIds),
      fixedConfirmOperationIds: Set.unmodifiable(fixedConfirmOperationIds),
      escalationRuleIds: Set.unmodifiable(escalationRuleIds),
      resetConfirmWindow: resetConfirmWindow,
    );
  }

  Map<String, Object?> toCanonicalJson() => <String, Object?>{
    'policyVersion': policyVersion,
    'agreedCeiling': agreedCeiling.name,
    'catalogueVersion': catalogueVersion,
    'operationIds':
        (agreedCeiling == AiAutonomyLevel.readOnly
              ? <String>[]
              : operationIds.toList())
          ..sort(),
    'hardLineOperationIds': hardLineOperationIds.toList()..sort(),
    'fixedConfirmOperationIds': fixedConfirmOperationIds.toList()..sort(),
    'escalationRuleIds': escalationRuleIds.toList()..sort(),
    'resetConfirmWindowMicros': resetConfirmWindow.inMicroseconds,
    'levels': <String, Object?>{
      for (final level in AiAutonomyLevel.values)
        level.name: <String, Object?>{
          for (final tier in AiWriteTier.values)
            tier.name: _decision(level, tier),
        },
    },
  };

  static String _decision(AiAutonomyLevel level, AiWriteTier tier) {
    if (level == AiAutonomyLevel.readOnly) return 'deny';
    if (tier == AiWriteTier.hardLine) return 'confirmName';
    if (level == AiAutonomyLevel.bypass) return 'automatic';
    if (tier == AiWriteTier.t4) return 'confirmName';
    if (level == AiAutonomyLevel.conversationGrant ||
        (level == AiAutonomyLevel.lowRiskAuto && tier == AiWriteTier.t1)) {
      return 'automatic';
    }
    return 'confirm';
  }
}

/// Account-wide confirmation period after resetting the write journal (§8).
const aiWriteResetConfirmWindow = Duration(hours: 24);

final class AiCaps {
  const AiCaps({
    required this.tokenLimitField,
    this.streamUsage = false,
    this.toolChoice = false,
    this.replayChatExtras = false,
    this.includeEncryptedReasoning = false,
    this.promptCaching = false,
    this.requiresKey = true,
    this.maxRequestChars = 400000,
    this.maxOutputTokens = 4096,
  });

  final AiTokenLimitField tokenLimitField;
  final bool streamUsage;
  final bool toolChoice;
  final bool replayChatExtras;
  final bool includeEncryptedReasoning;
  final bool promptCaching;
  final bool requiresKey;
  final int maxRequestChars;
  final int maxOutputTokens;

  @override
  bool operator ==(Object other) =>
      other is AiCaps &&
      tokenLimitField == other.tokenLimitField &&
      streamUsage == other.streamUsage &&
      toolChoice == other.toolChoice &&
      replayChatExtras == other.replayChatExtras &&
      includeEncryptedReasoning == other.includeEncryptedReasoning &&
      promptCaching == other.promptCaching &&
      requiresKey == other.requiresKey &&
      maxRequestChars == other.maxRequestChars &&
      maxOutputTokens == other.maxOutputTokens;

  @override
  int get hashCode => Object.hash(
    tokenLimitField,
    streamUsage,
    toolChoice,
    replayChatExtras,
    includeEncryptedReasoning,
    promptCaching,
    requiresKey,
    maxRequestChars,
    maxOutputTokens,
  );
}

final class AiModelPolicy {
  const AiModelPolicy({
    required this.modelId,
    required this.format,
    required this.dataUse,
    required this.retentionDays,
    required this.sourceUrl,
    required this.checkedOn,
  });

  final String modelId;
  final AiFormat format;
  final AiDataUse dataUse;
  final int? retentionDays;
  final String sourceUrl;
  final String checkedOn;

  String get identity => jsonEncode(<String, Object?>{
    'modelId': modelId,
    'format': format.name,
    'dataUse': dataUse.name,
    'retentionDays': retentionDays,
    'sourceUrl': sourceUrl,
    'checkedOn': checkedOn,
  });
}

final class AiPreset {
  AiPreset({
    required this.id,
    String? name,
    required this.defaultFormat,
    required Set<AiFormat> formats,
    required Map<AiFormat, String> baseUrls,
    required this.authStyle,
    required Map<AiFormat, AiCaps> caps,
    this.modelsUrl,
    this.modelSensitive = false,
    this.policyUrl,
    Map<String, AiModelPolicy> modelPolicies = const <String, AiModelPolicy>{},
  }) : _name = name,
       formats = Set.unmodifiable(formats),
       baseUrls = Map.unmodifiable(baseUrls),
       caps = Map.unmodifiable(caps),
       modelPolicies = Map.unmodifiable(modelPolicies) {
    if (!this.formats.contains(defaultFormat)) {
      throw ArgumentError.value(defaultFormat, 'defaultFormat');
    }
    if (!this.formats.every(this.baseUrls.containsKey) ||
        !this.formats.every(this.caps.containsKey)) {
      throw ArgumentError('Every supported format needs a base URL and caps.');
    }
  }

  final String id;
  final String? _name;
  String get name => _name ?? l10n.aiCustomProvider;
  final AiFormat defaultFormat;
  final Set<AiFormat> formats;
  final Map<AiFormat, String> baseUrls;
  final AiAuthStyle authStyle;
  final Map<AiFormat, AiCaps> caps;
  final String? modelsUrl;
  final bool modelSensitive;
  final String? policyUrl;
  final Map<String, AiModelPolicy> modelPolicies;

  String baseUrlFor(AiFormat format) =>
      baseUrls[format] ??
      (throw ArgumentError.value(format, 'format', 'Unsupported format'));

  AiCaps capsFor(AiFormat format) =>
      caps[format] ??
      (throw ArgumentError.value(format, 'format', 'Unsupported format'));

  List<AiModelPolicy> modelsFor(AiFormat format) => List.unmodifiable(
    modelPolicies.values.where((policy) => policy.format == format),
  );

  AiModelPolicy? policyFor(String model) => modelPolicies[model];
}

final class AiProviderConfig {
  const AiProviderConfig({
    required this.id,
    required this.name,
    required this.presetId,
    required this.baseUrl,
    required this.format,
    required this.model,
    required this.authStyle,
    required this.caps,
    required this.allowLanCleartext,
    required this.toolsEnabled,
    required this.recipientRevision,
    this.modelsUrl,
  });

  final String id;
  final String name;
  final String presetId;
  final String baseUrl;
  final String? modelsUrl;
  final AiFormat format;
  final String model;
  final AiAuthStyle authStyle;
  final AiCaps caps;
  final bool allowLanCleartext;
  final bool toolsEnabled;
  final int recipientRevision;
}

final class AiConsentContract {
  AiConsentContract({
    required this.providerId,
    required this.origin,
    required this.format,
    required this.cleartext,
    required this.toolsEnabled,
    required this.toolCatalogueVersion,
    required Set<String> dataCategories,
    required this.policyIdentity,
    required this.dataUse,
    required this.disclosureVersion,
    AiWritePolicy? writePolicy,
    this.routedModel,
    this.policyUrl,
    this.retentionDays,
    this.policyCheckedOn,
  }) : dataCategories = Set.unmodifiable(dataCategories),
       writePolicy = writePolicy?.copyWith(
         agreedCeiling: toolsEnabled
             ? writePolicy.agreedCeiling
             : AiAutonomyLevel.readOnly,
         catalogueVersion: toolCatalogueVersion,
       );

  final String providerId;
  final String origin;
  final AiFormat format;
  final bool cleartext;
  final bool toolsEnabled;
  final int toolCatalogueVersion;
  final Set<String> dataCategories;
  final AiWritePolicy? writePolicy;
  final String policyIdentity;
  final String? routedModel;
  final AiDataUse dataUse;
  final int disclosureVersion;
  final String? policyUrl;
  final int? retentionDays;
  final String? policyCheckedOn;

  late final String hash = sha256
      .convert(
        utf8.encode(
          jsonEncode(
            SplayTreeMap<String, Object?>.of(<String, Object?>{
              'providerId': providerId,
              'origin': origin,
              'format': format.name,
              'cleartext': cleartext,
              'toolsEnabled': toolsEnabled,
              'toolCatalogueVersion': toolCatalogueVersion,
              'dataCategories': dataCategories.toList()..sort(),
              'policyIdentity': policyIdentity,
              'routedModel': routedModel,
              'dataUse': dataUse.name,
              'disclosureVersion': disclosureVersion,
              'writePolicy': writePolicy?.toCanonicalJson(),
            }),
          ),
        ),
      )
      .toString();
}

/// Versions shared by current-contract callers, including settings.
const aiDisclosureVersion = 2;

AiConsentContract aiCurrentConsentContractFor(AiProviderConfig provider) =>
    aiConsentContractFor(provider);

/// Derives the disclosure from the actual recipient and the bundled policy table.
/// Unknown models and custom recipients never inherit a known model's policy.
AiConsentContract aiConsentContractFor(
  AiProviderConfig provider, {
  int toolCatalogueVersion = aiToolCatalogueVersion,
  int disclosureVersion = aiDisclosureVersion,
  Set<String>? dataCategories,
  AiWritePolicy? writePolicy,
}) {
  final preset = AiPresets.all
      .where((candidate) => candidate.id == provider.presetId)
      .firstOrNull;
  final endpoint = AiEndpoint.parse(
    provider.baseUrl,
    allowLanCleartext: provider.allowLanCleartext,
  );
  final presetUrl = preset?.baseUrls[provider.format];
  String? presetOrigin;
  if (presetUrl != null && presetUrl.isNotEmpty && !presetUrl.contains('{')) {
    presetOrigin = AiEndpoint.parse(presetUrl, allowLanCleartext: true).key;
  } else if (presetUrl != null && presetUrl.startsWith('https://{resource}.')) {
    // Substitute exactly one DNS label, then compare the entire
    // endpoint so the fixed host suffix, scheme, port and path must all match.
    final resource = endpoint.base.host.split('.').first;
    if (RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$').hasMatch(resource)) {
      presetOrigin = AiEndpoint.parse(
        presetUrl.replaceFirst('{resource}', resource),
        allowLanCleartext: false,
      ).key;
    }
  }
  final custom =
      preset == null ||
      preset.id == AiPresets.custom.id ||
      endpoint.key != presetOrigin;
  final modelSensitive = custom || preset.modelSensitive;
  final candidate = preset?.policyFor(provider.model);
  final policy = !custom && candidate?.format == provider.format
      ? candidate
      : null;
  final categories = <String>{
    ...?dataCategories,
    if (dataCategories == null) ...{
      'job_log',
      'diff',
      'source',
      'issue_text',
      'comments',
      if (provider.toolsEnabled) 'tool_reads',
    },
  };
  const toolCategories = {'tool_reads', 'write_results', 'attachment_metadata'};
  if (provider.toolsEnabled) {
    categories.addAll({'write_results', 'attachment_metadata'});
  } else {
    categories.removeAll(toolCategories);
  }
  final policyIdentity = custom
      ? 'custom'
      : jsonEncode(<String, Object?>{
          'preset': preset.id,
          if (modelSensitive) 'policy': policy?.identity,
          if (!modelSensitive) 'policyUrl': preset.policyUrl,
        });
  return AiConsentContract(
    providerId: provider.id,
    origin: endpoint.key,
    format: provider.format,
    cleartext: endpoint.cleartext,
    toolsEnabled: provider.toolsEnabled,
    toolCatalogueVersion: toolCatalogueVersion,
    dataCategories: categories,
    writePolicy: writePolicy,
    policyIdentity: policyIdentity,
    routedModel: modelSensitive ? provider.model : null,
    dataUse: policy?.dataUse ?? AiDataUse.unknown,
    disclosureVersion: disclosureVersion,
    policyUrl:
        policy?.sourceUrl ??
        (!custom && !modelSensitive ? preset.policyUrl : null),
    retentionDays: policy?.retentionDays,
    policyCheckedOn: policy?.checkedOn,
  );
}

const _maxTokensCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxTokens,
  replayChatExtras: true,
);
const _responsesCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxOutputTokens,
  toolChoice: true,
  includeEncryptedReasoning: true,
);
const _openAiChatCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxCompletionTokens,
  streamUsage: true,
  toolChoice: true,
);
const _lanCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxTokens,
  requiresKey: false,
);
const _ollamaChatCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxTokens,
  streamUsage: true,
  requiresKey: false,
);
const _anthropicCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxTokens,
  toolChoice: true,
  promptCaching: true,
);
const _proxyResponsesCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxOutputTokens,
  includeEncryptedReasoning: true,
);
const _proxyAnthropicCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxTokens,
);
const _goResponsesCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxOutputTokens,
  toolChoice: true,
  includeEncryptedReasoning: true,
);
const _goAnthropicCaps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxTokens,
  toolChoice: true,
);

final class AiPresets {
  AiPresets._();

  static const openCodePolicySource = 'https://opencode.ai/docs/go/';
  static const openCodeZenPolicySource = 'https://opencode.ai/docs/zen/';
  static const policyCheckedOn = '2026-10-20';

  static const Map<String, AiModelPolicy> _openCodePolicies = {
    'gpt-6-luna': AiModelPolicy(
      modelId: 'gpt-6-luna',
      format: AiFormat.responses,
      dataUse: AiDataUse.noTraining,
      retentionDays: 30,
      sourceUrl: openCodePolicySource,
      checkedOn: policyCheckedOn,
    ),
    'gpt-5.6-luna': AiModelPolicy(
      modelId: 'gpt-5.6-luna',
      format: AiFormat.responses,
      dataUse: AiDataUse.unknown,
      retentionDays: null,
      sourceUrl: openCodePolicySource,
      checkedOn: policyCheckedOn,
    ),
    'grok-4.7': AiModelPolicy(
      modelId: 'grok-4.7',
      format: AiFormat.responses,
      dataUse: AiDataUse.unknown,
      retentionDays: null,
      sourceUrl: openCodePolicySource,
      checkedOn: policyCheckedOn,
    ),
    'muse-spark-1.3-contributor': AiModelPolicy(
      modelId: 'muse-spark-1.3-contributor',
      format: AiFormat.responses,
      dataUse: AiDataUse.training,
      retentionDays: null,
      sourceUrl: openCodePolicySource,
      checkedOn: policyCheckedOn,
    ),
    'glm-5.3-flash': AiModelPolicy(
      modelId: 'glm-5.3-flash',
      format: AiFormat.chatCompletions,
      dataUse: AiDataUse.noTraining,
      retentionDays: 0,
      sourceUrl: openCodePolicySource,
      checkedOn: policyCheckedOn,
    ),
    'deepseek-v4.1-flash': AiModelPolicy(
      modelId: 'deepseek-v4.1-flash',
      format: AiFormat.chatCompletions,
      dataUse: AiDataUse.noTraining,
      retentionDays: 0,
      sourceUrl: openCodePolicySource,
      checkedOn: policyCheckedOn,
    ),
    'claude-haiku-5-5': AiModelPolicy(
      modelId: 'claude-haiku-5-5',
      format: AiFormat.anthropicMessages,
      dataUse: AiDataUse.noTraining,
      retentionDays: 30,
      sourceUrl: openCodePolicySource,
      checkedOn: policyCheckedOn,
    ),
    'qwen3.8-flash': AiModelPolicy(
      modelId: 'qwen3.8-flash',
      format: AiFormat.anthropicMessages,
      dataUse: AiDataUse.noTraining,
      retentionDays: 0,
      sourceUrl: openCodePolicySource,
      checkedOn: policyCheckedOn,
    ),
  };

  static final Map<String, AiModelPolicy> _openCodeZenPolicies =
      Map.unmodifiable(<String, AiModelPolicy>{
        for (final policy in _openCodePolicies.values)
          policy.modelId: AiModelPolicy(
            modelId: policy.modelId,
            format: policy.format,
            dataUse: AiDataUse.unknown,
            retentionDays: null,
            sourceUrl: openCodeZenPolicySource,
            checkedOn: policyCheckedOn,
          ),
      });

  static final openAi = AiPreset(
    id: 'openai',
    policyUrl: 'https://platform.openai.com/docs/guides/your-data',
    name: 'OpenAI',
    defaultFormat: AiFormat.responses,
    formats: const {AiFormat.responses, AiFormat.chatCompletions},
    baseUrls: const {
      AiFormat.responses: 'https://api.openai.com/v1',
      AiFormat.chatCompletions: 'https://api.openai.com/v1',
    },
    authStyle: AiAuthStyle.bearer,
    caps: const {
      AiFormat.responses: _responsesCaps,
      AiFormat.chatCompletions: _openAiChatCaps,
    },
  );

  static final openRouter = AiPreset(
    id: 'openrouter',
    name: 'OpenRouter',
    defaultFormat: AiFormat.chatCompletions,
    formats: const {AiFormat.chatCompletions, AiFormat.responses},
    baseUrls: const {
      AiFormat.chatCompletions: 'https://openrouter.ai/api/v1',
      AiFormat.responses: 'https://openrouter.ai/api/v1',
    },
    authStyle: AiAuthStyle.bearer,
    caps: const {
      AiFormat.chatCompletions: _maxTokensCaps,
      AiFormat.responses: AiCaps(
        tokenLimitField: AiTokenLimitField.maxOutputTokens,
      ),
    },
    modelSensitive: true,
  );

  static final azure = AiPreset(
    id: 'azure-openai',
    policyUrl:
        'https://learn.microsoft.com/en-us/legal/cognitive-services/openai/data-privacy',
    name: 'Azure OpenAI',
    defaultFormat: AiFormat.responses,
    formats: const {AiFormat.responses, AiFormat.chatCompletions},
    baseUrls: const {
      AiFormat.responses: 'https://{resource}.openai.azure.com/openai/v1',
      AiFormat.chatCompletions: 'https://{resource}.openai.azure.com/openai/v1',
    },
    authStyle: AiAuthStyle.apiKey,
    caps: const {
      AiFormat.responses: _responsesCaps,
      AiFormat.chatCompletions: _openAiChatCaps,
    },
  );

  static final gemini = AiPreset(
    id: 'gemini',
    policyUrl: 'https://ai.google.dev/gemini-api/terms',
    name: 'Gemini',
    defaultFormat: AiFormat.chatCompletions,
    formats: const {AiFormat.chatCompletions},
    baseUrls: const {
      AiFormat.chatCompletions:
          'https://generativelanguage.googleapis.com/v1beta/openai',
    },
    authStyle: AiAuthStyle.bearer,
    caps: const {AiFormat.chatCompletions: _maxTokensCaps},
  );

  static final deepSeek = AiPreset(
    id: 'deepseek',
    policyUrl:
        'https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html',
    name: 'DeepSeek',
    defaultFormat: AiFormat.chatCompletions,
    formats: const {AiFormat.chatCompletions},
    baseUrls: const {AiFormat.chatCompletions: 'https://api.deepseek.com'},
    authStyle: AiAuthStyle.bearer,
    caps: const {AiFormat.chatCompletions: _maxTokensCaps},
  );

  static final xAi = AiPreset(
    id: 'xai',
    policyUrl: 'https://x.ai/legal/privacy-policy',
    name: 'xAI',
    defaultFormat: AiFormat.responses,
    formats: const {AiFormat.responses, AiFormat.chatCompletions},
    baseUrls: const {
      AiFormat.responses: 'https://api.x.ai/v1',
      AiFormat.chatCompletions: 'https://api.x.ai/v1',
    },
    authStyle: AiAuthStyle.bearer,
    caps: const {
      AiFormat.responses: _responsesCaps,
      AiFormat.chatCompletions: AiCaps(
        tokenLimitField: AiTokenLimitField.maxTokens,
        toolChoice: true,
        replayChatExtras: true,
      ),
    },
  );

  static final ollama = AiPreset(
    id: 'ollama',
    policyUrl: 'https://ollama.com/privacy',
    name: 'Ollama',
    defaultFormat: AiFormat.chatCompletions,
    formats: const {AiFormat.chatCompletions, AiFormat.responses},
    baseUrls: const {
      AiFormat.chatCompletions: 'http://127.0.0.1:11434/v1',
      AiFormat.responses: 'http://127.0.0.1:11434/v1',
    },
    authStyle: AiAuthStyle.none,
    caps: const {
      AiFormat.chatCompletions: _ollamaChatCaps,
      AiFormat.responses: AiCaps(
        tokenLimitField: AiTokenLimitField.maxOutputTokens,
        requiresKey: false,
      ),
    },
  );

  static final lmStudio = AiPreset(
    id: 'lm-studio',
    policyUrl: 'https://lmstudio.ai/privacy',
    name: 'LM Studio',
    defaultFormat: AiFormat.chatCompletions,
    formats: const {AiFormat.chatCompletions},
    baseUrls: const {AiFormat.chatCompletions: 'http://127.0.0.1:1234/v1'},
    authStyle: AiAuthStyle.none,
    caps: const {AiFormat.chatCompletions: _lanCaps},
  );

  static final anthropic = AiPreset(
    id: 'anthropic',
    policyUrl:
        'https://privacy.claude.com/en/articles/7996868-how-long-do-you-store-my-organization-s-data',
    name: 'Anthropic',
    defaultFormat: AiFormat.anthropicMessages,
    formats: const {AiFormat.anthropicMessages},
    baseUrls: const {
      AiFormat.anthropicMessages: 'https://api.anthropic.com/v1',
    },
    authStyle: AiAuthStyle.bearer,
    caps: const {AiFormat.anthropicMessages: _anthropicCaps},
  );

  static final openCodeGo = _openCode(
    id: 'opencode-go',
    name: 'OpenCode Go',
    route: 'go/',
    modelsUrl: 'https://opencode.ai/inference/go/v1/models',
    modelPolicies: _openCodePolicies,
    chatCaps: const AiCaps(
      tokenLimitField: AiTokenLimitField.maxTokens,
      streamUsage: true,
      replayChatExtras: true,
    ),
    responsesCaps: _goResponsesCaps,
    anthropicCaps: _goAnthropicCaps,
  );

  static final openCodeZen = _openCode(
    id: 'opencode-zen',
    name: 'OpenCode Zen',
    route: '',
    modelsUrl: 'https://opencode.ai/inference/v1/models',
    modelPolicies: _openCodeZenPolicies,
  );

  static AiPreset _openCode({
    required String id,
    required String name,
    required String route,
    required String modelsUrl,
    required Map<String, AiModelPolicy> modelPolicies,
    AiCaps chatCaps = _maxTokensCaps,
    AiCaps responsesCaps = _proxyResponsesCaps,
    AiCaps anthropicCaps = _proxyAnthropicCaps,
  }) => AiPreset(
    id: id,
    name: name,
    defaultFormat: AiFormat.chatCompletions,
    formats: const {
      AiFormat.chatCompletions,
      AiFormat.responses,
      AiFormat.anthropicMessages,
    },
    baseUrls: {
      AiFormat.chatCompletions:
          'https://opencode.ai/inference/${route}openai/v1',
      AiFormat.responses: 'https://opencode.ai/inference/${route}openai/v1',
      AiFormat.anthropicMessages:
          'https://opencode.ai/inference/${route}anthropic/v1',
    },
    authStyle: AiAuthStyle.bearer,
    caps: {
      AiFormat.chatCompletions: chatCaps,
      AiFormat.responses: responsesCaps,
      AiFormat.anthropicMessages: anthropicCaps,
    },
    modelsUrl: modelsUrl,
    modelSensitive: true,
    modelPolicies: modelPolicies,
  );

  static final custom = AiPreset(
    id: 'custom',
    defaultFormat: AiFormat.chatCompletions,
    formats: const {
      AiFormat.chatCompletions,
      AiFormat.responses,
      AiFormat.anthropicMessages,
    },
    baseUrls: const {
      AiFormat.chatCompletions: '',
      AiFormat.responses: '',
      AiFormat.anthropicMessages: '',
    },
    authStyle: AiAuthStyle.bearer,
    caps: const {
      AiFormat.chatCompletions: _maxTokensCaps,
      AiFormat.responses: AiCaps(
        tokenLimitField: AiTokenLimitField.maxOutputTokens,
      ),
      AiFormat.anthropicMessages: _proxyAnthropicCaps,
    },
    modelSensitive: true,
  );

  static final List<AiPreset> all = List.unmodifiable(<AiPreset>[
    openAi,
    openRouter,
    azure,
    gemini,
    deepSeek,
    xAi,
    ollama,
    lmStudio,
    anthropic,
    openCodeGo,
    openCodeZen,
    custom,
  ]);
}
