import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';

void main() {
  test('usage totals known input and output token counts', () {
    const usage = AiUsage(
      inputTokens: 12,
      outputTokens: 7,
      cacheCreationInputTokens: 2,
      cacheReadInputTokens: 3,
    );

    expect(usage.totalTokens, 24);
    expect(const AiUsage().totalTokens, isNull);
    expect(const AiUsage(inputTokens: 4).totalTokens, 4);
  });

  test('stream event types keep refusal and terminal state distinct', () {
    const events = <AiEvent>[
      AiStarted(),
      AiReasoningActive(),
      AiTextDelta('partial'),
      AiRefusalDelta('refused'),
      AiFinished(AiStopReason.refusal),
    ];

    expect(events.whereType<AiRefusalDelta>().single.text, 'refused');
    expect(events.whereType<AiFinished>().single.reason, AiStopReason.refusal);
  });
}
