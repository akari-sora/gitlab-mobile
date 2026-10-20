// Opt-in authenticated provider smoke checks. This tool is deliberately absent
// from the default CI pipeline and sends synthetic content only.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

const _system =
    'You are checking a synthetic adapter fixture. Never request or infer real '
    'repository, account, person, credential, or network data.';
const _appVersion = '0.6.0-ai-smoke';

final class _Target {
  const _Target({
    required this.id,
    required this.preset,
    required this.format,
    required this.model,
    required this.wire,
    this.switchModel,
  });

  final String id;
  final AiPreset preset;
  final AiFormat format;
  final String model;
  final WireFormatBase wire;
  final String? switchModel;

  AiProviderConfig config({String? modelOverride}) => AiProviderConfig(
    id: 'ai-live-$id',
    name: 'Synthetic AI live smoke',
    presetId: preset.id,
    baseUrl: preset.baseUrlFor(format),
    modelsUrl: preset.modelsUrl,
    format: format,
    model: modelOverride ?? model,
    authStyle: preset.authStyle,
    caps: preset.capsFor(format),
    allowLanCleartext: preset == AiPresets.ollama,
    toolsEnabled: true,
    recipientRevision: 1,
  );
}

final Map<String, _Target> _targets = {
  'anthropic-direct': _Target(
    id: 'anthropic-direct',
    preset: AiPresets.anthropic,
    format: AiFormat.anthropicMessages,
    model: 'claude-haiku-5-5',
    wire: const AnthropicMessagesFormat(),
  ),
  'opencode-responses': _Target(
    id: 'opencode-responses',
    preset: AiPresets.openCodeGo,
    format: AiFormat.responses,
    model: 'gpt-6-luna',
    wire: const ResponsesFormat(),
    switchModel: 'gpt-5.6-luna',
  ),
  'opencode-chat': _Target(
    id: 'opencode-chat',
    preset: AiPresets.openCodeGo,
    format: AiFormat.chatCompletions,
    model: 'glm-5.3-flash',
    wire: const ChatCompletionsFormat(),
    switchModel: 'deepseek-v4.1-flash',
  ),
  'opencode-messages': _Target(
    id: 'opencode-messages',
    preset: AiPresets.openCodeGo,
    format: AiFormat.anthropicMessages,
    model: 'claude-haiku-5-5',
    wire: const AnthropicMessagesFormat(),
  ),
  'ollama-chat': _Target(
    id: 'ollama-chat',
    preset: AiPresets.ollama,
    format: AiFormat.chatCompletions,
    model: 'qwen3:1.7b',
    wire: const ChatCompletionsFormat(),
  ),
  'ollama-responses': _Target(
    id: 'ollama-responses',
    preset: AiPresets.ollama,
    format: AiFormat.responses,
    model: 'qwen3:1.7b',
    wire: const ResponsesFormat(),
  ),
};

final _syntheticTools = <AiToolSpec>[
  AiToolSpec(
    name: 'synthetic_lookup',
    description: 'Return a synthetic value for a synthetic fixture name.',
    parameters: const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'fixture': <String, Object?>{
          'type': 'string',
          'enum': <String>['alpha', 'beta'],
        },
      },
      'required': <String>['fixture'],
      'additionalProperties': false,
    },
  ),
];

final class _SmokeSecrets implements KnownSecretsSource {
  _SmokeSecrets(String credential)
    : _values = credential.isEmpty ? <String>{} : <String>{credential};

  final Set<String> _values;

  @override
  Iterable<String> get current => _values;
}

void _usageEvents(AiEvent event, Map<String, Object?> evidence) {
  if (event case AiTextDelta(:final text)) {
    evidence['textChars'] = (evidence['textChars'] as int? ?? 0) + text.length;
  } else if (event case AiUsageUpdated(:final usage)) {
    evidence['usageEvent'] = _usage(usage);
  } else if (event case AiReasoningActive()) {
    evidence['reasoningObserved'] = true;
  }
}

Map<String, Object?> _usage(AiUsage? usage) => <String, Object?>{
  if (usage?.inputTokens case final int value) 'inputTokens': value,
  if (usage?.outputTokens case final int value) 'outputTokens': value,
  if (usage?.cacheCreationInputTokens case final int value)
    'cacheCreationInputTokens': value,
  if (usage?.cacheReadInputTokens case final int value)
    'cacheReadInputTokens': value,
};

