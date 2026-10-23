import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'ai_endpoint.dart';
import 'ai_display.dart';
import 'ai_events.dart';
import 'ai_network_check.dart';
import 'ai_failure.dart';
import 'ai_provider.dart';
import 'ai_transcript.dart';
import 'app_text.dart';
import 'redaction.dart';
import 'prompts.dart';
import 'tools/write_coordinator.dart';
import 'wire/wire_format.dart';

/// The owner supplies live getters; no account or API secret enters the core.
final class AiRunGuard {
  const AiRunGuard({
    required this.expectedGeneration,
    required this.ownerApi,
    required this.generation,
    required this.api,
    required this.recipientRevision,
    required this.consentValid,
  });

  final int expectedGeneration;
  final Object ownerApi;
  final int Function() generation;
  final Object? Function() api;
  final int? Function() recipientRevision;
  final bool Function() consentValid;

  bool valid(int revision) =>
      generation() == expectedGeneration &&
      identical(api(), ownerApi) &&
      recipientRevision() == revision &&
      consentValid();
}

typedef AiComplete =
    Future<AiDecodedTurn> Function(
      AiRequestPlan plan, {
      void Function(AiEvent)? onEvent,
    });

enum AiRunEnd {
  done,
  maxTokens,
  contentFilter,
  refusal,
  toolBudget,
  toolBudgetNoAnswer,
  stopped,
  stoppedBySettings,
  newSecret,
  contextTooLong,
  tokenBudget,
  failed,
}

final class AiRunResult {
  const AiRunResult({
    required this.reason,
    required this.text,
    required this.modelCalls,
    required this.toolCalls,
    this.failure,
    this.offerRollover = false,
    this.withheldPrivateKeyContext = false,
  });
  final AiRunEnd reason;
  final String text;
  final int modelCalls;
  final int toolCalls;
  final AiFailure? failure;
  final bool offerRollover;
  final bool withheldPrivateKeyContext;
}

/// A conversation owner. Frozen entries are only ever appended or discarded
/// together at a segment boundary; application-generated tails remain editable.
final class AiRunner {
  AiRunner({
    required AiProviderConfig config,
    required this.wire,
    required AiComplete complete,
    required this.secrets,
    required this.refreshSecrets,
    required this.guard,
    required this.system,
    required void Function() close,
    required void Function() cancelActive,
    List<AiToolSpec> tools = const [],
    this.writeCoordinator,
    this.currentTools,
    this.toolPolicyRevision,
    this.onAwaitingApproval,
    DateTime Function()? now,
    this.executeTool,
    this.resetToolBudget,
    this.beginToolTurn,
    this.toolBudgetExhausted,
    this.onEvent,
    this.onTextChanged,
    this.onToolStarted,
    this.onRestorableResultCut,
    this.onToolResult,
    this.confirmCleartext,
    this.listInterfaceAddresses = listAiInterfaceAddresses,
    List<AiContextBlock> context = const [],
    bool contextWithheldPrivateKeyContext = false,
    this.conversationTokenCap = 500000,
    int? maxOutputTokens,
    this.toolDeadline = const Duration(seconds: 20),
    this.runDeadline = const Duration(minutes: 12),
    this.modelDeadline = const Duration(minutes: 5),
  }) : maxOutputTokens = maxOutputTokens ?? config.caps.maxOutputTokens,
       _config = config,
       _complete = complete,
       _close = close,
       _cancelActive = cancelActive,
       _now = now ?? DateTime.now,
       tools = List.unmodifiable(config.toolsEnabled ? tools : <AiToolSpec>[]),
       context = List.unmodifiable(context),
       _redactor = Redactor(secrets: secrets),
       _withheld = contextWithheldPrivateKeyContext {
    if (wire.format != config.format ||
        conversationTokenCap <= 0 ||
        this.maxOutputTokens < 512 ||
        toolDeadline <= Duration.zero ||
        runDeadline <= Duration.zero ||
        modelDeadline <= Duration.zero) {
      throw ArgumentError('Invalid runner configuration.');
    }
  }

  AiProviderConfig _config;
  AiProviderConfig get config => _config;
  final WireFormatBase wire;
  AiComplete _complete;
  final KnownSecretsSource secrets;
  final Future<void> Function() refreshSecrets;
  final AiRunGuard guard;
  final String system;
  void Function() _close;
  void Function() _cancelActive;
  final List<AiToolSpec> tools;
  final AiWriteCoordinator? writeCoordinator;
  final List<AiToolSpec> Function()? currentTools;
  final Object? Function()? toolPolicyRevision;
  final void Function(bool awaiting)? onAwaitingApproval;
  final DateTime Function() _now;
  final Future<AiToolResult> Function(AiToolCall)? executeTool;
  final void Function()? resetToolBudget;
  final void Function()? beginToolTurn;
  final bool Function()? toolBudgetExhausted;
  final void Function(AiEvent)? onEvent;

  /// Redacted cumulative display text; the UI replaces its pending text.
  final void Function(String text)? onTextChanged;
  final void Function(AiToolCall call)? onToolStarted;

  /// A tool result that carried whole writable fields was cut after its
  /// read recorded them (§3.1: no whole-field write of a value seen cut).
  final void Function()? onRestorableResultCut;
  final void Function(AiToolResult result)? onToolResult;
  final Future<bool> Function()? confirmCleartext;
  final AiInterfaceAddressLister listInterfaceAddresses;
  final List<AiContextBlock> context;
  final int conversationTokenCap;
  final int maxOutputTokens;
  final Duration toolDeadline;
  final Duration runDeadline;
  final Duration modelDeadline;
  final Redactor _redactor;

