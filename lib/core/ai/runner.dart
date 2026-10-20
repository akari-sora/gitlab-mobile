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
import 'redaction.dart';
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
    List<AiToolSpec> tools = const [],
    this.executeTool,
    this.resetToolBudget,
    this.beginToolTurn,
    this.confirmCleartext,
    this.listInterfaceAddresses = listAiInterfaceAddresses,
    List<AiContextBlock> context = const [],
    bool contextWithheldPrivateKeyContext = false,
    this.conversationTokenCap = 500000,
    this.maxOutputTokens = 4096,
    this.toolDeadline = const Duration(seconds: 20),
    this.runDeadline = const Duration(minutes: 12),
  }) : _config = config,
       _complete = complete,
       _close = close,
       tools = List.unmodifiable(config.toolsEnabled ? tools : <AiToolSpec>[]),
       context = List.unmodifiable(context),
       _redactor = Redactor(secrets: secrets),
       _withheld = contextWithheldPrivateKeyContext {
    if (wire.format != config.format ||
        conversationTokenCap <= 0 ||
        maxOutputTokens < 2048 ||
        toolDeadline <= Duration.zero ||
        runDeadline <= Duration.zero) {
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
  final List<AiToolSpec> tools;
  final Future<AiToolResult> Function(AiToolCall)? executeTool;
  final void Function()? resetToolBudget;
  final void Function()? beginToolTurn;
  final Future<bool> Function()? confirmCleartext;
  final AiInterfaceAddressLister listInterfaceAddresses;
  final List<AiContextBlock> context;
  final int conversationTokenCap;
  final int maxOutputTokens;
  final Duration toolDeadline;
  final Duration runDeadline;
  final Redactor _redactor;

  List<AiChatItem> _displayHistory = const [];
  AiSegment? _segment;
  AiSegment? get segment => _segment;
  SecretSetId? _verifiedSecrets;
  var _verifiedLength = -1;
  var _epoch = 0;
  var _running = false;
  var _pendingRead = false;
  var _needsProjection = false;
  bool _withheld;
  Completer<void>? _stopSignal;
  AiRunEnd _stopReason = AiRunEnd.stopped;
  String _segmentSystem = '';
  List<AiToolSpec> _segmentTools = const [];
  List<AiContextBlock> _segmentContext = const [];
  int actualInputTokens = 0;
  int estimatedInputTokens = 0;
  int lateRedactions = 0;

  /// Called by the settings/session listener as well as at every checkpoint.
  /// A changed recipient or revoked consent immediately closes the transport.
  void checkNow() {
    if (_running && !guard.valid(config.recipientRevision)) {
      stop(AiRunEnd.stoppedBySettings);
    }
  }

  void stop([AiRunEnd reason = AiRunEnd.stopped]) {
    _stopReason = reason;
    _epoch++;
    if (_stopSignal case final signal? when !signal.isCompleted) {
      signal.complete();
    }
    _close();
  }

  /// Only a key/revision change may preserve this conversation. A different
  /// recipient contract must create a new conversation in the caller.
  void replaceKeyRecipient({
    required AiProviderConfig config,
    required AiComplete complete,
    required void Function() close,
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

  Future<AiRunResult> run(String userText) async {
    if (_running) throw StateError('A runner has one active send.');
    _running = true;
    final epoch = ++_epoch;
    _stopSignal = Completer<void>();
    final timer = Timer(runDeadline, () => stop(AiRunEnd.failed));
    var modelCalls = 0;
    var toolCalls = 0;
    var outputChars = 0;
    var finishing = false;
    var answer = '';
    var partial = StringBuffer();
    final segmentBeforeSend = _segment;
    AiEntry? previousTail;
    var froze = false;
    AiEntry? beforeFinishingNote;

    AiToolResult synthetic(AiToolCall call, String reason) {
      final content = clipAiText(
        _redact(_synthetic(call, reason).content),
        math.min(20000, 120000 - outputChars),
      );
      outputChars += content.length;
      return AiToolResult(
        callId: call.id,
        name: call.name,
        content: content,
        isError: true,
      );
    }

    AiRunResult result(
      AiRunEnd reason, {
      AiFailure? failure,
      bool offer = false,
    }) => AiRunResult(
      reason: reason,
      text: answer,
      modelCalls: modelCalls,
      toolCalls: toolCalls,
      failure: failure,
      offerRollover: offer,
      withheldPrivateKeyContext: _withheld,
    );

    try {
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
        finishing |= call == 6 || toolCalls >= 12 || outputChars >= 120000;
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
          seg.clipTailToolResults(
            math.max(0, chars - (size + reserve - config.caps.maxRequestChars)),
          );
          finishing = true;
        }
        beforeFinishingNote = seg.tail;
        if (finishing && !config.caps.toolChoice) seg.addFinalAnswerNote();
        await _redactTail(seg, epoch);
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
        AiDecodedTurn turn;
        AiUsage? latestUsage;
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
                }
                if (event is AiUsageUpdated) latestUsage = event.usage;
                if (event is AiFinished && event.usage != null) {
                  latestUsage = event.usage;
                }
              },
            ).timeout(
              const Duration(minutes: 5),
              onTimeout: () {
                if (_running && epoch == _epoch) _close();
                throw const AiFailure(AiFailureKind.timeout);
              },
            ),
            epoch,
          );
          latestUsage = turn.usage ?? latestUsage;
        } finally {
          _recordUsage(latestUsage, encoded.length);
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
          for (var index = 0; index < calls.length; index++) {
            _check(epoch);
            final tc = calls[index];
            if (index >= 4 || toolCalls >= 12 || outputChars >= 120000) {
              results.add(synthetic(tc, 'budget'));
              continue;
            }
            toolCalls++;
            if (_pendingRead || executeTool == null || tools.isEmpty) {
              results.add(
                synthetic(tc, _pendingRead ? 'read_pending' : 'unavailable'),
              );
              continue;
            }
            _pendingRead = true;
            // Keep the underlying read owned until it settles. A soft timeout
            // or stop never grants permission to start a second read.
            final pending = Future<AiToolResult>.sync(() => executeTool!(tc));
            unawaited(
              pending.then<void>(
                (_) => _pendingRead = false,
                onError: (Object _, StackTrace _) {
                  _pendingRead = false;
                },
              ),
            );
            AiToolResult toolResult;
            try {
              toolResult = await _interruptible(
                pending.timeout(toolDeadline),
                epoch,
              );
            } on TimeoutException {
              toolResult = _synthetic(tc, 'timeout');
            } on _RunStopped {
              rethrow;
            } on Object {
              toolResult = _synthetic(tc, 'read_failed');
            }
            _check(epoch);
            await _refresh(epoch);
            // Whole tool content is redacted before any output truncation.
            final content = _redact(toolResult.content);
            final clipped = clipAiText(
              content,
              math.min(20000, 120000 - outputChars),
            );
            outputChars += clipped.length;
            _check(epoch);
            results.add(
              AiToolResult(
                callId: tc.id,
                name: tc.name,
                content: clipped,
                isError: toolResult.isError,
              ),
            );
          }
        } on _RunStopped catch (stopped) {
          exitReason = stopped.reason;
          rethrow;
        } finally {
          // Pair by position, not ID: hostile duplicate IDs cannot hide a call.
          seg.setTail(
            AppToolResultsEntry([
              ...results,
              for (final tc in calls.skip(results.length))
                synthetic(tc, exitReason.name),
            ]),
          );
        }
      }
      return result(AiRunEnd.toolBudget);
    } on _RunStopped catch (stopped) {
      _segment?.restoreTail(
        froze ? beforeFinishingNote ?? _segment?.tail : previousTail,
      );
      answer = await _partialAnswer(answer, partial.toString(), epoch);
      return result(stopped.reason);
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
      timer.cancel();
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
      await _refresh(epoch);
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
        blocks.add(
          AiContextBlock(
            source: _redact(block.source),
            text: _redact(block.text),
          ),
        );
      }
    }
    seg.setTail(AppUserEntry(text: text, context: blocks));
  }

  AiSegment _newSegment(String userText, {AiSegment? previous}) {
    _segmentSystem = _redact(system);
    _segmentTools = [
      for (final tool in tools)
        AiToolSpec(
          name: tool.name,
          description: _redact(tool.description),
          parameters: wireObject(
            jsonDecode(_redact(jsonEncode(tool.parameters))),
          ),
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
      final summary = buildAiProjection(
        context: context,
        entries: previous?.entries ?? const [],
        history: _displayHistory,
        budget: budget,
        redact: _redact,
      );
      _segmentContext = [
        AiContextBlock(source: 'conversation_summary', text: summary),
      ];
    }
    _segment = next;
    _verifiedSecrets = null;
    _verifiedLength = -1;
    _needsProjection = false;
    return next;
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

  String _redact(String text, {bool late = false}) {
    // Refuse before scanning or splitting a source; never cut a key in half.
    if (text.length > 2 * 1024 * 1024 ||
        utf8.encode(text).length > 2 * 1024 * 1024) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final redacted = _redactor.redactSource(stripAiAnsi(text));
    _withheld |= redacted.withheldPrivateKeyContext;
    if (late) lateRedactions += redacted.redactions;
    return redacted.text;
  }

  Future<void> _redactTail(AiSegment seg, int epoch) async {
    await _refresh(epoch);
    final tail = seg.tail;
    if (tail is AppUserEntry) {
      seg.setTail(
        AppUserEntry(
          text: _redact(tail.text, late: true),
          context: [
            for (final block in tail.context)
              AiContextBlock(
                source: _redact(block.source),
                text: _redact(block.text),
              ),
          ],
        ),
      );
    } else if (tail is AppToolResultsEntry) {
      seg.setTail(
        tail.copyWith(
          results: [
            for (final result in tail.results)
              result.copyWith(content: _redact(result.content, late: true)),
          ],
          followUpText: tail.followUpText == null
              ? null
              : _redact(tail.followUpText!, late: true),
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
    final needles = secrets.current.where((s) => s.isNotEmpty).toList();
    final values = <String>[
      _segmentSystem,
      for (final tool in _segmentTools) tool.description,
      for (final tool in _segmentTools) jsonEncode(tool.parameters),
      for (final entry in seg.frozen) ...readableAiEntry(entry),
    ];
    for (final text in values) {
      if (needles.any(text.contains)) return false;
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

AiToolResult _synthetic(AiToolCall call, String reason) => AiToolResult(
  callId: call.id,
  name: call.name,
  content: '[source: tool]\nNot executed: $reason',
  isError: true,
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
      yield block.text;
    }
  } else if (entry is AppToolResultsEntry) {
    for (final result in entry.results) {
      yield result.content;
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
            }
          }
        }
      }
    }
    for (final call in entry.toolCalls) {
      yield jsonEncode(call.arguments);
      yield* _readableJsonStrings(call.arguments);
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
String buildAiProjection({
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
  String escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final contextText = context
      .map((block) => escape(redact(block.text)))
      .join('\n');
  final head = clipAiText(contextText, (available * .4).floor());
  var remaining = available - head.length;
  final recent = <String>[];
  var dropped = false;
  final texts = <String>[
    for (final item in history)
      switch (item) {
        AiUserItem() => 'User: ${item.text}',
        AiAssistantItem() => 'Assistant (${item.state.name}): ${item.text}',
        AiToolRunItem() =>
          '[tool ${item.name}: ${item.provenance}; ${item.sizeChars} chars; ${item.status.name}]',
        AiNoticeItem() => '[notice: ${item.kind.name}]',
      },
    for (final entry in entries)
      switch (entry) {
        AppUserEntry() => 'User: ${entry.text}',
        ProviderOutputEntry() => 'Assistant: ${providerAnswerText(entry)}',
        AppToolResultsEntry() =>
          entry.results
              .map((r) {
                final firstLine = r.content.split('\n').first;
                final provenance = firstLine.startsWith('[source:')
                    ? clipAiText(firstLine, 512)
                    : '[source: tool ${r.name}]';
                return '[tool ${r.name}: $provenance; ${r.content.length} chars; ${r.isError ? 'interrupted' : 'read'}]';
              })
              .join('\n'),
      },
  ];
  for (final text in texts.reversed) {
    final safe = escape(redact(text));
    if (safe.length + 1 > remaining) {
      dropped = true;
      break;
    }
    recent.add(safe);
    remaining -= safe.length + 1;
  }
  return '$opening$head\n${dropped ? omitted : ''}${recent.reversed.join('\n')}$closing';
}