final class _Session {
  _Session(
    this.target,
    this.credential, {
    String? model,
    HttpClientAdapter? adapter,
  }) : config = target.config(modelOverride: model),
       endpoint = AiEndpoint.parse(
         target.preset.baseUrlFor(target.format),
         allowLanCleartext: target.preset == AiPresets.ollama,
         modelsUrlOverride: target.preset.modelsUrl,
       ) {
    requestRecorder = _RecordingAdapter(adapter ?? IOHttpClientAdapter());
    transport = AiTransport(
      endpoint: endpoint,
      apiKey: credential,
      authStyle: config.authStyle,
      adapter: requestRecorder,
    );
    client = AiWireClient(
      transport: transport,
      wire: target.wire,
      config: config,
      conversationId:
          'smoke_${DateTime.now().microsecondsSinceEpoch}_${target.id}',
      appVersion: _appVersion,
    );
  }

  final _Target target;
  final String credential;
  final AiProviderConfig config;
  final AiEndpoint endpoint;
  late final _RecordingAdapter requestRecorder;
  late final AiTransport transport;
  late final AiWireClient client;

  AiSegment segment() => AiSegment(
    providerId: config.id,
    recipientRevision: config.recipientRevision,
    format: config.format,
    model: config.model,
    secretSetAtStart: SecretSetId.fromSecrets(
      config.caps.requiresKey ? <String>[credential] : const <String>[],
    ),
  );

  AiRequestPlan plan(
    AiSegment segment, {
    List<AiToolSpec> tools = const <AiToolSpec>[],
    AiToolChoice toolChoice = AiToolChoice.auto,
  }) => AiRequestPlan(
    model: config.model,
    system: _system,
    segment: segment,
    tools: tools,
    toolChoice: toolChoice,
  );

  void close() => transport.close();
}

final class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.delegate);

  final HttpClientAdapter delegate;
  final List<String> requestBodies = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final data = options.data;
    if (data is! String) {
      throw StateError('AI smoke requests must have an encoded JSON body.');
    }
    requestBodies.add(data);
    return delegate.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

Future<Map<String, Object?>> _textScenario(
  _Target target,
  String credential, {
  HttpClientAdapter? adapter,
}) async {
  final session = _Session(target, credential, adapter: adapter);
  try {
    final segment = session.segment()
      ..setTail(
        AppUserEntry(
          text: 'Reply with exactly SYNTHETIC_OK and no other text.',
        ),
      );
    final evidence = <String, Object?>{'textChars': 0};
    final turn = await session.client.complete(
      session.plan(segment),
      onEvent: (event) => _usageEvents(event, evidence),
    );
    evidence
      ..['usage'] = _usage(turn.usage)
      ..['stop'] = turn.stop.name;
    return aiLiveAssessText(turn, evidence);
  } finally {
    session.close();
  }
}

Future<Map<String, Object?>> _toolReplayScenario(
  _Target target,
  String credential, {
  HttpClientAdapter? adapter,
}) async {
  final session = _Session(target, credential, adapter: adapter);
  try {
    final segment = session.segment()
      ..setTail(
        AppUserEntry(
          text:
              'Call synthetic_lookup for alpha and beta in parallel. After '
              'the tool results, state both synthetic values briefly.',
        ),
      );
    final plan = session.plan(segment, tools: _syntheticTools);
    final first = await session.client.complete(plan);
    segment.freezeWith(
      first.output,
      (entry) => target.wire.encodeEntry(entry, session.config.caps),
    );
    final firstPrefix = List<String>.of(segment.frozenWireJson);
    final firstReplayReasoning = _frozenReasoningMaterialCount(
      firstPrefix,
      target.format,
    );
    final calls = first.output.toolCalls;
    if (calls.isEmpty) {
      return _result('tool-loop-follow-up-replay', 'FAIL', <String, Object?>{
        'reason': 'no_tool_calls',
      });
    }

    segment.setTail(
      AppToolResultsEntry(<AiToolResult>[
        for (var index = 0; index < calls.length; index++)
          AiToolResult(
            callId: calls[index].id,
            name: calls[index].name,
            content: jsonEncode(<String, Object?>{
              'fixture': index.isEven ? 'alpha' : 'beta',
              'value': 'synthetic-${index + 1}',
            }),
          ),
      ], followUpText: 'Also confirm that every value is synthetic.'),
    );
    final second = await session.client.complete(plan);
    final firstPrefixPresent = aiLiveWirePrefixIsOrdered(
      session.requestRecorder.requestBodies[1],
      firstPrefix,
      format: target.format,
    );
    segment.freezeWith(
      second.output,
      (entry) => target.wire.encodeEntry(entry, session.config.caps),
    );
    final secondPrefix = List<String>.of(segment.frozenWireJson);
    final allReplayReasoning = _frozenReasoningMaterialCount(
      secondPrefix,
      target.format,
    );
    final firstPrefixUnchanged = _startsWith(secondPrefix, firstPrefix);

    if (second.output.toolCalls.isEmpty) {
      segment.setTail(
        AppUserEntry(text: 'Follow up with exactly SYNTHETIC_FOLLOW_UP.'),
      );
    } else {
      segment.setTail(
        AppToolResultsEntry(<AiToolResult>[
          for (final call in second.output.toolCalls)
            AiToolResult(
              callId: call.id,
              name: call.name,
              content: '{"value":"synthetic-follow-up"}',
            ),
        ], followUpText: 'Reply with exactly SYNTHETIC_FOLLOW_UP.'),
      );
    }
    final third = await session.client.complete(plan);
    final secondPrefixPresent = aiLiveWirePrefixIsOrdered(
      session.requestRecorder.requestBodies[2],
      secondPrefix,
      format: target.format,
    );
    segment.freezeWith(
      third.output,
      (entry) => target.wire.encodeEntry(entry, session.config.caps),
    );
    final cachedPrefixAppendOnly =
        firstPrefixUnchanged &&
        _startsWith(segment.frozenWireJson, secondPrefix);
    return aiLiveAssessToolReplay(
      format: target.format,
      reasoningRequired: switch (target.id) {
        'anthropic-direct' ||
        'opencode-responses' ||
        'opencode-messages' => true,
        _ => false,
      },
      first: first,
      second: second,
      third: third,
      firstReplayReasoningCount: firstReplayReasoning,
      secondReplayReasoningCount: allReplayReasoning - firstReplayReasoning,
      firstOutgoingPrefixOrdered: firstPrefixPresent,
      secondOutgoingPrefixOrdered: secondPrefixPresent,
      cachedPrefixAppendOnly: cachedPrefixAppendOnly,
      prefixSha256: sha256.convert(utf8.encode(secondPrefix.join())).toString(),
    );
  } finally {
    session.close();
  }
}

