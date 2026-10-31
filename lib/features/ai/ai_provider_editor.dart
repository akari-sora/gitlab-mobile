import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mergeline_on_device_ai/mergeline_on_device_ai.dart';

import '../../core/ai/ai_endpoint.dart';
import '../../core/ai/ai_failure.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/ai_transport.dart';
import '../../core/ai/ai_wire_client.dart';
import '../../core/ai/wire/anthropic_messages.dart';
import '../../core/ai/wire/chat_completions.dart';
import '../../core/ai/wire/responses.dart';
import '../../l10n/l10n.dart';
import '../../shared/layout_constants.dart';
import '../../shared/workspace_ui.dart';
import '../demo/demo_scope.dart';
import 'ai_consent_dialog.dart';
import 'ai_scope.dart';
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
    this.accountKey,
    this.onDeviceAi,
  });

  final AiSettingsController settings;
  final AiProviderConfig? provider;
  final AiProviderClientFactory? clientFactory;
  final String? accountKey;
  final MergelineOnDeviceAi? onDeviceAi;

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
  late final ExpansibleController _advancedController;
  late final String _providerId;
  late _EditorSnapshot _initialSnapshot;
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
  bool _deviceSupportChecked = false;
  bool _onDeviceSupported = false;
  bool _checkingOnDeviceStatus = false;
  bool _downloadingOnDevice = false;
  OnDeviceStatus? _onDeviceStatus;
  int? _bytesDownloaded;
  int? _bytesToDownload;
  String? _onDeviceDownloadError;
  StreamSubscription<OnDeviceDownloadEvent>? _downloadSubscription;
  int _onDeviceTicket = 0;
  // The recipient (origin and auth style) the unsaved key draft was typed
  // for. A draft is never reused or sent once the recipient changes.
  String? _keyDraftRecipient;
  bool _keyDraftCleared = false;
  int _networkTicket = 0;
  AiWireClient? _activeClient;
  String? _endpointError;
  // The endpoint error belongs to the model list URL: the base URL is valid on
  // its own.
  bool _endpointErrorOnModelsUrl = false;
  // The model list URL follows the preset's default until the user edits it.
  late bool _modelsUrlEdited;
  bool _syncingModelsUrl = false;
  // The last text each listener saw. A controller also notifies on selection
  // and composing changes (a tap into the field), which are not edits.
  late String _baseUrlText;
  late String _modelsUrlText;
  String _apiKeyText = '';
  late String _modelText;
  final _baseUrlFieldKey = GlobalKey();
  final _modelsUrlFieldKey = GlobalKey();
  final _requestLimitFieldKey = GlobalKey();
  final _outputLimitFieldKey = GlobalKey();
  String? _requestLimitError;
  String? _outputLimitError;
  String? _modelsMessage;
  List<String> _loadedModels = const <String>[];
  // A read succeeded for the current recipient; the list may be empty.
  bool _modelsLoaded = false;
  // That read's catalogue was empty before any format filtering.
  bool _catalogueEmpty = false;

  bool get _editing => widget.provider != null;
  bool get _requiresKey =>
      _preset.id == 'custom' ? !_customNoKey : _caps.requiresKey;
  MergelineOnDeviceAi get _onDeviceAi =>
      widget.onDeviceAi ?? MergelineOnDeviceAi.instance;

  String get _effectiveProviderId => _editing
      ? _providerId
      : (_preset.onDevice ? AiPresets.onDeviceId : _providerId);

  // On-device consent is per account; without one the option is not offered.
  String? get _accountKey =>
      widget.accountKey ??
      (mounted ? AiScope.maybeOf(context)?.accountKey : null);

  bool get _hasOnDeviceConsent {
    final accountKey = _accountKey;
    if (!_preset.onDevice || accountKey == null) return false;
    final contract = _currentContract();
    if (contract == null) return false;
    return widget.settings.isValid(accountKey, contract);
  }

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_settingsChanged);
    final provider = widget.provider;
    _providerId =
        provider?.id ?? 'ai-provider-${DateTime.now().microsecondsSinceEpoch}';
    _preset = provider == null
        ? AiPresets.openAi
        : (AiPresets.byId(provider.presetId) ?? AiPresets.custom);
    _format = provider?.format ?? _preset.defaultFormat;
    _caps = provider?.caps ?? _preset.capsFor(_format);
    _authStyle = provider?.authStyle ?? _preset.authStyle;
    _allowLanCleartext = provider?.allowLanCleartext ?? false;
    _toolsEnabled = provider?.toolsEnabled ?? false;
    _customNoKey = _preset.id == 'custom' && !_caps.requiresKey;
    _name = TextEditingController(text: provider?.name ?? _presetName(_preset));
    _baseUrl = TextEditingController(
      text: provider?.baseUrl ?? _preset.baseUrlFor(_format),
    )..addListener(_baseUrlChanged);
    _apiKey = TextEditingController()..addListener(_keyChanged);
    _model = TextEditingController(
      text: provider?.model ?? (_preset.defaultModel ?? ''),
    )..addListener(_modelChanged);
    final savedModelsUrl = provider?.modelsUrl ?? '';
    _modelsUrlEdited =
        savedModelsUrl.isNotEmpty && savedModelsUrl != _preset.modelsUrl;
    _modelsUrl = TextEditingController(
      text: _modelsUrlEdited
          ? savedModelsUrl
          : _defaultModelsUrlFor(_baseUrl.text) ?? savedModelsUrl,
    )..addListener(_modelsUrlChanged);
    _maxRequestChars = TextEditingController(
      text: _caps.maxRequestChars.toString(),
    );
    _maxOutputTokens = TextEditingController(
      text: _caps.maxOutputTokens.toString(),
    );
    _advancedController = ExpansibleController();
    _baseUrlText = _baseUrl.text;
    _modelsUrlText = _modelsUrl.text;
    _modelText = _model.text;
    _initialSnapshot = _snapshot;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_deviceSupportChecked) {
      _deviceSupportChecked = true;
      unawaited(_checkOnDeviceSupport());
    }
    if (_preset.onDevice &&
        _hasOnDeviceConsent &&
        _onDeviceStatus == null &&
        !_checkingOnDeviceStatus) {
      unawaited(_refreshOnDeviceStatus());
    }
  }

  @override
  void dispose() {
    widget.settings.removeListener(_settingsChanged);
    _onDeviceTicket += 1;
    unawaited(_downloadSubscription?.cancel());
    _downloadSubscription = null;
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

  void _settingsChanged() {
    if (!mounted) return;
    if (_preset.onDevice) {
      if (_hasOnDeviceConsent) {
        if (_onDeviceStatus == null && !_checkingOnDeviceStatus) {
          unawaited(_refreshOnDeviceStatus());
        }
      } else {
        _cancelOnDeviceWork();
      }
    }
    setState(() {});
  }

  Future<void> _checkOnDeviceSupport() async {
    if (!mounted) return;
    if (DemoScope.maybeOf(context) != null ||
        Theme.of(context).platform != TargetPlatform.android ||
        _accountKey == null) {
      if (_onDeviceSupported && mounted) {
        setState(() => _onDeviceSupported = false);
      }
      return;
    }
    try {
      final support = await _onDeviceAi.deviceSupport();
      if (!mounted) return;
      if (DemoScope.maybeOf(context) != null ||
          Theme.of(context).platform != TargetPlatform.android) {
        return;
      }
      if (support.isLikely != _onDeviceSupported) {
        setState(() => _onDeviceSupported = support.isLikely);
      }
    } on Object {
      // Never offer on-device if capability check fails.
    }
  }

  void _cancelOnDeviceWork() {
    _onDeviceTicket += 1;
    unawaited(_downloadSubscription?.cancel());
    _downloadSubscription = null;
    _checkingOnDeviceStatus = false;
    _downloadingOnDevice = false;
    _onDeviceStatus = null;
    _bytesDownloaded = null;
    _bytesToDownload = null;
    _onDeviceDownloadError = null;
  }

  Future<void> _refreshOnDeviceStatus({bool resumeDownload = true}) async {
    if (!mounted || !_preset.onDevice || !_hasOnDeviceConsent) return;
    final ticket = ++_onDeviceTicket;
    setState(() {
      _checkingOnDeviceStatus = true;
      _onDeviceDownloadError = null;
    });
    try {
      final status = await _onDeviceAi.status();
      if (!mounted || ticket != _onDeviceTicket || !_hasOnDeviceConsent) return;
      setState(() {
        _checkingOnDeviceStatus = false;
        _onDeviceStatus = status;
      });
      // A download started on an earlier visit shows its progress again;
      // the plugin attaches to it.
      if (resumeDownload && status.isDownloading && !_downloadingOnDevice) {
        _startOnDeviceDownload();
      }
    } on Object catch (error) {
      if (!mounted || ticket != _onDeviceTicket || !_hasOnDeviceConsent) return;
      setState(() {
        _checkingOnDeviceStatus = false;
        _onDeviceStatus = const OnDeviceStatus.unavailable();
        _onDeviceDownloadError = _downloadErrorText(error);
      });
    }
  }

  Future<void> _reviewOnDeviceConsent() async {
    final accountKey = _accountKey;
    if (_saving || !_preset.onDevice || accountKey == null) return;
    if (!_validateCaps()) return;
    final invalid = _formKey.currentState!.validateGranularly();
    if (invalid.isNotEmpty) return;
    setState(() => _saving = true);
    final previous = widget.settings.providers
        .where((candidate) => candidate.id == _effectiveProviderId)
        .firstOrNull;
    final edited = _snapshot != _initialSnapshot;
    try {
      // The consent screen reads the saved provider; a decline undoes this.
      final saved = await widget.settings.saveProvider(_config());
      if (!mounted) return;
      if (widget.settings.accountRecord(accountKey) == null) {
        await widget.settings.loadAccount(accountKey);
      }
      if (!mounted) return;
      final contract = aiConsentContractFor(saved);
      final agreed = await showAiConsentDialog(
        context,
        widget.settings,
        accountKey,
        contract,
        agreeLabel: l10n.aiConsentAgree,
      );
      if (!agreed) {
        // A declined provider is not kept: a new one would otherwise become
        // the device default. An edited one gets its saved settings back.
        if (previous == null) {
          await widget.settings.deleteProvider(saved.id);
        } else if (edited) {
          await widget.settings.saveProvider(previous);
        }
        return;
      }
      if (!mounted) return;
      _initialSnapshot = _snapshot;
      if (_hasOnDeviceConsent &&
          !_checkingOnDeviceStatus &&
          _onDeviceStatus == null) {
        await _refreshOnDeviceStatus();
      }
    } on Object catch (error) {
      if (mounted) showAiSettingsFailure(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _startOnDeviceDownload() {
    if (_downloadingOnDevice || !_preset.onDevice || !_hasOnDeviceConsent) {
      return;
    }
    final ticket = ++_onDeviceTicket;
    unawaited(_downloadSubscription?.cancel());
    setState(() {
      _downloadingOnDevice = true;
      _onDeviceDownloadError = null;
      _bytesDownloaded = 0;
      _bytesToDownload = null;
      _onDeviceStatus = const OnDeviceStatus.downloading();
    });
    _downloadSubscription = _onDeviceAi.download().listen(
      (event) {
        if (!mounted || ticket != _onDeviceTicket || !_hasOnDeviceConsent) {
          return;
        }
        switch (event.state) {
          case OnDeviceDownloadState.started:
            setState(() {
              _bytesToDownload = event.bytesToDownload;
              _bytesDownloaded = 0;
              _onDeviceStatus = const OnDeviceStatus.downloading();
            });
          case OnDeviceDownloadState.progress:
            setState(() {
              _bytesDownloaded = event.bytesDownloaded;
              _bytesToDownload = event.bytesToDownload ?? _bytesToDownload;
              _onDeviceStatus = const OnDeviceStatus.downloading();
            });
          case OnDeviceDownloadState.completed:
            setState(() {
              _downloadingOnDevice = false;
              _onDeviceStatus = const OnDeviceStatus.available();
            });
            unawaited(_refreshOnDeviceStatus(resumeDownload: false));
          case OnDeviceDownloadState.failed:
            setState(() {
              _downloadingOnDevice = false;
              _onDeviceStatus = const OnDeviceStatus.downloadable();
              _onDeviceDownloadError = _downloadErrorText(event.error);
            });
        }
      },
      onError: (Object error) {
        if (!mounted || ticket != _onDeviceTicket || !_hasOnDeviceConsent) {
          return;
        }
        setState(() {
          _downloadingOnDevice = false;
          _onDeviceStatus = const OnDeviceStatus.downloadable();
          _onDeviceDownloadError = _downloadErrorText(error);
        });
      },
      // A stream that ends without a final event: read the status again.
      onDone: () {
        if (!mounted || ticket != _onDeviceTicket || !_downloadingOnDevice) {
          return;
        }
        setState(() => _downloadingOnDevice = false);
        unawaited(_refreshOnDeviceStatus(resumeDownload: false));
      },
    );
  }

  String _downloadErrorText(Object? error) {
    if (error is OnDeviceAiException) {
      return switch (error.code) {
        OnDeviceAiErrorCode.insufficientStorage =>
          l10n.aiOnDeviceUnavailableReasonInsufficientStorage,
        OnDeviceAiErrorCode.backgroundBlocked =>
          l10n.aiOnDeviceForegroundOnlyDetail,
        OnDeviceAiErrorCode.busy => l10n.aiOnDeviceBusyDetail,
        OnDeviceAiErrorCode.quotaExceeded => l10n.aiOnDeviceQuotaExceededDetail,
        OnDeviceAiErrorCode.unsupported => l10n.aiOnDeviceUnavailableDetail,
        OnDeviceAiErrorCode.notDownloaded => l10n.aiOnDeviceModelNotReadyDetail,
        _ => l10n.aiOnDeviceErrorDetail,
      };
    }
    return l10n.aiOnDeviceErrorDetail;
  }

  String _unavailableReasonText(String? reason) => switch (reason) {
    'not_android' => l10n.aiOnDeviceUnavailableReasonNotAndroid,
    'sdk_too_old' => l10n.aiOnDeviceUnavailableReasonSdkTooOld,
    'aicore_missing' => l10n.aiOnDeviceUnavailableReasonAicoreMissing,
    'aicore_disabled' => l10n.aiOnDeviceUnavailableReasonAicoreDisabled,
    'insufficient_storage' ||
    'insufficientStorage' ||
    'NOT_ENOUGH_DISK_SPACE' =>
      l10n.aiOnDeviceUnavailableReasonInsufficientStorage,
    _ => l10n.aiOnDeviceUnavailableReasonUnsupported,
  };

  static String _formatMb(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(1);

  void _modelChanged() {
    if (_model.text == _modelText) return;
    _modelText = _model.text;
    if (mounted) {
      setState(() {
        if (_modelsMessage == l10n.aiProviderKeyVerified) {
          _modelsMessage = null;
        }
      });
    }
  }

  void _networkInputChanged() {
    _endpointTouched = true;
    _invalidateNetworkRequest();
    _validateEndpoint();
  }

  void _keyChanged() {
    if (_apiKey.text == _apiKeyText) return;
    _apiKeyText = _apiKey.text;
    final draft = _apiKey.text;
    if (draft.isEmpty) {
      _keyDraftRecipient = null;
    } else {
      _keyDraftRecipient ??= _recipientFingerprint();
    }
    // The key status line ("Key set") reads the draft, so it is rebuilt as
    // the user types, not on the next unrelated rebuild.
    if (mounted) setState(() => _keyDraftCleared &= draft.isEmpty);
    _networkInputChanged();
  }

  void _baseUrlChanged() {
    if (_baseUrl.text == _baseUrlText) return;
    _baseUrlText = _baseUrl.text;
    if (!_showsCleartextControl && _allowLanCleartext) {
      _allowLanCleartext = false;
    }
    if (!_modelsUrlEdited) {
      final wanted = _defaultModelsUrlFor(_baseUrl.text);
      if (wanted != null && wanted != _modelsUrl.text) _setModelsUrl(wanted);
    }
    _dropKeyDraftForNewRecipient();
    _networkInputChanged();
    // The policy notice depends on the recipient, so it is rebuilt per edit.
    if (mounted) setState(() {});
  }

  void _modelsUrlChanged() {
    if (_modelsUrl.text == _modelsUrlText) return;
    _modelsUrlText = _modelsUrl.text;
    if (!_syncingModelsUrl) _modelsUrlEdited = true;
    _networkInputChanged();
  }

  void _setModelsUrl(String value) {
    _syncingModelsUrl = true;
    try {
      _modelsUrl.text = value;
    } finally {
      _syncingModelsUrl = false;
    }
  }

  /// The preset's model list URL while [baseUrl] is on the preset's server,
  /// empty on any other server (a list URL must share the base URL's origin),
  /// or null when the preset has no list URL of its own.
  String? _defaultModelsUrlFor(String baseUrl) {
    final preset = _preset.modelsUrl;
    if (preset == null) return null;
    final base = Uri.tryParse(baseUrl.trim());
    final models = Uri.parse(preset);
    bool sameOrigin;
    try {
      sameOrigin =
          base != null &&
          base.hasScheme &&
          base.host.isNotEmpty &&
          base.scheme.toLowerCase() == models.scheme &&
          base.host.toLowerCase() == models.host &&
          base.port == models.port;
    } on FormatException {
      // A port too large for an int; the endpoint check reports the URL.
      sameOrigin = false;
    }
    return sameOrigin ? preset : '';
  }

  String _recipientFingerprint() {
    final raw = _baseUrl.text.trim();
    final uri = Uri.tryParse(raw);
    String origin;
    try {
      origin = uri == null || !uri.hasScheme
          ? raw
          : '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:'
                '${uri.hasPort ? uri.port : (uri.scheme == 'http' ? 80 : 443)}'
                '${uri.path.replaceFirst(RegExp(r'/+$'), '')}';
    } on FormatException {
      // A port too large for an int: the raw text still names the recipient.
      origin = raw;
    }
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
    if (_loadingModels ||
        _modelsLoaded ||
        _loadedModels.isNotEmpty ||
        _modelsMessage != null) {
      setState(() {
        _loadingModels = false;
        _loadedModels = const <String>[];
        _modelsLoaded = false;
        _modelsMessage = null;
      });
    }
  }

  void _validateEndpoint() {
    if (_preset.onDevice) {
      if (mounted && (_endpointError != null || _endpointErrorOnModelsUrl)) {
        setState(() {
          _endpointError = null;
          _endpointErrorOnModelsUrl = false;
        });
      } else {
        _endpointError = null;
        _endpointErrorOnModelsUrl = false;
      }
      return;
    }
    String? error;
    var onModelsUrl = false;
    try {
      AiEndpoint.parse(
        _baseUrl.text.trim(),
        allowLanCleartext: _allowLanCleartext,
        modelsUrlOverride: _modelsUrl.text.trim(),
      );
    } on Object {
      if (_endpointTouched || _saveAttempted) {
        onModelsUrl = _modelsUrl.text.trim().isNotEmpty && _baseUrlValidAlone;
        error = onModelsUrl
            ? l10n.aiProviderModelsUrlInvalid
            : _looksLikeLocalCleartext
            ? l10n.aiProviderLocalCleartextHelp
            : l10n.aiProviderBaseUrlInvalid;
      }
    }
    if (mounted &&
        (error != _endpointError || onModelsUrl != _endpointErrorOnModelsUrl)) {
      setState(() {
        _endpointError = error;
        _endpointErrorOnModelsUrl = onModelsUrl;
      });
    } else {
      _endpointError = error;
      _endpointErrorOnModelsUrl = onModelsUrl;
    }
  }

  /// The field drawn highest on the screen.
  static FormFieldState<Object?>? _topmost(
    Iterable<FormFieldState<Object?>> fields,
  ) {
    FormFieldState<Object?>? topmost;
    var top = double.infinity;
    for (final field in fields) {
      final box = field.context.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y < top) {
        top = y;
        topmost = field;
      }
    }
    return topmost;
  }

  bool get _baseUrlValidAlone {
    if (_preset.onDevice) return true;
    try {
      AiEndpoint.parse(
        _baseUrl.text.trim(),
        allowLanCleartext: _allowLanCleartext,
      );
      return true;
    } on Object {
      return false;
    }
  }

  /// Whether the endpoint blocks a network action; scrolls to the field
  /// whose error explains it, opening the advanced section for the model
  /// list URL.
  bool _endpointBlocked() {
    if (_endpointError == null) return false;
    if (_endpointErrorOnModelsUrl) {
      _reveal(
        () => _modelsUrlFieldKey.currentContext,
        inAdvanced: true,
        stillNeeded: () => _endpointError != null && _endpointErrorOnModelsUrl,
      );
    } else {
      _reveal(
        () => _baseUrlFieldKey.currentContext,
        stillNeeded: () => _endpointError != null && !_endpointErrorOnModelsUrl,
      );
    }
    return true;
  }

  /// Scrolls the context [field] returns into view, so a blocked action never
  /// looks like a dead button. A field in the advanced section is built only
  /// once the section opens, so the scroll waits until the opening animation
  /// has had its time (the first animation frames do not grow the section
  /// yet) and the scroll extent is the same on two frames in a row. It gives
  /// up when [stillNeeded] turns false, so an error fixed meanwhile does not
  /// move the page.
  void _reveal(
    BuildContext? Function() field, {
    bool inAdvanced = false,
    required bool Function() stillNeeded,
  }) {
    if (inAdvanced && !_advancedController.isExpanded) {
      _advancedController.expand();
    }
    Duration? start;
    double? lastExtent;
    void step(Duration timeStamp) {
      if (!mounted || !stillNeeded()) return;
      final elapsed = timeStamp - (start ??= timeStamp);
      final context = field();
      final extent = context == null
          ? null
          : Scrollable.maybeOf(context)?.position.maxScrollExtent;
      // ExpansionTile opens in kThemeAnimationDuration (200 ms).
      if (context == null ||
          extent == null ||
          elapsed < kThemeAnimationDuration ||
          extent != lastExtent) {
        lastExtent = extent;
        if (elapsed < const Duration(seconds: 1)) {
          WidgetsBinding.instance
            ..addPostFrameCallback(step)
            ..ensureVisualUpdate();
        }
        return;
      }
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: kThemeAnimationDuration,
      );
    }

    WidgetsBinding.instance
      ..addPostFrameCallback(step)
      ..ensureVisualUpdate();
  }

  void _selectPreset(AiPreset preset) {
    if (preset.id == _preset.id) return;
    _invalidateNetworkRequest();
    _cancelOnDeviceWork();
    setState(() {
      _preset = preset;
      _format = preset.defaultFormat;
      _caps = preset.capsFor(_format);
      _authStyle = preset.authStyle;
      _customNoKey = false;
      _allowLanCleartext = false;
      _name.text = _presetName(preset);
      _modelsUrlEdited = false;
      _baseUrl.text = preset.baseUrlFor(_format);
      _model.text = preset.defaultModel ?? '';
      _setModelsUrl(preset.modelsUrl ?? '');
      _maxRequestChars.text = _caps.maxRequestChars.toString();
      _maxOutputTokens.text = _caps.maxOutputTokens.toString();
      _requestLimitError = null;
      _outputLimitError = null;
      _loadedModels = const <String>[];
      _modelsLoaded = false;
      _modelsMessage = null;
      _apiKey.clear();
      _keyDraftCleared = false;
      _endpointTouched = false;
      _endpointError = null;
      _endpointErrorOnModelsUrl = false;
    });
    if (preset.onDevice && _hasOnDeviceConsent) {
      unawaited(_refreshOnDeviceStatus());
    }
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
      _requestLimitError = null;
      _outputLimitError = null;
      _loadedModels = const <String>[];
      _modelsLoaded = false;
      _modelsMessage = null;
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

  AiProviderConfig _config({AiAuthStyle? authStyle}) {
    final id = _effectiveProviderId;
    final persistedRevision = widget.settings.providers
        .where((candidate) => candidate.id == id)
        .firstOrNull
        ?.recipientRevision;
    return AiProviderConfig(
      id: id,
      name: _name.text.trim(),
      presetId: _preset.id,
      baseUrl: _baseUrl.text.trim(),
      modelsUrl: _modelsUrl.text.trim().isEmpty ? null : _modelsUrl.text.trim(),
      format: _format,
      model: _model.text.trim(),
      authStyle: authStyle ?? (_requiresKey ? _authStyle : AiAuthStyle.none),
      caps: _effectiveCaps(),
      allowLanCleartext: _showsCleartextControl && _allowLanCleartext,
      toolsEnabled: _preset.onDevice ? false : _toolsEnabled,
      recipientRevision:
          persistedRevision ?? widget.provider?.recipientRevision ?? 0,
    );
  }

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
    final invalid = _formKey.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      // isValid checks the current value; the shown error stays until the
      // next save. The set is in registration order, not screen order.
      Iterable<FormFieldState<Object?>> stillInvalid() =>
          invalid.where((field) => field.mounted && !field.isValid);
      _reveal(
        () => _topmost(stillInvalid())?.context,
        stillNeeded: () => stillInvalid().isNotEmpty,
      );
      return;
    }
    _validateEndpoint();
    if (_endpointBlocked()) return;
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
    // A model read still running must not open its picker over the editor
    // while it saves; the save's pop would then close the picker instead.
    _cancelModelRead();
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

  /// Stops a model read or key check in flight, keeping any list loaded
  /// before it.
  void _cancelModelRead() {
    if (!_loadingModels) return;
    _networkTicket += 1;
    final client = _activeClient;
    _activeClient = null;
    client?.transport.close();
    setState(() => _loadingModels = false);
  }

  /// Reads the catalogue for the current recipient. True when this read
  /// succeeded and is still current.
  Future<bool> _readModels() async {
    if (_loadingModels) return false;
    _dropKeyDraftForNewRecipient();
    _validateEndpoint();
    if (_endpointBlocked()) return false;
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
        return false;
      }
      if (!assessAiProviderKey(key).accepted) {
        setState(() => _modelsMessage = l10n.aiProviderKeyMinimum);
        return false;
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
      if (!mounted || ticket != _networkTicket) return false;
      final allowed = _preset.modelPolicies.isEmpty
          ? page.models.map((model) => model.id)
          : page.models
                .map((model) => model.id)
                .where((id) => _preset.modelPolicies[id]?.format == _format);
      setState(() {
        _loadedModels = allowed.toSet().toList()..sort();
        _modelsLoaded = true;
        _catalogueEmpty = page.models.isEmpty;
        _modelsMessage = page.hasMore
            ? l10n.aiProviderModelsTruncated
            : l10n.aiProviderModelsReadSuccess;
      });
      return true;
    } on Object {
      if (mounted && ticket == _networkTicket) {
        setState(() => _modelsMessage = l10n.aiProviderModelsReadFailure);
      }
      return false;
    } finally {
      client?.transport.close();
      final wasActive = identical(_activeClient, client);
      if (wasActive) _activeClient = null;
      if (mounted && wasActive) {
        setState(() => _loadingModels = false);
      }
    }
  }

  /// Offers the model catalogue in a searchable sheet, reading it first when
  /// it is not loaded or when [refresh] asks for a new read. The field still
  /// takes any typed model ID.
  Future<void> _pickModel({bool refresh = false}) async {
    if (_loadingModels || _saving || _saved) return;
    // A read that failed or went stale offers nothing, not the list from
    // before it.
    if ((refresh || !_modelsLoaded) && !await _readModels()) return;
    // The editor may be saving or on its way out, or a dialog may cover it.
    if (!mounted ||
        _saving ||
        _saved ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _ModelPickerSheet(
        models: _loadedModels,
        current: _model.text.trim(),
        catalogueEmpty: _catalogueEmpty,
      ),
    );
    if (picked != null && mounted) _model.text = picked;
  }

  Future<void> _verifyOpenRouterKey() async {
    if (_loadingModels || _preset.id != 'openrouter') return;
    _dropKeyDraftForNewRecipient();
    _validateEndpoint();
    if (_endpointBlocked()) return;
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
            titleSpacing: 0,
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
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
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
                        for (final preset in _availablePresets)
                          Align(
                            key: ValueKey('ai-preset-${preset.id}'),
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(isolated(_presetName(preset))),
                          ),
                      ],
                      items: [
                        for (final preset in _availablePresets)
                          DropdownMenuItem(
                            key: ValueKey('ai-preset-option-${preset.id}'),
                            value: preset,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(isolated(_presetName(preset))),
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
                    const SizedBox(height: SharedLayout.fieldGap),
                    TextFormField(
                      key: const ValueKey('ai-provider-name'),
                      controller: _name,
                      decoration: InputDecoration(labelText: l10n.nameLabel),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? l10n.aiProviderNameRequired
                          : null,
                    ),
                    if (_preset.onDevice) ...[
                      const SizedBox(height: SharedLayout.fieldGap),
                      _buildOnDeviceSection(),
                    ] else ...[
                      const SizedBox(height: SharedLayout.fieldGap),
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
                      const SizedBox(height: SharedLayout.fieldGap),
                      KeyedSubtree(
                        key: _baseUrlFieldKey,
                        child: TextFormField(
                          key: const ValueKey('ai-provider-base-url'),
                          controller: _baseUrl,
                          autocorrect: false,
                          keyboardType: TextInputType.url,
                          decoration: InputDecoration(
                            labelText: l10n.aiProviderBaseUrlLabel,
                            // The base URL is fine on its own; point at the
                            // collapsed field that needs the fix.
                            errorText: _endpointErrorOnModelsUrl
                                ? l10n.aiProviderModelsUrlNeedsFix
                                : _endpointError,
                          ),
                        ),
                      ),
                      // Clear of the field above, like the switches below.
                      if (_showsCleartextControl || _preset.id == 'custom')
                        const SizedBox(height: 8),
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
                        const SizedBox(height: 8),
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
                            if (RegExp(r'[\s\x00-\x1f\x7f-\x9f]')
                                .hasMatch(key)) {
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
                            key: const ValueKey(
                              'ai-provider-key-draft-cleared',
                            ),
                            padding: const EdgeInsets.only(top: 8),
                            child: _StatusLine(
                              icon: Icons.info_outline_rounded,
                              label: l10n.aiProviderKeyDraftCleared,
                              explanation: l10n.aiProviderKeyDraftClearedDetail,
                            ),
                          ),
                      ],
                      const SizedBox(height: SharedLayout.fieldGap),
                      TextFormField(
                        key: const ValueKey('ai-provider-model'),
                        controller: _model,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: l10n.aiProviderModelLabel,
                          suffixIcon: IconButton(
                            key: const ValueKey('ai-provider-pick-model'),
                            tooltip: l10n.aiProviderChooseModel,
                            onPressed: _loadingModels || _saving
                                ? null
                                : _pickModel,
                            icon: _loadingModels
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.format_list_bulleted),
                          ),
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? l10n.aiProviderModelRequired
                            : null,
                      ),
                      // A routed model means the policy depends on the model
                      // (or the recipient is custom), so an unknown one is
                      // shown.
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
                          onPressed: _loadingModels || _saving
                              ? null
                              : () => _pickModel(refresh: true),
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
                            onPressed: _loadingModels || _saving
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
                    ],
                    const SizedBox(height: 8),
                    ExpansionTile(
                      key: const ValueKey('ai-provider-advanced'),
                      controller: _advancedController,
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text(l10n.aiProviderAdvancedTitle),
                      children: [
                        // A gap under the tile's title before the first
                        // field.
                        const SizedBox(height: 8),
                        if (!_preset.onDevice) ...[
                          KeyedSubtree(
                            key: _modelsUrlFieldKey,
                            child: TextFormField(
                              key: const ValueKey('ai-provider-models-url'),
                              controller: _modelsUrl,
                              autocorrect: false,
                              keyboardType: TextInputType.url,
                              decoration: InputDecoration(
                                labelText: l10n.aiProviderModelsUrlLabel,
                                errorText: _endpointErrorOnModelsUrl
                                    ? _endpointError
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(l10n.aiProviderToolsEnabled),
                            subtitle: Text(
                              l10n.aiProviderToolsHint(
                                l10n.aiWriteSettingsTitle,
                              ),
                            ),
                            value: _toolsEnabled,
                            onChanged: (value) =>
                                setState(() => _toolsEnabled = value),
                          ),
                          const SizedBox(height: SharedLayout.fieldGap),
                          if (_requiresKey) ...[
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
                            const SizedBox(height: SharedLayout.fieldGap),
                          ],
                          DropdownButtonFormField<AiTokenLimitField>(
                            key: const ValueKey(
                              'ai-provider-token-limit-field',
                            ),
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
                          const SizedBox(height: 8),
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
                          const SizedBox(height: SharedLayout.fieldGap),
                        ],
                        KeyedSubtree(
                          key: _requestLimitFieldKey,
                          child: TextFormField(
                            key: const ValueKey('ai-provider-request-limit'),
                            controller: _maxRequestChars,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l10n.aiProviderMaxRequestCharsLabel,
                              errorText: _requestLimitError,
                            ),
                          ),
                        ),
                        const SizedBox(height: SharedLayout.fieldGap),
                        KeyedSubtree(
                          key: _outputLimitFieldKey,
                          child: TextFormField(
                            key: const ValueKey('ai-provider-output-limit'),
                            controller: _maxOutputTokens,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l10n.aiProviderMaxOutputTokensLabel,
                              errorText: _outputLimitError,
                            ),
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
    // A model read still running must not open its picker over the page
    // this editor returns to.
    _invalidateNetworkRequest();
    Navigator.of(context).pop();
  }

  String? get _requestLimitProblem {
    final request = int.tryParse(_maxRequestChars.text.trim());
    return request == null || request < 8000 || request > 400000
        ? l10n.aiProviderRequestCharsRange
        : null;
  }

  String? get _outputLimitProblem {
    final output = int.tryParse(_maxOutputTokens.text.trim());
    return output == null || output < 512 || output > 65536
        ? l10n.aiProviderOutputTokensRange
        : null;
  }

  bool _validateCaps() {
    final requestError = _requestLimitProblem;
    final outputError = _outputLimitProblem;
    setState(() {
      _requestLimitError = requestError;
      _outputLimitError = outputError;
    });
    if (requestError == null && outputError == null) return true;
    // Only a field whose error is shown and whose value is still wrong is a
    // target: a value fixed meanwhile does not move the page, with both wrong
    // fixing the request limit moves on to the output one, and a limit broken
    // after the save (no error shown yet) does not take the reveal.
    bool requestShown() =>
        _requestLimitError != null && _requestLimitProblem != null;
    bool outputShown() =>
        _outputLimitError != null && _outputLimitProblem != null;
    _reveal(
      () => (requestShown() ? _requestLimitFieldKey : _outputLimitFieldKey)
          .currentContext,
      inAdvanced: true,
      stillNeeded: () => requestShown() || outputShown(),
    );
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

  List<AiTokenLimitField> get _tokenLimitFields => switch (_format) {
    AiFormat.chatCompletions => const <AiTokenLimitField>[
      AiTokenLimitField.maxTokens,
      AiTokenLimitField.maxCompletionTokens,
    ],
    AiFormat.responses || AiFormat.onDevicePrompt => const <AiTokenLimitField>[
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

  List<AiPreset> get _availablePresets => [
    if (_onDeviceSupported || _preset.onDevice) AiPresets.onDevice,
    ..._presetMenuOrder,
  ];

  String _presetName(AiPreset preset) =>
      preset.onDevice ? l10n.aiPresetOnDeviceName : preset.name;

  String _presetDescription(AiPreset preset) => switch (preset.id) {
    'on-device' => l10n.aiOnDeviceCapabilitiesNote,
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

  Widget _buildOnDeviceSection() {
    final hasConsent = _hasOnDeviceConsent;
    final status = _onDeviceStatus;
    final progressValue =
        (_bytesToDownload != null &&
            _bytesToDownload! > 0 &&
            _bytesDownloaded != null)
        ? (_bytesDownloaded! / _bytesToDownload!).clamp(0.0, 1.0)
        : null;
    return DecoratedBox(
      key: const ValueKey('ai-on-device-section'),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusLine(
              icon: Icons.smartphone_outlined,
              label: l10n.aiPresetOnDeviceName,
              explanation: l10n.aiOnDeviceCapabilitiesNote,
            ),
            const SizedBox(height: 12),
            if (!hasConsent) ...[
              Text(
                l10n.aiOnDeviceConsentBeforeStatus,
                key: const ValueKey('ai-on-device-consent-required'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const ValueKey('ai-on-device-review-consent'),
                onPressed: _saving ? null : _reviewOnDeviceConsent,
                icon: const Icon(Icons.privacy_tip_outlined),
                label: Text(l10n.aiOnDeviceReviewConsentAction),
              ),
            ] else if (_checkingOnDeviceStatus && status == null) ...[
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: CircularProgressIndicator(),
                ),
              ),
            ] else if (status != null) ...[
              switch (status.availability) {
                OnDeviceAvailability.available => _StatusLine(
                  icon: Icons.check_circle_outline,
                  label: l10n.aiOnDeviceStatusAvailable,
                  explanation:
                      status.modelName != null && status.modelName!.isNotEmpty
                      ? isolated(status.modelName!)
                      : null,
                ),
                OnDeviceAvailability.downloadable => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatusLine(
                      icon: Icons.download_for_offline_outlined,
                      label: l10n.aiOnDeviceStatusDownloadable,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      key: const ValueKey('ai-on-device-download'),
                      onPressed: _downloadingOnDevice || _saving
                          ? null
                          : _startOnDeviceDownload,
                      icon: const Icon(Icons.download),
                      label: Text(l10n.aiOnDeviceDownloadButton),
                    ),
                  ],
                ),
                OnDeviceAvailability.downloading => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatusLine(
                      icon: Icons.downloading,
                      label: l10n.aiOnDeviceStatusDownloading,
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      key: const ValueKey('ai-on-device-download-progress'),
                      value: progressValue,
                    ),
                    if (_bytesDownloaded != null &&
                        _bytesToDownload != null &&
                        _bytesToDownload! > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        l10n.aiOnDeviceDownloadProgress(
                          _formatMb(_bytesDownloaded!),
                          _formatMb(_bytesToDownload!),
                        ),
                        key: const ValueKey(
                          'ai-on-device-download-progress-text',
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
                OnDeviceAvailability.unavailable => _StatusLine(
                  icon: Icons.error_outline,
                  label: l10n.aiOnDeviceStatusUnavailable,
                  explanation: _unavailableReasonText(status.reason),
                ),
              },
              // Leaving the editor cancels the download.
              if (status.isDownloadable || status.isDownloading) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.aiOnDeviceDownloadKeepOpen,
                  key: const ValueKey('ai-on-device-download-keep-open'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_onDeviceDownloadError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _onDeviceDownloadError!,
                  key: const ValueKey('ai-on-device-download-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

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
    AiFormat.onDevicePrompt => AiPresets.onDevice.name,
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
      AiDataUse.noTraining || AiDataUse.onDevice => (
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
    // The editor tests network providers only; on-device has no endpoint.
    AiFormat.onDevicePrompt => throw const AiFailure(
      AiFailureKind.policyBlocked,
    ),
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
    appVersion: aiClientAppVersion,
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

/// The read model catalogue as a list to pick from, searchable when long.
/// The current model comes first. Pops the chosen model ID.
class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({
    required this.models,
    required this.current,
    required this.catalogueEmpty,
  });
  final List<String> models;
  final String current;
  // The endpoint listed nothing, as opposed to nothing for this format.
  final bool catalogueEmpty;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final _search = TextEditingController();
  // Keeps the search field (its focus and input connection) through any
  // relayout, such as the keyboard appearing.
  final _searchField = GlobalKey();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final query = _search.text.trim().toLowerCase();
    final models = query.isEmpty
        ? [
            if (widget.models.contains(widget.current)) widget.current,
            for (final model in widget.models)
              if (model != widget.current) model,
          ]
        : widget.models
              .where((model) => model.toLowerCase().contains(query))
              .toList(growable: false);
    // A handful of models fit on screen; a search field would only add noise.
    final searchable = widget.models.length > 6;
    final keyboard = media.viewInsets.bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The constraints already leave out the status bar (useSafeArea) and
        // the drag handle. Short windows (the keyboard up, landscape, split
        // screen) use all the room that is left above the keyboard.
        final room = math.max(0.0, constraints.maxHeight - keyboard);
        final short = keyboard > 0 || room * 0.7 < 360;
        final height = short ? room : room * 0.7;
        // One shape whatever the size: a header that scrolls on its own when
        // it does not fit its share (large text, long languages, landscape)
        // above the list, so nothing overflows and nothing is rebuilt.
        return Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: SizedBox(
            height: height,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: height * 0.6),
                  child: SingleChildScrollView(
                    key: const ValueKey('ai-provider-model-picker-header'),
                    // The list below is the sheet's primary scroll view.
                    primary: false,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.aiProviderModelPickerTitle,
                          style: theme.textTheme.titleMedium,
                        ),
                        // Search before the hint: a long hint in large text
                        // must not push the field out of the header's view.
                        if (searchable) ...[
                          const SizedBox(height: 12),
                          KeyedSubtree(
                            key: _searchField,
                            child: TextField(
                              key: const ValueKey('ai-provider-model-search'),
                              controller: _search,
                              autocorrect: false,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                labelText: l10n.aiProviderSearchModels,
                                prefixIcon: const Icon(Icons.search),
                              ),
                            ),
                          ),
                        ],
                        if (!short) ...[
                          const SizedBox(height: 8),
                          Text(l10n.aiProviderModelPickerHint, style: muted),
                        ],
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: models.isEmpty
                      // Scrolls, so a short window still shows all of it.
                      ? SingleChildScrollView(
                          key: const ValueKey('ai-provider-model-picker-empty'),
                          // Clear of the navigation bar, like the list.
                          padding: EdgeInsets.fromLTRB(
                            16,
                            16,
                            16,
                            16 + media.padding.bottom,
                          ),
                          child: Text(
                            widget.catalogueEmpty
                                ? l10n.aiProviderModelPickerNone
                                : l10n.aiProviderModelPickerEmpty,
                            style: muted,
                          ),
                        )
                      : ListView.builder(
                          key: const ValueKey('ai-provider-model-picker'),
                          // Clear of the system navigation bar when the
                          // keyboard is down.
                          padding: EdgeInsets.only(
                            bottom: 16 + media.padding.bottom,
                          ),
                          itemCount: models.length,
                          itemBuilder: (context, index) {
                            final model = models[index];
                            final selected = model == widget.current;
                            return ListTile(
                              key: ValueKey('ai-provider-model-option-$model'),
                              dense: true,
                              selected: selected,
                              title: Text(isolated(model)),
                              trailing: selected
                                  ? const Icon(Icons.check)
                                  : null,
                              onTap: () => Navigator.of(context).pop(model),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
