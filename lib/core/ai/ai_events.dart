enum AiStopReason { endTurn, maxTokens, contentFilter, refusal, other }

/// Provider token counts normalized to disjoint, nonnegative categories.
///
/// [inputTokens] excludes cache reads, and for Anthropic also cache creation,
/// which Anthropic reports separately; [totalTokens] sums each known category
/// once. Null means unknown, not a reported zero. Chat and Responses subtract
/// only cache reads from their inclusive input counts (cache-write counts are
/// not parsed). Inconsistent cache splits are dropped, and malformed counts
/// stay unknown in Chat and Responses, preserving their otherwise completed
/// provider turns; a usage object with no usable count is ignored.
final class AiUsage {
  const AiUsage({
    this.inputTokens,
    this.outputTokens,
    this.cacheCreationInputTokens,
    this.cacheReadInputTokens,
  });

  final int? inputTokens;
  final int? outputTokens;
  final int? cacheCreationInputTokens;
  final int? cacheReadInputTokens;

  int? get totalTokens {
    final input = inputTokens;
    final output = outputTokens;
    final cacheCreation = cacheCreationInputTokens;
    final cacheRead = cacheReadInputTokens;
    if (input == null &&
        output == null &&
        cacheCreation == null &&
        cacheRead == null) {
      return null;
    }
    return (input ?? 0) +
        (output ?? 0) +
        (cacheCreation ?? 0) +
        (cacheRead ?? 0);
  }
}

sealed class AiEvent {
  const AiEvent();
}

final class AiStarted extends AiEvent {
  const AiStarted();
}

final class AiTextDelta extends AiEvent {
  const AiTextDelta(this.text);

  final String text;
}

final class AiRefusalDelta extends AiEvent {
  const AiRefusalDelta(this.text);

  final String text;
}

final class AiReasoningActive extends AiEvent {
  const AiReasoningActive();
}

final class AiUsageUpdated extends AiEvent {
  const AiUsageUpdated(this.usage);

  final AiUsage usage;
}

final class AiFinished extends AiEvent {
  const AiFinished(this.reason, {this.usage});

  final AiStopReason reason;
  final AiUsage? usage;
}
