import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';

Map<String, Object?> _assistant() => {
  'kind': 'assistant',
  'text': 'Synthetic answer',
  'state': 'done',
  'usage': null,
};

Map<String, Object?> _conversation(Map<String, Object?> item) => {
  'items': [item],
};

void main() {
  test('legacy assistant rows keep their bytes and default report fields', () {
    final legacy = _conversation(_assistant());
    final restored = aiDisplayFromJson(legacy);
    final answer = restored.items.single as AiAssistantItem;

    expect(answer.source, isNull);
    expect(answer.reported, isFalse);
    expect(jsonEncode(aiDisplayJson(restored)), jsonEncode(legacy));
  });

  test('assistant report source and true flag survive history round trips', () {
    final marked = _conversation({
      ..._assistant(),
      'source': {
        'presetId': 'openai',
        'format': 'responses',
        'model': 'gpt-synthetic',
      },
      'reported': true,
    });

    final restored = aiDisplayFromJson(marked);
    final answer = restored.items.single as AiAssistantItem;
    expect(answer.source?.presetId, 'openai');
    expect(answer.source?.format, 'responses');
    expect(answer.source?.model, 'gpt-synthetic');
    expect(answer.reported, isTrue);
    expect(aiDisplayJson(restored), marked);
    expect(aiDisplayJson(aiDisplayFromJson(aiDisplayJson(restored))), marked);
  });

  test('explicit false reported is accepted and omitted on write', () {
    final restored = aiDisplayFromJson(
      _conversation({..._assistant(), 'reported': false}),
    );

    expect((restored.items.single as AiAssistantItem).reported, isFalse);
    expect(aiDisplayJson(restored), _conversation(_assistant()));
  });

  for (final invalid in ['true', 1, null, <Object?>[], <String, Object?>{}]) {
    test('history rejects non-bool reported: $invalid', () {
      expect(
        () => aiDisplayFromJson(
          _conversation({..._assistant(), 'reported': invalid}),
        ),
        throwsA(isA<AiHistoryUnsupportedFormat>()),
      );
    });
  }

  for (final invalid in ['source', 1, true, null, <Object?>[]]) {
    test('history rejects non-object source: $invalid', () {
      expect(
        () => aiDisplayFromJson(
          _conversation({..._assistant(), 'source': invalid}),
        ),
        throwsA(isA<AiHistoryUnsupportedFormat>()),
      );
    });
  }

  for (final field in ['presetId', 'format', 'model']) {
    for (final invalid in [null, 1, true, <Object?>[], <String, Object?>{}]) {
      test('history rejects malformed source $field: $invalid', () {
        expect(
          () => aiDisplayFromJson(
            _conversation({
              ..._assistant(),
              'source': {
                'presetId': 'openai',
                'format': 'responses',
                'model': 'gpt-synthetic',
                field: invalid,
              },
            }),
          ),
          throwsA(isA<AiHistoryUnsupportedFormat>()),
        );
      });
    }
  }

  test('history rejects missing and unknown nested source fields', () {
    for (final source in <Map<String, Object?>>[
      {'presetId': 'openai', 'format': 'responses'},
      {
        'presetId': 'openai',
        'format': 'responses',
        'model': 'gpt-synthetic',
        'extra': 'unsupported',
      },
    ]) {
      expect(
        () => aiDisplayFromJson(
          _conversation({..._assistant(), 'source': source}),
        ),
        throwsA(isA<AiHistoryUnsupportedFormat>()),
      );
    }
  });
}
