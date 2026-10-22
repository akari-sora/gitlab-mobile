import 'dart:async';
import 'dart:convert';
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
import '../../core/ai/context_builders.dart' show aiMaxRedactionInputChars;
import '../../core/ai/prompts.dart';
import '../../core/ai/redaction.dart';
import '../../core/ai/runner.dart';
import '../../core/ai/tools/gitlab_read_port.dart';
import '../../core/ai/tools/gitlab_write_port.dart' as writes;
import '../../core/ai/tools/tool_catalogue.dart';
import '../../core/ai/tools/write_coordinator.dart';
import '../../core/ai/tools/write_ledger.dart' as ledger;
import '../../core/ai/tools/write_tier.dart' as tiers;
import '../../core/ai/wire/anthropic_messages.dart';
import '../../core/ai/wire/chat_completions.dart';
import '../../core/ai/wire/responses.dart';
import '../../core/ai/write_text.dart' as write_text;
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../l10n/l10n.dart';
import '../auth/session_controller.dart';
import '../workspace/attachment_picker.dart';
import 'ai_chat_context.dart';
import 'ai_chat_session.dart';
import 'ai_attachment_session.dart';
import 'ai_history.dart';
import 'ai_runner_binding.dart';
import 'ai_secrets.dart';
import 'ai_stores.dart';
import 'ai_write_journal.dart';

typedef AiChatWireClientFactory =
    AiWireClient Function({
      required AiProviderConfig config,
      required String? apiKey,
      required String conversationId,
    });

