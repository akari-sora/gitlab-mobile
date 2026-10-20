import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../l10n/l10n.dart';

enum AiFormat { chatCompletions, responses, anthropicMessages }

enum AiAuthStyle { bearer, apiKey, xApiKey, none }

enum AiTokenLimitField { maxTokens, maxCompletionTokens, maxOutputTokens }

enum AiDataUse { noTraining, training, unknown }

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
  });

  final AiTokenLimitField tokenLimitField;
  final bool streamUsage;
  final bool toolChoice;
  final bool replayChatExtras;
  final bool includeEncryptedReasoning;
  final bool promptCaching;
  final bool requiresKey;
  final int maxRequestChars;
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

  String get identity =>
      '$modelId|${format.name}|${dataUse.name}|'
      '${retentionDays ?? 'unknown'}|$sourceUrl|$checkedOn';
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
    this.routedModel,
  }) : dataCategories = Set.unmodifiable(dataCategories);

  final String providerId;
  final String origin;
  final AiFormat format;
  final bool cleartext;
  final bool toolsEnabled;
  final int toolCatalogueVersion;
  final Set<String> dataCategories;
  final String policyIdentity;
  final String? routedModel;
  final AiDataUse dataUse;
  final int disclosureVersion;

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
            }),
          ),
        ),
      )
      .toString();
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
    name: 'DeepSeek',
    defaultFormat: AiFormat.chatCompletions,
    formats: const {AiFormat.chatCompletions},
    baseUrls: const {AiFormat.chatCompletions: 'https://api.deepseek.com'},
    authStyle: AiAuthStyle.bearer,
    caps: const {AiFormat.chatCompletions: _maxTokensCaps},
  );

  static final xAi = AiPreset(
    id: 'xai',
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
    name: 'LM Studio',
    defaultFormat: AiFormat.chatCompletions,
    formats: const {AiFormat.chatCompletions},
    baseUrls: const {AiFormat.chatCompletions: 'http://127.0.0.1:1234/v1'},
    authStyle: AiAuthStyle.none,
    caps: const {AiFormat.chatCompletions: _lanCaps},
  );

  static final anthropic = AiPreset(
    id: 'anthropic',
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
