import 'dart:math' as math;

import 'package:mergeline_on_device_ai/mergeline_on_device_ai.dart';

import '../ai_events.dart';
import '../ai_failure.dart';
import '../ai_provider.dart';
import '../ai_transcript.dart';
import '../app_text.dart';
import '../redaction.dart';
import '../sse.dart';
import 'wire_format.dart';

/// Conservative input token cap for Android AICore / Gemini Nano (hard limit
/// is 4,000 tokens; 600 tokens are reserved for SentencePiece variance).
const int kOnDeviceMaxInputTokens = 3400;

/// Heuristic token estimator for Gemini Nano's SentencePiece vocabulary:
/// ~1.5 tokens per CJK / fullwidth rune and ~1 token per 3 ASCII/other chars.
int estimateOnDeviceTokens(String text) {
  if (text.isEmpty) return 0;
  var cjkRunes = 0;
  var otherChars = 0;
  for (final rune in text.runes) {
    if (_isCjkOrFullwidth(rune)) {
      cjkRunes++;
    } else {
      otherChars++;
    }
  }
  return ((cjkRunes * 3 + 1) ~/ 2) + ((otherChars + 2) ~/ 3);
}

bool _isCjkOrFullwidth(int rune) =>
    (rune >= 0x2E80 && rune <= 0x9FFF) ||
    (rune >= 0xAC00 && rune <= 0xD7AF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0xFE30 && rune <= 0xFE4F) ||
    (rune >= 0xFF00 && rune <= 0xFFEF) ||
    (rune >= 0x20000 && rune <= 0x2FA1F);

String _joinContext(List<AiContextBlock> blocks) =>
    blocks.map((b) => b.text).join('\n\n');

/// Fits [blocks] into [maxTokens] estimated tokens. The first block that does
/// not fit whole is clipped through its plain model ([AiAppText.clipped]), so
/// the `<gitlab_data>` labels and nonce stay intact and the cut end is redacted
/// again; later blocks are dropped. Cutting needs the conversation's
/// [redactor]: without one this throws `contextTooLong` instead of cutting.
({List<AiContextBlock> blocks, bool truncated}) truncateOnDeviceContextBlocks(
  List<AiContextBlock> blocks,
  int maxTokens, {
  Redactor? redactor,
}) {
  if (estimateOnDeviceTokens(_joinContext(blocks)) <= maxTokens) {
    return (
      blocks: List<AiContextBlock>.unmodifiable(blocks),
      truncated: false,
    );
  }
  final kept = <AiContextBlock>[];
  for (final block in blocks) {
    // The '\n\n' separator adds at most one estimated token.
    final used = kept.isEmpty
        ? 0
        : estimateOnDeviceTokens(_joinContext(kept)) + 1;
    final remaining = maxTokens - used;
    if (estimateOnDeviceTokens(block.text) <= remaining) {
      kept.add(block);
      continue;
    }
    final clipped = _clipContextBlock(block, remaining, redactor);
    if (clipped != null) kept.add(clipped);
    break;
  }
  return (blocks: List<AiContextBlock>.unmodifiable(kept), truncated: true);
}

