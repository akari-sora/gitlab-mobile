import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/ai/ai_display.dart';
import '../../core/ai/ai_endpoint.dart';
import '../../core/ai/ai_events.dart';
import '../../core/ai/ai_failure.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/ai_transport.dart';
import '../../core/ai/ai_transcript.dart';
import '../../core/ai/ai_wire_client.dart';
import '../../core/ai/prompts.dart';
import '../../core/ai/redaction.dart';
import '../../core/ai/runner.dart';
import '../../core/ai/tools/gitlab_read_port.dart';
import '../../core/ai/tools/tool_catalogue.dart';
import '../../core/ai/wire/anthropic_messages.dart';
import '../../core/ai/wire/chat_completions.dart';
import '../../core/ai/wire/responses.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../auth/session_controller.dart';
import 'ai_chat_context.dart';
import 'ai_chat_session.dart';
import 'ai_history.dart';
import 'ai_runner_binding.dart';
import 'ai_secrets.dart';
import 'ai_stores.dart';

typedef AiChatWireClientFactory =
    AiWireClient Function({
      required AiProviderConfig config,
      required String? apiKey,
      required String conversationId,
    });

/// Owns a conversation independently of its route. Only display models escape
/// this owner; provider replay and transports stay in the existing runner.
class AiChatController extends ChangeNotifier implements AiChatSession {
  AiChatController({
    required this.origin,
    required this.session,
    required this.settings,
    required this.runningCount,
    AiChatWireClientFactory? wireClientFactory,
    Future<void> Function()? refreshSecrets,
  }) : _wireClientFactory = wireClientFactory ?? _createWireClient,
       _generation = session.generation,
       _api = session.api!,
       _accountKey = session.active!.key {
    _secrets = KnownSecretsLive(
      session,
      settings,
      readGitLabCredential: () => _api.credential,
    );
    _redactor = Redactor(secrets: _secrets);
    _refreshSecrets = () async {
      await _secrets.refresh();
      if (refreshSecrets != null) {
        await refreshSecrets();
        await _secrets.refresh();
      }
      if (!_alive) return;
      // Patterns never change; only a larger secret set needs a new pass over
      // what is shown, which can hold whole files and long replies.
      if (_secrets.revision == _displayRevision) return;
      try {
        // The pass re-redacts the chips too; _settleChips sets the run's
        // final ones.
        _redactDisplay();
      } finally {
        if (_assistantIndex != null) _notifyStream();
      }
    };
    _historyState = _history.state(_accountKey);
    _history.addListener(_historyChanged);
    settings.addListener(_settingsChanged);
    session.addListener(_sessionChanged);
    unawaited(recheck());
  }

  @override
  final AiChatOrigin origin;
  final SessionController session;
  final AiSettingsController settings;
  final int Function() runningCount;
  final AiChatWireClientFactory _wireClientFactory;
  final int _generation;
  final GitLabApi _api;
  final String _accountKey;
  late final KnownSecretsLive _secrets;
  late final Redactor _redactor;
  late final Future<void> Function() _refreshSecrets;

  /// The secret-set revision the display was last redacted with.
  int _displayRevision = -1;
  String _id = _newId();
  String? _chosenProvider;
  AiProviderConfig? _provider;
  AiConsentContract? _contract;
  AiChatContext? _context;
  Future<AiAccountRecord>? _accountRead;
  bool _accountLoaded = false;
  AiRunner? _runner;
  AiRunnerBinding? _binding;
  final List<AiChatItem> _items = [];
  final Expando<AiChatItem> _successors = Expando<AiChatItem>();
  final AiHistoryCoordinator _history = AiHistoryCoordinator.instance;
  final Map<String, AiSavedConversation> _pendingReportedHistory = {};
  final Set<String> _blockedReportedHistory = {};
  late AiHistoryState _historyState;
  AiSavedConversation? _latestReportedSnapshot;
  AiSavedConversation? _savedReportedSnapshot;
  bool _reportNotSaved = false;
  bool _historySaving = false;
  int _historySnapshotRevision = 0;
  Timer? _historyRetry;
  // One initial flush and at most three retries per snapshot/state revision.
  int _historyRetryAttempts = 0;
  final List<({String id, int index})> _pendingTools = [];
  AiChatPhase _phase = AiChatPhase.preparing;
  AiChatBlocker _blocker = AiChatBlocker.settingsLoading;
  UserFacingFailure? _failure;
  bool _contextFailed = false;
  bool _displayFailed = false;
  bool _offerNewConversation = false;
  AiRunEnd? _lastEnd;
  bool _disposed = false;
  bool _transportClosed = false;
  bool _settingsChangedDuringRun = false;
  int _epoch = 0;
  int? _assistantIndex;
  AiUsage? _usage;
  Timer? _streamNotification;
  Future<bool> Function()? _confirmCleartext;

  bool get _alive =>
      !_disposed &&
      session.generation == _generation &&
      identical(session.api, _api) &&
      !_api.isClosed &&
      session.active?.key == _accountKey;
  bool _current(int epoch) => _alive && epoch == _epoch;

  @override
  String get id => _id;
  @override
  List<AiChatItem> get items => List.unmodifiable(_items);
  @override
  AiChatPhase get phase => _phase;
  @override
  AiChatBlocker get blocker {
    if (_phase == AiChatPhase.idle &&
        (_blocker == AiChatBlocker.none ||
            _blocker == AiChatBlocker.tooManyRunning)) {
      return runningCount() >= AiRunRegistry.maxRunning
          ? AiChatBlocker.tooManyRunning
          : AiChatBlocker.none;
    }
    return _blocker;
  }