  List<AiChatItem> _displayHistory = const [];
  AiSegment? _segment;
  AiSegment? get segment => _segment;
  SecretSetId? _verifiedSecrets;
  var _verifiedLength = -1;
  var _epoch = 0;
  var _running = false;
  var _pendingGitLab = false;
  var _pendingGitLabWrite = false;
  var _needsProjection = false;
  bool _withheld;
  Completer<void>? _stopSignal;
  AiRunEnd _stopReason = AiRunEnd.stopped;
  String _segmentSystem = '';
  List<AiToolSpec> _segmentTools = const [];
  List<AiToolSpec> _nextTools = const [];
  String? _segmentToolFingerprint;
  Object? _segmentToolPolicyRevision;
  Object? _nextToolPolicyRevision;
  List<AiContextBlock> _segmentContext = const [];
  List<AiContextBlock> _sentContext = const [];
  _ActiveRunDeadline? _activeDeadline;

  /// The redacted context blocks attached to the last run's user message, as
  /// last redacted before sending: the page context, or a conversation
  /// summary after a new segment. Empty when that message carried none. They
  /// may have left the device when [AiRunResult.modelCalls] > 0.
  List<AiContextBlock> get sentContext => _sentContext;
  int actualInputTokens = 0;
  int estimatedInputTokens = 0;
  int lateRedactions = 0;

  void _notifyToolResult(AiToolResult result) {
    try {
      onToolResult?.call(result);
    } on Object {
      // Display observers cannot prevent pairing a completed provider call.
    }
  }

  /// Called by the settings/session listener as well as at every checkpoint.
  /// A changed recipient or revoked consent immediately closes the transport.
  void checkNow() {
    writeCoordinator?.checkNow();
    _activeDeadline?.checkNow();
    if (_running && !guard.valid(config.recipientRevision)) {
      stop(AiRunEnd.stoppedBySettings);
    }
  }

  void stop([AiRunEnd reason = AiRunEnd.stopped]) {
    _stopReason = reason;
    _epoch++;
    if (_running) writeCoordinator?.stop(_coordinatorStopReason(reason));
    if (_stopSignal case final signal? when !signal.isCompleted) {
      signal.complete();
    }
    if (reason == AiRunEnd.stoppedBySettings) {
      _close();
    } else {
      _cancelActive();
    }
  }

  /// Only a key/revision change may preserve this conversation. A different
  /// recipient contract must create a new conversation in the caller.
  void replaceKeyRecipient({
    required AiProviderConfig config,
    required AiComplete complete,
    required void Function() close,
    required void Function() cancelActive,
  }) {
    final old = _config;
    if (_running ||
        config.id != old.id ||
        config.baseUrl != old.baseUrl ||
        config.format != old.format ||
        config.model != old.model ||
        config.authStyle != old.authStyle ||
        config.toolsEnabled != old.toolsEnabled ||
        config.allowLanCleartext != old.allowLanCleartext ||
        config.modelsUrl != old.modelsUrl ||
        config.caps != old.caps) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    _close();
    _config = config;
    _complete = complete;
    _close = close;
    _cancelActive = cancelActive;
    _needsProjection = true;
  }

  void noteWithheldPrivateKeyContext(bool withheld) => _withheld |= withheld;

  void forceProjection() => _needsProjection = true;

  /// History has display models only. Recipient/summary consent belongs to the
  /// caller; the next send always builds a fresh, re-redacted segment.
  void restoreFromDisplay(List<AiChatItem> items) {
    if (_running || _segment != null) {
      throw StateError('History can only initialize an idle conversation.');
    }
    _displayHistory = List.unmodifiable(items);
    _needsProjection = true;
  }