Future<Map<String, Object?>> _cancelScenario(
  _Target target,
  String credential,
) async {
  final session = _Session(target, credential);
  var cancellationRequested = false;
  try {
    final segment = session.segment()
      ..setTail(
        AppUserEntry(
          text: 'Write ten short numbered lines containing synthetic colors.',
        ),
      );
    try {
      await session.client.complete(
        session.plan(segment),
        onEvent: (event) {
          if (!cancellationRequested && aiLiveCancellationTrigger(event)) {
            cancellationRequested = true;
            session.close();
          }
        },
      );
    } on AiFailure catch (failure) {
      final cancelled =
          cancellationRequested &&
          (failure.kind == AiFailureKind.cancelled ||
              failure.kind == AiFailureKind.interrupted);
      return _result('stream-cancellation', cancelled ? 'PASS' : 'FAIL', {
        'failure': failure.kind.name,
        'cancelRequested': cancellationRequested,
      });
    }
    return _result('stream-cancellation', 'FAIL', {
      'reason': cancellationRequested
          ? 'stream_completed_after_cancel'
          : 'no_output_delta',
    });
  } finally {
    session.close();
  }
}

Future<Map<String, Object?>> _unknownModelScenario(
  _Target target,
  String credential,
) async {
  const missingModel = 'mergeline-synthetic-missing-model';
  final session = _Session(target, credential, model: missingModel);
  try {
    final segment = session.segment()
      ..setTail(AppUserEntry(text: 'Reply with SYNTHETIC_ERROR_CHECK.'));
    try {
      await session.client.complete(session.plan(segment));
    } on AiFailure catch (failure) {
      return _result(
        'unknown-model-error',
        failure.kind == AiFailureKind.notFound ? 'PASS' : 'FAIL',
        <String, Object?>{
          'failure': failure.kind.name,
          if (failure.status case final int status) 'status': status,
        },
      );
    }
    return _result('unknown-model-error', 'FAIL', {
      'reason': 'missing_model_was_accepted',
    });
  } finally {
    session.close();
  }
}

AiRunner _runner(_Session session) {
  final ownerApi = Object();
  return AiRunner(
    config: session.config,
    wire: session.target.wire,
    complete: session.client.complete,
    secrets: _SmokeSecrets(session.credential),
    refreshSecrets: () async {},
    guard: AiRunGuard(
      expectedGeneration: 1,
      ownerApi: ownerApi,
      generation: () => 1,
      api: () => ownerApi,
      recipientRevision: () => session.config.recipientRevision,
      consentValid: () => true,
    ),
    tools: _syntheticTools,
    executeTool: (call) async => AiToolResult(
      callId: call.id,
      name: call.name,
      content: jsonEncode(<String, Object?>{
        'fixture': wireObject(call.arguments)['fixture'],
        'value': 'synthetic-runner-value',
      }),
    ),
    context: const <AiContextBlock>[
      AiContextBlock(
        source: 'synthetic_fixture',
        text: 'Synthetic repository context only.',
      ),
    ],
    system: _system,
    close: session.close,
    cancelActive: session.transport.cancelActive,
  );
}