  /// The registry calls this when shared capacity changes, for idle pages.
  void notifyCapacityChanged() {
    if (_phase == AiChatPhase.idle) _notify();
  }

  @override
  List<AiProviderConfig> get providers => settings.providers;
  @override
  AiProviderConfig? get provider => _provider;
  @override
  AiConsentContract? get consentRequest =>
      _blocker == AiChatBlocker.consentRequired ? _contract : null;
  @override
  UserFacingFailure? get failure => _failure;
  @override
  bool get offerNewConversation => _offerNewConversation;

  @override
  AiRunEnd? get lastEnd => _lastEnd;
  @override
  bool get historySaved =>
      settings.accountRecord(_accountKey)?.historyEnabled == true &&
      _history.state(_accountKey) == AiHistoryState.ready &&
      _savedReportedSnapshot != null &&
      identical(_savedReportedSnapshot, _latestReportedSnapshot) &&
      _savedReportedSnapshot!.id == _id &&
      listEquals(_savedReportedSnapshot!.conversation.items, _items) &&
      _savedReportedSnapshot!.stopReason == _lastEnd?.name;
  @override
  bool get reportNotSaved =>
      settings.accountRecord(_accountKey)?.historyEnabled == true &&
      _reportNotSaved &&
      _items.whereType<AiAssistantItem>().any((item) => item.reported);
  @override
  bool get canSend =>
      _alive &&
      _phase == AiChatPhase.idle &&
      blocker == AiChatBlocker.none &&
      _context != null &&
      runningCount() < AiRunRegistry.maxRunning;
  @override
  set confirmCleartext(Future<bool> Function()? callback) =>
      _confirmCleartext = callback;

  @override
  String displaySafe(String text) {
    try {
      return _redactor.redactSource(text.replaceAll(_displayControls, '')).text;
    } on Object {
      // Called while the page builds, so it must not throw; what cannot be
      // checked against the live secrets is not shown.
      return '';
    }
  }