  /// [userText] is what the model receives as the user turn. The chat
  /// controller appends its attachment-metadata block to it.
  /// [bindingUtterance] is what write target binding and intent read, and
  /// the request a proposal card shows; it defaults to [userText]. The
  /// controller passes the user's own text, so a filename in that block
  /// never binds a target or authorizes a write.
  Future<AiRunResult> run(String userText, {String? bindingUtterance}) async {
    if (_running) throw StateError('A runner has one active send.');
    _running = true;
    _sentContext = const [];
    final epoch = ++_epoch;
    _stopSignal = Completer<void>();
    final deadline = _ActiveRunDeadline(
      duration: runDeadline,
      now: _now,
      onExpire: () => stop(AiRunEnd.failed),
    )..start();
    _activeDeadline = deadline;
    var modelCalls = 0;
    var toolCalls = 0;
    var outputChars = 0;
    var finishing = false;
    var answer = '';
    var partial = StringBuffer();
    var nextProgressChars = 256;
    final segmentBeforeSend = _segment;
    AiEntry? previousTail = segmentBeforeSend?.tail;
    var froze = false;
    AiEntry? beforeFinishingNote;

    AiToolResult synthetic(AiToolCall call, String reason) {
      final coordinator = writeCoordinator;
      final recorded = coordinator is AiWriteStateSource
          ? (coordinator as AiWriteStateSource).recordedOutcomeFor(call.id)
          : null;
      final original = recorded?.toToolResult(call) ?? _synthetic(call, reason);
      String safe;
      try {
        safe = _redact(original.content);
      } on Object {
        // Pairing must survive a redactor refusing even its own placeholders.
        safe = '';
      }
      final data = AiAppText.plain(
        safe,
      ).clipped(math.min(20000, 120000 - outputChars));
      outputChars += data.encode().length;
      return AiToolResult.fromData(
        callId: call.id,
        name: call.name,
        data: data,
        isError: original.isError,
        notExecuted: recorded == null || original.notExecuted,
      );
    }

    AiRunResult result(
      AiRunEnd reason, {
      AiFailure? failure,
      bool offer = false,
    }) {
      String display;
      try {
        display = _redact(answer);
      } on Object {
        display = '';
      }
      return AiRunResult(
        reason: reason,
        text: display,
        modelCalls: modelCalls,
        toolCalls: toolCalls,
        failure: failure,
        offerRollover: offer,
        withheldPrivateKeyContext: _withheld,
      );
    }

    try {
      writeCoordinator?.beginRun(bindingUtterance ?? userText);
      _refreshToolPolicy();
      _check(epoch);
      await _refresh(epoch);
      if (actualInputTokens + estimatedInputTokens >= conversationTokenCap) {
        return result(AiRunEnd.tokenBudget);
      }
      final endpoint = AiEndpoint.parse(
        config.baseUrl,
        allowLanCleartext: config.allowLanCleartext,
      );
      if (await _interruptible(
        cleartextLanNeedsConfirmation(
          endpoint,
          listAddresses: listInterfaceAddresses,
        ),
        epoch,
      )) {
        if (confirmCleartext == null ||
            !await _interruptible(confirmCleartext!(), epoch)) {
          throw const AiFailure(AiFailureKind.policyBlocked);
        }
      }
      _check(epoch);
      resetToolBudget?.call();
      final text = _redact(userText);
      var seg = _segment;
      if (seg == null || _needsProjection || !seg.replayable || !_verify(seg)) {
        seg = _newSegment(text, previous: seg);
      }
      seg.removeFinalAnswerNote();
      previousTail = seg.tail;
      await _setUserTail(seg, text, epoch);
      if (identical(seg, segmentBeforeSend) &&
          _requestSize(seg) > config.caps.maxRequestChars) {
        seg.restoreTail(previousTail);
        seg = _newSegment(text, previous: segmentBeforeSend);
        previousTail = seg.tail;
        await _setUserTail(seg, text, epoch);
      }
      for (var call = 1; call <= 6; call++) {
        _check(epoch);
        await _refresh(epoch);
        if (!_verify(seg)) {
          _needsProjection = true;
          throw const _RunStopped(AiRunEnd.newSecret);
        }
        if (actualInputTokens + estimatedInputTokens >= conversationTokenCap) {
          return result(AiRunEnd.tokenBudget);
        }
        finishing |=
            call == 6 ||
            toolCalls >= 12 ||
            outputChars >= 120000 ||
            (toolBudgetExhausted?.call() ?? false);
        // Reserve the complete encoded closing note before deciding the plan.
        final reserve = jsonEncode(aiFinalAnswerNote).length + 100;
        final size = _requestSize(seg);
        if (size + reserve > config.caps.maxRequestChars &&
            seg.tail is AppToolResultsEntry) {
          final tail = seg.tail! as AppToolResultsEntry;
          final chars = tail.results.fold<int>(
            0,
            (n, r) => n + r.content.length,
          );
          if (seg.clipTailToolResults(
            math.max(0, chars - (size + reserve - config.caps.maxRequestChars)),
          )) {
            onRestorableResultCut?.call();
          }
          finishing = true;
        }
        beforeFinishingNote = seg.tail;
        if (finishing && !config.caps.toolChoice) seg.addFinalAnswerNote();
        await _redactTail(seg, epoch);
        // _redactTail performs the last asynchronous secret refresh. Verify
        // the frozen prefix against that same snapshot immediately before send.
        if (!_verify(seg)) {
          _needsProjection = true;
          throw const _RunStopped(AiRunEnd.newSecret);
        }
        final plan = _plan(seg, finishing: finishing);
        // This is the final redacted payload, including the finishing note.
        final encoded = wire.encodeJson(plan, config.caps);
        if (encoded.length > config.caps.maxRequestChars ||
            utf8.encode(encoded).length > 4 * 1024 * 1024) {
          if (!froze) {
            seg.restoreTail(previousTail);
            _segment = segmentBeforeSend;
            _needsProjection = true;
          }
          return result(AiRunEnd.contextTooLong, offer: call == 1);
        }
        _check(epoch);
        modelCalls++;
        partial = StringBuffer();
        nextProgressChars = 256;
        AiDecodedTurn turn;
        AiUsage? latestUsage;
        var refused = false;
        try {
          turn = await _interruptible(
            _complete(
              plan,
              onEvent: (event) {
                _check(epoch);
                if (event
                    case AiTextDelta(:final text) ||
                        AiRefusalDelta(:final text)) {
                  if (partial.length + text.length > 64000) {
                    throw const AiFailure(AiFailureKind.responseTooLarge);
                  }
                  partial.write(text);
                  if (onTextChanged != null &&
                      partial.length >= nextProgressChars) {
                    onTextChanged!(
                      _redact(
                        [
                          if (answer.isNotEmpty) answer,
                          partial.toString(),
                        ].join('\n'),
                      ),
                    );
                    nextProgressChars = partial.length * 2;
                  }
                }
                if (event is AiUsageUpdated || event is AiFinished) {
                  onEvent?.call(event);
                }
                if (event is AiUsageUpdated) latestUsage = event.usage;
                if (event is AiFinished && event.usage != null) {
                  latestUsage = event.usage;
                }
              },
            ).timeout(
              modelDeadline,
              onTimeout: () {
                if (_running && epoch == _epoch) _cancelActive();
                throw const AiFailure(AiFailureKind.timeout);
              },
            ),
            epoch,
          );
          latestUsage = turn.usage ?? latestUsage;
          if (onTextChanged != null && partial.isNotEmpty) {
            onTextChanged!(
              _redact(
                [if (answer.isNotEmpty) answer, partial.toString()].join('\n'),
              ),
            );
          }
        } on AiFailure catch (failure) {
          // Refused locally (a remembered Retry-After, a closed transport):
          // this request never left the device and used nothing.
          if (failure.notSent) {
            refused = true;
            modelCalls--;
          }
          rethrow;
        } finally {
          if (!refused) _recordUsage(latestUsage, encoded.length);
        }
        _check(epoch);
        seg.freezeWith(
          turn.output,
          (entry) => wire.encodeEntry(entry, config.caps),
        );
        froze = true;
        beforeFinishingNote = null;
        final calls = turn.output.toolCalls;
        // A completed provider output stays byte-identical. Readable display
        // text and projection material are separate, freshly redacted models.
        if (calls.isEmpty) {
          await _refresh(epoch);
          answer = clipAiText(
            [
              if (answer.isNotEmpty) answer,
              _redact(providerAnswerText(turn.output)),
            ].join('\n'),
            64000,
          );
          partial = StringBuffer();
          return result(
            finishing && providerAnswerText(turn.output).isEmpty
                ? AiRunEnd.toolBudgetNoAnswer
                : _endForStop(turn.stop),
          );
        }
        final results = <AiToolResult>[];
        var exitReason = AiRunEnd.toolBudget;
        try {
          await _refresh(epoch);
          answer = clipAiText(
            [
              if (answer.isNotEmpty) answer,
              _redact(providerAnswerText(turn.output)),
            ].join('\n'),
            64000,
          );
          partial = StringBuffer();
          if (finishing || turn.stop != AiStopReason.endTurn) {
            exitReason = finishing
                ? AiRunEnd.toolBudget
                : _endForStop(turn.stop);
            return result(exitReason);
          }
          beginToolTurn?.call();
          writeCoordinator?.beginTurn();
          var previousWriteIncomplete = false;
          for (var index = 0; index < calls.length; index++) {
            _check(epoch);
            final tc = calls[index];
            onToolStarted?.call(
              AiToolCall(
                id: tc.id,
                name: _redact(tc.name),
                arguments: _displayArguments(tc.arguments),
              ),
            );
            final handlesWrite = writeCoordinator?.handles(tc.name) ?? false;
            if (handlesWrite && previousWriteIncomplete) {
              results.add(synthetic(tc, 'previousWriteIncomplete'));
              _notifyToolResult(results.last);
              continue;
            }
            if (index >= 4 || toolCalls >= 12 || outputChars >= 120000) {
              previousWriteIncomplete |= handlesWrite;
              results.add(synthetic(tc, 'budget'));
              _notifyToolResult(results.last);
              continue;
            }
            if (_pendingGitLab ||
                (!handlesWrite &&
                    (executeTool == null || _nextTools.isEmpty))) {
              previousWriteIncomplete |= handlesWrite;
              results.add(
                synthetic(
                  tc,
                  _pendingGitLab
                      ? _pendingGitLabWrite
                            ? 'write_pending'
                            : 'read_pending'
                      : 'unavailable',
                ),
              );
              _notifyToolResult(results.last);
              continue;
            }
            toolCalls++;
            _pendingGitLab = true;
            _pendingGitLabWrite = handlesWrite;
            // Keep the underlying GitLab operation owned until it settles. A
            // read soft timeout or run stop never permits a second operation.
            final pending = handlesWrite
                ? Future<AiToolResult>.sync(
                    () async => (await writeCoordinator!.execute(
                      tc,
                      onAwaitingApproval: (awaiting) {
                        deadline.setPaused(awaiting);
                        try {
                          onAwaitingApproval?.call(awaiting);
                        } on Object {
                          // UI observers cannot alter approval or deadlines.
                        }
                      },
                    )).toToolResult(tc),
                  )
                : Future<AiToolResult>.sync(() => executeTool!(tc));
            unawaited(
              pending.then<void>(
                (_) {
                  _pendingGitLab = false;
                  _pendingGitLabWrite = false;
                },
                onError: (Object _, StackTrace _) {
                  _pendingGitLab = false;
                  _pendingGitLabWrite = false;
                },
              ),
            );
            AiToolResult toolResult;
            try {
              toolResult = await _interruptible(
                handlesWrite ? pending : pending.timeout(toolDeadline),
                epoch,
              );
            } on TimeoutException {
              toolResult = _synthetic(tc, 'timeout');
            } on _RunStopped {
              rethrow;
            } on Object {
              toolResult = _synthetic(
                tc,
                handlesWrite ? 'write_failed' : 'read_failed',
              );
            }
            previousWriteIncomplete |=
                handlesWrite && (toolResult.isError || toolResult.notExecuted);
            _check(epoch);
            await _refresh(epoch);
            _withheld |= toolResult.withheldPrivateKeyContext;
            // Whole tool content is redacted before any output truncation.
            final data = toolResult.plainData.redact(
              _redactor,
              source: (s) => _redact(
                s,
                keepAppPlaceholders: toolResult.uploadPlaceholders,
              ),
            );
            final content = data.encode();
            final clippedData = data.clipped(
              math.min(20000, 120000 - outputChars),
            );
            final clipped = clippedData.encode();
            outputChars += clipped.length;
            if (toolResult.uploadPlaceholders &&
                clipped.length < content.length) {
              onRestorableResultCut?.call();
            }
            _check(epoch);
            final successfulRead =
                !toolResult.isError &&
                !toolResult.notExecuted &&
                !toolResult.blockedSensitive;
            final safeResult = AiToolResult.fromData(
              callId: tc.id,
              name: tc.name,
              data: clippedData,
              isError: toolResult.isError,
              withheldPrivateKeyContext: toolResult.withheldPrivateKeyContext,
              truncated:
                  toolResult.truncated || clipped.length < content.length,
              blockedSensitive: toolResult.blockedSensitive,
              notExecuted: toolResult.notExecuted,
              readConfidential: successfulRead && toolResult.readConfidential,
              readInternal: successfulRead && toolResult.readInternal,
              uploadPlaceholders: toolResult.uploadPlaceholders,
            );
            results.add(safeResult);
            _notifyToolResult(safeResult);
          }
        } on _RunStopped catch (stopped) {
          exitReason = stopped.reason;
          rethrow;
        } finally {
          // Pair by position, not ID: hostile duplicate IDs cannot hide a call.
          final paired = AppToolResultsEntry([
            ...results,
            for (final tc in calls.skip(results.length))
              synthetic(tc, exitReason.name),
          ]);
          seg.setTail(paired);
          for (final result in paired.results.skip(results.length)) {
            _notifyToolResult(result);
          }
        }
      }
      return result(AiRunEnd.toolBudget);
    } on _RunStopped catch (stopped) {
      _segment?.restoreTail(
        froze ? beforeFinishingNote ?? _segment?.tail : previousTail,
      );
      answer = await _partialAnswer(answer, partial.toString(), epoch);
      return result(
        stopped.reason,
        failure: stopped.reason == AiRunEnd.failed
            ? const AiFailure(AiFailureKind.timeout)
            : null,
      );
    } on AiFailure catch (failure) {
      _segment?.restoreTail(
        froze ? beforeFinishingNote ?? _segment?.tail : previousTail,
      );
      answer = await _partialAnswer(answer, partial.toString(), epoch);
      if (failure.requiresNewSegment) _needsProjection = true;
      return result(
        finishing ? AiRunEnd.toolBudget : AiRunEnd.failed,
        failure: failure,
        offer: failure.kind == AiFailureKind.contextTooLong && modelCalls == 1,
      );
    } on Object {
      _segment?.restoreTail(
        froze ? beforeFinishingNote ?? _segment?.tail : previousTail,
      );
      answer = await _partialAnswer(answer, partial.toString(), epoch);
      return result(
        AiRunEnd.failed,
        failure: const AiFailure(AiFailureKind.policyBlocked),
      );
    } finally {
      deadline.dispose();
      if (identical(_activeDeadline, deadline)) _activeDeadline = null;
      _running = false;
      _stopSignal = null;
    }
  }

