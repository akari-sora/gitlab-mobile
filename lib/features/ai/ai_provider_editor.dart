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
import 'ai_settings_failure.dart';
import 'ai_stores.dart';

typedef AiProviderClientFactory =
    AiWireClient Function(AiProviderConfig config, String apiKey);

typedef _EditorSnapshot = ({
  String presetId,
  AiFormat format,
  String name,
  String baseUrl,
  String apiKey,
  String model,
  String modelsUrl,
  String maxRequestChars,
  String maxOutputTokens,
  AiAuthStyle authStyle,
  AiTokenLimitField tokenLimitField,
  bool allowLanCleartext,
  bool toolsEnabled,
  bool customNoKey,
  bool streamUsage,
  bool toolChoice,
  bool replayChatExtras,
  bool includeEncryptedReasoning,
  bool promptCaching,
});

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
  late final TextEditingController _modelSearch;
  late final ExpansibleController _advancedController;
  late final String _providerId;
  late final _EditorSnapshot _initialSnapshot;
  late AiPreset _preset;
  late AiFormat _format;
  late AiCaps _caps;
  late AiAuthStyle _authStyle;
  late bool _allowLanCleartext;
  late bool _toolsEnabled;
  late bool _customNoKey;
  bool _saving = false;
  bool _loadingModels = false;
  bool _saveAttempted = false;
  bool _endpointTouched = false;
  bool _saved = false;
  // The recipient (origin and auth style) the unsaved key draft was typed
  // for. A draft is never reused or sent once the recipient changes.
  String? _keyDraftRecipient;
  bool _keyDraftCleared = false;
  int _networkTicket = 0;
  AiWireClient? _activeClient;
  String? _endpointError;
  String? _requestLimitError;
  String? _outputLimitError;
  String? _modelsMessage;
  List<String> _loadedModels = const <String>[];

  bool get _editing => widget.provider != null;
  bool get _requiresKey =>
      _preset.id == 'custom' ? !_customNoKey : _caps.requiresKey;

  @override
  void initState() {
    super.initState();
    final provider = widget.provider;
    _providerId =
        provider?.id ?? 'ai-provider-${DateTime.now().microsecondsSinceEpoch}';
    _preset = provider == null
        ? AiPresets.openAi
        : AiPresets.all.firstWhere(
            (candidate) => candidate.id == provider.presetId,
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
    )..addListener(_baseUrlChanged);
    _apiKey = TextEditingController()..addListener(_keyChanged);
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
    _modelSearch = TextEditingController()..addListener(_modelSearchChanged);
    _advancedController = ExpansibleController();
    _initialSnapshot = _snapshot;
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
    _modelSearch.dispose();
    super.dispose();
  }

  void _modelChanged() {
    if (mounted) {
      setState(() {
        if (_modelsMessage == l10n.aiProviderKeyVerified) {
          _modelsMessage = null;
        }
      });
    }
  }

  void _modelSearchChanged() {
    if (mounted) setState(() {});
  }

  void _networkInputChanged() {
    _endpointTouched = true;
    _invalidateNetworkRequest();
    _validateEndpoint();
  }

  void _keyChanged() {
    final draft = _apiKey.text;
    if (draft.isEmpty) {
      _keyDraftRecipient = null;
    } else {
      _keyDraftRecipient ??= _recipientFingerprint();
      if (_keyDraftCleared) setState(() => _keyDraftCleared = false);
    }
    _networkInputChanged();
  }

  void _baseUrlChanged() {
    if (!_showsCleartextControl && _allowLanCleartext) {
      _allowLanCleartext = false;
    }
    _dropKeyDraftForNewRecipient();
    _networkInputChanged();
    // The policy notice depends on the recipient, so it is rebuilt per edit.
    if (mounted) setState(() {});
  }

  String _recipientFingerprint() {
    final uri = Uri.tryParse(_baseUrl.text.trim());
    final origin = uri == null || !uri.hasScheme
        ? _baseUrl.text.trim()
        : '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:'
              '${uri.hasPort ? uri.port : (uri.scheme == 'http' ? 80 : 443)}'
              '${uri.path.replaceFirst(RegExp(r'/+$'), '')}';
    return '$origin|${_authStyle.name}';
  }

  void _dropKeyDraftForNewRecipient() {
    final recipient = _keyDraftRecipient;
    if (recipient == null || _apiKey.text.isEmpty) return;
    if (recipient == _recipientFingerprint()) return;
    _apiKey.clear();
    setState(() => _keyDraftCleared = true);
  }

  void _invalidateNetworkRequest() {
    _networkTicket += 1;
    final client = _activeClient;
    _activeClient = null;
    client?.transport.close();
    if (_loadingModels || _loadedModels.isNotEmpty || _modelsMessage != null) {
      setState(() {
        _loadingModels = false;
        _loadedModels = const <String>[];
        _modelsMessage = null;
        _modelSearch.clear();
      });
    }
  }

  void _validateEndpoint() {
    String? error;
    try {
      AiEndpoint.parse(
        _baseUrl.text.trim(),
        allowLanCleartext: _allowLanCleartext,
        modelsUrlOverride: _modelsUrl.text.trim(),
      );
    } on Object {
      if (_endpointTouched || _saveAttempted) {
        error = _looksLikeLocalCleartext
            ? l10n.aiProviderLocalCleartextHelp
            : l10n.aiProviderBaseUrlInvalid;
      }
    }
    if (mounted && error != _endpointError) {
      setState(() => _endpointError = error);
    } else {
      _endpointError = error;
    }
  }

  void _selectPreset(AiPreset preset) {
    if (preset.id == _preset.id) return;
    _invalidateNetworkRequest();
    setState(() {
      _preset = preset;
      _format = preset.defaultFormat;
      _caps = preset.capsFor(_format);
      _authStyle = preset.authStyle;
      _customNoKey = false;
      _allowLanCleartext = false;
      _name.text = preset.name;
      _baseUrl.text = preset.baseUrlFor(_format);
      _modelsUrl.text = preset.modelsUrl ?? '';
      _maxRequestChars.text = _caps.maxRequestChars.toString();
      _maxOutputTokens.text = _caps.maxOutputTokens.toString();
      _loadedModels = const <String>[];
      _modelsMessage = null;
      _modelSearch.clear();
      _apiKey.clear();
      _keyDraftCleared = false;
      _endpointTouched = false;
      _endpointError = null;
    });
  }

  void _selectFormat(AiFormat format) {
    if (format == _format) return;
    _invalidateNetworkRequest();
    setState(() {
      final customBaseUrl = _baseUrl.text;
      _format = format;
      _caps = _preset.capsFor(format);
      _authStyle = _preset.authStyle;
      _baseUrl.text = _preset.id == 'custom'
          ? customBaseUrl
          : _preset.baseUrlFor(format);
      _maxRequestChars.text = _caps.maxRequestChars.toString();
      _maxOutputTokens.text = _caps.maxOutputTokens.toString();
      _loadedModels = const <String>[];
      _modelsMessage = null;
      _modelSearch.clear();
    });
    // The format resets the auth style; the URL may stay the same, in which
    // case its listener does not run.
    _dropKeyDraftForNewRecipient();
    _validateEndpoint();
  }

  /// The disclosure the consent dialog would show for the current fields, or
  /// null while the endpoint cannot be parsed.
  AiConsentContract? _currentContract() {
    try {
      return aiCurrentConsentContractFor(_config());
    } on Object {
      return null;
    }
  }

  AiCaps _effectiveCaps() => AiCaps(
    tokenLimitField: _caps.tokenLimitField,
    streamUsage: _caps.streamUsage,
    toolChoice: _caps.toolChoice,
    replayChatExtras: _caps.replayChatExtras,
    includeEncryptedReasoning: _caps.includeEncryptedReasoning,
    promptCaching: _caps.promptCaching,
    requiresKey: _requiresKey,
    // Same parsing as _validateCaps, so a validated value is the saved one.
    maxRequestChars:
        int.tryParse(_maxRequestChars.text.trim()) ?? _caps.maxRequestChars,
    maxOutputTokens:
        int.tryParse(_maxOutputTokens.text.trim()) ?? _caps.maxOutputTokens,
  );

  AiProviderConfig _config({AiAuthStyle? authStyle}) => AiProviderConfig(
    id: _providerId,
    name: _name.text.trim(),
    presetId: _preset.id,
    baseUrl: _baseUrl.text.trim(),
    modelsUrl: _modelsUrl.text.trim().isEmpty ? null : _modelsUrl.text.trim(),
    format: _format,
    model: _model.text.trim(),
    authStyle: authStyle ?? (_requiresKey ? _authStyle : AiAuthStyle.none),
    caps: _effectiveCaps(),
    allowLanCleartext: _showsCleartextControl && _allowLanCleartext,
    toolsEnabled: _toolsEnabled,
    recipientRevision: widget.provider?.recipientRevision ?? 0,
  );

  String? _validatedKey({bool allowStored = true}) {
    final key = _apiKey.text.trim();
    if (key.isEmpty &&
        _editing &&
        allowStored &&
        widget.settings.providerKeyFor(_config()) != null) {
      return null;
    }
    if (RegExp(r'[\s\x00-\x1f\x7f-\x9f]').hasMatch(key)) {
      throw const _KeyValidationException(_KeyProblem.whitespace);
    }
    if (!assessAiProviderKey(key).accepted) {
      throw const _KeyValidationException(_KeyProblem.tooShort);
    }
    return key;
  }

  Future<void> _save() async {
    if (_saving) return;
    _saveAttempted = true;
    _dropKeyDraftForNewRecipient();
    if (!_validateCaps()) return;
    if (!_formKey.currentState!.validate()) return;
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
      final saved = await widget.settings.saveProviderWithKey(
        _config(),
        key: key,
        acknowledgeWarning: true,
      );
      if (mounted) {
        _saved = true;
        Navigator.of(context).pop(saved);
      }
    } on Object catch (error) {
      if (mounted) showAiSettingsFailure(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _readModels() async {
    if (_loadingModels) return;
    _dropKeyDraftForNewRecipient();
    _validateEndpoint();
    if (_endpointError != null) return;
    final publicCatalog = _preset.id == 'openrouter';
    String key = '';
    if (_requiresKey && !publicCatalog) {
      try {
        key =
            _validatedKey() ?? widget.settings.providerKeyFor(_config()) ?? '';
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
    _dropKeyDraftForNewRecipient();
    _validateEndpoint();
    if (_endpointError != null) return;
    String key;
    try {
      key = _validatedKey() ?? widget.settings.providerKeyFor(_config()) ?? '';
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
    final model = _model.text.trim();
    // Same derivation as the consent dialog, so a changed endpoint or format
    // never shows the preset's guarantees.
    final contract = model.isEmpty ? null : _currentContract();
    final filteredModels = _filteredModels;
    return PopScope<Object?>(
      key: const ValueKey('ai-provider-pop-scope'),
      // Text edits do not rebuild this widget, so whether anything changed is
      // decided when the pop happens, not when the scope was built.
      canPop: _saved,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _saving) return;
        await _discard();
      },
      child: _WrappingFieldMessages(
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              _editing
                  ? l10n.aiProviderEditorEditTitle
                  : l10n.aiProviderEditorAddTitle,
            ),
            leading: IconButton(
              tooltip: l10n.cancelAction,
              onPressed: _saving ? null : _discard,
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<AiPreset>(
                      key: const ValueKey('ai-provider-preset'),
                      isExpanded: true,
                      initialValue: _preset,
                      decoration: InputDecoration(
                        labelText: l10n.aiProviderPresetLabel,
                      ),
                      itemHeight: null,
                      selectedItemBuilder: (context) => [
                        for (final preset in _presetMenuOrder)
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(isolated(preset.name)),
                          ),
                      ],
                      items: [
                        for (final preset in _presetMenuOrder)
                          DropdownMenuItem(
                            value: preset,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(isolated(preset.name)),
                                  Text(
                                    _presetDescription(preset),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
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
                      validator: (value) =>
                          value == null || value.trim().isEmpty
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
                    if (_showsCleartextControl)
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
                            : (value) {
                                _invalidateNetworkRequest();
                                setState(() => _customNoKey = value);
                              },
                      ),
                    if (_requiresKey) ...[
                      const SizedBox(height: 4),
                      TextFormField(
                        key: const ValueKey('ai-provider-api-key'),
                        controller: _apiKey,
                        obscureText: true,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        autocorrect: false,
                        keyboardType: TextInputType.visiblePassword,
                        decoration: InputDecoration(
                          labelText: l10n.aiProviderApiKeyLabel,
                          helperText: _editing
                              ? l10n.aiProviderApiKeyReplaceHint
                              : l10n.aiProviderApiKeyNewHint,
                        ),
                        validator: (value) {
                          if (_editing &&
                              (value == null || value.isEmpty) &&
                              widget.settings.providerKeyFor(_config()) !=
                                  null) {
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
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _StatusLine(
                          icon: _hasUsableStoredKey
                              ? Icons.key_rounded
                              : Icons.key_off_outlined,
                          label: _hasUsableStoredKey
                              ? l10n.aiProviderKeySet
                              : l10n.aiProviderKeyNotSet,
                        ),
                      ),
                      if (_keyDraftCleared)
                        Padding(
                          key: const ValueKey('ai-provider-key-draft-cleared'),
                          padding: const EdgeInsets.only(top: 8),
                          child: _StatusLine(
                            icon: Icons.info_outline_rounded,
                            label: l10n.aiProviderKeyDraftCleared,
                            explanation: l10n.aiProviderKeyDraftClearedDetail,
                          ),
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
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? l10n.aiProviderModelRequired
                          : null,
                    ),
                    // A routed model means the policy depends on the model (or
                    // the recipient is custom), so an unknown one is shown.
                    if (contract != null &&
                        (contract.dataUse != AiDataUse.unknown ||
                            contract.routedModel != null))
                      _PolicyNotice(
                        dataUse: contract.dataUse,
                        retentionDays: contract.retentionDays,
                      ),
                    if (model.isNotEmpty && _verificationLabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _StatusLine(
                          icon: Icons.help_outline_rounded,
                          label: _verificationLabel!,
                          explanation: l10n.aiProviderVerificationExplanation,
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
                          onPressed: _loadingModels
                              ? null
                              : _verifyOpenRouterKey,
                          icon: const Icon(Icons.key_outlined),
                          label: Text(l10n.aiProviderVerifyKey),
                        ),
                      ),
                    if (_modelsMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_modelsMessage!),
                      ),
                    if (_preset.id == 'openrouter' && _loadedModels.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: TextField(
                          key: const ValueKey('ai-provider-model-search'),
                          controller: _modelSearch,
                          decoration: InputDecoration(
                            labelText: l10n.aiProviderSearchModels,
                            prefixIcon: const Icon(Icons.search),
                          ),
                        ),
                      ),
                    if (filteredModels.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final model in filteredModels)
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
                      controller: _advancedController,
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text(l10n.aiProviderAdvancedTitle),
                      children: [
                        TextFormField(
                          key: const ValueKey('ai-provider-models-url'),
                          controller: _modelsUrl,
                          autocorrect: false,
                          keyboardType: TextInputType.url,
                          decoration: InputDecoration(
                            labelText: l10n.aiProviderModelsUrlLabel,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.aiProviderToolsEnabled),
                          value: _toolsEnabled,
                          onChanged: (value) =>
                              setState(() => _toolsEnabled = value),
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
                                _invalidateNetworkRequest();
                                setState(() => _authStyle = style);
                                _dropKeyDraftForNewRecipient();
                              }
                            },
                          ),
                        DropdownButtonFormField<AiTokenLimitField>(
                          key: const ValueKey('ai-provider-token-limit-field'),
                          isExpanded: true,
                          initialValue: _caps.tokenLimitField,
                          decoration: InputDecoration(
                            labelText: l10n.aiProviderTokenLimitFieldLabel,
                          ),
                          items: [
                            for (final field in _tokenLimitFields)
                              DropdownMenuItem(
                                value: field,
                                child: Text(_tokenLimitFieldLabel(field)),
                              ),
                          ],
                          onChanged: (field) {
                            if (field != null) {
                              _copyCaps(tokenLimitField: field);
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
                          (value) =>
                              _copyCaps(includeEncryptedReasoning: value),
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
                            errorText: _requestLimitError,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const ValueKey('ai-provider-output-limit'),
                          controller: _maxOutputTokens,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l10n.aiProviderMaxOutputTokensLabel,
                            errorText: _outputLimitError,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _discard() async {
    if (_saving) return;
    if (_hasUnsavedChanges) {
      final discard = await confirmAction(
        context,
        l10n.aiProviderDiscardTitle,
        l10n.aiProviderDiscardDetail,
      );
      if (!discard || !mounted) return;
    }
    _saved = true;
    Navigator.of(context).pop();
  }

  bool _validateCaps() {
    final request = int.tryParse(_maxRequestChars.text.trim());
    final output = int.tryParse(_maxOutputTokens.text.trim());
    final requestError = request == null || request < 8000 || request > 400000
        ? l10n.aiProviderRequestCharsRange
        : null;
    final outputError = output == null || output < 512 || output > 65536
        ? l10n.aiProviderOutputTokensRange
        : null;
    setState(() {
      _requestLimitError = requestError;
      _outputLimitError = outputError;
    });
    if (requestError == null && outputError == null) return true;
    _advancedController.expand();
    return false;
  }

  bool get _looksLikeLocalCleartext {
    final value = _baseUrl.text.trim();
    return value.toLowerCase().startsWith('http://') && !_allowLanCleartext;
  }

  bool get _showsCleartextControl =>
      _baseUrl.text.trim().toLowerCase().startsWith('http://');

  bool get _hasUsableStoredKey =>
      _apiKey.text.trim().isNotEmpty ||
      (_editing && widget.settings.providerKeyFor(_config()) != null);

  List<String> get _filteredModels {
    final query = _modelSearch.text.trim().toLowerCase();
    if (query.isEmpty) return _loadedModels;
    return _loadedModels
        .where((model) => model.toLowerCase().contains(query))
        .toList(growable: false);
  }

  List<AiTokenLimitField> get _tokenLimitFields => switch (_format) {
    AiFormat.chatCompletions => const <AiTokenLimitField>[
      AiTokenLimitField.maxTokens,
      AiTokenLimitField.maxCompletionTokens,
    ],
    AiFormat.responses => const <AiTokenLimitField>[
      AiTokenLimitField.maxOutputTokens,
    ],
    AiFormat.anthropicMessages => const <AiTokenLimitField>[
      AiTokenLimitField.maxTokens,
    ],
  };

  String _tokenLimitFieldLabel(AiTokenLimitField field) => switch (field) {
    AiTokenLimitField.maxTokens => 'max_tokens',
    AiTokenLimitField.maxCompletionTokens => 'max_completion_tokens',
    AiTokenLimitField.maxOutputTokens => 'max_output_tokens',
  };

  // Most likely first; Custom stays last.
  static const _presetMenuIds = <String>[
    'openai',
    'anthropic',
    'gemini',
    'openrouter',
    'opencode-go',
    'deepseek',
    'xai',
    'azure-openai',
    'opencode-zen',
    'ollama',
    'lm-studio',
    'custom',
  ];

  static final List<AiPreset> _presetMenuOrder = [
    for (final id in _presetMenuIds)
      ...AiPresets.all.where((preset) => preset.id == id),
    ...AiPresets.all.where((preset) => !_presetMenuIds.contains(preset.id)),
  ];

  String _presetDescription(AiPreset preset) => switch (preset.id) {
    'openai' => l10n.aiPresetAboutOpenAi,
    'anthropic' => l10n.aiPresetAboutAnthropic,
    'gemini' => l10n.aiPresetAboutGemini,
    'openrouter' => l10n.aiPresetAboutOpenRouter,
    'opencode-go' => l10n.aiPresetAboutOpenCodeGo,
    'deepseek' => l10n.aiPresetAboutDeepSeek,
    'xai' => l10n.aiPresetAboutXai,
    'azure-openai' => l10n.aiPresetAboutAzure,
    'opencode-zen' => l10n.aiPresetAboutOpenCodeZen,
    'ollama' => l10n.aiPresetAboutOllama,
    'lm-studio' => l10n.aiPresetAboutLmStudio,
    _ => l10n.aiProviderPresetDescriptionCustom,
  };

  _EditorSnapshot get _snapshot => (
    presetId: _preset.id,
    format: _format,
    name: _name.text,
    baseUrl: _baseUrl.text,
    apiKey: _apiKey.text,
    model: _model.text,
    modelsUrl: _modelsUrl.text,
    maxRequestChars: _maxRequestChars.text,
    maxOutputTokens: _maxOutputTokens.text,
    authStyle: _authStyle,
    tokenLimitField: _caps.tokenLimitField,
    allowLanCleartext: _allowLanCleartext,
    toolsEnabled: _toolsEnabled,
    customNoKey: _customNoKey,
    streamUsage: _caps.streamUsage,
    toolChoice: _caps.toolChoice,
    replayChatExtras: _caps.replayChatExtras,
    includeEncryptedReasoning: _caps.includeEncryptedReasoning,
    promptCaching: _caps.promptCaching,
  );

  bool get _hasUnsavedChanges => _snapshot != _initialSnapshot;

  AiEndpoint? get _parsedEndpoint {
    try {
      return AiEndpoint.parse(
        _baseUrl.text.trim(),
        allowLanCleartext: _allowLanCleartext,
        modelsUrlOverride: _modelsUrl.text.trim(),
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
    AiTokenLimitField? tokenLimitField,
    bool? streamUsage,
    bool? toolChoice,
    bool? replayChatExtras,
    bool? includeEncryptedReasoning,
    bool? promptCaching,
  }) {
    setState(() {
      _caps = AiCaps(
        tokenLimitField: tokenLimitField ?? _caps.tokenLimitField,
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

final class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.label,
    this.explanation,
  });

  final IconData icon;
  final String label;
  final String? explanation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.bodyMedium),
              if (explanation != null)
                Text(
                  explanation!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _PolicyNotice extends StatelessWidget {
  const _PolicyNotice({required this.dataUse, required this.retentionDays});

  final AiDataUse dataUse;
  final int? retentionDays;

  @override
  Widget build(BuildContext context) {
    final days = retentionDays;
    final retention = days == null
        ? l10n.aiConsentRetentionNotStated
        : days == 0
        ? l10n.aiPolicyNoRetention
        : l10n.aiPolicyRetainedDays(
            MaterialLocalizations.of(context).formatDecimal(days),
          );
    final (icon, label) = switch (dataUse) {
      AiDataUse.training => (
        Icons.model_training,
        l10n.aiProviderModelTrainingWarning,
      ),
      AiDataUse.noTraining => (
        Icons.verified_user_outlined,
        l10n.aiPolicyNoTraining,
      ),
      AiDataUse.unknown => (
        Icons.help_outline,
        l10n.aiProviderModelPolicyUnknown,
      ),
    };
    final line = Padding(
      padding: const EdgeInsets.only(top: 8),
      child: _StatusLine(
        icon: icon,
        label: label,
        // Unknown policies already say retention cannot be confirmed.
        explanation: dataUse == AiDataUse.unknown ? null : retention,
      ),
    );
    if (dataUse != AiDataUse.training) return line;
    final error = Theme.of(context).colorScheme.error;
    return IconTheme.merge(
      data: IconThemeData(color: error),
      child: line,
    );
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

/// Lets field helper and error text wrap instead of being cut to one line.
class _WrappingFieldMessages extends StatelessWidget {
  const _WrappingFieldMessages({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          errorMaxLines: 20,
          helperMaxLines: 20,
        ),
      ),
      child: child,
    );
  }
}
