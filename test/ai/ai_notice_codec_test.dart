import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';

void main() {
  test('every notice kind has a stable wire code that reads back', () {
    final conversation = AiConversation(
      items: [for (final kind in AiNoticeKind.values) AiNoticeItem(kind)],
    );
    final json = aiDisplayJson(conversation);
    final codes = [
      for (final item in json['items']! as List<Object?>)
        (item! as Map<String, Object?>)['notice'],
    ];
    expect(codes, contains('private_key_withheld'));
    expect(codes.toSet(), hasLength(AiNoticeKind.values.length));

    final read = aiDisplayFromJson(json);
    expect(
      [for (final item in read.items) (item as AiNoticeItem).kind],
      AiNoticeKind.values,
    );
  });
}