  Future<String> _partialAnswer(
    String previous,
    String partial,
    int epoch,
  ) async {
    if (partial.isEmpty) return previous;
    try {
      if (epoch == _epoch) {
        await _refresh(epoch);
      } else {
        if (!guard.valid(config.recipientRevision)) return previous;
        // A stopped send cannot use its completed interruption signal. Refresh
        // directly with a bounded wait before exposing any partial display text.
        await refreshSecrets().timeout(toolDeadline);
        if (!guard.valid(config.recipientRevision)) return previous;
      }
      return clipAiText(
        [if (previous.isNotEmpty) previous, _redact(partial)].join('\n'),
        64000,
      );
    } on Object {
      return previous;
    }
  }

  Future<void> _setUserTail(AiSegment seg, String text, int epoch) async {
    if (seg.tail is AppToolResultsEntry) {
      seg.addFollowUp(text);
      return;
    }
    final blocks = <AiContextBlock>[];
    if (!seg.contextDelivered) {
      for (final block in _segmentContext) {
        await _refresh(epoch);
        blocks.add(block.redact(_redactor, source: _redact));
      }
    }
    _sentContext = List.unmodifiable(blocks);
    seg.setTail(AppUserEntry(text: text, context: blocks));
  }

  AiSegment _newSegment(String userText, {AiSegment? previous}) {
    // The system prompt is the app's own text: its `[[attachment:att-1]]`
    // example reaches the provider intact. Every other source still turns
    // such a literal into an ordinary marker.
    _segmentSystem = _redact(system, keepAppPlaceholders: true);
    _segmentTools = [
      for (final tool in _nextTools)
        AiToolSpec(
          name: tool.name,
          description: _redact(tool.description),
          parameters: wireObject(mapAiJsonStrings(tool.parameters, _redact)),
        ),
    ];
    final next = AiSegment(
      providerId: config.id,
      recipientRevision: config.recipientRevision,
      format: config.format,
      model: config.model,
      secretSetAtStart: SecretSetId.fromSecrets(secrets.current),
    );
    _segmentContext = context;
    if (previous != null || _displayHistory.isNotEmpty) {
      final overhead = _requestSize(next) + jsonEncode(userText).length + 1000;
      final budget = math.min(
        config.caps.maxRequestChars ~/ 2,
        config.caps.maxRequestChars - overhead,
      );
      if (budget < 1000) throw const AiFailure(AiFailureKind.contextTooLong);
      final summary = buildAiProjectionData(
        context: context,
        entries: previous?.entries ?? const [],
        history: _displayHistory,
        budget: budget,
        redact: _redact,
      );
      _segmentContext = [
        AiContextBlock.fromData(source: 'conversation_summary', data: summary),
      ];
    }
    _segment = next;
    writeCoordinator?.beginSegment();
    _verifiedSecrets = null;
    _verifiedLength = -1;
    _segmentToolFingerprint = _toolFingerprint(_nextTools);
    _segmentToolPolicyRevision = _nextToolPolicyRevision;
    _needsProjection = false;
    return next;
  }