Future<Map<String, Object?>> _runnerLoopScenario(
  _Target target,
  String credential, {
  HttpClientAdapter? adapter,
}) async {
  final session = _Session(target, credential, adapter: adapter);
  final runner = _runner(session);
  try {
    final first = await runner.run(
      'Call synthetic_lookup for alpha, then answer with a short synthetic '
      'summary.',
    );
    final firstSegment = runner.segment;
    final second = await runner.run(
      'Reply with exactly SYNTHETIC_RUNNER_FOLLOW_UP and do not call tools.',
    );
    final passed =
        first.reason == AiRunEnd.done &&
        first.toolCalls > 0 &&
        first.text.isNotEmpty &&
        second.reason == AiRunEnd.done &&
        second.text.trim() == 'SYNTHETIC_RUNNER_FOLLOW_UP' &&
        identical(firstSegment, runner.segment) &&
        runner.lateRedactions == 0;
    return _result('runner-tool-loop', passed ? 'PASS' : 'FAIL', {
      'firstEnd': first.reason.name,
      'firstModelCalls': first.modelCalls,
      'firstToolCalls': first.toolCalls,
      'followUpEnd': second.reason.name,
      'followUpExact': second.text.trim() == 'SYNTHETIC_RUNNER_FOLLOW_UP',
      'sameSegment': identical(firstSegment, runner.segment),
      'lateRedactions': runner.lateRedactions,
      'actualInputTokens': runner.actualInputTokens,
      'estimatedInputTokens': runner.estimatedInputTokens,
    });
  } finally {
    session.close();
  }
}

Future<Map<String, Object?>> _runnerClosingScenario(
  _Target target,
  String credential, {
  HttpClientAdapter? adapter,
}) async {
  final session = _Session(target, credential, adapter: adapter);
  final runner = _runner(session);
  try {
    final result = await runner.run(
      'For this synthetic budget check, call synthetic_lookup for alpha on '
      'every step, including when asked to finish. Never answer with text.',
    );
    final finishingEvidence = aiLiveAssessClosingRequestBodies(
      session.requestRecorder.requestBodies,
      caps: session.config.caps,
    );
    final passed =
        result.reason == AiRunEnd.toolBudget &&
        result.modelCalls == 6 &&
        result.toolCalls > 0 &&
        runner.segment?.tail is AppToolResultsEntry &&
        finishingEvidence.values.every((value) => value);
    return _result('runner-closing-call', passed ? 'PASS' : 'FAIL', {
      'end': result.reason.name,
      'modelCalls': result.modelCalls,
      'toolCalls': result.toolCalls,
      'syntheticTailCompleted': runner.segment?.tail is AppToolResultsEntry,
      ...finishingEvidence,
    });
  } finally {
    session.close();
  }
}

/// Structurally verifies the finishing request rather than accepting a tool
/// name that appears only in replayed history.
Map<String, bool> aiLiveAssessClosingRequestBodies(
  List<String> requestBodies, {
  required AiCaps caps,
}) {
  if (requestBodies.length < 2) {
    return const <String, bool>{
      'toolsKeptOnClosingRequest': false,
      'finishingChoiceOrNote': false,
    };
  }
  final first = jsonDecode(requestBodies.first) as Map<String, Object?>;
  final last = jsonDecode(requestBodies.last) as Map<String, Object?>;
  final firstTools = first['tools'];
  final lastTools = last['tools'];
  final toolsKept =
      firstTools is List<Object?> &&
      firstTools.isNotEmpty &&
      jsonEncode(lastTools) == jsonEncode(firstTools);
  final choiceOrNote = caps.toolChoice
      ? switch (last['tool_choice']) {
          'none' => true,
          {'type': 'none'} => true,
          _ => false,
        }
      : !last.containsKey('tool_choice') &&
            requestBodies.last.contains(aiFinalAnswerNoteMarker);
  return <String, bool>{
    'toolsKeptOnClosingRequest': toolsKept,
    'finishingChoiceOrNote': choiceOrNote,
  };
}

