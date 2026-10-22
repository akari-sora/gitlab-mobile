import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';

Map<String, Object?> _tool() => {
  'kind': 'tool',
  'name': 'get_issue',
  'argsPreview': '#3',
  'status': 'completed',
  'sizeChars': 12,
  'provenance': 'issue #3',
  'truncated': false,
  'blocked': false,
  'resultExcerpt': 'Synthetic note',
};

Map<String, Object?> _chip() => {
  'source': 'issue #3',
  'preview': 'Synthetic note',
  'sizeChars': 12,
  'blocked': false,
  'type': null,
  'resource': '#3',
  'pinnedSha': null,
};

Map<String, Object?> _conversation({
  Map<String, Object?>? tool,
  Map<String, Object?>? chip,
}) => {
  'items': [
    {
      'kind': 'user',
      'text': 'Explain the note',
      'chips': [chip ?? _chip()],
    },
    tool ?? _tool(),
  ],
};

void main() {
  test(
    'legacy tool rows and chips default to public without changing bytes',
    () {
      final legacy = _conversation();
      final restored = aiDisplayFromJson(legacy);
      expect(
        (restored.items.first as AiUserItem).chips.single.internal,
        isFalse,
      );
      expect((restored.items.last as AiToolRunItem).internal, isFalse);
      expect(jsonEncode(aiDisplayJson(restored)), jsonEncode(legacy));
    },
  );

  test('true internal flags survive tool and chip history round trips', () {
    final marked = _conversation(
      tool: {..._tool(), 'internal': true, 'confidential': true},
      chip: {..._chip(), 'internal': true},
    );
    final restored = aiDisplayFromJson(marked);
    final user = restored.items.first as AiUserItem;
    final tool = restored.items.last as AiToolRunItem;
    expect(user.chips.single.internal, isTrue);
    expect(tool.internal, isTrue);
    expect(tool.confidential, isTrue);
    expect(aiDisplayJson(restored), marked);
    expect(aiDisplayJson(aiDisplayFromJson(aiDisplayJson(restored))), marked);
  });

  test('explicit false internal flags are read but omitted on write', () {
    final restored = aiDisplayFromJson(
      _conversation(
        tool: {..._tool(), 'internal': false},
        chip: {..._chip(), 'internal': false},
      ),
    );
    expect((restored.items.first as AiUserItem).chips.single.internal, isFalse);
    expect((restored.items.last as AiToolRunItem).internal, isFalse);
    expect(aiDisplayJson(restored), _conversation());
  });

  for (final invalid in ['true', 1, null, <Object?>[], <String, Object?>{}]) {
    for (final onChip in [false, true]) {
      test('history rejects non-bool internal=$invalid on chip=$onChip', () {
        expect(
          () => aiDisplayFromJson(
            _conversation(
              tool: onChip ? null : {..._tool(), 'internal': invalid},
              chip: onChip ? {..._chip(), 'internal': invalid} : null,
            ),
          ),
          throwsA(isA<AiHistoryUnsupportedFormat>()),
        );
      });
    }
  }
}