/// Owns a conversation independently of its route. Only display models escape
/// this owner; provider replay and transports stay in the existing runner.
class AiChatController extends ChangeNotifier
    implements AiChatSession, AiWriteChatSession, AiWriteSettlementSource {
  AiChatController({
    required this.origin,
    required this.session,
    required this.settings,
    required this.runningCount,
    AiChatWireClientFactory? wireClientFactory,
    Future<void> Function()? refreshSecrets,
    @visibleForTesting
    List<Duration> historyRetryDelays = defaultHistoryRetryDelays,
    bool Function()? appInForeground,
    bool Function()? clientMayStart,
    AiWriteJournal? writeJournal,
    ledger.AiWriteScope Function()? writeScope,
    AiWriteFreshnessReader? readWriteFreshness,
    writes.AiGitLabWritePort Function()? writePortFactory,
    AttachmentPicker? attachmentPicker,
  }) : assert(
         historyRetryDelays.length == 3,
         'one delay per retry after the first attempt',
       ),
       _historyRetryDelays = historyRetryDelays,
       _wireClientFactory = wireClientFactory ?? _createWireClient,
       _appInForeground = appInForeground ?? (() => false),
       _clientMayStart = clientMayStart,
       _writeJournal = writeJournal ?? AiWriteJournal.instance,
       _writeScopeOverride = writeScope,
       _readWriteFreshness = readWriteFreshness,
       _writePortFactory = writePortFactory,
       _attachmentPicker = attachmentPicker ?? const PluginAttachmentPicker(),
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
    _openAttachmentSession();
    unawaited(recheck());
  }

  @override
  final AiChatOrigin origin;
  final SessionController session;
  final AiSettingsController settings;
  final int Function() runningCount;
  final AiChatWireClientFactory _wireClientFactory;
  final bool Function() _appInForeground;
  final bool Function()? _clientMayStart;
  final AiWriteJournal _writeJournal;
  final ledger.AiWriteScope Function()? _writeScopeOverride;
  final AiWriteFreshnessReader? _readWriteFreshness;
  final writes.AiGitLabWritePort Function()? _writePortFactory;
  final AttachmentPicker _attachmentPicker;
  PolicyAiWriteCoordinator? _writes;

  /// This conversation's upload placeholder table, created with its runner
  /// and dropped with it. It lives only in memory.
  write_text.UploadPlaceholderTable? _placeholders;
  AiAttachmentSession? _attachments;
  AiAutonomyLevel? _autonomyLevel;
  int _writeScopeRevision = 0;
  String? _writeScopeFingerprint;
  bool _readConfidential = false;
  bool _readInternal = false;
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
  /// After a failed save of a reported conversation: a first attempt, then
  /// these three retries, and no more until a new snapshot or a recovery.
  static const defaultHistoryRetryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 5),
    Duration(seconds: 30),
  ];

  bool _historySaving = false;

  /// Set when the history became ready while a flush was running: snapshots
  /// that flush skipped as blocked are tried once it ends.
  bool _flushAfterSave = false;
  final List<Duration> _historyRetryDelays;

  /// Index of the first item of this conversation. A new conversation that
  /// keeps the earlier display starts after the kept items.
  int _conversationStart = 0;
  int _historySnapshotRevision = 0;
  Timer? _historyRetry;
  // One initial flush and at most three retries per snapshot/state revision.
  int _historyRetryAttempts = 0;
  final List<({String id, int index})> _pendingTools = [];
  final Map<String, int> _writeRows = {};
  final List<Future<AiWriteOutcome>> _retiredWrites = [];
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
  List<AiWriteProposal> get proposals => _writes?.proposals ?? const [];

  @override
  List<Future<AiWriteOutcome>> get inFlightWrites =>
      List.unmodifiable([..._retiredWrites, ...?_writes?.inFlightWrites]);

  AiAutonomyLevel get _effectiveWriteCeiling {
    final account = settings.accountRecord(_accountKey);
    final agreed = _contract?.writePolicy?.agreedCeiling;
    return effectiveCeiling(
      ceiling: account?.ceiling ?? AiAutonomyLevel.readOnly,
      agreedCeiling: agreed ?? AiAutonomyLevel.readOnly,
    );
  }

  @override
  AiAutonomyLevel get autonomyLevel => effectiveCeiling(
    ceiling: _effectiveWriteCeiling,
    agreedCeiling:
        _autonomyLevel ??
        settings.accountRecord(_accountKey)?.startingLevel ??
        AiAutonomyLevel.readOnly,
  );

  @override
  AiAutonomyLevel get autonomyCeiling => _effectiveWriteCeiling;

  @override
  Future<void> setAutonomyLevel(AiAutonomyLevel level) async {
    if (!_alive || level.index > _effectiveWriteCeiling.index) return;
    _autonomyLevel = level;
    _writes?.checkNow();
    _notify();
  }

  @override
  Future<AiWriteOutcome> approveWrite(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  }) async {
    final coordinator = _writes;
    if (!_alive || coordinator == null) {
      return const AiWriteOutcome(
        state: AiJournalState.notExecuted,
        reasonCode: 'invalidProposal',
      );
    }
    if (_phase == AiChatPhase.awaitingApproval &&
        runningCount() >= AiRunRegistry.maxRunning) {
      return const AiWriteOutcome(
        state: AiJournalState.notExecuted,
        reasonCode: 'tooManyRunning',
      );
    }
    if (proposal.tier.requiresTypedName &&
        typedName != proposal.tier.typedName) {
      return coordinator.approve(
        proposal,
        typedName: typedName,
        editedText: editedText,
      );
    }
    if (_phase == AiChatPhase.awaitingApproval) {
      _phase = AiChatPhase.running;
      _notify();
    }
    final outcome = await coordinator.approve(
      proposal,
      typedName: typedName,
      editedText: editedText,
    );
    if (_alive &&
        proposal.valid &&
        _phase == AiChatPhase.running &&
        proposals.contains(proposal)) {
      _phase = AiChatPhase.awaitingApproval;
      _notify();
    }
    return outcome;
  }

  @override
  Future<void> rejectWrite(AiWriteProposal proposal) async =>
      _writes?.reject(proposal);

  /// The lifecycle owner supplies foreground state; MR6c owns native permits.
  Future<void> onAppBackground() async {
    await _writes?.onAppBackground();
    stop();
  }

  AiAttachmentSession? get attachmentSession => _attachments;

  /// Attachment UI calls this after removal to invalidate an unprepared card.
  void checkWriteProposals() => _writes?.checkNow();

  @override
  List<AiStoredAttachment> get attachments =>
      _attachments?.items ?? const <AiStoredAttachment>[];

  @override
  bool get canAttach =>
      _alive && _phase == AiChatPhase.idle && _uploadToolInSegment();

  @override
  Future<AiAttachResult> attach(AiAttachmentPick pick) async {
    final AiAttachmentSession? session = _attachments;
    if (!_alive || session == null) {
      return const AiAttachResult(
        status: AiAttachStatus.disabled,
        reasonCode: _attachConversationClosed,
      );
    }
    if (_phase != AiChatPhase.idle) {
      return const AiAttachResult(
        status: AiAttachStatus.disabled,
        reasonCode: _attachConversationBusy,
      );
    }
    if (!_uploadToolInSegment()) {
      return const AiAttachResult(
        status: AiAttachStatus.disabled,
        reasonCode: _attachUploadToolDisabled,
      );
    }
    // A new conversation, account change or dispose while the picker is open
    // discards [session], which then reports the pick as expired.
    final AiAttachResult result = await session.reserveAndRead(
      picker: _attachmentPicker,
      uploadToolInSegment: true,
      pick: pick,
    );
    if (result.status == AiAttachStatus.stored &&
        identical(session, _attachments)) {
      _notify();
    }
    return result;
  }

  @override
  void removeAttachment(String id) {
    final AiAttachmentSession? session = _attachments;
    if (!_alive || session == null) return;
    final bool held = session.lookup(id) != null;
    session.remove(id);
    // A proposal waiting to upload [id] can no longer resolve it.
    checkWriteProposals();
    if (held) _notify();
  }

  /// Whether the tool list the runner builds for the next segment includes
  /// `upload_attachment`: the runner's `currentTools` gate (`toolsEnabled`)
  /// and the coordinator's `specs`, from the same write policy snapshot and
  /// the production catalogue.
  bool _uploadToolInSegment() {
    if (!_alive) return false;
    final AiProviderConfig? config = _runner?.config ?? _provider;
    if (config == null || !config.toolsEnabled) return false;
    final PolicyAiWriteCoordinator? coordinator = _writes;
    if (coordinator != null) {
      return coordinator.specs.any((spec) => spec.name == _uploadOperation);
    }
    // Before the first send there is no coordinator yet. These are the
    // conditions of [PolicyAiWriteCoordinator.specs] over the snapshot it
    // will read.
    final AiWritePolicySnapshot policy = _writeSnapshot(config);
    if (!policy.alive ||
        !policy.toolsEnabled ||
        !policy.consentValid ||
        !policy.scope.allowsWrites ||
        policy.ceiling == AiAutonomyLevel.readOnly) {
      return false;
    }
    return ledger
        .toolsForScope(policy.scope)
        .any(
          (ledger.AiCapability capability) =>
              capability.operationId == _uploadOperation,
        );
  }

  /// The conversation's attachments. One session lives as long as [_id];
  /// [_clearConversation] discards it and opens the next one.
  void _openAttachmentSession() {
    _attachments = AiAttachmentSession(
      accountKey: _accountKey,
      conversationId: _id,
      redactor: _redactor,
    );
  }

  /// The segment this send builds has no upload tool, so the files held for
  /// it are dropped before the turn is composed and their names are not sent.
  /// Each one is removed rather than the session discarded: the coordinator
  /// keeps resolving ids against this session, and `att-<n>` numbers are
  /// never issued twice in one conversation.
  void _dropHeldAttachments() {
    final AiAttachmentSession? session = _attachments;
    if (session == null) return;
    final List<AiStoredAttachment> held = session.items;
    if (held.isEmpty) return;
    for (final AiStoredAttachment attachment in held) {
      session.remove(attachment.id);
    }
    checkWriteProposals();
    _notify();
  }

  /// The model text of a turn: the user's own text, then one
  /// `attachment_metadata` untrusted-data block when files are held (ids,
  /// redacted names, sizes and types; never bytes). With nothing held the
  /// text is unchanged, so requests stay as they were. [bindingUtterance] is
  /// the user's text alone: target binding and intent never see a filename.
  /// Without the upload tool no block is sent, even for a file whose removal
  /// waits for its upload to finish.
  ({String modelText, String? bindingUtterance, List<AiContextChip> chips})
  _attachmentTurn(
    String text, {
    required bool uploadInSegment,
    String? outgoing,
  }) {
    final AiAttachmentSession? session = _attachments;
    if (!uploadInSegment || session == null || session.items.isEmpty) {
      return (
        modelText: outgoing ?? text,
        bindingUtterance: null,
        chips: const <AiContextChip>[],
      );
    }
    final Map<String, Object?> metadata = session.metadataForModel();
    final String block = metadata['block']! as String;
    final List<Object?> rows = metadata['attachments']! as List<Object?>;
    return (
      modelText: '${outgoing ?? text}\n\n$block',
      bindingUtterance: session.textForTargetBinding(text),
      chips: <AiContextChip>[
        for (final Object? row in rows)
          if (row case final Map<String, Object?> sent) _attachmentChip(sent),
      ],
    );
  }

  /// The user's own text as the provider receives it. Upload links in it
  /// become ordinary markers, and the table remembers them so a write that
  /// carries one is refused with `pasteOnScreen`. Text over the scan limit
  /// is left to the runner, which refuses it.
  String _outgoingUserText(String text) {
    final placeholders = _placeholders;
    if (placeholders == null ||
        utf8.encode(text).length > aiMaxRedactionInputChars) {
      return text;
    }
    return placeholders.redactOutgoing(
      text,
      knownSecrets: _secrets.current.toSet(),
      userMessage: true,
    );
  }

  /// "What was sent" for one attachment: its metadata row as the model got
  /// it. The file's bytes never leave the device.
  AiContextChip _attachmentChip(Map<String, Object?> row) {
    final String sent = jsonEncode(row);
    final Object? name = row['filename'];
    return AiContextChip(
      source: _attachmentChipSource,
      resource: name is String ? name : null,
      preview: clipAiText(sent, 200),
      sentText: sent,
      sizeChars: sent.length,
    );
  }

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
      listEquals(
        _savedReportedSnapshot!.conversation.items,
        _conversationItems,
      ) &&
      _savedReportedSnapshot!.stopReason == _lastEnd?.name;
  @override
  bool get reportNotSaved =>
      settings.accountRecord(_accountKey)?.historyEnabled == true &&
      _reportNotSaved &&
      _conversationItems.whereType<AiAssistantItem>().any(
        (item) => item.reported,
      );
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
    if (current is! AiAssistantItem) return null;
    final index = _items.indexOf(current);
    // Kept display from an earlier conversation is not this conversation's.
    return index >= _conversationStart ? current : null;
  }

  @override
  Future<bool> refreshSecrets() async {
    if (!_alive) return false;
    final shown = _displayRevision;
    try {
      await _refreshSecrets();
    } on Object catch (error) {
      if (!_alive) return false;
      // As in recheck: what is shown could not be checked against the
      // larger secret set, so the chat stops until it can. A run in flight
      // keeps its phase (and Stop); the failed display it left blocks the
      // chat when the run ends.
      if (_phase == AiChatPhase.idle) {
        _failure = error is AiFailure ? error : safeFailure(error);
        _contextFailed = true;
        _setBlocked(AiChatBlocker.contextUnavailable);
      }
      return false;
    }
    if (!_alive) return false;
    // A larger secret set re-redacted what is shown. A stream notifies on
    // its own; while idle nothing else tells the page.
    if (_displayRevision != shown && _assistantIndex == null) _notify();
    return true;
  }

  /// This conversation's items, without display kept from an earlier one.
  List<AiChatItem> get _conversationItems => _items.sublist(_conversationStart);

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
        !_conversationItems.whereType<AiAssistantItem>().any(
          (item) => item.reported,
        )) {
      return;
    }
    // Only this conversation: answers kept on screen from an earlier one
    // were saved, if reported, under that conversation's id.
    final snapshot = AiSavedConversation(
      id: _id,
      updatedAt: DateTime.now().toUtc(),
      conversation: AiConversation(items: _conversationItems),
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
      if (_historySaving) {
        _flushAfterSave = true;
      } else if (_historyRetry == null) {
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
        } else if (_flushAfterSave && _historyRetry == null) {
          // The history became ready while this flush ran. As for any
          // transition into ready, what is pending gets a fresh budget,
          // including a snapshot this flush blocked on its last attempt.
          _flushAfterSave = false;
          _blockedReportedHistory.clear();
          _historyRetryAttempts = 0;
          unawaited(_flushReportedHistory());
        } else if (retry &&
            _historyRetry == null &&
            _historyRetryAttempts < 4 &&
            (_history.state(_accountKey) == AiHistoryState.ready ||
                _history.state(_accountKey) == AiHistoryState.readFailed)) {
          // File failures leave the coordinator ready; unlike unavailable
          // keys they have no coordinator retry timer. Bound these retries.
          _historyRetry = Timer(
            _historyRetryDelays[_historyRetryAttempts - 1],
            () {
              _historyRetry = null;
              unawaited(_flushReportedHistory());
            },
          );
        } else if (retry &&
            _historyRetry == null &&
            _history.state(_accountKey) != AiHistoryState.ready &&
            _history.state(_accountKey) != AiHistoryState.readFailed &&
            _pendingReportedHistory.containsKey(_id)) {
          // No timer here: a missing key never comes back by itself, and an
          // unavailable one is retried by the coordinator. Say now that the
          // mark is not saved; a transition into ready flushes again, and a
          // save clears this.
          _reportNotSaved = true;
          _notify();
        }
      }
      _flushAfterSave = false;
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
    if (_phase == AiChatPhase.running ||
        _phase == AiChatPhase.awaitingApproval ||
        _phase == AiChatPhase.stopping) {
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
        _phase == AiChatPhase.awaitingApproval ||
        _phase == AiChatPhase.stopping) {
      return;
    }
    final epoch = ++_epoch;
    if (_contextFailed) {
      _failure = null;
      _contextFailed = false;
    }
    final previousContract = _contract;
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
    final contract = _consentContract(selected);
    if (previousContract != null &&
        previousContract.hash != contract.hash &&
        _runner != null) {
      _clearConversation(keepDisplay: true);
    }
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

  AiConsentContract _consentContract(AiProviderConfig provider) =>
      aiConversationConsentContract(settings, _accountKey, provider);

  ledger.AiWriteScope _writeScope() {
    final supplied = _writeScopeOverride;
    if (supplied != null) return supplied();
    final project = projectForAiChatOrigin(origin);
    return ledger.AiWriteScope(
      accountKey: _accountKey,
      instance: _api.instance,
      grants: [
        if (origin case AiWorkItemOrigin(:final kind, :final iid))
          ledger.AiScopeGrant(
            kind: kind == AiWorkItemKind.issue
                ? ledger.AiScopeKind.workItem
                : ledger.AiScopeKind.mergeRequest,
            projectId: project!.id,
            projectPath: project.path,
            iid: iid,
          )
        else if (project != null)
          ledger.AiScopeGrant(
            kind: ledger.AiScopeKind.project,
            projectId: project.id,
            projectPath: project.path,
          ),
      ],
    );
  }

  /// Whether the app-level write gates are open now: the app is on screen and
  /// the GitLab client may start a request. [_writeSnapshot] reads the same.
  @visibleForTesting
  bool get writeGatesOpen =>
      _appInForeground() &&
      !_api.isClosed &&
      (_clientMayStart?.call() ?? false);

  AiWritePolicySnapshot _writeSnapshot(AiProviderConfig config) {
    final account = settings.accountRecord(_accountKey);
    final contract = _consentContract(config);
    final scope = _writeScope();
    _updateWriteScopeRevision(scope);
    return AiWritePolicySnapshot(
      scope: scope,
      level: autonomyLevel,
      ceiling: _effectiveWriteCeiling,
      consentHash: contract.hash,
      writePolicyRevision: account?.writePolicyRevision ?? 0,
      scopeRevision: _writeScopeRevision,
      sessionGeneration: _generation,
      toolsEnabled: config.toolsEnabled && _provider?.id == config.id,
      consentValid: settings.isValid(_accountKey, contract),
      alive: _alive,
      appInForeground: _appInForeground(),
      // GitLabApi's Retry-After state is private. The integration owner must
      // provide the synchronous predicate; absence fails closed for writes.
      clientMayStart: !_api.isClosed && (_clientMayStart?.call() ?? false),
      aiAttribution: account?.aiAttribution ?? false,
    );
  }

  void _updateWriteScopeRevision(ledger.AiWriteScope scope) {
    final fingerprint = jsonEncode([
      scope.accountKey,
      scope.resolvedInstance?.key,
      for (final grant in scope.grants)
        [
          grant.kind.name,
          grant.projectId,
          grant.projectPath,
          grant.iid,
          grant.groupFullPath,
          grant.groupId,
        ],
    ]);
    if (_writeScopeFingerprint == fingerprint) return;
    _writeScopeFingerprint = fingerprint;
    _writeScopeRevision++;
  }

  Future<AiWriteFreshness> _freshWrite(
    writes.AiWriteRequest request,
    write_text.UploadPlaceholderTable placeholders,
  ) async {
    await _refreshSecrets();
    if (!_alive) throw const AiJournalException('accountChanged');
    final args = request.arguments;
    if (request.operationId == 'markTodoDone') {
      return const AiWriteFreshness();
    }
    final project = args['projectId'];
    if (project is! int || project < 1) {
      throw const AiJournalException('invalidArguments');
    }
    final projectData = await _api.record(['projects', '$project']);
    if (!_alive || projectData['id'] != project) {
      throw const AiJournalException('accountChanged');
    }
    final operation = request.operationId;
    final iid = args['iid'];
    final resource = switch (operation) {
      'updateIssue' || 'moveBoardCard' => 'issues',
      'updateMergeRequest' ||
      'unapproveMergeRequest' ||
      'createDraftNote' ||
      'updateDraftNote' => 'merge_requests',
      _ => args['resource'],
    };
    Map<String, dynamic> target = projectData;
    List<String>? path;
    if (resource != null) {
      if ((resource != 'issues' && resource != 'merge_requests') ||
          iid is! int ||
          iid < 1) {
        throw const AiJournalException('invalidArguments');
      }
      path = ['projects', '$project', resource as String, '$iid'];
      if (operation == 'updateNote') {
        path.addAll(['notes', _writeId(args, 'noteId')]);
      } else if (operation == 'updateDraftNote') {
        path.addAll(['draft_notes', _writeId(args, 'noteId')]);
      } else if (operation == 'updateDiscussionNote' ||
          operation == 'setDiscussionResolved') {
        final discussion = args['discussionId'];
        if (discussion is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(discussion)) {
          throw const AiJournalException('invalidArguments');
        }
        path.addAll(['discussions', discussion]);
        if (operation == 'updateDiscussionNote') {
          path.addAll(['notes', _writeId(args, 'noteId')]);
        }
      }
    } else if (operation == 'updateLabel') {
      path = ['projects', '$project', 'labels', _writeId(args, 'labelId')];
    } else if (operation == 'updateMilestone' ||
        operation == 'setMilestoneState') {
      path = [
        'projects',
        '$project',
        'milestones',
        _writeId(args, 'milestoneId'),
      ];
    } else if (operation == 'renameBoard' ||
        operation == 'setBoardSystemListHidden') {
      path = ['projects', '$project', 'boards', _writeId(args, 'boardId')];
    } else if (operation == 'moveBoardList') {
      path = [
        'projects',
        '$project',
        'boards',
        _writeId(args, 'boardId'),
        'lists',
        _writeId(args, 'listId'),
      ];
    }
    if (path != null) target = await _api.record(path);
    if (!_alive) throw const AiJournalException('accountChanged');
    final fields = args['fields'];
    final confidentialLowered =
        fields is Map<String, Object?> &&
        fields['confidential'] == false &&
        target['confidential'] != false;
    final visibility = projectData['visibility'];
    final originProject = projectForAiChatOrigin(origin);
    final sourceVisibility = originProject?.visibility;
    int rank(Object? value) => switch (value) {
      'private' => 0,
      'internal' => 1,
      'public' => 2,
      _ => -1,
    };
    // The written field's own provenance: only placeholders the table issued
    // for this resource and field are restored. Other writes get none.
    final projectPath = projectData['path_with_namespace'];
    final noteId = args['noteId'];
    write_text.AiFieldProvenance restorable({int? note}) =>
        write_text.AiFieldProvenance.gitLab(
          instance: placeholders.instance,
          projectId: project,
          projectPath: projectPath is String ? projectPath : null,
          resource: resource as String,
          iid: iid as int,
          noteId: note,
        );
    final provenance = <String, write_text.AiFieldProvenance>{
      if (operation == 'updateIssue' || operation == 'updateMergeRequest')
        'description': restorable(),
      if ((operation == 'updateNote' || operation == 'updateDiscussionNote') &&
          noteId is int)
        'body': restorable(note: noteId),
    };
    final noChange = switch (operation) {
      'setStar' =>
        target['starred'] is bool && target['starred'] == args['starred'],
      'setSubscribed' =>
        target['subscribed'] is bool &&
            target['subscribed'] == args['subscribed'],
      'renameBoard' => target['name'] == args['name'],
      'setDiscussionResolved' =>
        target['resolved'] is bool && target['resolved'] == args['resolved'],
      _ => false,
    };
    return AiWriteFreshness(
      updatedAt: target['updated_at'] is String
          ? target['updated_at'] as String
          : null,
      headSha: resource == 'merge_requests' && target['sha'] is String
          ? target['sha'] as String
          : null,
      lastCommitId: target['last_commit_id'] is String
          ? target['last_commit_id'] as String
          : null,
      noChange: noChange,
      facts: tiers.AiTierFacts(confidentialLowered: confidentialLowered),
      visibilityUnreadable: rank(visibility) < 0 || rank(sourceVisibility) < 0,
      polluted:
          _readConfidential ||
          _readInternal ||
          (_context?.built.readInternal ?? false) ||
          (rank(sourceVisibility) >= 0 &&
              rank(visibility) > rank(sourceVisibility)),
      currentFields: {
        for (final key in ['body', 'description', 'title', 'name'])
          if (target[key] is String) key: target[key] as String,
      },
      provenance: provenance,
    );
  }

  void _createRunner() {
    final config = _provider!;
    final context = _context!;
    final scope = context.scope;
    final placeholders = write_text.UploadPlaceholderTable(
      instance: _api.instance,
    );
    _placeholders = placeholders;
    final catalogue = scope == null || !config.toolsEnabled
        ? null
        : AiToolCatalogue(
            port: GitLabAiReadPort(_api, scope.projectId),
            scope: scope,
            redactor: _redactor,
            refreshSecrets: _refreshSecrets,
            placeholders: placeholders,
          );
    var budget = AiToolBudget();
    final client = _client(config);
    final conversationId = _id;
    bool current() => _alive && _id == conversationId;
    final coordinator = PolicyAiWriteCoordinator(
      snapshot: () => _writeSnapshot(config),
      createPort:
          _writePortFactory ??
          () => writes.GitLabAiWritePort(_api, accountKey: _accountKey),
      journal: _writeJournal,
      conversationId: conversationId,
      budget: () => budget,
      readFreshness:
          _readWriteFreshness ??
          (request) => _freshWrite(request, placeholders),
      placeholders: placeholders,
      knownSecrets: () => _secrets.current.toSet(),
      safeDisplay: draftSafe,
      attachments: _attachments,
      currentInterfaceLanguage: () => l10n.language.tag,
      currentDeviceLanguages: () => [
        for (final locale in PlatformDispatcher.instance.locales)
          locale.toLanguageTag(),
      ],
      persistConversation: historySaved,
      onChanged: () {
        if (current()) _notify();
      },
      onOutcome: (call, outcome) {
        if (current()) _settleLateWrite(call, outcome);
      },
    );
    _writes = coordinator;
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
        consentValid: () =>
            settings.isValid(_accountKey, _consentContract(config)),
      ),
      system: _contract?.writePolicy == null
          ? aiSystemPrompt
          : aiWriteSystemPrompt,
      close: client.transport.close,
      cancelActive: client.transport.cancelActive,
      tools: catalogue?.specs ?? const [],
      writeCoordinator: coordinator,
      currentTools: () => [
        if (config.toolsEnabled) ...?catalogue?.specs,
        ...coordinator.specs,
      ],
      toolPolicyRevision: () {
        _updateWriteScopeRevision(_writeScope());
        return (
          settings.accountRecord(_accountKey)?.writePolicyRevision,
          _writeScopeRevision,
          aiToolCatalogueVersion,
          _consentContract(config).hash,
        );
      },
      onAwaitingApproval: (waiting) {
        if (!current() || _phase == AiChatPhase.stopping) return;
        if (!waiting &&
            _phase == AiChatPhase.awaitingApproval &&
            runningCount() >= AiRunRegistry.maxRunning) {
          stop();
          return;
        }
        _phase = waiting ? AiChatPhase.awaitingApproval : AiChatPhase.running;
        _notify();
      },
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
        if (!result.notExecuted && !result.isError) {
          _readConfidential |= result.readConfidential;
          _readInternal |= result.readInternal;
        }
        final pending = _pendingTools.indexWhere((p) => p.id == result.callId);
        final completed = pending < 0 ? null : _pendingTools.removeAt(pending);
        final index = completed?.index;
        final started = index == null ? null : _items[index];
        final outcome = coordinator.recordedOutcomeFor(result.callId);
        final writeStatus = outcome == null ? null : _writeStatus(outcome);
        final executionId =
            outcome?.executionId ?? coordinator.executionIdFor(result.callId);
        final item = AiToolRunItem(
          name: _toolName(result.name),
          argsPreview: started is AiToolRunItem ? started.argsPreview : '',
          status: writeStatus != null
              ? writeStatus.legacyStatus
              : result.notExecuted || pending < 0
              ? AiToolRunStatus.skipped
              : result.isError
              ? AiToolRunStatus.failed
              : AiToolRunStatus.completed,
          writeStatus: writeStatus,
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
          final inserted = _insertRunItem(item);
          if (executionId != null) _writeRows[executionId] = inserted;
        } else {
          _replaceItem(index, item);
          if (executionId != null) _writeRows[executionId] = index;
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
      // Nothing awaits from here to the run's tool refresh, so this is the
      // tool list of the segment this send uses.
      final uploadInSegment = _uploadToolInSegment();
      if (!uploadInSegment) _dropHeldAttachments();
      final turn = _attachmentTurn(
        text,
        uploadInSegment: uploadInSegment,
        outgoing: _outgoingUserText(text),
      );
      if (turn.chips.isNotEmpty) {
        if (_items[userIndex] case AiUserItem(
          text: final shown,
          :final chips,
        )) {
          // Like the page context: one chip per attachment, settled below
          // with what the run really sent.
          _replaceItem(
            userIndex,
            AiUserItem(text: shown, chips: [...chips, ...turn.chips]),
          );
        }
      }
      final segment = runner.segment;
      final redactions = runner.lateRedactions;
      final result = await runner.run(
        turn.modelText,
        // Binding still reads the user's own words, as before.
        bindingUtterance: turn.bindingUtterance ?? text,
      );
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
            !settings.isValid(_accountKey, _consentContract(config))) {
          _contract = _consentContract(config);
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
  /// conversation summary, or none). Blocked-path chips always stay;
  /// attachment chips stay only when the message was sent. A
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
            if (chip.blocked || (sent && chip.source == _attachmentChipSource))
              chip,
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
          :final writeStatus,
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
            writeStatus: writeStatus,
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
      :final writeStatus,
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
        writeStatus: writeStatus,
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

  void _settleLateWrite(AiToolCall call, AiWriteOutcome outcome) {
    final index = _writeRows[outcome.executionId];
    if (index == null || index >= _items.length) return;
    final previous = _items[index];
    if (previous is! AiToolRunItem) return;
    final status = _writeStatus(outcome);
    _replaceItem(index, AiToolRunItem(
      name: _toolName(call.name),
      argsPreview: previous.argsPreview,
      status: status.legacyStatus,
      writeStatus: status,
      sizeChars: outcome.summary.length,
      provenance: previous.provenance,
      resultExcerpt: displaySafe(outcome.summary),
      blocked: previous.blocked,
      truncated: previous.truncated,
      confidential: previous.confidential,
      internal: previous.internal,
    ));
    _notify();
    _saveReportedHistory();
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
    if (!_alive ||
        (_phase != AiChatPhase.running &&
            _phase != AiChatPhase.awaitingApproval)) {
      return;
    }
    _phase = AiChatPhase.stopping;
    _runner?.stop();
    _notify();
  }

  void _clearConversation({bool keepDisplay = false}) {
    _binding?.dispose();
    _binding = null;
    _runner?.stop(AiRunEnd.stoppedBySettings);
    _writes?.stop('settingsChanged');
    for (final pending
        in _writes?.inFlightWrites ?? const <Future<AiWriteOutcome>>[]) {
      _retiredWrites.add(pending);
      unawaited(pending.then<void>((_) => _retiredWrites.remove(pending)));
    }
    _writes = null;
    _placeholders = null;
    _attachments?.discardAll();
    _attachments = null;
    _autonomyLevel = null;
    _writeScopeFingerprint = null;
    _writeScopeRevision = 0;
    _readConfidential = false;
    _readInternal = false;
    _runner = null;
    _transportClosed = false;
    _streamNotification?.cancel();
    _streamNotification = null;
    if (keepDisplay) {
      if (_items.isNotEmpty) {
        _items.add(const AiNoticeItem(AiNoticeKind.newConversation));
      }
      _conversationStart = _items.length;
    } else {
      _items.clear();
      _conversationStart = 0;
      // Nothing unchecked is shown any more.
      _displayFailed = false;
    }
    _pendingTools.clear();
    _writeRows.clear();
    _assistantIndex = null;
    _failure = null;
    _contextFailed = false;
    _offerNewConversation = false;
    _lastEnd = null;
    _latestReportedSnapshot = null;
    _savedReportedSnapshot = null;
    _reportNotSaved = false;
    _id = _newId();
    if (!_disposed) _openAttachmentSession();
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

const _uploadOperation = 'upload_attachment';

/// Chip source of an attachment's "What was sent" row; the same tag as the
/// untrusted-data block and the consent category.
const _attachmentChipSource = 'attachment_metadata';

/// Reason codes [AiChatController.attach] returns with
/// [AiAttachStatus.disabled]: the segment has no upload tool; the
/// conversation is not idle (preparing, running, awaiting approval or
/// stopping); or the conversation is gone (disposed, account changed).
const _attachUploadToolDisabled = 'uploadToolDisabled';
const _attachConversationBusy = 'conversationBusy';
const _attachConversationClosed = 'conversationClosed';

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
  _ => ledger.productionAiLedger.find(name) == null ? '' : name,
};

AiWriteResultStatus _writeStatus(AiWriteOutcome outcome) => outcome.noChange
    ? AiWriteResultStatus.noChange
    : switch (outcome.state) {
        AiJournalState.succeeded =>
          outcome.readbackConfirmed
              ? AiWriteResultStatus.readbackConfirmed
              : AiWriteResultStatus.succeeded,
        AiJournalState.failedCertain => AiWriteResultStatus.failedCertain,
        AiJournalState.writeUncertain ||
        AiJournalState.dispatching => AiWriteResultStatus.writeUncertain,
        AiJournalState.resolvedByUser => AiWriteResultStatus.resolvedByUser,
        AiJournalState.notExecuted ||
        AiJournalState.prepared => AiWriteResultStatus.notExecuted,
      };

String _writeId(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is! int || value < 1) {
    throw const AiJournalException('invalidArguments');
  }
  return '$value';
}

