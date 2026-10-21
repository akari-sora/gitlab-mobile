import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';

void main() {
  const encoded =
      '<gitlab_data source="synthetic">safe&amp;secret</gitlab_data>';

  test('legacy context constructor rejects encoded app data', () {
    expect(
      () => AiContextBlock(source: 'synthetic', text: encoded),
      throwsAssertionError,
    );
  });

  test('legacy tool-result constructor rejects encoded app data', () {
    expect(
      () => AiToolResult(callId: 'call', name: 'read_file', content: encoded),
      throwsAssertionError,
    );
  });
}