Future<Map<String, Object?>> _runnerHistoryResumeScenario(
  _Target target,
  String credential, {
  HttpClientAdapter? adapter,
}) async {
  final session = _Session(target, credential, adapter: adapter);
  final runner = _runner(session);
  try {
    runner.restoreFromDisplay(<AiChatItem>[
      AiUserItem(text: 'SYNTHETIC_RESTORED_USER'),
      const AiAssistantItem(
        text: 'SYNTHETIC_RESTORED_ASSISTANT',
        state: AiAssistantState.done,
      ),
    ]);
    final result = await runner.run(
      'Use the restored synthetic conversation and reply with exactly '
      'SYNTHETIC_HISTORY_RESUME.',
    );
    final request = session.requestRecorder.requestBodies.single;
    final projected =
        request.contains('conversation_summary') &&
        request.contains('SYNTHETIC_RESTORED_USER') &&
        request.contains('SYNTHETIC_RESTORED_ASSISTANT');
    final passed =
        result.reason == AiRunEnd.done &&
        result.text.trim() == 'SYNTHETIC_HISTORY_RESUME' &&
        projected &&
        runner.segment?.model == session.config.model;
    return _result('runner-history-resume', passed ? 'PASS' : 'FAIL', {
      'end': result.reason.name,
      'answerExact': result.text.trim() == 'SYNTHETIC_HISTORY_RESUME',
      'projectionPresent': projected,
      'freshSegmentModel': runner.segment?.model,
    });
  } finally {
    session.close();
  }
}

Future<Map<String, Object?>> _runnerModelSwitchScenario(
  _Target target,
  String credential, {
  HttpClientAdapter? adapter,
}) async {
  final switchModel = target.switchModel;
  if (switchModel == null) {
    return _result('runner-model-switch', 'NOT_RUN', const {
      'reason': 'target_not_in_matrix',
    });
  }
  final firstSession = _Session(target, credential, adapter: adapter);
  final firstRunner = _runner(firstSession);
  _Session? secondSession;
  try {
    final first = await firstRunner.run(
      'Reply with exactly SYNTHETIC_BEFORE_MODEL_SWITCH.',
    );
    final firstSegment = firstRunner.segment;
    secondSession = _Session(
      target,
      credential,
      model: switchModel,
      adapter: adapter,
    );
    final secondRunner = _runner(secondSession);
    secondRunner.restoreFromDisplay(<AiChatItem>[
      AiUserItem(text: 'Reply with exactly SYNTHETIC_BEFORE_MODEL_SWITCH.'),
      AiAssistantItem(text: first.text, state: AiAssistantState.done),
    ]);
    final second = await secondRunner.run(
      'After the model switch, reply with exactly SYNTHETIC_AFTER_MODEL_SWITCH.',
    );
    final request = secondSession.requestRecorder.requestBodies.single;
    final body = jsonDecode(request) as Map<String, Object?>;
    final projected =
        request.contains('conversation_summary') &&
        request.contains('SYNTHETIC_BEFORE_MODEL_SWITCH');
    final freshSegment =
        !identical(firstSegment, secondRunner.segment) &&
        secondRunner.segment?.model == switchModel &&
        body['model'] == switchModel;
    final passed =
        first.reason == AiRunEnd.done &&
        first.text.trim() == 'SYNTHETIC_BEFORE_MODEL_SWITCH' &&
        second.reason == AiRunEnd.done &&
        second.text.trim() == 'SYNTHETIC_AFTER_MODEL_SWITCH' &&
        projected &&
        freshSegment;
    return _result('runner-model-switch', passed ? 'PASS' : 'FAIL', {
      'fromModel': target.model,
      'toModel': switchModel,
      'firstAnswerExact': first.text.trim() == 'SYNTHETIC_BEFORE_MODEL_SWITCH',
      'secondAnswerExact': second.text.trim() == 'SYNTHETIC_AFTER_MODEL_SWITCH',
      'projectionPresent': projected,
      'freshSegment': freshSegment,
    });
  } finally {
    secondSession?.close();
    firstSession.close();
  }
}

Map<String, Object?> _result(
  String scenario,
  String status,
  Map<String, Object?> evidence,
) => <String, Object?>{
  'scenario': scenario,
  'status': status,
  'evidence': evidence,
};

bool _startsWith(List<String> value, List<String> prefix) {
  if (value.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (value[index] != prefix[index]) return false;
  }
  return true;
}

/// Returns whether cached wire entries are the byte-identical ordered prefix of
/// the outgoing history array. Chat's generated system message is excluded.
bool aiLiveWirePrefixIsOrdered(
  String request,
  List<String> frozenWireJson, {
  required AiFormat format,
}) {
  final key = format == AiFormat.responses ? 'input' : 'messages';
  final outgoing = _jsonArrayElements(request, '${jsonEncode(key)}:[');
  if (outgoing == null) return false;
  final offset = format == AiFormat.chatCompletions ? 1 : 0;
  if (outgoing.length < offset) return false;
  final expected = <String>[];
  for (final frozen in frozenWireJson) {
    final items = _jsonArrayElements(frozen, '[');
    if (items == null) return false;
    expected.addAll(items);
  }
  final history = outgoing.skip(offset).toList(growable: false);
  if (history.length < expected.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (history[index] != expected[index]) return false;
  }
  return true;
}