  @override
  String draftSafe(String text) {
    try {
      // GitLab deletes every CR of a comment. Do it before redacting, so a
      // secret split by a CR is joined, and caught, here rather than later.
      final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '');
      return _redactor.redactSource(lines.replaceAll(_draftControls, '')).text;
    } on Object {
      return '';
    }
  }

  @override
  AiAssistantItem? currentOf(AiAssistantItem item) {
    if (!_alive) return null;
    AiChatItem current = item;
    for (
      var next = _successors[current];
      next != null;
      next = _successors[current]
    ) {
      current = next;
    }
    return current is AiAssistantItem && _items.contains(current)
        ? current
        : null;
  }

  void _replaceItem(int index, AiChatItem replacement) {
    final previous = _items[index];
    if (!identical(previous, replacement)) _successors[previous] = replacement;
    _items[index] = replacement;
  }

  @override
  void markReported(AiAssistantItem item) {
    final current = currentOf(item);
    if (current == null || current.reported) return;
    _replaceItem(
      _items.indexOf(current),
      AiAssistantItem(
        text: current.text,
        state: current.state,
        usage: current.usage,
        source: current.source,
        reported: true,
      ),
    );
    _saveReportedHistory();
    _notify();
  }

  void _saveReportedHistory() {
    if (!_alive ||
        settings.accountRecord(_accountKey)?.historyEnabled != true ||
        !_items.whereType<AiAssistantItem>().any((item) => item.reported)) {
      return;
    }
    final snapshot = AiSavedConversation(
      id: _id,
      updatedAt: DateTime.now().toUtc(),
      conversation: AiConversation(items: _items),
      stopReason: _lastEnd?.name,
    );
    _latestReportedSnapshot = snapshot;
    _pendingReportedHistory[_id] = snapshot;
    _blockedReportedHistory.remove(_id);
    _historySnapshotRevision++;
    _historyRetry?.cancel();
    _historyRetry = null;
    _historyRetryAttempts = 0;
    unawaited(_flushReportedHistory());
  }

  void _historyChanged() {
    final state = _history.state(_accountKey);
    final previous = _historyState;
    _historyState = state;
    if (state == AiHistoryState.disabled || state == AiHistoryState.cleaning) {
      _pendingReportedHistory.clear();
      _blockedReportedHistory.clear();
      _latestReportedSnapshot = null;
      _savedReportedSnapshot = null;
      _reportNotSaved = false;
      _historyRetry?.cancel();
      _historyRetry = null;
      _historyRetryAttempts = 0;
    } else if (state == AiHistoryState.ready && previous != state) {
      _blockedReportedHistory.clear();
      if (_historyRetry == null && !_historySaving) {
        _historyRetryAttempts = 0;
        unawaited(_flushReportedHistory());
      }
    }
    if (previous != state) _notify();
  }

  Future<void> _flushReportedHistory() async {
    if (!_alive ||
        _historySaving ||
        _historyRetry != null ||
        _historyRetryAttempts >= 4 ||
        !_pendingReportedHistory.keys.any(
          (id) => !_blockedReportedHistory.contains(id),
        )) {
      return;
    }
    _historySaving = true;
    _historyRetryAttempts++;
    final revision = _historySnapshotRevision;
    var retry = false;
    try {
      // Only display snapshots cross this boundary. The singleton's account
      // queue and cleanup epochs fence pending writes on account removal.
      for (final snapshot in _pendingReportedHistory.values.toList()) {
        if (!_alive) return;
        if (_blockedReportedHistory.contains(snapshot.id)) continue;
        final result = await _history.save(_accountKey, snapshot);
        if (!_alive) return;
        if (!identical(_pendingReportedHistory[snapshot.id], snapshot)) {
          continue;
        }
        if (result == AiHistorySaveResult.saved) {
          _pendingReportedHistory.remove(snapshot.id);
          if (snapshot.id == _id) {
            _savedReportedSnapshot = snapshot;
            _reportNotSaved = false;
          }
        } else if (result == AiHistorySaveResult.failed ||
            result == AiHistorySaveResult.cancelled) {
          retry = true;
          if (_historyRetryAttempts >= 4) {
            _blockedReportedHistory.add(snapshot.id);
            if (snapshot.id == _id) _reportNotSaved = true;
          }
        } else {
          // Capacity, unsupported data and eviction need a new snapshot or
          // a coordinator state transition, rather than a timer retry.
          _blockedReportedHistory.add(snapshot.id);
          if (snapshot.id == _id) _reportNotSaved = true;
        }
      }
    } finally {
      _historySaving = false;
      if (_alive) {
        _notify();
        // A newer redaction/report snapshot supersedes one being written.
        if (_pendingReportedHistory.isEmpty) {
          _historyRetry?.cancel();
          _historyRetry = null;
          _historyRetryAttempts = 0;
        } else if (revision != _historySnapshotRevision) {
          unawaited(_flushReportedHistory());
        } else if (retry &&
            _historyRetry == null &&
            _historyRetryAttempts < 4 &&
            (_history.state(_accountKey) == AiHistoryState.ready ||
                _history.state(_accountKey) == AiHistoryState.readFailed)) {
          // File failures leave the coordinator ready; unlike unavailable
          // keys they have no coordinator retry timer. Bound these retries.
          final seconds = const [1, 5, 30][_historyRetryAttempts - 1];
          _historyRetry = Timer(Duration(seconds: seconds), () {
            _historyRetry = null;
            unawaited(_flushReportedHistory());
          });
        }
      }
    }
  }

  void _notify() {
    _streamNotification?.cancel();
    _streamNotification = null;
    if (_alive) notifyListeners();
  }

  void _notifyStream() {
    if (!_alive || _streamNotification != null) return;
    _streamNotification = Timer(const Duration(milliseconds: 100), () {
      _streamNotification = null;
      if (_alive) notifyListeners();
    });
  }

  void _sessionChanged() {
    if (!_alive) dispose();
  }

  void _settingsChanged() {
    if (!_alive) return;
    // Loading the account publishes its record through the settings owner.
    // The pending recheck reads the latest providers after that load finishes.
    if (_accountRead != null) return;
    if (_phase == AiChatPhase.running || _phase == AiChatPhase.stopping) {
      _settingsChangedDuringRun = true;
      _runner?.checkNow();
      return;
    }
    unawaited(recheck());
  }

  @override
  Future<void> recheck() async {
    if (!_alive ||
        _phase == AiChatPhase.running ||
        _phase == AiChatPhase.stopping) {
      return;
    }
    final epoch = ++_epoch;
    if (_contextFailed) {
      _failure = null;
      _contextFailed = false;
    }
    _contract = null;
    // The page shows GitLab values (the title) through displaySafe before any
    // blocker is cleared, so learn the live secrets first.
    try {
      await _secrets.refresh();
    } on Object {
      if (!_current(epoch)) return;
      _setBlocked(AiChatBlocker.settingsUnavailable);
      return;
    }
    if (!_current(epoch)) return;
    // What is already shown follows the larger secret set too, whatever the
    // blocker turns out to be.
    try {
      _redactDisplayIfNeeded();
      unawaited(_flushReportedHistory());
    } on Object catch (error) {
      _failure = error is AiFailure ? error : safeFailure(error);
      _contextFailed = true;
      _setBlocked(AiChatBlocker.contextUnavailable);
      return;
    }
    if (settings.initializationFailure != null) {
      _setBlocked(AiChatBlocker.settingsUnavailable);
      return;
    }
    if (!settings.initialized) {
      _setBlocked(AiChatBlocker.settingsLoading, preparing: true);
      return;
    }
    final selected = _chosenProvider == null
        ? settings.providers.firstOrNull
        : settings.providers.where((p) => p.id == _chosenProvider).firstOrNull;
    _provider = selected;
    if (selected == null) {
      _setBlocked(AiChatBlocker.noProvider);
      return;
    }
    if (selected.caps.requiresKey &&
        settings.providerKeyFor(selected) == null) {
      _setBlocked(AiChatBlocker.keyMissing);
      return;
    }
    if (_accountRead != null ||
        !_accountLoaded && settings.accountRecord(_accountKey) == null) {
      _setBlocked(AiChatBlocker.settingsLoading, preparing: true);
      final read = _accountRead ??= settings.loadAccount(_accountKey);
      try {
        await read;
      } on Object {
        if (!_current(epoch)) return;
        _setBlocked(AiChatBlocker.settingsUnavailable);
        return;
      } finally {
        if (_alive && identical(_accountRead, read)) _accountRead = null;
      }
      if (!_current(epoch)) return;
      _accountLoaded = true;
      // Settings may have changed while their account record was loading.
      return recheck();
    }
    // Use exactly the versioned MR5 disclosure, including all categories the
    // read catalogue can access. Narrowing it would invalidate saved grants.
    final contract = aiCurrentConsentContractFor(selected);
    _contract = contract;
    if (!settings.isValid(_accountKey, contract)) {
      _setBlocked(AiChatBlocker.consentRequired);
      return;
    }
    _phase = AiChatPhase.preparing;
    _blocker = AiChatBlocker.none;
    _notify();
    var contextReady = false;
    try {
      await _refreshSecrets();
      if (!_current(epoch)) return;
      _redactDisplayIfNeeded();
      if (_context == null) {
        final loaded = await loadAiChatContext(
          origin: origin,
          api: _api,
          redactor: _redactor,
          accountKey: _accountKey,
          isCurrent: () => _current(epoch),
          refreshSecrets: _refreshSecrets,
        );
        if (!_current(epoch)) return;
        _context = loaded;
      }
      contextReady = true;
      if (_runner case final runner?
          when _transportClosed || !identical(runner.config, selected)) {
        final client = _client(selected);
        try {
          runner.replaceKeyRecipient(
            config: selected,
            complete: client.complete,
            close: client.transport.close,
            cancelActive: client.transport.cancelActive,
          );
          _transportClosed = false;
        } on Object {
          client.transport.close();
          _clearConversation(keepDisplay: true);
        }
      }
      _phase = AiChatPhase.idle;
      _blocker = AiChatBlocker.none;
      _notify();
    } on Object catch (error) {
      if (!_current(epoch)) return;
      _failure = contextReady
          ? _mapFailure(error)
          : error is AiFailure
          ? error
          : safeFailure(error);
      _contextFailed = true;
      _setBlocked(AiChatBlocker.contextUnavailable);
    }
  }

  void _setBlocked(AiChatBlocker value, {bool preparing = false}) {
    _blocker = value;
    _phase = preparing ? AiChatPhase.preparing : AiChatPhase.idle;
    _notify();
  }

  AiWireClient _client(AiProviderConfig config) => _wireClientFactory(
    config: config,
    apiKey: settings.providerKeyFor(config),
    conversationId: _id,
  );

  void _createRunner() {
    final config = _provider!;
    final contract = _contract!;
    final context = _context!;
    final scope = context.scope;
    final catalogue = scope == null || !config.toolsEnabled
        ? null
        : AiToolCatalogue(
            port: GitLabAiReadPort(_api, scope.projectId),
            scope: scope,
            redactor: _redactor,
            refreshSecrets: _refreshSecrets,
          );
    var budget = AiToolBudget();
    final client = _client(config);
    final conversationId = _id;
    bool current() => _alive && _id == conversationId;
    final runner = AiRunner(
      config: config,
      wire: client.wire,
      complete: client.complete,
      secrets: _secrets,
      refreshSecrets: _refreshSecrets,
      guard: AiRunGuard(
        expectedGeneration: _generation,
        ownerApi: _api,
        generation: () => _alive ? session.generation : -1,
        api: () => session.api,
        recipientRevision: () => settings.recipientRevision(config.id),
        consentValid: () => settings.isValid(_accountKey, contract),
      ),
      system: aiSystemPrompt,
      close: client.transport.close,
      cancelActive: client.transport.cancelActive,
      tools: catalogue?.specs ?? const [],
      executeTool: catalogue == null
          ? null
          : (call) => catalogue.executeResult(call, budget: budget),
      resetToolBudget: () => budget = AiToolBudget(),
      beginToolTurn: () => budget.beginTurn(),
      toolBudgetExhausted: () => budget.exhausted,
      context: context.built.blocks,
      contextWithheldPrivateKeyContext: context.built.withheldPrivateKeyContext,
      conversationTokenCap:
          settings.accountRecord(_accountKey)?.conversationTokenCap ?? 500000,
      maxOutputTokens: config.caps.maxOutputTokens,
      confirmCleartext: () async => await _confirmCleartext?.call() ?? false,
      onTextChanged: (text) {
        if (!current()) return;
        _setAssistant(text, AiAssistantState.streaming);
        _notifyStream();
      },
      onToolStarted: (call) {
        if (!current()) return;
        final index = _insertRunItem(
          AiToolRunItem(
            name: _toolName(call.name),
            argsPreview: _toolTarget(call),
            status: AiToolRunStatus.running,
            sizeChars: 0,
            provenance: '',
          ),
        );
        _pendingTools.add((id: call.id, index: index));
        _notifyStream();
      },
      onToolResult: (result) {
        if (!current()) return;
        final pending = _pendingTools.indexWhere((p) => p.id == result.callId);
        final completed = pending < 0 ? null : _pendingTools.removeAt(pending);
        final index = completed?.index;
        final started = index == null ? null : _items[index];
        final item = AiToolRunItem(
          name: _toolName(result.name),
          argsPreview: started is AiToolRunItem ? started.argsPreview : '',
          status: result.notExecuted || pending < 0
              ? AiToolRunStatus.skipped
              : result.isError
              ? AiToolRunStatus.failed
              : AiToolRunStatus.completed,
          sizeChars: result.notExecuted || pending < 0
              ? 0
              : result.content.length,
          provenance: _toolProvenance(result),
          truncated: result.truncated,
          blocked: result.blockedSensitive,
          confidential:
              pending >= 0 &&
              !result.notExecuted &&
              !result.isError &&
              !result.blockedSensitive &&
              result.readConfidential,
          internal:
              pending >= 0 &&
              !result.notExecuted &&
              !result.isError &&
              !result.blockedSensitive &&
              result.readInternal,
          resultExcerpt: _toolExcerpt(result.plainData.plainText),
        );
        if (index == null) {
          _insertRunItem(item);
        } else {
          _replaceItem(index, item);
        }
        if (result.withheldPrivateKeyContext) _noticeWithheld();
        _notifyStream();
      },
      onEvent: (event) {
        if (!current()) return;
        if (event
            case AiUsageUpdated(:final usage) ||
                AiFinished(usage: final usage?)) {
          _usage = usage;
          _notifyStream();
        }
      },
    );
    _runner = runner;
    _binding = AiRunnerBinding(
      runner: runner,
      settings: settings,
      session: session,
    );
  }

  @override
  Future<void> send(String text) async {
    if (!_alive || _phase != AiChatPhase.idle || text.trim().isEmpty) return;
    if (_blocker != AiChatBlocker.none &&
        _blocker != AiChatBlocker.tooManyRunning) {
      return;
    }
    if (runningCount() >= AiRunRegistry.maxRunning) {
      _setBlocked(AiChatBlocker.tooManyRunning);
      return;
    }
    if (!canSend) return;
    final epoch = _epoch;
    _phase = AiChatPhase.running;
    _blocker = AiChatBlocker.none;
    _failure = null;
    _offerNewConversation = false;
    _lastEnd = null;
    _settingsChangedDuringRun = false;
    _usage = null;
    _notify();
    var userAdded = false;
    int? userIndex;
    try {
      await _refreshSecrets();
      if (!_current(epoch)) return;
      _redactDisplayIfNeeded();
      final clean = _redactor.redactSource(text);
      // The page context goes with the first request this segment delivers;
      // its "What was sent" chips go with that message.
      final first = _runner == null || _contextPending;
      _items.add(
        AiUserItem(text: clean.text, chips: first ? _chips() : const []),
      );
      userAdded = true;
      userIndex = _items.length - 1;
      if (_phase == AiChatPhase.stopping) {
        // Nothing was sent, so only blocked-path chips stay; the next message
        // carries the others.
        _settleChips(userIndex, sent: false);
        _items.add(const AiNoticeItem(AiNoticeKind.notSent));
        _lastEnd = AiRunEnd.stopped;
        return;
      }
      if (first && _context!.built.withheldPrivateKeyContext ||
          clean.withheldPrivateKeyContext) {
        _noticeWithheld();
      }
      if (clean.redactions > 0 || first && _context!.built.redactions > 0) {
        _items.add(
          AiNoticeItem(
            AiNoticeKind.redacted,
            count: clean.redactions + (first ? _context!.built.redactions : 0),
          ),
        );
      }
      _assistantIndex = _items.length;
      final config = _provider!;
      _items.add(
        AiAssistantItem(
          text: '',
          state: AiAssistantState.streaming,
          source: AiAnswerSource(
            presetId: config.presetId,
            format: config.format.name,
            model: config.model,
          ),
        ),
      );
      if (_runner == null) _createRunner();
      _notifyStream();
      final runner = _runner!;
      final segment = runner.segment;
      final redactions = runner.lateRedactions;
      final result = await runner.run(text);
      if (!_current(epoch)) return;
      _settleChips(
        userIndex,
        sent: result.modelCalls > 0,
        blocks: runner.sentContext,
      );
      try {
        _redactDisplayIfNeeded();
      } on AiFailure {
        // _displayFailed blocks the chat once the run's outcome is recorded.
      }
      _failure = result.failure;
      _offerNewConversation = result.offerRollover;
      _lastEnd = result.reason;
      if (_displayFailed) {
        // The reply cannot be checked against the live secrets either.
        _setAssistant('', AiAssistantState.hidden);
      } else {
        _setAssistant(result.text, _stateFor(result.reason));
      }
      _assistantIndex = null;
      if (segment != null && !identical(segment, runner.segment)) {
        _items.add(const AiNoticeItem(AiNoticeKind.segmentSummary));
      }
      if (runner.lateRedactions > redactions) {
        _items.add(
          AiNoticeItem(
            AiNoticeKind.redacted,
            count: runner.lateRedactions - redactions,
          ),
        );
      }
      if (result.withheldPrivateKeyContext) _noticeWithheld();
      if (result.reason == AiRunEnd.stoppedBySettings) {
        _transportClosed = true;
        _items.add(const AiNoticeItem(AiNoticeKind.settingsChanged));
      } else if (result.reason == AiRunEnd.stopped) {
        _items.add(const AiNoticeItem(AiNoticeKind.stopped));
      }
    } on Object catch (error) {
      if (!_current(epoch)) return;
      // Only steps before the run throw (refreshing, redacting the message,
      // creating the runner): nothing left the device.
      _settleChips(userIndex, sent: false);
      _failure = _assistantIndex != null
          ? _mapFailure(error)
          : error is AiFailure
          ? error
          : safeFailure(error);
      _lastEnd = AiRunEnd.failed;
      if (_assistantIndex == null) {
        if (!userAdded) {
          // Redacting may be what failed (text over the scan limit); then the
          // message is not shown rather than thrown again.
          try {
            _items.add(AiUserItem(text: _redactor.redactSource(text).text));
          } on Object {
            // Only the notice below remains.
          }
        }
        _items.add(const AiNoticeItem(AiNoticeKind.notSent));
      } else {
        _setAssistant('', AiAssistantState.interrupted);
      }
    } finally {
      if (_current(epoch)) {
        _phase = AiChatPhase.idle;
        _assistantIndex = null;
        _pendingTools.clear();
        // The next action can revisit settings without erasing this run's
        // terminal failure. Recheck on a settings notification or explicit retry.
        final config = _provider;
        if (config != null &&
            !settings.isValid(
              _accountKey,
              aiCurrentConsentContractFor(config),
            )) {
          _contract = aiCurrentConsentContractFor(config);
          _blocker = AiChatBlocker.consentRequired;
        }
        if (_displayFailed) {
          // What is shown could not be checked against the live secrets;
          // block like recheck does, and retry on the next one.
          _failure ??= const AiFailure(AiFailureKind.policyBlocked);
          _contextFailed = true;
          _blocker = AiChatBlocker.contextUnavailable;
        }
        _notify();
        _saveReportedHistory();
        if (_transportClosed || _settingsChangedDuringRun) {
          _settingsChangedDuringRun = false;
          unawaited(recheck());
        }
      }
    }
  }

  /// What the page was about, for the chip label. The block source stays
  /// the provenance tag the model sees.
  String? get _originResource => switch (origin) {
    AiGeneralOrigin() => null,
    AiJobOrigin(:final jobName) => jobName,
    AiWorkItemOrigin(:final kind, :final iid) =>
      kind == AiWorkItemKind.mergeRequest ? '!$iid' : '#$iid',
    AiFileOrigin(:final path) => path,
  };

  /// A chip for a block that is already redacted, as sent. Its preview is
  /// cut from the redacted text. [sizeChars] keeps the size that was sent
  /// when a later pass redacts more.
  AiContextChip _sentChip(
    AiContextBlock sent, {
    int? sizeChars,
    bool? internal,
  }) {
    final resource = _originResource;
    final pinned = _context?.built.pinnedSha;
    return AiContextChip(
      source: _redactor.redactSource(sent.source).text,
      // A conversation summary is not the page itself.
      resource: resource == null || sent.source == 'conversation_summary'
          ? null
          : _redactor.redactSource(resource).text,
      sentText: sent.text,
      preview: clipAiText(sent.text, 200),
      sizeChars: sizeChars ?? sent.text.length,
      pinnedSha: pinned == null ? null : _redactor.redactSource(pinned).text,
      block: sent,
      internal:
          internal ??
          (sent.source != 'conversation_summary' &&
              (_context?.built.readInternal ?? false)),
    );
  }

  List<AiContextChip> _blockedChips() {
    final built = _context!.built;
    return [
      for (final path in built.blockedSensitivePaths)
        AiContextChip(
          source: _redactor.redactSource(path).text,
          preview: '',
          sizeChars: 0,
          blocked: true,
          pinnedSha: built.pinnedSha == null
              ? null
              : _redactor.redactSource(built.pinnedSha!).text,
        ),
    ];
  }

  /// The chips shown while the first request is prepared: the page context as
  /// it will be sent. [_settleChips] corrects them once the run says what it
  /// really sent.
  List<AiContextChip> _chips() => [
    for (final block in _context!.built.blocks)
      _sentChip(
        block.redact(
          _redactor,
          source: (value) => _redactor.redactSource(value).text,
        ),
      ),
    ..._blockedChips(),
  ];

  /// Makes the chips of the message at [index] say what its request carried.
  /// Nothing left the device when [sent] is false; otherwise [blocks] are
  /// the redacted blocks the runner attached (the page context, a
  /// conversation summary, or none). Blocked-path chips always stay. A
  /// request that started and then failed or was stopped did leave the
  /// device, so it keeps its chips. The runner redacted [blocks] before
  /// sending; secrets learned since are redacted here, and a message that
  /// cannot be checked is hidden like in a display pass.
  void _settleChips(
    int? index, {
    required bool sent,
    List<AiContextBlock> blocks = const [],
  }) {
    if (index == null || index >= _items.length) return;
    if (_items[index] case AiUserItem(:final text, :final chips)) {
      try {
        final settled = [
          if (sent)
            for (final block in blocks) _sentChip(block),
          for (final chip in chips)
            if (chip.blocked) chip,
        ];
        if (settled.isEmpty && chips.isEmpty) return;
        _replaceItem(
          index,
          _redactItem(
            AiUserItem(text: text, chips: settled),
            (value) => _redactor.redactSource(value).text,
          ),
        );
      } on Object {
        _replaceItem(index, _hiddenItem(_items[index]));
        _displayFailed = true;
        // The next pass recomputes the flag over what is shown now.
        _displayRevision = -1;
      }
    }
  }

  /// The page context has content the current segment has not delivered yet.
  bool get _contextPending =>
      (_context?.built.blocks.isNotEmpty ?? false) &&
      !(_runner?.segment?.contextDelivered ?? false);

  /// Re-redacts what is shown only when the secret set has grown since the
  /// last pass.
  void _redactDisplayIfNeeded() {
    if (_secrets.revision != _displayRevision) _redactDisplay();
  }

  // Display history is never provider replay. Re-scan it when the live secret
  // union changes, including credentials learned during a GitLab OAuth read.
  // The revision is recorded only after every item passed, so a failed pass
  // is tried again rather than skipped.
  void _redactDisplay() {
    final revision = _secrets.revision;
    String safe(String text) => _redactor.redactSource(text).text;
    final redacted = List<AiChatItem>.of(_items);
    var failed = false;
    try {
      // Notices hold no text, so a list of them alone would pass even when
      // nothing can be redacted.
      safe('');
    } on Object {
      failed = true;
    }
    for (var index = 0; index < redacted.length; index++) {
      try {
        redacted[index] = _redactItem(redacted[index], safe);
      } on Object {
        // What cannot be checked against the new secrets is not shown.
        failed = true;
        redacted[index] = _hiddenItem(redacted[index]);
      }
    }
    for (var index = 0; index < redacted.length; index++) {
      _replaceItem(index, redacted[index]);
    }
    _displayFailed = failed;
    _saveReportedHistory();
    if (failed) {
      // Leave the revision so the next pass tries again, and block.
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    _displayRevision = revision;
  }

  AiChatItem _redactItem(AiChatItem item, String Function(String) safe) =>
      switch (item) {
        AiUserItem(:final text, :final chips) => AiUserItem(
          text: safe(text),
          chips: [
            for (final chip in chips)
              if (chip.block case final block?)
                // Redact the plain text, then encode: see AiContextChip.block.
                _sentChip(
                  block.redact(_redactor, source: safe),
                  sizeChars: chip.sizeChars,
                  internal: chip.internal,
                )
              else
                AiContextChip(
                  source: safe(chip.source),
                  preview: safe(chip.preview),
                  sentText: chip.sentText == null ? null : safe(chip.sentText!),
                  sizeChars: chip.sizeChars,
                  blocked: chip.blocked,
                  internal: chip.internal,
                  type: chip.type,
                  resource: chip.resource == null ? null : safe(chip.resource!),
                  pinnedSha: chip.pinnedSha == null
                      ? null
                      : safe(chip.pinnedSha!),
                ),
          ],
        ),
        AiAssistantItem(
          :final text,
          :final state,
          :final usage,
          :final source,
          :final reported,
        ) =>
          AiAssistantItem(
            text: safe(text),
            state: state,
            usage: usage,
            source: source,
            reported: reported,
          ),
        AiToolRunItem(
          :final name,
          :final argsPreview,
          :final status,
          :final sizeChars,
          :final provenance,
          :final truncated,
          :final blocked,
          :final resultExcerpt,
          :final confidential,
          :final internal,
        ) =>
          AiToolRunItem(
            name: safe(name),
            argsPreview: safe(argsPreview),
            status: status,
            sizeChars: sizeChars,
            provenance: safe(provenance),
            truncated: truncated,
            blocked: blocked,
            resultExcerpt: safe(resultExcerpt),
            confidential: confidential,
            internal: internal,
          ),
        final AiNoticeItem notice => notice,
      };

  static AiChatItem _hiddenItem(AiChatItem item) => switch (item) {
    AiUserItem() => const AiNoticeItem(AiNoticeKind.redacted),
    AiAssistantItem(:final usage, :final source, :final reported) =>
      AiAssistantItem(
        text: '',
        state: AiAssistantState.hidden,
        usage: usage,
        source: source,
        reported: reported,
      ),
    AiToolRunItem(
      :final name,
      :final status,
      :final sizeChars,
      :final truncated,
      :final blocked,
      :final confidential,
      :final internal,
    ) =>
      AiToolRunItem(
        name: name,
        argsPreview: '',
        status: status,
        sizeChars: sizeChars,
        provenance: '',
        truncated: truncated,
        blocked: blocked,
        confidential: confidential,
        internal: internal,
      ),
    final AiNoticeItem notice => notice,
  };

  void _noticeWithheld() {
    if (!_items.whereType<AiNoticeItem>().any(
      (i) => i.kind == AiNoticeKind.privateKeyWithheld,
    )) {
      _insertRunItem(const AiNoticeItem(AiNoticeKind.privateKeyWithheld));
    }
  }

  /// Run details go just before the active answer. Earlier rows keep their
  /// indices; details added after the answer finishes go after it.
  int _insertRunItem(AiChatItem item) {
    final index = _assistantIndex ?? _items.length;
    _items.insert(index, item);
    if (_assistantIndex != null) _assistantIndex = index + 1;
    return index;
  }

  /// A short label for what a tool call reads, for display only. The model
  /// chose these values, so they are redacted and stripped of controls.
  String _toolTarget(AiToolCall call) {
    final arguments = call.arguments;
    if (arguments is! Map<String, Object?>) return '';
    String value(String key) => switch (arguments[key]) {
      final String text => text,
      final int number => '$number',
      _ => '',
    };
    String prefixed(String sigil, String key) =>
        value(key).isEmpty ? '' : '$sigil${value(key)}';
    final target = switch (call.name) {
      'read_file' ||
      'list_directory' => value('path').isEmpty ? '/' : value('path'),
      'get_issue' => prefixed('#', 'iid'),
      'get_merge_request' => prefixed('!', 'iid'),
      'get_job_log' => prefixed('#', 'job_id'),
      'get_commit' || 'get_commit_diff' => value('sha'),
      'search_project' => value('query'),
      _ => '',
    };
    return _redactor.redactSource(target.replaceAll(_displayControls, '')).text;
  }

  void _setAssistant(String text, AiAssistantState state) {
    final index = _assistantIndex;
    if (index == null) return;
    final previous = _items[index] as AiAssistantItem;
    _replaceItem(
      index,
      AiAssistantItem(
        text: text,
        state: state,
        usage: _usage,
        source: previous.source,
        reported: previous.reported,
      ),
    );
  }

  @override
  void stop() {
    if (!_alive || _phase != AiChatPhase.running) return;
    _phase = AiChatPhase.stopping;
    _runner?.stop();
    _notify();
  }

  void _clearConversation({bool keepDisplay = false}) {
    _binding?.dispose();
    _binding = null;
    _runner?.stop(AiRunEnd.stoppedBySettings);
    _runner = null;
    _transportClosed = false;
    _streamNotification?.cancel();
    _streamNotification = null;
    if (keepDisplay) {
      if (_items.isNotEmpty) {
        _items.add(const AiNoticeItem(AiNoticeKind.newConversation));
      }
    } else {
      _items.clear();
      // Nothing unchecked is shown any more.
      _displayFailed = false;
    }
    _pendingTools.clear();
    _assistantIndex = null;
    _failure = null;
    _contextFailed = false;
    _offerNewConversation = false;
    _lastEnd = null;
    _latestReportedSnapshot = null;
    _savedReportedSnapshot = null;
    _reportNotSaved = false;
    _id = _newId();
  }

  @override
  void startNewConversation() {
    if (!_alive) return;
    ++_epoch;
    _clearConversation();
    _context = null;
    _phase = AiChatPhase.idle;
    unawaited(recheck());
  }

  @override
  Future<void> useProvider(String providerId) async {
    if (!_alive || !providers.any((p) => p.id == providerId)) return;
    _chosenProvider = providerId;
    ++_epoch;
    _clearConversation();
    _context = null;
    _phase = AiChatPhase.idle;
    await recheck();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_epoch;
    _historyRetry?.cancel();
    _history.removeListener(_historyChanged);
    _pendingReportedHistory.clear();
    settings.removeListener(_settingsChanged);
    session.removeListener(_sessionChanged);
    _clearConversation();
    _phase = AiChatPhase.idle;
    super.dispose();
  }
}