AiContextBlock? _clipContextBlock(
  AiContextBlock block,
  int maxTokens,
  Redactor? redactor,
) {
  if (maxTokens <= 0) return null;
  if (redactor == null) {
    throw const AiFailure(AiFailureKind.contextTooLong, notSent: true);
  }
  AiContextBlock? best;
  var low = 1;
  var high = block.text.length - 1;
  while (low <= high) {
    final mid = low + (high - low) ~/ 2;
    final candidate = AiContextBlock.fromData(
      source: block.source,
      data: block.plainData.clipped(mid),
    ).redact(redactor);
    if (estimateOnDeviceTokens(candidate.text) <= maxTokens) {
      best = candidate;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  if (best == null || best.plainData.plainText.isEmpty) return null;
  return best;
}

final class OnDeviceAssembledPrompt {
  OnDeviceAssembledPrompt({
    required this.system,
    required List<OnDeviceTurn> turns,
    required this.prompt,
    required this.estimatedInputTokens,
    required this.maxOutputTokens,
    required this.contextTruncated,
    required this.historyDropped,
    required List<AiContextBlock> sentContext,
    required List<String> plainStrings,
  }) : turns = List<OnDeviceTurn>.unmodifiable(turns),
       sentContext = List<AiContextBlock>.unmodifiable(sentContext),
       plainStrings = List<String>.unmodifiable(plainStrings);

  final String system;
  final List<OnDeviceTurn> turns;
  final String prompt;
  final int estimatedInputTokens;
  final int maxOutputTokens;

  /// The current page context was clipped or partly dropped.
  final bool contextTruncated;

  /// Older turns were left out; nothing was cut.
  final bool historyDropped;
  final List<AiContextBlock> sentContext;

  /// Every plain value sent (system, texts, context values), before any
  /// wire escaping: what the transport checks against the redactor.
  final List<String> plainStrings;
}

final _boundPrompts =
    Expando<({OnDeviceAssembledPrompt prompt, Redactor redactor})>(
      'onDevicePrompt',
    );

/// Binds the runner's single assembly, made with the conversation's
/// [redactor], to the [plan] it sends, so the transport never assembles again.
void bindOnDevicePrompt(
  AiRequestPlan plan,
  OnDeviceAssembledPrompt prompt,
  Redactor redactor,
) => _boundPrompts[plan] = (prompt: prompt, redactor: redactor);

({OnDeviceAssembledPrompt prompt, Redactor redactor})? boundOnDevicePrompt(
  AiRequestPlan plan,
) => _boundPrompts[plan];

/// Assembles a prompt and turn list for Android AICore / Gemini Nano under
/// [maxInputTokens] (3,400 by default), truncating `<gitlab_data>` context
/// blocks safely when needed.
OnDeviceAssembledPrompt assembleOnDevicePrompt(
  AiRequestPlan plan, {
  int maxInputTokens = kOnDeviceMaxInputTokens,
  Redactor? redactor,
}) {
  if (plan.segment.format != AiFormat.onDevicePrompt ||
      plan.segment.model != plan.model ||
      !plan.segment.replayable ||
      plan.tools.isNotEmpty) {
    throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
  }
  final tail = plan.segment.tail;
  if (tail is! AppUserEntry) {
    throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
  }
  for (final entry in plan.segment.frozen) {
    if (entry is AppToolResultsEntry) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    if (entry is ProviderOutputEntry &&
        (entry.format != AiFormat.onDevicePrompt ||
            entry.toolCalls.isNotEmpty)) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
  }

  // AICore (checked on prod_aicore_20260917, nano-v2) answers only the first
  // user Content of a multi-turn request, so a follow-up sent as
  // [user, model, user] got the first answer again. Earlier turns therefore
  // travel inside the one user turn, in <conversation_history>.
  const historyOpen = '<conversation_history>';
  const historyClose = '</conversation_history>';
  final systemSection =
      '<system_instructions>\n${plan.system}\n</system_instructions>';
  final userSection = '<user_request>\n${tail.text}\n</user_request>';
  final basePrompt = '$systemSection\n\n$userSection';
  final baseTokens = estimateOnDeviceTokens(basePrompt);
  if (baseTokens > maxInputTokens) {
    throw const AiFailure(AiFailureKind.contextTooLong, notSent: true);
  }

  var contextTruncated = false;
  var historyDropped = false;
  final historyEntries = <_HistoryTurn>[];
  for (final entry in plan.segment.frozen) {
    switch (entry) {
      case AppUserEntry(:final text, :final context):
        final sectionParts = <String>[
          for (final block in context) block.text,
          if (text.isNotEmpty) '<user_turn>\n$text\n</user_turn>',
        ];
        if (sectionParts.isNotEmpty) {
          historyEntries.add((
            role: OnDeviceRole.user,
            section: sectionParts.join('\n\n'),
            plain: <String>[
              for (final block in context) ...block.plainData.plainStrings,
              text,
            ],
          ));
        }
      case ProviderOutputEntry(:final raw):
        final map = wireObject(raw);
        final content = map['content'];
        if (content is String && content.isNotEmpty) {
          historyEntries.add((
            role: OnDeviceRole.model,
            section: '<assistant_turn>\n$content\n</assistant_turn>',
            plain: <String>[content],
          ));
        }
      case AppToolResultsEntry():
        throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
  }

  // Fit prior turns, most recent first. A turn that does not fit is dropped
  // whole (never cut), together with every older turn.
  final keptHistoryRev = <_HistoryTurn>[];
  if (historyEntries.isNotEmpty) {
    final remainingForHistoryAndContext =
        maxInputTokens - baseTokens - (tail.context.isNotEmpty ? 4 : 0);
    final tailContextTokens = tail.context.isEmpty
        ? 0
        : estimateOnDeviceTokens(_joinContext(tail.context));
    final reservedForTailContext = math.min(
      tailContextTokens,
      math.min(remainingForHistoryAndContext, 1400),
    );
    var historyBudget = math.max(
      0,
      remainingForHistoryAndContext -
          reservedForTailContext -
          4 -
          estimateOnDeviceTokens('$historyOpen\n\n$historyClose'),
    );
    for (var i = historyEntries.length - 1; i >= 0; i--) {
      final item = historyEntries[i];
      final partTokens = estimateOnDeviceTokens(item.section);
      if (partTokens > historyBudget) {
        historyDropped = true;
        break;
      }
      keptHistoryRev.add(item);
      historyBudget -= partTokens + 2;
    }
    // The kept history starts with a user turn, as the model expects.
    while (keptHistoryRev.isNotEmpty &&
        keptHistoryRev.last.role == OnDeviceRole.model) {
      keptHistoryRev.removeLast();
      historyDropped = true;
    }
  }
  final keptHistory = keptHistoryRev.reversed.toList(growable: false);
  final historySection = keptHistory.isEmpty
      ? ''
      : '$historyOpen\n'
            '${keptHistory.map((item) => item.section).join('\n\n')}\n'
            '$historyClose';

  final promptWithoutContext = [
    systemSection,
    if (historySection.isNotEmpty) historySection,
    userSection,
  ].join('\n\n');
  final nonContextTokens = estimateOnDeviceTokens(promptWithoutContext);
  if (nonContextTokens > maxInputTokens) {
    throw const AiFailure(AiFailureKind.contextTooLong, notSent: true);
  }

  var sentContext = tail.context;
  if (tail.context.isNotEmpty) {
    var contextBudget = math.max(0, maxInputTokens - nonContextTokens - 2);
    var fitted = truncateOnDeviceContextBlocks(
      tail.context,
      contextBudget,
      redactor: redactor,
    );
    sentContext = fitted.blocks;
    contextTruncated |= fitted.truncated;

    String buildPrompt(List<AiContextBlock> blocks) {
      final contextSection = blocks.map((b) => b.text).join('\n\n');
      return [
        systemSection,
        if (historySection.isNotEmpty) historySection,
        if (contextSection.isNotEmpty) contextSection,
        userSection,
      ].join('\n\n');
    }

    var candidatePrompt = buildPrompt(sentContext);
    while (estimateOnDeviceTokens(candidatePrompt) > maxInputTokens &&
        contextBudget > 0 &&
        sentContext.isNotEmpty) {
      final overage = estimateOnDeviceTokens(candidatePrompt) - maxInputTokens;
      contextBudget = math.max(0, contextBudget - math.max(1, overage));
      fitted = truncateOnDeviceContextBlocks(
        tail.context,
        contextBudget,
        redactor: redactor,
      );
      sentContext = fitted.blocks;
      contextTruncated = true;
      candidatePrompt = buildPrompt(sentContext);
    }
    if (estimateOnDeviceTokens(candidatePrompt) > maxInputTokens) {
      sentContext = const <AiContextBlock>[];
      contextTruncated = true;
    }
  }

  final contextSection = sentContext.map((b) => b.text).join('\n\n');
  final finalPrompt = [
    systemSection,
    if (historySection.isNotEmpty) historySection,
    if (contextSection.isNotEmpty) contextSection,
    userSection,
  ].join('\n\n');
  final estimatedTokens = estimateOnDeviceTokens(finalPrompt);
  if (estimatedTokens > maxInputTokens) {
    throw const AiFailure(AiFailureKind.contextTooLong, notSent: true);
  }
  // A first turn keeps its plain shape. A follow-up is one user turn: the
  // prompt above without the system section, which goes as the system
  // instruction, so the 3,400-token check covers everything sent.
  final turns = <OnDeviceTurn>[
    OnDeviceTurn.user(
      [
        if (historySection.isNotEmpty) historySection,
        if (contextSection.isNotEmpty) contextSection,
        if (historySection.isEmpty) tail.text else userSection,
      ].join('\n\n'),
    ),
  ];
  final maxOutputTokens = plan.maxOutputTokens.clamp(1, 4096);
  return OnDeviceAssembledPrompt(
    system: plan.system,
    turns: turns,
    prompt: finalPrompt,
    estimatedInputTokens: estimatedTokens,
    maxOutputTokens: maxOutputTokens,
    contextTruncated: contextTruncated,
    historyDropped: historyDropped,
    sentContext: sentContext,
    plainStrings: <String>[
      plan.system,
      for (final item in keptHistory) ...item.plain,
      for (final block in sentContext) ...block.plainData.plainStrings,
      tail.text,
    ],
  );
}

typedef _HistoryTurn = ({
  OnDeviceRole role,
  String section,
  List<String> plain,
});

final class OnDevicePromptFormat extends WireFormatBase {
  const OnDevicePromptFormat();

  @override
  AiFormat get format => AiFormat.onDevicePrompt;

  @override
  List<String> get streamPath => const <String>[];

  @override
  Map<String, Object?> encode(AiRequestPlan plan, AiCaps caps) {
    if (plan.segment.format != format) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final messages = <Object?>[
      <String, Object?>{'role': 'system', 'content': plan.system},
      ...encodeWireEntries(plan, caps, encodeEntry),
    ];
    final body = <String, Object?>{
      'model': plan.model,
      'system': plan.system,
      'messages': messages,
      'max_output_tokens': plan.maxOutputTokens,
    };
    if (plan.tools.isNotEmpty) {
      body['tools'] = [
        for (final tool in plan.tools)
          <String, Object?>{
            'type': 'function',
            'function': <String, Object?>{
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
          },
      ];
      if (caps.toolChoice) body['tool_choice'] = plan.toolChoice.name;
    }
    return body;
  }

  @override
  List<Object?> encodeEntry(AiEntry entry, AiCaps caps) => switch (entry) {
    AppUserEntry() => [
      <String, Object?>{'role': 'user', 'content': userEntryText(entry)},
    ],
    ProviderOutputEntry() => [_replayMessage(entry, caps)],
    AppToolResultsEntry() => [
      for (final result in entry.results)
        <String, Object?>{
          'role': 'tool',
          'tool_call_id': result.callId,
          'content': result.content,
        },
      if (entry.followUpText case final String text)
        <String, Object?>{'role': 'user', 'content': text},
    ],
  };

  Map<String, Object?> _replayMessage(ProviderOutputEntry entry, AiCaps caps) {
    if (entry.format != format) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final message = wireObject(entry.raw);
    if (caps.replayChatExtras) return message;
    return <String, Object?>{
      for (final key in const [
        'role',
        'content',
        'refusal',
        'tool_calls',
        'function_call',
      ])
        if (message.containsKey(key)) key: message[key],
    };
  }

  @override
  AiStreamDecoder newDecoder() => OnDeviceStreamDecoder();
}

final class OnDeviceStreamDecoder implements AiStreamDecoder {
  final StringBuffer _content = StringBuffer();
  bool _started = false;
  bool _finished = false;
  AiUsage? _usage;

  @override
  List<AiEvent> add(SseEvent event) {
    if (_finished) return const <AiEvent>[];
    if (event.data == '[DONE]') {
      _finished = true;
      return <AiEvent>[AiFinished(AiStopReason.endTurn, usage: _usage)];
    }
    final emitted = <AiEvent>[];
    if (!_started) {
      _started = true;
      emitted.add(const AiStarted());
    }
    if (event.data.isNotEmpty) {
      _content.write(event.data);
      emitted.add(AiTextDelta(event.data));
    }
    return emitted;
  }

  @override
  AiDecodedTurn finish() {
    if (!_finished) throw const AiFailure(AiFailureKind.interrupted);
    return AiDecodedTurn(
      ProviderOutputEntry(AiFormat.onDevicePrompt, <String, Object?>{
        'role': 'assistant',
        'content': _content.toString(),
      }, toolCalls: const <AiToolCall>[]),
      AiStopReason.endTurn,
      _usage,
    );
  }
}