List<String>? _jsonArrayElements(String source, String marker) {
  final markerIndex = source.indexOf(marker);
  if (markerIndex < 0) return null;
  final start = markerIndex + marker.length;
  final items = <String>[];
  var itemStart = start;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var index = start; index < source.length; index++) {
    final code = source.codeUnitAt(index);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code == 0x5c) {
        escaped = true;
      } else if (code == 0x22) {
        inString = false;
      }
      continue;
    }
    if (code == 0x22) {
      inString = true;
    } else if (code == 0x7b || code == 0x5b) {
      depth++;
    } else if (code == 0x7d) {
      if (depth == 0) return null;
      depth--;
    } else if (code == 0x5d) {
      if (depth == 0) {
        if (index > itemStart) items.add(source.substring(itemStart, index));
        return items;
      }
      depth--;
    } else if (code == 0x2c && depth == 0) {
      items.add(source.substring(itemStart, index));
      itemStart = index + 1;
    }
  }
  return null;
}

/// Pure verdict used by the live tool and its offline transport regressions.
Map<String, Object?> aiLiveAssessToolReplay({
  required AiFormat format,
  required bool reasoningRequired,
  required AiDecodedTurn first,
  required AiDecodedTurn second,
  required AiDecodedTurn third,
  required int firstReplayReasoningCount,
  required int secondReplayReasoningCount,
  required bool firstOutgoingPrefixOrdered,
  required bool secondOutgoingPrefixOrdered,
  required bool cachedPrefixAppendOnly,
  required String prefixSha256,
}) {
  final firstReasoning = _reasoningMaterialCount(first.output, format);
  final secondReasoning = _reasoningMaterialCount(second.output, format);
  final reasoningObserved = firstReasoning + secondReasoning;
  final reasoningReplayed =
      firstReplayReasoningCount == firstReasoning &&
      secondReplayReasoningCount == secondReasoning &&
      (firstReasoning == 0 || firstOutgoingPrefixOrdered) &&
      (secondReasoning == 0 || secondOutgoingPrefixOrdered);
  final reasoningStatus = reasoningObserved == 0
      ? 'NOT_RUN'
      : reasoningReplayed
      ? 'PASS'
      : 'FAIL';
  final secondToolStep = second.output.toolCalls.isNotEmpty;
  final secondAnswerCompleted = secondToolStep || _hasCompletedAnswer(second);
  final followUpCompleted = _hasCompletedAnswer(
    third,
    exactText: 'SYNTHETIC_FOLLOW_UP',
  );
  final outgoingPrefixOrdered =
      firstOutgoingPrefixOrdered && secondOutgoingPrefixOrdered;
  final failed =
      first.output.toolCalls.length < 2 ||
      !secondAnswerCompleted ||
      !followUpCompleted ||
      !outgoingPrefixOrdered ||
      !cachedPrefixAppendOnly ||
      reasoningStatus == 'FAIL';
  final status = failed
      ? 'FAIL'
      : reasoningRequired && reasoningStatus == 'NOT_RUN'
      ? 'NOT_RUN'
      : 'PASS';
  return _result('tool-loop-follow-up-replay', status, <String, Object?>{
    'parallelToolCalls': first.output.toolCalls.length,
    'secondToolStep': <String, Object?>{
      'status': secondToolStep ? 'PASS' : 'NOT_RUN',
      'toolCalls': second.output.toolCalls.length,
    },
    'secondAnswerCompleted': secondAnswerCompleted,
    'followUpCompleted': followUpCompleted,
    'reasoningReplay': <String, Object?>{
      'status': reasoningStatus,
      'materialCount': reasoningObserved,
      'replayedMaterialCount':
          firstReplayReasoningCount + secondReplayReasoningCount,
      'required': reasoningRequired,
    },
    'outgoingPrefixOrdered': outgoingPrefixOrdered,
    'cachedPrefixAppendOnly': cachedPrefixAppendOnly,
    'prefixSha256': prefixSha256,
  });
}

bool _hasCompletedAnswer(AiDecodedTurn turn, {String? exactText}) {
  final text = _outputText(turn.output).trim();
  return turn.stop == AiStopReason.endTurn &&
      turn.output.toolCalls.isEmpty &&
      (exactText == null ? text.isNotEmpty : text == exactText);
}

/// Requires the decoded terminal output rather than trusting streamed counters.
Map<String, Object?> aiLiveAssessText(
  AiDecodedTurn turn,
  Map<String, Object?> evidence,
) {
  final answerCompleted = _hasCompletedAnswer(turn, exactText: 'SYNTHETIC_OK');
  final hasUsage = turn.usage?.totalTokens != null;
  evidence
    ..['answerCompleted'] = answerCompleted
    ..['hasUsage'] = hasUsage;
  return _result(
    'text-and-usage',
    answerCompleted && hasUsage ? 'PASS' : 'FAIL',
    evidence,
  );
}