/// Canonical disclosure for the production MR6b-1 catalogue. The UI owner uses
/// this same policy when requesting a new write grant.
AiWritePolicy aiMr6b1WritePolicy(AiAutonomyLevel agreedCeiling) =>
    AiWritePolicy(
      policyVersion: 1,
      agreedCeiling: agreedCeiling,
      catalogueVersion: aiToolCatalogueVersion,
      operationIds: {
        for (final capability in ledger.productionAiLedger.modelVisible)
          capability.operationId,
      },
      hardLineOperationIds: {
        for (final capability in ledger.productionAiLedger.modelVisible)
          if (capability.baseTier == ledger.AiWriteTier.hardLine)
            capability.operationId,
      },
      fixedConfirmOperationIds: ledger.aiFixedConfirmOperationIds,
      resetConfirmWindow: aiWriteResetConfirmWindow,
    );

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

/// The consent a conversation with [provider] asks for on [accountKey].
/// Without tools the AI cannot write: the read-only disclosure. Otherwise it
/// names the highest level the user agrees to: the account's ceiling, or an
/// earlier, higher agreement. Raising the ceiling above what was agreed asks
/// again; lowering it does not.
AiConsentContract aiConversationConsentContract(
  AiSettingsController settings,
  String accountKey,
  AiProviderConfig provider,
) {
  if (!provider.toolsEnabled) return aiCurrentConsentContractFor(provider);
  final account = settings.accountRecord(accountKey);
  final ceiling = account?.ceiling ?? AiAutonomyLevel.lowRiskAuto;
  final saved =
      account?.consents[provider.id]?.agreedCeiling ?? AiAutonomyLevel.readOnly;
  final agreed = ceiling.index > saved.index ? ceiling : saved;
  if (agreed == AiAutonomyLevel.readOnly) {
    return aiCurrentConsentContractFor(provider);
  }
  return settings.consentContractFor(
    accountKey,
    provider,
    writePolicy: aiMr6b1WritePolicy(agreed),
    agreedCeiling: agreed,
  );
}