  void _refreshToolPolicy() {
    _nextTools = List.unmodifiable(
      config.toolsEnabled ? currentTools?.call() ?? tools : <AiToolSpec>[],
    );
    _nextToolPolicyRevision = toolPolicyRevision?.call();
    if (_segment != null &&
        (_segmentToolFingerprint != _toolFingerprint(_nextTools) ||
            _segmentToolPolicyRevision != _nextToolPolicyRevision)) {
      _needsProjection = true;
    }
  }

  AiRequestPlan _plan(AiSegment seg, {bool finishing = false}) => AiRequestPlan(
    model: config.model,
    system: _segmentSystem,
    segment: seg,
    tools: _segmentTools,
    toolChoice: finishing && config.caps.toolChoice
        ? AiToolChoice.none
        : AiToolChoice.auto,
    maxOutputTokens: maxOutputTokens,
    allowSmallOutputTokens: true,
  );

  int _requestSize(AiSegment seg) =>
      wire.encodeJson(_plan(seg), config.caps).length;

  Future<void> _refresh(int epoch) async {
    _check(epoch);
    await _interruptible(refreshSecrets(), epoch);
    _check(epoch);
  }

  void _check(int epoch) {
    checkNow();
    if (epoch != _epoch) throw _RunStopped(_stopReason);
  }