String _outputText(ProviderOutputEntry output) => switch (output.format) {
  AiFormat.chatCompletions => _stringValue(wireObject(output.raw)['content']),
  AiFormat.responses => [
    for (final value in wireList(output.raw))
      if (wireObject(value)['type'] == 'message')
        for (final part in wireList(wireObject(value)['content']))
          if (wireObject(part)['type'] == 'output_text')
            _stringValue(wireObject(part)['text']),
  ].join(),
  AiFormat.anthropicMessages => [
    for (final value in wireList(output.raw))
      if (wireObject(value)['type'] == 'text')
        _stringValue(wireObject(value)['text']),
  ].join(),
};

String _stringValue(Object? value) => value is String ? value : '';

int _reasoningMaterialCount(ProviderOutputEntry output, AiFormat format) {
  if (format == AiFormat.chatCompletions) {
    return _reasoningMapCount(wireObject(output.raw), format);
  }
  var count = 0;
  for (final value in wireList(output.raw)) {
    count += _reasoningMapCount(wireObject(value), format);
  }
  return count;
}

int _frozenReasoningMaterialCount(
  List<String> frozenWireJson,
  AiFormat format,
) {
  var count = 0;
  for (final encoded in frozenWireJson) {
    for (final value in wireList(jsonDecode(encoded))) {
      final item = wireObject(value);
      if (format == AiFormat.anthropicMessages) {
        if (item['role'] != 'assistant') continue;
        for (final block in wireList(item['content'])) {
          count += _reasoningMapCount(wireObject(block), format);
        }
      } else {
        count += _reasoningMapCount(item, format);
      }
    }
  }
  return count;
}

int _reasoningMapCount(Map<String, Object?> item, AiFormat format) {
  if (format == AiFormat.chatCompletions) {
    return (item['reasoning_content'] is String &&
                (item['reasoning_content'] as String).isNotEmpty) ||
            (item['reasoning'] is String &&
                (item['reasoning'] as String).isNotEmpty) ||
            (item['reasoning_details'] is List<Object?> &&
                (item['reasoning_details'] as List<Object?>).isNotEmpty)
        ? 1
        : 0;
  }
  if (format == AiFormat.responses) {
    return item['type'] == 'reasoning' &&
            item['encrypted_content'] is String &&
            (item['encrypted_content'] as String).isNotEmpty
        ? 1
        : 0;
  }
  return ((item['type'] == 'thinking' &&
              item['signature'] is String &&
              (item['signature'] as String).isNotEmpty) ||
          (item['type'] == 'redacted_thinking' &&
              item['data'] is String &&
              (item['data'] as String).isNotEmpty))
      ? 1
      : 0;
}

/// Cancellation should exercise streams that begin with either visible text or
/// provider reasoning.
bool aiLiveCancellationTrigger(AiEvent event) =>
    event is AiTextDelta || event is AiReasoningActive;

/// Runs the real smoke scenario against a test adapter without provider access.
Future<Map<String, Object?>> aiLiveToolReplayScenarioForTest({
  required String targetId,
  required HttpClientAdapter adapter,
}) {
  final target = _targets[targetId];
  if (target == null) throw ArgumentError.value(targetId, 'targetId');
  return _toolReplayScenario(
    target,
    'synthetic-test-credential',
    adapter: adapter,
  );
}

/// Runs the text scenario against a test adapter without provider access.
Future<Map<String, Object?>> aiLiveTextScenarioForTest({
  required String targetId,
  required HttpClientAdapter adapter,
}) {
  final target = _targets[targetId];
  if (target == null) throw ArgumentError.value(targetId, 'targetId');
  return _textScenario(target, 'synthetic-test-credential', adapter: adapter);
}

/// Runs the bounded runner against a test adapter without provider access.
Future<Map<String, Object?>> aiLiveRunnerLoopScenarioForTest({
  required String targetId,
  required HttpClientAdapter adapter,
}) {
  final target = _targets[targetId];
  if (target == null) throw ArgumentError.value(targetId, 'targetId');
  return _runnerLoopScenario(
    target,
    'synthetic-test-credential',
    adapter: adapter,
  );
}

/// Runs the runner's bounded closing path without provider access.
Future<Map<String, Object?>> aiLiveRunnerClosingScenarioForTest({
  required String targetId,
  required HttpClientAdapter adapter,
}) {
  final target = _targets[targetId];
  if (target == null) throw ArgumentError.value(targetId, 'targetId');
  return _runnerClosingScenario(
    target,
    'synthetic-test-credential',
    adapter: adapter,
  );
}