String _newId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// Control, bidi and zero-width characters a model could put in a tool
/// argument to break or reorder a displayed label.
final _displayControls = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e'
  r'\u2060-\u2069\ufeff]',
);

/// [_displayControls] without the tab and line feed, which a multi-line draft
/// needs (`draftSafe` removes carriage returns before it).
final _draftControls = RegExp(
  r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u061c'
  r'\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]',
);

// Keep catalogue identifiers only; provider-chosen unknown names are untrusted.
String _toolName(String name) => switch (name) {
  'read_file' ||
  'list_directory' ||
  'get_issue' ||
  'get_merge_request' ||
  'get_merge_request_diff' ||
  'get_pipeline_jobs' ||
  'get_job_log' ||
  'get_commit' ||
  'get_commit_diff' ||
  'search_project' => name,
  _ => '',
};

String _toolExcerpt(String text) {
  final clipped = clipAiText(text, 2000);
  if (clipped.length < text.length &&
      _excerptToken.hasMatch(text[clipped.length]) &&
      clipped.isNotEmpty &&
      _excerptToken.hasMatch(clipped[clipped.length - 1])) {
    return clipped.replaceFirst(RegExp(r'[A-Za-z0-9_\-.+/=]+$'), '');
  }
  return clipped;
}

final _excerptToken = RegExp(r'[A-Za-z0-9_\-.+/=]');