  Future<T> _interruptible<T>(Future<T> future, int epoch) => Future.any([
    future,
    _stopSignal!.future.then<T>((_) => throw _RunStopped(_stopReason)),
  ]);

  /// Top-level scalar arguments for the progress row, redacted like other
  /// display text. Long or nested values are left out rather than cut, so a
  /// secret is never split past the redactor. Display only: this does not
  /// change what the run reports as withheld.
  Map<String, Object?>? _displayArguments(Object? arguments) {
    if (arguments is! Map) return null;
    return {
      for (final MapEntry(:key, :value) in arguments.entries)
        if (key is String && _displayArgumentKey.hasMatch(key))
          if (value is String && value.length <= 1024)
            key: _redactor
                .redactSource(
                  stripAiAnsi(value).replaceAll(_displayControls, ''),
                )
                .text
          else if (value is int || value is bool)
            key: value,
    };
  }

  /// [keepAppPlaceholders] is only for a tool result whose producer already
  /// neutralized every source-authored placeholder
  /// ([AiToolResult.uploadPlaceholders]); everything else still turns a
  /// literal `[[upload:` or `[[attachment:` into an ordinary marker.
  String _redact(
    String text, {
    bool late = false,
    bool keepAppPlaceholders = false,
  }) {
    // Refuse before scanning or splitting a source; never cut a key in half.
    if (text.length > 2 * 1024 * 1024 ||
        utf8.encode(text).length > 2 * 1024 * 1024) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final redacted = _redactor.redactSource(
      stripAiAnsi(text),
      keepAppPlaceholders: keepAppPlaceholders,
    );
    _withheld |= redacted.withheldPrivateKeyContext;
    if (late) lateRedactions += redacted.redactions;
    return redacted.text;
  }

  Future<void> _redactTail(AiSegment seg, int epoch) async {
    await _refresh(epoch);
    final tail = seg.tail;
    if (tail is AppUserEntry) {
      final context = [
        for (final block in tail.context)
          block.redact(_redactor, source: _redact),
      ];
      seg.setTail(
        tail.redactedCopy(
          text: _redact(tail.text, late: true),
          context: context,
        ),
      );
      _sentContext = List.unmodifiable(context);
    } else if (tail is AppToolResultsEntry) {
      seg.setTail(
        tail.copyWith(
          results: [
            for (final result in tail.results)
              result.copyWith(
                data: result.plainData.redact(
                  _redactor,
                  source: (s) => _redact(
                    s,
                    late: true,
                    keepAppPlaceholders: result.uploadPlaceholders,
                  ),
                ),
              ),
          ],
          followUpText: tail.followUpText == null
              ? null
              : _redact(tail.followUpText!, late: true),
          preserveFinalAnswerNote: true,
        ),
      );
    }
  }

  bool _verify(AiSegment seg) {
    final id = SecretSetId.fromSecrets(secrets.current);
    if (_verifiedSecrets == id && _verifiedLength == seg.frozenLength) {
      return true;
    }
    // Only known-secret changes warrant rechecking old provider text. Opaque
    // fields never enter this traversal and provider objects are never mutated.
    final needles = [
      ...secrets.current.where((s) => s.isNotEmpty),
      ..._redactor.verificationAliases,
    ];
    final values = <String>[
      _segmentSystem,
      for (final tool in _segmentTools) tool.description,
      for (final tool in _segmentTools)
        ...readableAiJsonStrings(tool.parameters),
      for (final entry in seg.frozen) ...readableAiEntry(entry),
    ];
    for (final text in values) {
      if (containsKnownAiSecret(text, needles)) return false;
    }
    _verifiedSecrets = id;
    _verifiedLength = seg.frozenLength;
    return true;
  }

  void _recordUsage(AiUsage? usage, int requestChars) {
    if (usage?.inputTokens != null ||
        usage?.cacheReadInputTokens != null ||
        usage?.cacheCreationInputTokens != null) {
      actualInputTokens +=
          (usage?.inputTokens ?? 0) +
          (usage?.cacheReadInputTokens ?? 0) +
          (usage?.cacheCreationInputTokens ?? 0);
    } else {
      estimatedInputTokens += (requestChars + 2) ~/ 3;
    }
  }
}

AiToolResult _synthetic(AiToolCall call, String reason) =>
    AiToolResult.fromData(
      callId: call.id,
      name: call.name,
      data: AiAppText.plain('[source: tool]\nNot executed: $reason'),
      isError: true,
    );

final _displayArgumentKey = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

final _displayControls = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e'
  r'\u2060-\u2069\ufeff]',
);

AiRunEnd _endForStop(AiStopReason stop) => switch (stop) {
  AiStopReason.maxTokens => AiRunEnd.maxTokens,
  AiStopReason.contentFilter => AiRunEnd.contentFilter,
  AiStopReason.refusal => AiRunEnd.refusal,
  _ => AiRunEnd.done,
};