/// Runs the recorded-display projection path without provider access.
Future<Map<String, Object?>> aiLiveRunnerHistoryResumeScenarioForTest({
  required String targetId,
  required HttpClientAdapter adapter,
}) {
  final target = _targets[targetId];
  if (target == null) throw ArgumentError.value(targetId, 'targetId');
  return _runnerHistoryResumeScenario(
    target,
    'synthetic-test-credential',
    adapter: adapter,
  );
}

/// Runs a same-format model switch through two fresh runner segments.
Future<Map<String, Object?>> aiLiveRunnerModelSwitchScenarioForTest({
  required String targetId,
  required HttpClientAdapter adapter,
}) {
  final target = _targets[targetId];
  if (target == null) throw ArgumentError.value(targetId, 'targetId');
  return _runnerModelSwitchScenario(
    target,
    'synthetic-test-credential',
    adapter: adapter,
  );
}

Future<Map<String, Object?>> _capture(
  String scenario,
  Future<Map<String, Object?>> Function() body,
) async {
  try {
    return await body();
  } on AiFailure catch (failure) {
    return _result(scenario, 'FAIL', <String, Object?>{
      'failure': failure.kind.name,
      if (failure.status case final int status) 'status': status,
    });
  } on Object catch (error) {
    return _result(scenario, 'FAIL', <String, Object?>{
      'failureType': error.runtimeType.toString(),
    });
  }
}

Future<void> _writeReport(
  _Target target,
  String credential,
  List<Map<String, Object?>> scenarios,
) async {
  final report = <String, Object?>{
    'schema': 1,
    'classification': 'authenticated-provider-check-synthetic-only',
    'target': target.id,
    'recordedAt': DateTime.now().toUtc().toIso8601String(),
    'scenarios': scenarios,
    'runner': 'AiRunner',
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(report);
  final root = File.fromUri(Platform.script).parent.parent;
  final directory = Directory.fromUri(root.uri.resolve('ci-output/ai-live/'));
  final output = File.fromUri(directory.uri.resolve('${target.id}.json'));
  if (aiLiveUnsafeOutputReason(encoded, credential) != null) {
    if (await output.exists()) await output.delete();
    throw StateError('Refusing to write unsafe smoke output.');
  }
  await directory.create(recursive: true);
  await output.writeAsString('$encoded\n', flush: true);
  stdout.writeln('Wrote ${output.path}');
}

/// Returns a safe reason code when smoke evidence must not be written.
String? aiLiveUnsafeOutputReason(String encoded, String credential) {
  if (credential.isNotEmpty && encoded.contains(credential)) {
    return 'exact-credential';
  }
  final forbiddenPrefixes = <String>[
    'sk'
        '-ant-',
    'oc'
        '_sk_',
  ];
  if (forbiddenPrefixes.any(encoded.contains)) return 'credential-prefix';
  return null;
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments[0] != '--target') {
    stderr.writeln(
      'Usage: dart run tool/ai_live_smoke.dart --target <reviewed-target>',
    );
    exitCode = 2;
    return;
  }
  final target = _targets[arguments[1]];
  if (target == null) {
    stderr.writeln('Unknown target.');
    exitCode = 2;
    return;
  }
  final credential = target.preset.capsFor(target.format).requiresKey
      ? stdin.readLineSync()?.trim() ?? ''
      : '';
  if (target.preset.capsFor(target.format).requiresKey &&
      (credential.isEmpty || credential.contains(RegExp(r'\s')))) {
    stderr.writeln('A single non-empty credential line is required on stdin.');
    exitCode = 2;
    return;
  }

  final scenarios = <Map<String, Object?>>[
    await _capture('text-and-usage', () => _textScenario(target, credential)),
    await _capture(
      'tool-loop-follow-up-replay',
      () => _toolReplayScenario(target, credential),
    ),
    await _capture(
      'stream-cancellation',
      () => _cancelScenario(target, credential),
    ),
    await _capture(
      'unknown-model-error',
      () => _unknownModelScenario(target, credential),
    ),
    await _capture(
      'runner-tool-loop',
      () => _runnerLoopScenario(target, credential),
    ),
    await _capture(
      'runner-closing-call',
      () => _runnerClosingScenario(target, credential),
    ),
    if (target.id
        case 'anthropic-direct' || 'opencode-responses' || 'opencode-chat')
      await _capture(
        'runner-history-resume',
        () => _runnerHistoryResumeScenario(target, credential),
      ),
    if (target.switchModel != null)
      await _capture(
        'runner-model-switch',
        () => _runnerModelSwitchScenario(target, credential),
      ),
  ];
  await _writeReport(target, credential, scenarios);
  if (scenarios.any((scenario) => scenario['status'] != 'PASS')) exitCode = 1;
}