String _toolProvenance(AiToolResult result) {
  final text = result.plainData.plainText;
  final end = text.indexOf('\n');
  return text.startsWith('[source:')
      ? (end < 0 ? text : text.substring(0, end))
      : '';
}

AiAssistantState _stateFor(AiRunEnd reason) => switch (reason) {
  AiRunEnd.done => AiAssistantState.done,
  AiRunEnd.refusal || AiRunEnd.contentFilter => AiAssistantState.refused,
  AiRunEnd.maxTokens ||
  AiRunEnd.tokenBudget ||
  AiRunEnd.contextTooLong ||
  AiRunEnd.toolBudget ||
  AiRunEnd.toolBudgetNoAnswer => AiAssistantState.truncated,
  _ => AiAssistantState.interrupted,
};

AiFailure _mapFailure(Object error) {
  if (error is AiFailure) return error;
  if (error is ApiFailure) {
    return AiFailure(
      switch (error.kind) {
        FailureKind.unauthenticated => AiFailureKind.unauthenticated,
        FailureKind.forbidden => AiFailureKind.forbidden,
        FailureKind.invisible => AiFailureKind.notFound,
        FailureKind.rateLimited => AiFailureKind.rateLimited,
        FailureKind.network => AiFailureKind.network,
        FailureKind.server => AiFailureKind.server,
        FailureKind.tooLarge => AiFailureKind.responseTooLarge,
        FailureKind.redirectBlocked => AiFailureKind.redirectBlocked,
        FailureKind.cancelled => AiFailureKind.cancelled,
        _ => AiFailureKind.invalidResponse,
      },
      status: error.status,
      retryAt: error.retryAt,
    );
  }
  return const AiFailure(AiFailureKind.invalidResponse);
}

AiWireClient _createWireClient({
  required AiProviderConfig config,
  required String? apiKey,
  required String conversationId,
}) {
  final wire = switch (config.format) {
    AiFormat.chatCompletions => const ChatCompletionsFormat(),
    AiFormat.responses => const ResponsesFormat(),
    AiFormat.anthropicMessages => const AnthropicMessagesFormat(),
  };
  return AiWireClient(
    transport: AiTransport(
      endpoint: AiEndpoint.parse(
        config.baseUrl,
        allowLanCleartext: config.allowLanCleartext,
        modelsUrlOverride: config.modelsUrl,
      ),
      apiKey: apiKey ?? '',
      authStyle: config.authStyle,
    ),
    wire: wire,
    config: config,
    conversationId: conversationId,
    appVersion: aiClientAppVersion,
  );
}
