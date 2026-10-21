import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/app_text.dart';

void main() {
  const wrapped = '<gitlab_data source="synthetic">safe</gitlab_data>';

  test('legacy context rejects wrapped data after a provenance line', () {
    expect(
      () => AiContextBlock(
        source: 'synthetic',
        text: '[source: synthetic]\n$wrapped',
      ),
      throwsAssertionError,
    );
  });

  test('legacy tool result rejects wrapped data after leading whitespace', () {
    expect(
      () => AiToolResult(
        callId: 'call',
        name: 'read_file',
        content: '\n$wrapped',
      ),
      throwsAssertionError,
    );
  });

  test('tool result copyWith preserves the structured data path', () {
    final result = AiToolResult.fromData(
      callId: 'call',
      name: 'read_file',
      data: AiAppText.plain('before'),
    );

    final replaced = result.copyWith(data: AiAppText.plain('after'));

    expect(replaced.data, isNotNull);
    expect(replaced.content, 'after');
  });
}