final class _RunStopped implements Exception {
  const _RunStopped(this.reason);
  final AiRunEnd reason;
}

String _toolFingerprint(List<AiToolSpec> tools) => jsonEncode([
  for (final tool in tools)
    {
      'name': tool.name,
      'description': tool.description,
      'parameters': tool.parameters,
    },
]);

final class _ActiveRunDeadline {
  _ActiveRunDeadline({
    required this.duration,
    required this.now,
    required this.onExpire,
  }) : _remaining = duration;

  final Duration duration;
  final DateTime Function() now;
  final void Function() onExpire;
  Duration _remaining;
  DateTime? _startedAt;
  Timer? _timer;
  var _paused = false;
  var _disposed = false;

  void start() {
    if (_disposed || _startedAt != null) return;
    _startedAt = now();
    _schedule();
  }

  void setPaused(bool paused) {
    if (_disposed || paused == _paused) return;
    if (paused) {
      _consumeActiveTime();
      _timer?.cancel();
      _timer = null;
      _paused = true;
    } else {
      _paused = false;
      _startedAt = now();
      _schedule();
    }
  }

  void checkNow() {
    if (_disposed || _paused) return;
    _consumeActiveTime();
    if (_remaining <= Duration.zero) {
      _expire();
    } else {
      _schedule();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  void _consumeActiveTime() {
    final startedAt = _startedAt;
    if (startedAt == null) return;
    final current = now();
    final elapsed = current.difference(startedAt);
    if (!elapsed.isNegative) _remaining -= elapsed;
    _startedAt = current;
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || _paused) return;
    if (_remaining <= Duration.zero) {
      _expire();
      return;
    }
    _timer = Timer(_remaining, checkNow);
  }

  void _expire() {
    if (_disposed) return;
    dispose();
    onExpire();
  }
}

String _coordinatorStopReason(AiRunEnd reason) => switch (reason) {
  AiRunEnd.failed => 'timeout',
  AiRunEnd.stoppedBySettings => 'settingsChanged',
  _ => 'stopped',
};

String clipAiText(String text, int maximum) {
  if (text.length <= maximum) return text;
  var end = maximum;
  if (end > 0 &&
      text.codeUnitAt(end - 1) >= 0xd800 &&
      text.codeUnitAt(end - 1) <= 0xdbff &&
      text.codeUnitAt(end) >= 0xdc00 &&
      text.codeUnitAt(end) <= 0xdfff) {
    end--;
  }
  return text.substring(0, end);
}

final _ansi = RegExp(
  r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-_])',
);
String stripAiAnsi(String text) => text.replaceAll(_ansi, '');

/// Read only fields defined to hold human-readable provider data. In particular
/// signatures, encrypted reasoning, extra_content and redacted thinking stay opaque.
Iterable<String> readableAiEntry(AiEntry entry) sync* {
  if (entry is AppUserEntry) {
    yield entry.text;
    for (final block in entry.context) {
      yield block.source;
      yield* block.plainData.plainStrings;
    }
  } else if (entry is AppToolResultsEntry) {
    for (final result in entry.results) {
      yield* result.plainData.plainStrings;
    }
    if (entry.followUpText != null) yield entry.followUpText!;
  } else if (entry is ProviderOutputEntry) {
    final raw = entry.raw;
    final blocks = raw is List<Object?> ? raw : <Object?>[raw];
    for (final value in blocks) {
      if (value is! Map<String, Object?>) continue;
      if (entry.format == AiFormat.chatCompletions) {
        for (final key in [
          'content',
          'refusal',
          'reasoning_content',
          'reasoning',
        ]) {
          if (value[key] case final String text) yield text;
        }
        yield* _readableAnnotations(value['annotations']);
        if (value['reasoning_details'] case final List<Object?> details) {
          for (final detail in details) {
            if (detail is! Map<String, Object?> ||
                detail['type'] == 'reasoning.encrypted') {
              continue;
            }
            for (final key in ['text', 'summary']) {
              if (detail[key] case final String text) yield text;
            }
          }
        }
      } else {
        final type = value['type'];
        if (type == 'text' || type == 'thinking' || type == 'fallback') {
          final field = type == 'thinking' ? 'thinking' : 'text';
          if (value[field] case final String text) yield text;
          if (type == 'text') yield* _readableAnnotations(value['citations']);
        } else if (type == 'reasoning' && value['summary'] is List<Object?>) {
          for (final summary in value['summary']! as List<Object?>) {
            if (summary is Map<String, Object?> && summary['text'] is String) {
              yield summary['text']! as String;
            }
          }
        } else if (type == 'server_tool_use') {
          yield* _readableJsonStrings(value['input']);
        } else if (type == 'message' && value['content'] is List<Object?>) {
          for (final part in value['content']! as List<Object?>) {
            if (part is Map<String, Object?> &&
                (part['type'] == 'output_text' || part['type'] == 'refusal')) {
              if (part['text'] case final String text) yield text;
              if (part['refusal'] case final String text) yield text;
              yield* _readableAnnotations(part['annotations']);
            }
          }
        }
      }
    }
    for (final call in entry.toolCalls) {
      yield* _readableJsonStrings(call.arguments);
    }
  }
}

// Citation display fields are readable; encrypted indices and signatures are not.
Iterable<String> _readableAnnotations(Object? value) sync* {
  if (value is List<Object?>) {
    for (final item in value) {
      yield* _readableAnnotations(item);
    }
  } else if (value is Map<String, Object?>) {
    for (final key in [
      'cited_text',
      'document_title',
      'title',
      'url',
      'text',
      'quote',
      'filename',
    ]) {
      if (value[key] case final String text) yield text;
    }
    for (final key in [
      'url_citation',
      'file_citation',
      'file_path',
      'container_file_citation',
    ]) {
      yield* _readableAnnotations(value[key]);
    }
  }
}

