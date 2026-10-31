import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../../shared/skeleton.dart';
import '../../shared/workspace_ui.dart';
import '../security/app_lock.dart';
import 'ai_chat_controller.dart';
import 'ai_consent_dialog.dart';
import 'ai_history.dart';
import 'ai_provider_editor.dart';
import 'ai_settings_failure.dart';
import 'ai_stores.dart';
import 'ai_write_journal.dart';
import 'ai_write_log_page.dart';
import 'ai_write_settings.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({
    super.key,
    required this.settings,
    required this.accountKey,
    this.account,
    this.api,
    this.isAccountRetained,
    this.history,
    this.deviceCheck,
    this.writeJournal,
  });

  final AiSettingsController settings;
  final String accountKey;
  final Account? account;

  /// [account]'s GitLab client, for re-reading interrupted writes.
  final GitLabApi? api;
  final bool Function(String accountKey)? isAccountRetained;
  final AiHistoryCoordinator? history;

  /// The device check that turning on "allow everything" requires, the same
  /// one the app lock uses; replaced in tests.
  final AppLockAuthenticator? deviceCheck;

  /// The account's AI change log; replaced in tests.
  final AiWriteJournal? writeJournal;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  AiHistoryCoordinator get _history =>
      widget.history ?? AiHistoryCoordinator.instance;
  bool _loading = true;
  bool _firstLoadDone = false;
  bool _failed = false;
  Object? _loadFailure;
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
    if (_capFocus.hasFocus) {
      final cap = _parseCap(_cap.text);
      if (cap != null) _cap.text = '$cap';
    } else {
      _saveCap();
      _formatCap();
    }
  }

  int? _parseCap(String value) {
    const arabicDigits = '٠١٢٣٤٥٦٧٨٩';
    const easternArabicDigits = '۰۱۲۳۴۵۶۷۸۹';
    final normalized = StringBuffer();
    const groupingCharacters = <String>{
      ',',
      '.',
      "'",
      '’',
      ' ',
      '\u00a0',
      '\u202f',
      '\u066c',
    };
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      if (rune >= 0x30 && rune <= 0x39) {
        normalized.write(character);
      } else if (arabicDigits.contains(character)) {
        normalized.write(arabicDigits.indexOf(character));
      } else if (easternArabicDigits.contains(character)) {
        normalized.write(easternArabicDigits.indexOf(character));
      } else if (!groupingCharacters.contains(character)) {
        return null;
      }
    }
    return int.tryParse(normalized.toString());
  }

  void _formatCap() {
    if (!mounted || _capFocus.hasFocus) return;
    final cap = _parseCap(_cap.text);
    if (cap != null) {
      _cap.text = MaterialLocalizations.of(context).formatDecimal(cap);
    }
  }

  bool _canSetCeiling(AiAutonomyLevel level) {
    final current =
        widget.settings.accountRecord(widget.accountKey) ?? AiAccountRecord();
    final historyReadable = {
      AiHistoryState.ready,
      AiHistoryState.disabled,
    }.contains(_history.state(widget.accountKey));
    return historyReadable || level.index <= current.ceiling.index;
  }

  Future<void> _setCeiling(AiAutonomyLevel level) async {
    if (!_canSetCeiling(level)) return;
    final account = widget.account;
    if (level == AiAutonomyLevel.bypass) {
      // Only for a known account, on this page, after the username and the
      // device check (plan v6 §4.2).
      if (account == null) return;
      final allowed = await confirmAiBypass(
        context,
        account: account,
        deviceCheck: widget.deviceCheck ?? LocalAuthAuthenticator(),
      );
      if (!allowed || !mounted) return;
    }
    await _act(() async {
      if (!_canSetCeiling(level)) return;
      await widget.settings.setAutonomySettings(
        widget.accountKey,
        ceiling: level,
      );
    });
  }

  void _saveCap() {
    final cap = _parseCap(_cap.text);
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
      _firstLoadDone = false;
      _loading = true;
      _failed = false;
      _loadFailure = null;
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
          _loadFailure = null;
          _firstLoadDone = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _formatCap());
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _failed = true;
          _loadFailure = error;
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
    } catch (error) {
      if (mounted && generation == _generation) {
        showAiSettingsFailure(context, error);
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

  Future<void> _resetProviders() async {
    final generation = _generation;
    final confirmed = await confirmAction(
      context,
      l10n.aiResetProviders,
      l10n.aiResetProvidersDetail,
    );
    if (!confirmed || !mounted || generation != _generation) return;
    setState(() => _loading = true);
    try {
      await widget.settings.resetProviders();
      await _load();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _failed = true;
          _loadFailure = error;
        });
      }
    }
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

  Future<void> _setRetention(int currentDays, int days) async {
    if (days < currentDays) {
      final generation = _generation;
      final confirmed = await confirmAction(
        context,
        l10n.aiShortenRetention,
        l10n.aiShortenRetentionDetail,
      );
      if (!confirmed || !mounted || generation != _generation) return;
    }
    await _act(() => _history.setRetention(widget.accountKey, days));
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
            tooltip: l10n.aiProviderActions,
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
                  if (provider.caps.requiresKey)
                    _status(
                      widget.settings.knownProviderKeys.containsKey(provider.id)
                          ? Icons.key
                          : Icons.key_off_outlined,
                      widget.settings.knownProviderKeys.containsKey(provider.id)
                          ? l10n.aiProviderKeySet
                          : l10n.aiProviderKeyNotSet,
                      warning:
                          provider.caps.requiresKey &&
                          !widget.settings.knownProviderKeys.containsKey(
                            provider.id,
                          ),
                    ),
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
    // A clear that did not finish (also after a restart) says so plainly,
    // and its action continues the clear rather than a generic retry.
    final clearUnfinished =
        state == AiHistoryState.readFailed &&
        _history.failure(widget.accountKey)?.operation == 'clearHistory';
    // Uncertain AI writes hold the removal: only the account list's named
    // removal can release them, so a retry here would fail again.
    final journalBlocked =
        state == AiHistoryState.cleaning &&
        _history.journalCleanupBlock(widget.accountKey) != null;
    final text = journalBlocked
        ? l10n.aiRemoveRetryFromAccountList
        : state == AiHistoryState.cleaning
        ? l10n.aiHistoryCleaning
        : clearUnfinished
        ? l10n.aiHistoryClearUnfinished
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
              icon: Icon(
                clearUnfinished ? Icons.delete_sweep_outlined : Icons.refresh,
              ),
              label: Text(
                clearUnfinished
                    ? l10n.aiHistoryContinueClear
                    : l10n.retryAction,
              ),
            ),
          if (state == AiHistoryState.cleaning && !journalBlocked)
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _act(() async {
                      final generation = _generation;
                      final accountKey = widget.accountKey;
                      final isAccountRetained = widget.isAccountRetained;
                      await _history.retryCleanup(
                        accountKey,
                        // Without the session's account list, keep the fence
                        // closed rather than reopen it for a removed account.
                        isRetained: () =>
                            isAccountRetained?.call(accountKey) ?? false,
                      );
                      if (mounted && generation == _generation) {
                        await widget.settings.loadAccount(accountKey);
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
    final accountIdentity = widget.account;
    return HubSection(
      title: l10n.aiCurrentAccount,
      children: [
        if (accountIdentity != null)
          ListTile(
            leading: Monogram(
              accountIdentity.user.name,
              size: 40,
              circle: true,
            ),
            title: Text(isolated(accountIdentity.user.name)),
            subtitle: Text(
              '${isolated('@${accountIdentity.user.username}')} · '
              '${isolated(accountIdentity.instance.base.host)}',
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
          _consentRow(consent.key, consent.value),
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
                onChanged: editable && account.historyEnabled
                    ? (days) {
                        if (days != null) {
                          unawaited(_setRetention(account.retentionDays, days));
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
                  errorMaxLines: 20,
                  suffixText: l10n.aiTokenUnit,
                  suffixIcon: IconButton(
                    tooltip: l10n.saveAction,
                    onPressed: editable ? _saveCap : null,
                    icon: const Icon(Icons.check),
                  ),
                ),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: (value) {
                  final cap = _parseCap(value ?? '');
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
                  l10n.aiWorstCaseUsageForProvider(
                    isolated(provider.name),
                    MaterialLocalizations.of(
                      context,
                    ).formatDecimal(6 * provider.caps.maxRequestChars),
                  ),
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

  /// The account's AI change log on this device. Interrupted changes are
  /// counted from what the journal already holds in memory.
  AiWriteJournal get _journal =>
      widget.writeJournal ?? AiWriteJournal.instance;

  Widget _writeLogTile(Account account) {
    final interrupted = _journal
        .entries(account.key)
        .where((entry) => entry.state == AiJournalState.writeUncertain)
        .length;
    // Start-up recovery could not read the log: there may be interrupted
    // changes the app cannot list, and writes stay refused until a retry or
    // a reset on the log page.
    final unreadable = switch (_journal.recoveryStatus(account.key)) {
      AiJournalKeyStatus.unavailable ||
      AiJournalKeyStatus.keyMissing ||
      AiJournalKeyStatus.unknownFormat ||
      AiJournalKeyStatus.overSize => true,
      _ => false,
    };
    final attention = unreadable || interrupted > 0;
    final theme = Theme.of(context);
    return ListTile(
      key: const ValueKey('ai-write-log'),
      leading: Icon(
        unreadable
            ? Icons.error_outline
            : interrupted > 0
            ? Icons.help_outline
            : Icons.history,
        color: unreadable
            ? theme.colorScheme.error
            : interrupted > 0
            ? HubColors.orange
            : null,
      ),
      title: Text(l10n.aiWriteLogTitle),
      subtitle: Text(
        unreadable
            ? l10n.aiWriteLogUnreadableShort
            : interrupted > 0
            ? l10n.aiWriteLogNeedsAttention('$interrupted')
            : l10n.aiWriteLogSubtitle,
        style: attention ? TextStyle(color: theme.colorScheme.error) : null,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AiWriteLogPage(
              account: account,
              journal: _journal,
              api: widget.api,
            ),
          ),
        );
        if (mounted) setState(() {});
      },
    );
  }

  Widget _writeSection() {
    final record =
        widget.settings.accountRecord(widget.accountKey) ?? AiAccountRecord();
    final editable =
        !_busy &&
        {
          AiHistoryState.ready,
          AiHistoryState.disabled,
        }.contains(_history.state(widget.accountKey));
    return AiWriteSettingsSection(
      record: record,
      enabled: editable,
      ceilingEnabled:
          !_busy && (editable || record.ceiling != AiAutonomyLevel.readOnly),
      onCeiling: (level) => unawaited(_setCeiling(level)),
      onStartingLevel: (level) => unawaited(
        _act(
          () => widget.settings.setAutonomySettings(
            widget.accountKey,
            startingLevel: level,
          ),
        ),
      ),
      onAttribution: (value) => unawaited(
        _act(
          () => widget.settings.setAutonomySettings(
            widget.accountKey,
            aiAttribution: value,
          ),
        ),
      ),
    );
  }

  Widget _consentRow(String providerId, AiConsentRecord consent) {
    final provider = widget.settings.providers
        .where((candidate) => candidate.id == providerId)
        .firstOrNull;
    // The same contract a conversation asks for, so a write consent is not
    // flagged against the read-only contract.
    final needsReconsent =
        provider == null ||
        !widget.settings.isValid(
          widget.accountKey,
          aiConversationConsentContract(
            widget.settings,
            widget.accountKey,
            provider,
          ),
        );
    return HubRow(
      leading: NeutralTile(
        needsReconsent
            ? Icons.warning_amber_outlined
            : Icons.verified_user_outlined,
      ),
      title: isolated(provider?.name ?? providerId),
      subtitle: needsReconsent ? l10n.aiConsentNeedsReconsent : null,
      onTap: () => showAiConsentRecordDialog(context, consent),
      trailing: IconButton(
        tooltip: l10n.aiRevokeConsent,
        onPressed: _busy ? null : () => _revoke(providerId),
        icon: const Icon(Icons.remove_circle_outline),
      ),
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
          if (_loading && !_firstLoadDone) return const SettingsSkeleton();
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
                        setState(() {
                          _loading = true;
                          _failed = false;
                        });
                        unawaited(_load());
                      },
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.retryAction),
                    ),
                    if (_loadFailure is AiStoreException &&
                        (_loadFailure! as AiStoreException).failure.kind ==
                            AiStoreFailureKind.malformed)
                      TextButton.icon(
                        onPressed: _resetProviders,
                        icon: const Icon(Icons.restart_alt),
                        label: Text(l10n.aiResetProviders),
                      ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            children: [
              if (_loading && _firstLoadDone)
                const LinearProgressIndicator(minHeight: 2),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  l10n.aiSettingsIntro,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
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
              _writeSection(),
              if (widget.account case final account?) _writeLogTile(account),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l10n.aiWritePromise),
              ),
            ],
          );
        },
      ),
    ),
  );
}
