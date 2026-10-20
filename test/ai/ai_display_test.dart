import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';

void main() {
  test('display collections cannot be mutated after construction', () {
    final chips = <AiContextChip>[
      const AiContextChip(source: 'file', preview: 'preview', sizeChars: 7),
    ];
    final item = AiUserItem(text: 'question', chips: chips);
    chips.clear();

    expect(item.chips, hasLength(1));
    expect(
      () => item.chips.add(
        const AiContextChip(source: 'job', preview: 'trace', sizeChars: 5),
      ),
      throwsUnsupportedError,
    );
  });

  test('conversation owns an immutable item snapshot', () {
    final items = <AiChatItem>[
      const AiAssistantItem(text: 'answer', state: AiAssistantState.done),
    ];
    final conversation = AiConversation(items: items);
    items.clear();

    expect(conversation.items, hasLength(1));
    expect(() => conversation.items.clear(), throwsUnsupportedError);
  });
}