Iterable<String> _readableJsonStrings(Object? value) sync* {
  if (value is String) {
    yield value;
  } else if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      yield entry.key;
      yield* _readableJsonStrings(entry.value);
    }
  } else if (value is List<Object?>) {
    for (final element in value) {
      yield* _readableJsonStrings(element);
    }
  }
}

String providerAnswerText(ProviderOutputEntry entry) {
  if (entry.raw case final Map<String, Object?> raw) {
    return '${raw['content'] ?? raw['refusal'] ?? ''}';
  }
  final out = <String>[];
  for (final block in entry.raw as List<Object?>) {
    if (block is! Map<String, Object?>) continue;
    if (block['type'] == 'text' && block['text'] is String) {
      out.add(block['text']! as String);
    }
    if (block['type'] == 'message' && block['content'] is List<Object?>) {
      for (final part in block['content']! as List<Object?>) {
        if (part is Map<String, Object?> &&
            (part['type'] == 'output_text' || part['type'] == 'refusal')) {
          final text = part['text'] ?? part['refusal'];
          if (text is String) out.add(text);
        }
      }
    }
  }
  return out.join('\n');
}

/// A bounded, deterministic projection. The caller redacts before clipping;
/// no provider replay object is retained in the projected segment.
AiAppText buildAiProjectionData({
  required List<AiContextBlock> context,
  required List<AiEntry> entries,
  List<AiChatItem> history = const [],
  required int budget,
  required String Function(String) redact,
}) {
  final nonce = List<int>.generate(
    16,
    (_) => math.Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final opening =
      '<gitlab_data source="conversation_summary" nonce="$nonce">\n';
  const closing = '\n</gitlab_data>';
  const omitted = '[earlier turns omitted]\n';
  final available = budget - opening.length - closing.length - omitted.length;
  if (available < 0) throw const AiFailure(AiFailureKind.contextTooLong);
  final hasPriorSummary = entries.whereType<AppUserEntry>().any(
    (entry) =>
        entry.context.any((block) => block.source == 'conversation_summary'),
  );
  final contextData = AiAppText.join([
    for (final block in hasPriorSummary ? const <AiContextBlock>[] : context)
      block.plainData.plainView(redact),
  ]);
  final contextLimit = (available * .4).floor();
  final head = contextData.clipped(contextLimit, escapeDepth: 1);
  var remaining = available - escapeUntrustedGitLabText(head.encode()).length;
  final recent = <AiAppText>[];
  var dropped = head.plainText.length < contextData.plainText.length;
  AiAppText plain(String text) => AiAppText.plain(redact(text));
  AiAppText toolSummary(AiToolResult result) {
    final data = result.plainData.plainView(redact);
    final firstLine = data.plainText.split('\n').first;
    if (firstLine.startsWith('write ')) {
      return AiAppText.join([
        plain('[tool ${result.name}: '),
        data.clipped(firstLine.length),
        plain(']'),
      ], '');
    }
    return AiAppText.join([
      plain('[tool ${result.name}: '),
      (firstLine.startsWith('[source:')
              ? data.clipped(firstLine.length)
              : plain('[source: tool ${result.name}]'))
          .clipped(512),
      plain(
        '; ${result.content.length} chars; ${result.isError ? 'interrupted' : 'read'}]',
      ),
    ], '');
  }

  final texts = <AiAppText>[
    for (final item in hasPriorSummary ? const <AiChatItem>[] : history)
      plain(switch (item) {
        AiUserItem() => 'User: ${item.text}',
        AiAssistantItem() => 'Assistant (${item.state.name}): ${item.text}',
        AiToolRunItem(:final writeStatus?) =>
          '[write ${item.name}: '
              '${item.resultExcerpt.split('\n').first}; ${writeStatus.name}]',
        AiToolRunItem() =>
          '[tool ${item.name}: ${item.provenance}; ${item.sizeChars} chars; ${item.status.name}]',
        AiNoticeItem() => '[notice: ${item.kind.name}]',
      }),
    for (final entry in entries) ...[
      if (entry is AppUserEntry)
        for (final block in entry.context)
          if (block.source == 'conversation_summary')
            block.plainData.plainView(redact),
      switch (entry) {
        AppUserEntry() => plain('User: ${entry.text}'),
        ProviderOutputEntry() => plain(
          'Assistant: ${providerAnswerText(entry)}',
        ),
        AppToolResultsEntry() => AiAppText.join(
          entry.results.map(toolSummary).toList(),
        ),
      },
      if (entry is AppToolResultsEntry && entry.followUpText != null)
        plain('User: ${entry.followUpText}'),
    ],
  ];
  for (final text in texts.reversed) {
    if (escapeUntrustedGitLabText(text.encode()).length + 1 > remaining) {
      dropped = true;
      break;
    }
    recent.add(text);
    remaining -= escapeUntrustedGitLabText(text.encode()).length + 1;
  }
  return AiAppText.untrusted(
    source: 'conversation_summary',
    nonce: nonce,
    body: AiAppText.join([
      head,
      AiAppText.join([
        if (dropped) const AiAppText.plain(omitted),
        AiAppText.join(recent.reversed.toList()),
      ], ''),
    ]),
  );
}

/// Encoded convenience view; the runner retains [buildAiProjectionData] instead.
String buildAiProjection({
  required List<AiContextBlock> context,
  required List<AiEntry> entries,
  List<AiChatItem> history = const [],
  required int budget,
  required String Function(String) redact,
}) => buildAiProjectionData(
  context: context,
  entries: entries,
  history: history,
  budget: budget,
  redact: redact,
).encode();
