import 'package:flutter/material.dart';

import '../../core/ai/ai_endpoint.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/ai_transport.dart';
import '../../core/ai/ai_wire_client.dart';
import '../../core/ai/wire/anthropic_messages.dart';
import '../../core/ai/wire/chat_completions.dart';
import '../../core/ai/wire/responses.dart';
import '../../l10n/l10n.dart';
import '../../shared/workspace_ui.dart';
import 'ai_stores.dart';

typedef AiProviderClientFactory =
    AiWireClient Function(AiProviderConfig config, String apiKey);

/// Full-screen editor for one provider. Existing secrets are deliberately
/// never copied into a text controller or rendered in the widget tree.
final class AiProviderEditor extends StatefulWidget {
  const AiProviderEditor({
    super.key,
    required this.settings,
    this.provider,
    this.clientFactory,
  });

  final AiSettingsController settings;
  final AiProviderConfig? provider;
  final AiProviderClientFactory? clientFactory;

  @override
  State<AiProviderEditor> createState() => _AiProviderEditorState();
}

final class _AiProviderEditorState extends State<AiProviderEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _modelsUrl;
  late final TextEditingController _maxRequestChars;
  late final TextEditingController _maxOutputTokens;
  late AiPreset _preset;
  late AiFormat _format;
  late AiCaps _caps;
  late AiAuthStyle _authStyle;
  late bool _allowLanCleartext;
  late bool _toolsEnabled;
  late bool _customNoKey;
  bool _saving = false;
  bool _loadingModels = false;
  int _networkTicket = 0;
  AiWireClient? _activeClient;
  String? _endpointError;
  String? _modelsMessage;
  List<String> _loadedModels = const <String>[];

  bool get _editing => widget.provider != null;
  bool get _requiresKey =>
      _preset.id == 'custom' ? !_customNoKey : _caps.requiresKey;

  @override
  void initState() {
    super.initState();
    final provider = widget.provider;
    _preset = AiPresets.all.firstWhere(
      (candidate) => candidate.id == provider?.presetId,
      orElse: () => AiPresets.custom,
    );
    _format = provider?.format ?? _preset.defaultFormat;
    _caps = provider?.caps ?? _preset.capsFor(_format);
    _authStyle = provider?.authStyle ?? _preset.authStyle;
    _allowLanCleartext = provider?.allowLanCleartext ?? false;
    _toolsEnabled = provider?.toolsEnabled ?? false;
    _customNoKey = _preset.id == 'custom' && !_caps.requiresKey;
    _name = TextEditingController(text: provider?.name ?? _preset.name);
    _baseUrl = TextEditingController(
      text: provider?.baseUrl ?? _preset.baseUrlFor(_format),
    )..addListener(_networkInputChanged);
    _apiKey = TextEditingController()..addListener(_networkInputChanged);
    _model = TextEditingController(text: provider?.model ?? '')
      ..addListener(_modelChanged);
    _modelsUrl = TextEditingController(
      text: provider?.modelsUrl ?? _preset.modelsUrl ?? '',
    )..addListener(_networkInputChanged);
    _maxRequestChars = TextEditingController(
      text: _caps.maxRequestChars.toString(),
    );
    _maxOutputTokens = TextEditingController(
      text: _caps.maxOutputTokens.toString(),
    );
    _validateEndpoint();
  }

  @override
  void dispose() {
    _networkTicket += 1;
    _activeClient?.transport.close();
    _activeClient = null;
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _modelsUrl.dispose();
    _maxRequestChars.dispose();
    _maxOutputTokens.dispose();
    super.dispose();
  }

  void _modelChanged() {
    if (mounted) setState(() {});
  }

  void _networkInputChanged() {
    _invalidateNetworkRequest();
    _validateEndpoint();
  }

  void _invalidateNetworkRequest() {
    _networkTicket += 1;
    final client = _activeClient;
    _activeClient = null;
    client?.transport.close();
    if (_loadingModels) {
      setState(() => _loadingModels = false);
    }
  }

  void _validateEndpoint() {
    String? error;
    try {
      AiEndpoint.parse(
        _baseUrl.text,
        allowLanCleartext: _allowLanCleartext,
        modelsUrlOverride: _modelsUrl.text,
      );
    } on Object {
      error = l10n.aiProviderBaseUrlInvalid;
    }
    if (mounted && error != _endpointError) {
      setState(() => _endpointError = error);
    } else {
      _endpointError = error;
    }
  }

  void _selectPreset(AiPreset preset) {
    _networkTicket += 1;
    setState(() {
      _preset = preset;
      _format = preset.defaultFormat;
      _caps = preset.capsFor(_format);
      _authStyle = preset.authStyle;
      _customNoKey = false;
      _name.text = preset.name;
      _baseUrl.text = preset.baseUrlFor(_format);
      _modelsUrl.text = preset.modelsUrl ?? '';
      _maxRequestChars.text = _caps.maxRequestChars.toString();
      _maxOutputTokens.text = _caps.maxOutputTokens.toString();
      _loadedModels = const <String>[];
      _modelsMessage = null;
    });
    _validateEndpoint();
  }

  void _selectFormat(AiFormat format) {
    _networkTicket += 1;
    setState(() {
      _format = format;
      _caps = _preset.capsFor(format);
      _authStyle = _preset.authStyle;
      _baseUrl.text = _preset.baseUrlFor(format);
      _maxRequestChars.text = _caps.maxRequestChars.toString();
      _maxOutputTokens.text = _caps.maxOutputTokens.toString();
      _loadedModels = const <String>[];
      _modelsMessage = null;
    });
    _validateEndpoint();
  }

  AiCaps _effectiveCaps() => AiCaps(
    tokenLimitField: _caps.tokenLimitField,
    streamUsage: _caps.streamUsage,
    toolChoice: _caps.toolChoice,
    replayChatExtras: _caps.replayChatExtras,
    includeEncryptedReasoning: _caps.includeEncryptedReasoning,
    promptCaching: _caps.promptCaching,
    requiresKey: _requiresKey,
    maxRequestChars:
        int.tryParse(_maxRequestChars.text) ?? _caps.maxRequestChars,
    maxOutputTokens:
        int.tryParse(_maxOutputTokens.text) ?? _caps.maxOutputTokens,
  );

  AiProviderConfig _config({AiAuthStyle? authStyle}) => AiProviderConfig(
    id:
        widget.provider?.id ??
        'ai-provider-${DateTime.now().microsecondsSinceEpoch}',
    name: _name.text.trim(),
    presetId: _preset.id,
    baseUrl: _baseUrl.text.trim(),
    modelsUrl: _modelsUrl.text.trim().isEmpty ? null : _modelsUrl.text.trim(),
    format: _format,
    model: _model.text.trim(),
    authStyle: authStyle ?? (_requiresKey ? _authStyle : AiAuthStyle.none),
    caps: _effectiveCaps(),
    allowLanCleartext: _allowLanCleartext,
    toolsEnabled: _toolsEnabled,
    recipientRevision: widget.provider?.recipientRevision ?? 0,
  );

  String? _validatedKey() {
    final key = _apiKey.text.trim();
    if (key.isEmpty && _editing) return null;
    if (RegExp(r'[\s\x00-\x1f\x7f-\x9f]').hasMatch(key)) {
      throw const _KeyValidationException(_KeyProblem.whitespace);
    }
    if (!assessAiProviderKey(key).accepted) {
      throw const _KeyValidationException(_KeyProblem.tooShort);
    }
    return key;
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    _validateEndpoint();
    if (_endpointError != null) return;
    String? key;
    if (_requiresKey) {
      try {
        key = _validatedKey();
      } on _KeyValidationException catch (error) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.problem == _KeyProblem.whitespace
                  ? l10n.aiProviderKeyWhitespace
                  : l10n.aiProviderKeyMinimum,
            ),
          ),
        );
        return;
      }
      if (key != null && assessAiProviderKey(key).warning != null) {
        final confirmed = await confirmAction(
          context,
          l10n.aiProviderKeyWarningTitle,
          l10n.aiProviderKeyWarningDetail,
        );
        if (!confirmed || !mounted) return;
      }
    }
    setState(() => _saving = true);
    try {
      final saved = await widget.settings.saveProvider(_config());
      if (key != null) {
        await widget.settings.saveProviderKey(
          saved.id,
          key,
          acknowledgeWarning: true,
        );
      }
      if (mounted) Navigator.of(context).pop(saved);
    } on Object catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _readModels() async {
    if (_loadingModels) return;
    _validateEndpoint();
    if (_endpointError != null) return;
    final publicCatalog = _preset.id == 'openrouter';
    String key = '';
    if (_requiresKey && !publicCatalog) {
      try {
        key =
            _validatedKey() ??
            widget.settings.knownProviderKeys[widget.provider?.id] ??
            '';
      } on _KeyValidationException catch (error) {
        setState(() {
          _modelsMessage = error.problem == _KeyProblem.whitespace
              ? l10n.aiProviderKeyWhitespace
              : l10n.aiProviderKeyMinimum;
        });
        return;
      }
      if (!assessAiProviderKey(key).accepted) {
        setState(() => _modelsMessage = l10n.aiProviderKeyMinimum);
        return;
      }
    }
    setState(() {
      _loadingModels = true;
      _modelsMessage = null;
    });
    final ticket = ++_networkTicket;
    AiWireClient? client;
    try {
      final config = _config(
        authStyle: publicCatalog ? AiAuthStyle.none : null,
      );
      client = (widget.clientFactory ?? _defaultClientFactory)(config, key);
      _activeClient = client;
      final page = await client.listModels();
      if (!mounted || ticket != _networkTicket) return;
      final allowed = _preset.modelPolicies.isEmpty
          ? page.models.map((model) => model.id)
          : page.models
                .map((model) => model.id)
                .where((id) => _preset.modelPolicies[id]?.format == _format);
      setState(() {
        _loadedModels = allowed.toSet().toList()..sort();
        _modelsMessage = page.hasMore
            ? l10n.aiProviderModelsTruncated
            : l10n.aiProviderModelsReadSuccess;
      });
    } on Object {
      if (mounted && ticket == _networkTicket) {
        setState(() => _modelsMessage = l10n.aiProviderModelsReadFailure);
      }
    } finally {
      client?.transport.close();
      final wasActive = identical(_activeClient, client);
      if (wasActive) _activeClient = null;
      if (mounted && wasActive) {
        setState(() => _loadingModels = false);
      }
    }
  }

  Future<void> _verifyOpenRouterKey() async {
    if (_loadingModels || _preset.id != 'openrouter') return;
    _validateEndpoint();
    if (_endpointError != null) return;
    String key;
    try {
      key =
          _validatedKey() ??
          widget.settings.knownProviderKeys[widget.provider?.id] ??
          '';
    } on _KeyValidationException catch (error) {
      setState(() {
        _modelsMessage = error.problem == _KeyProblem.whitespace
            ? l10n.aiProviderKeyWhitespace
            : l10n.aiProviderKeyMinimum;
      });
      return;
    }
    if (!assessAiProviderKey(key).accepted) {
      setState(() => _modelsMessage = l10n.aiProviderKeyMinimum);
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelsMessage = null;
    });
    final ticket = ++_networkTicket;
    AiWireClient? client;
    try {
      client = (widget.clientFactory ?? _defaultClientFactory)(_config(), key);
      _activeClient = client;
      await client.checkOpenRouterKey();
      if (!mounted || ticket != _networkTicket) return;
      setState(() => _modelsMessage = l10n.aiProviderKeyVerified);
    } on Object {
      if (mounted && ticket == _networkTicket) {
        setState(() => _modelsMessage = l10n.aiProviderModelsReadFailure);
      }
    } finally {
      client?.transport.close();
      final wasActive = identical(_activeClient, client);
      if (wasActive) _activeClient = null;
      if (mounted && wasActive) {
        setState(() => _loadingModels = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final endpoint = _parsedEndpoint;
    final policy = _preset.policyFor(_model.text.trim());
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _editing
              ? l10n.aiProviderEditorEditTitle
              : l10n.aiProviderEditorAddTitle,
        ),
        leading: IconButton(
          tooltip: l10n.cancelAction,
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(l10n.saveAction),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              DropdownButtonFormField<AiPreset>(
                key: const ValueKey('ai-provider-preset'),
                isExpanded: true,
                initialValue: _preset,
                decoration: InputDecoration(
                  labelText: l10n.aiProviderPresetLabel,
                ),
                items: [
                  for (final preset in AiPresets.all)
                    DropdownMenuItem(
                      value: preset,
                      child: Text(isolated(preset.name)),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (preset) {
                        if (preset != null) _selectPreset(preset);
                      },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('ai-provider-name'),
                controller: _name,
                decoration: InputDecoration(labelText: l10n.nameLabel),
                validator: (value) => value == null || value.trim().isEmpty
                    ? l10n.aiProviderNameRequired
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AiFormat>(
                key: const ValueKey('ai-provider-format'),
                isExpanded: true,
                initialValue: _format,
                decoration: InputDecoration(
                  labelText: l10n.aiProviderFormatLabel,
                ),
                items: [
                  for (final format in _preset.formats)
                    DropdownMenuItem(
                      value: format,
                      child: Text(_formatLabel(format)),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (format) {
                        if (format != null) _selectFormat(format);
                      },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('ai-provider-base-url'),
                controller: _baseUrl,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: l10n.aiProviderBaseUrlLabel,
                  errorText: _endpointError,
                ),
              ),
              SwitchListTile(
                key: const ValueKey('ai-provider-cleartext'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.aiProviderCleartextOptIn),
                subtitle: endpoint?.cleartext == true
                    ? Text(
                        l10n.aiProviderCleartextWarning,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      )
                    : null,
                value: _allowLanCleartext,
                onChanged: _saving
                    ? null
                    : (value) {
                        _invalidateNetworkRequest();
                        setState(() => _allowLanCleartext = value);
                        _validateEndpoint();
                      },
              ),
              if (_preset.id == 'custom')
                SwitchListTile(
                  key: const ValueKey('ai-provider-no-key'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.aiProviderNoKeyNeeded),
                  value: _customNoKey,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _customNoKey = value),
                ),
              if (_requiresKey) ...[
                const SizedBox(height: 4),
                TextFormField(
                  key: const ValueKey('ai-provider-api-key'),
                  controller: _apiKey,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l10n.aiProviderApiKeyLabel,
                    helperText: _editing
                        ? l10n.aiProviderApiKeyReplaceHint
                        : l10n.aiProviderApiKeyNewHint,
                  ),
                  validator: (value) {
                    if (_editing && (value == null || value.isEmpty)) {
                      return null;
                    }
                    final key = (value ?? '').trim();
                    if (RegExp(r'[\s\x00-\x1f\x7f-\x9f]').hasMatch(key)) {
                      return l10n.aiProviderKeyWhitespace;
                    }
                    return assessAiProviderKey(key).accepted
                        ? null
                        : l10n.aiProviderKeyMinimum;
                  },
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('ai-provider-model'),
                controller: _model,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.aiProviderModelLabel,
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? l10n.aiProviderModelRequired
                    : null,
              ),
              if (policy != null) _PolicyNotice(policy: policy),
              if (_preset.modelSensitive && policy == null)
                _WarningText(l10n.aiProviderModelPolicyUnknown),
              if (_verificationLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_verificationLabel!),
                ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('ai-provider-models-url'),
                controller: _modelsUrl,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: l10n.aiProviderModelsUrlLabel,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  key: const ValueKey('ai-provider-read-models'),
                  onPressed: _loadingModels ? null : _readModels,
                  icon: _loadingModels
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_outlined),
                  label: Text(l10n.aiProviderReadModels),
                ),
              ),
              if (_preset.id == 'openrouter')
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    key: const ValueKey('ai-provider-verify-key'),
                    onPressed: _loadingModels ? null : _verifyOpenRouterKey,
                    icon: const Icon(Icons.key_outlined),
                    label: Text(l10n.aiProviderVerifyKey),
                  ),
                ),
              if (_modelsMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_modelsMessage!),
                ),
              if (_loadedModels.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final model in _loadedModels)
                        ActionChip(
                          label: Text(isolated(model)),
                          onPressed: () => _model.text = model,
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              ExpansionTile(
                key: const ValueKey('ai-provider-advanced'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(l10n.aiProviderAdvancedTitle),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.aiProviderToolsEnabled),
                    value: _toolsEnabled,
                    onChanged: (value) => setState(() => _toolsEnabled = value),
                  ),
                  if (_requiresKey)
                    DropdownButtonFormField<AiAuthStyle>(
                      key: const ValueKey('ai-provider-auth-style'),
                      isExpanded: true,
                      initialValue: _authStyle,
                      decoration: InputDecoration(
                        labelText: l10n.aiProviderAuthStyleLabel,
                      ),
                      items: [
                        for (final style in const <AiAuthStyle>[
                          AiAuthStyle.bearer,
                          AiAuthStyle.apiKey,
                          AiAuthStyle.xApiKey,
                        ])
                          DropdownMenuItem(
                            value: style,
                            child: Text(_authStyleLabel(style)),
                          ),
                      ],
                      onChanged: (style) {
                        if (style != null) {
                          setState(() => _authStyle = style);
                        }
                      },
                    ),
                  _capSwitch(
                    l10n.aiProviderToolChoiceCapability,
                    _caps.toolChoice,
                    (value) => _copyCaps(toolChoice: value),
                  ),
                  _capSwitch(
                    l10n.aiProviderStreamUsageCapability,
                    _caps.streamUsage,
                    (value) => _copyCaps(streamUsage: value),
                  ),
                  _capSwitch(
                    l10n.aiProviderReplayExtrasCapability,
                    _caps.replayChatExtras,
                    (value) => _copyCaps(replayChatExtras: value),
                  ),
                  _capSwitch(
                    l10n.aiProviderEncryptedReasoningCapability,
                    _caps.includeEncryptedReasoning,
                    (value) => _copyCaps(includeEncryptedReasoning: value),
                  ),
                  _capSwitch(
                    l10n.aiProviderPromptCachingCapability,
                    _caps.promptCaching,
                    (value) => _copyCaps(promptCaching: value),
                  ),
                  TextFormField(
                    key: const ValueKey('ai-provider-request-limit'),
                    controller: _maxRequestChars,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.aiProviderMaxRequestCharsLabel,
                    ),
                    validator: (value) {
                      final parsed = int.tryParse(value ?? '');
                      return parsed == null || parsed <= 0
                          ? l10n.aiProviderBaseUrlInvalid
                          : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('ai-provider-output-limit'),
                    controller: _maxOutputTokens,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.aiProviderMaxOutputTokensLabel,
                    ),
                    validator: (value) {
                      final parsed = int.tryParse(value ?? '');
                      return parsed == null || parsed < 512 || parsed > 65536
                          ? l10n.aiProviderMaxOutputTokensLabel
                          : null;
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  AiEndpoint? get _parsedEndpoint {
    try {
      return AiEndpoint.parse(
        _baseUrl.text,
        allowLanCleartext: _allowLanCleartext,
        modelsUrlOverride: _modelsUrl.text,
      );
    } on Object {
      return null;
    }
  }

  String _formatLabel(AiFormat format) => switch (format) {
    AiFormat.chatCompletions => l10n.aiProviderFormatChat,
    AiFormat.responses => l10n.aiProviderFormatResponses,
    AiFormat.anthropicMessages => l10n.aiProviderFormatAnthropic,
  };

  String _authStyleLabel(AiAuthStyle style) => switch (style) {
    AiAuthStyle.bearer => l10n.aiProviderAuthBearer,
    AiAuthStyle.apiKey => l10n.aiProviderAuthApiKey,
    AiAuthStyle.xApiKey => l10n.aiProviderAuthXApiKey,
    AiAuthStyle.none => l10n.aiProviderNoKeyNeeded,
  };

  String? get _verificationLabel {
    // The retained fixture evidence does not establish a complete live
    // format-by-model pass. Promote a combination only when the verification
    // ledger gains an explicit full-pass row.
    return l10n.aiProviderUnverifiedLabel;
  }

  Widget _capSwitch(String title, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        value: value,
        onChanged: onChanged,
      );

  void _copyCaps({
    bool? streamUsage,
    bool? toolChoice,
    bool? replayChatExtras,
    bool? includeEncryptedReasoning,
    bool? promptCaching,
  }) {
    setState(() {
      _caps = AiCaps(
        tokenLimitField: _caps.tokenLimitField,
        streamUsage: streamUsage ?? _caps.streamUsage,
        toolChoice: toolChoice ?? _caps.toolChoice,
        replayChatExtras: replayChatExtras ?? _caps.replayChatExtras,
        includeEncryptedReasoning:
            includeEncryptedReasoning ?? _caps.includeEncryptedReasoning,
        promptCaching: promptCaching ?? _caps.promptCaching,
        requiresKey: _caps.requiresKey,
        maxRequestChars: _caps.maxRequestChars,
        maxOutputTokens: _caps.maxOutputTokens,
      );
    });
  }
}

final class _WarningText extends StatelessWidget {
  const _WarningText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.warning_amber_rounded,
          size: 20,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

final class _PolicyNotice extends StatelessWidget {
  const _PolicyNotice({required this.policy});

  final AiModelPolicy policy;

  @override
  Widget build(BuildContext context) {
    final text = switch ((policy.dataUse, policy.retentionDays)) {
      (AiDataUse.training, _) => l10n.aiProviderModelTrainingWarning,
      (AiDataUse.noTraining, 0) => l10n.aiProviderModelZeroRetention,
      (AiDataUse.noTraining, 30) => l10n.aiProviderModelThirtyDayRetention,
      _ => l10n.aiProviderModelPolicyUnknown,
    };
    return policy.dataUse == AiDataUse.training
        ? _WarningText(text)
        : Padding(padding: const EdgeInsets.only(top: 8), child: Text(text));
  }
}

enum _KeyProblem { tooShort, whitespace }

final class _KeyValidationException implements Exception {
  const _KeyValidationException(this.problem);

  final _KeyProblem problem;
}

AiWireClient _defaultClientFactory(AiProviderConfig config, String apiKey) {
  final endpoint = AiEndpoint.parse(
    config.baseUrl,
    allowLanCleartext: config.allowLanCleartext,
    modelsUrlOverride: config.modelsUrl,
    allowKeyEndpoint: config.presetId == 'openrouter',
  );
  final wire = switch (config.format) {
    AiFormat.chatCompletions => const ChatCompletionsFormat(),
    AiFormat.responses => const ResponsesFormat(),
    AiFormat.anthropicMessages => const AnthropicMessagesFormat(),
  };
  return AiWireClient(
    transport: AiTransport(
      endpoint: endpoint,
      apiKey: apiKey,
      authStyle: config.authStyle,
    ),
    wire: wire,
    config: config,
    conversationId: 'provider-editor',
    appVersion: '0.6.0',
  );
}
