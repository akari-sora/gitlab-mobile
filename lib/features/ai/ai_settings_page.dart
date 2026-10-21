import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../../shared/workspace_ui.dart';
import 'ai_consent_dialog.dart';
import 'ai_history.dart';
import 'ai_provider_editor.dart';
import 'ai_stores.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({
    super.key,
    required this.settings,
    required this.accountKey,
    this.history,
  });

  final AiSettingsController settings;
  final String accountKey;
  final AiHistoryCoordinator? history;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  AiHistoryCoordinator get _history =>
      widget.history ?? AiHistoryCoordinator.instance;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  int _generation = 0;
  final _cap = TextEditingController();
  final _capFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _capFocus.addListener(_capFocusChanged);
    unawaited(_load());
  }

  void _capFocusChanged() {
    if (!_capFocus.hasFocus) _saveCap();
  }

  void _saveCap() {
    final cap = int.tryParse(_cap.text);
    final editable = {
      AiHistoryState.ready,
      AiHistoryState.disabled,
    }.contains(_history.state(widget.accountKey));
    if (_loading ||
        _busy ||
        !editable ||
        cap == null ||
        cap < 50000 ||
        cap > 5000000) {
      return;
    }
    final settings = widget.settings;
    final account = widget.accountKey;
    if (settings.accountRecord(account)?.conversationTokenCap == cap) return;
    unawaited(_act(() => settings.setConversationTokenCap(account, cap)));
  }

  @override
  void dispose() {
    _capFocus.removeListener(_capFocusChanged);
    _capFocus.dispose();
    _cap.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AiSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountKey != widget.accountKey ||
        !identical(oldWidget.settings, widget.settings) ||
        !identical(oldWidget.history, widget.history)) {
      _loading = true;
      _failed = false;
      _busy = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final settings = widget.settings;
    final history = _history;
    final account = widget.accountKey;
    try {
      await settings.initialize();
      await history.load(account);
      await settings.loadAccount(account);
      if (mounted && generation == _generation) {
        _cap.text =
            '${settings.accountRecord(account)?.conversationTokenCap ?? 500000}';
        setState(() {
          _loading = false;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    final generation = _generation;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted && generation == _generation) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.aiSettingsSaveFailure)));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _edit([AiProviderConfig? provider]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AiProviderEditor(settings: widget.settings, provider: provider),
      ),
    );
  }

  Future<void> _delete(AiProviderConfig provider) async {
    final settings = widget.settings;
    final generation = _generation;
    final confirmed = await confirmAction(
      context,
      l10n.aiDeleteProvider,
      l10n.aiDeleteProviderDetail,
    );
    if (!confirmed || !mounted || generation != _generation) return;
    await _act(() => settings.deleteProvider(provider.id));
  }

  Future<void> _revoke(String providerId) async {
    final settings = widget.settings;
    final account = widget.accountKey;
    final generation = _generation;
    final confirmed = await confirmAction(
      context,
      l10n.aiRevokeConsent,
      l10n.aiRevokeConsentDetail,
    );
    if (!confirmed || !mounted || generation != _generation) return;
    await _act(() => settings.revokeConsent(account, providerId));
  }

  Future<void> _clearHistory() async {
    final generation = _generation;
    final history = _history;
    final account = widget.accountKey;
    final confirmed = await confirmAction(
      context,
      l10n.aiClearHistory,
      l10n.aiClearHistoryDetail,
    );
    if (!confirmed || !mounted || generation != _generation) return;
    final settings = widget.settings;
    await _act(() async {
      await history.clearHistory(account);
      await settings.loadAccount(account);
    });
  }

  String _format(AiFormat format) => switch (format) {
    AiFormat.chatCompletions => l10n.aiProviderFormatChat,
    AiFormat.responses => l10n.aiProviderFormatResponses,
    AiFormat.anthropicMessages => l10n.aiProviderFormatAnthropic,
  };

  Widget _provider(AiProviderConfig provider, bool isDefault) {
    final preset = AiPresets.all
        .where((p) => p.id == provider.presetId)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HubRow(
          key: ValueKey('ai-provider-${provider.id}'),
          leading: const IconTile(Icons.auto_awesome, color: HubColors.purple),
          title: isolated(provider.name),
          subtitle: isDefault ? l10n.aiDefaultProvider : null,
          onTap: _busy ? null : () => _edit(provider),
          trailing: PopupMenuButton<String>(
            enabled: !_busy,
            tooltip: l10n.editAction,
            onSelected: (action) {
              switch (action) {
                case 'edit':
                  _edit(provider);
                case 'default':
                  unawaited(
                    _act(() => widget.settings.setDefaultProvider(provider.id)),
                  );
                case 'delete':
                  unawaited(_delete(provider));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'edit', child: Text(l10n.editAction)),
              if (!isDefault)
                PopupMenuItem(
                  value: 'default',
                  child: Text(l10n.aiMakeDefault),
                ),
              PopupMenuItem(
                value: 'delete',
                child: Text(l10n.aiDeleteProvider),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(64, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${isolated(preset?.name ?? provider.presetId)} · ${_format(provider.format)}',
              ),
              Text(isolated(provider.model)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _status(Icons.info_outline, l10n.aiProviderUnverifiedLabel),
                  if (provider.allowLanCleartext &&
                      Uri.tryParse(provider.baseUrl)?.scheme == 'http')
                    _status(
                      Icons.no_encryption_outlined,
                      l10n.aiConsentUnencrypted,
                      warning: true,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _status(IconData icon, String text, {bool warning = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 18,
          color: warning ? scheme.error : scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: warning ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _historyStatus(AiHistoryState state) {
    final notice = _history.notice(widget.accountKey);
    final text = state == AiHistoryState.cleaning
        ? l10n.aiHistoryCleaning
        : notice;
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _status(Icons.info_outline, text, warning: true),
          if (state == AiHistoryState.unavailable ||
              state == AiHistoryState.readFailed)
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : state == AiHistoryState.readFailed &&
                        _history.failure(widget.accountKey)?.operation ==
                            'clearHistory'
                  ? _clearHistory
                  : () => _act(() async {
                      if (state == AiHistoryState.unavailable) {
                        await _history.onResume();
                        await widget.settings.loadAccount(widget.accountKey);
                      } else {
                        await _history.read(widget.accountKey);
                      }
                    }),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.retryAction),
            ),
          if (state == AiHistoryState.cleaning)
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _act(() async {
                      final generation = _generation;
                      await _history.retryCleanup(
                        widget.accountKey,
                        isRetained: () => mounted && generation == _generation,
                      );
                      if (mounted && generation == _generation) {
                        await widget.settings.loadAccount(widget.accountKey);
                      }
                    }),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.aiHistoryRetryCleanup),
            ),
        ],
      ),
    );
  }

  Widget _accountSection() {
    final account =
        widget.settings.accountRecord(widget.accountKey) ?? AiAccountRecord();
    final state = _history.state(widget.accountKey);
    final editable =
        !_busy &&
        {AiHistoryState.ready, AiHistoryState.disabled}.contains(state);
    return HubSection(
      title: l10n.aiCurrentAccount,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            isolated(widget.accountKey),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            l10n.aiConsentsHeading,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (account.consents.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.aiNoConsents),
          ),
        for (final consent in account.consents.entries)
          HubRow(
            leading: const NeutralTile(Icons.verified_user_outlined),
            title: isolated(
              widget.settings.providers
                      .where((p) => p.id == consent.key)
                      .firstOrNull
                      ?.name ??
                  consent.key,
            ),
            onTap: () => showAiConsentRecordDialog(context, consent.value),
            trailing: IconButton(
              tooltip: l10n.aiRevokeConsent,
              onPressed: _busy ? null : () => _revoke(consent.key),
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ),
        SwitchListTile.adaptive(
          key: const ValueKey('ai-history-switch'),
          title: Text(l10n.aiEncryptedHistory),
          value: account.historyEnabled,
          onChanged: editable
              ? (enabled) => _act(() async {
                  if (enabled) {
                    await _history.enable(widget.accountKey);
                  } else {
                    await _history.disable(widget.accountKey);
                  }
                })
              : null,
        ),
        _historyStatus(state),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int>(
                key: ValueKey('ai-retention-${account.retentionDays}'),
                initialValue: account.retentionDays,
                isExpanded: true,
                decoration: InputDecoration(labelText: l10n.aiHistoryRetention),
                items: [
                  DropdownMenuItem(
                    value: 7,
                    child: Text(l10n.aiHistorySevenDays),
                  ),
                  DropdownMenuItem(
                    value: 30,
                    child: Text(l10n.aiHistoryThirtyDays),
                  ),
                  DropdownMenuItem(
                    value: 90,
                    child: Text(l10n.aiHistoryNinetyDays),
                  ),
                ],
                onChanged: editable
                    ? (days) {
                        if (days != null) {
                          unawaited(
                            _act(
                              () => _history.setRetention(
                                widget.accountKey,
                                days,
                              ),
                            ),
                          );
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 20),
              TextFormField(
                key: ValueKey('ai-token-cap-${widget.accountKey}'),
                controller: _cap,
                focusNode: _capFocus,
                enabled: editable,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l10n.aiConversationTokenCap,
                  suffixIcon: IconButton(
                    tooltip: l10n.saveAction,
                    onPressed: editable ? _saveCap : null,
                    icon: const Icon(Icons.check),
                  ),
                ),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: (value) {
                  final cap = int.tryParse(value ?? '');
                  return cap == null || cap < 50000 || cap > 5000000
                      ? l10n.aiConversationCapHelp
                      : null;
                },
                onFieldSubmitted: (_) => _saveCap(),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.aiConversationCapHelp,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(l10n.aiWorstCaseUsage),
              for (final provider in widget.settings.providers)
                Text(
                  '${isolated(provider.name)} · ${6 * provider.caps.maxRequestChars}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed:
                    _busy ||
                        state == AiHistoryState.unavailable ||
                        state == AiHistoryState.cleaning
                    ? null
                    : _clearHistory,
                icon: const Icon(Icons.delete_outline),
                label: Text(l10n.aiClearHistory),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(l10n.aiAssistantLabel)),
    body: SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: Listenable.merge([widget.settings, _history]),
        builder: (context, _) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_failed) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline),
                    const SizedBox(height: 12),
                    Text(l10n.aiSettingsReadFailure),
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _loading = true);
                        unawaited(_load());
                      },
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.retryAction),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            children: [
              HubSection(
                title: l10n.aiProvidersHeading,
                children: [
                  for (var i = 0; i < widget.settings.providers.length; i++)
                    _provider(widget.settings.providers[i], i == 0),
                  if (widget.settings.providers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(l10n.aiNotConfigured),
                    ),
                  HubRow(
                    leading: const IconTile(Icons.add, color: HubColors.blue),
                    title: l10n.aiAddProvider,
                    onTap: _busy ? null : _edit,
                    chevron: true,
                  ),
                ],
              ),
              _accountSection(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l10n.aiReadOnlyPromise),
              ),
            ],
          );
        },
      ),
    ),
  );
}
