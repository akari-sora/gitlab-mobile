import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';

import 'runner_test.dart' show Harness;

void main() {
  for (final format in AiFormat.values) {
    test(
      '${format.name} restored report metadata never enters request bytes',
      () async {
        Future<String> request({
          AiAnswerSource? source,
          bool reported = false,
        }) async {
          final harness = Harness(format: format);
          addTearDown(harness.runner.stop);
          harness.runner.restoreFromDisplay([
            AiUserItem(text: 'old question'),
            AiAssistantItem(
              text: 'old answer',
              state: AiAssistantState.done,
              source: source,
              reported: reported,
            ),
          ]);
          expect((await harness.runner.run('continue')).reason, AiRunEnd.done);
          final payload = harness.payloads.single;
          // Restoring creates a fresh anti-injection summary nonce each time.
          // Compare every other byte, including the entire projected history.
          final nonce = RegExp(r'nonce=\\"[0-9a-f]{32}\\"');
          expect(nonce.allMatches(payload), hasLength(1));
          return payload.replaceFirst(nonce, 'nonce=synthetic');
        }

        final legacy = await request();
        expect(
          await request(
            source: const AiAnswerSource(
              presetId: 'report-only-preset',
              format: 'report-only-format',
              model: 'report-only-model',
            ),
            reported: true,
          ),
          legacy,
        );
        expect(await request(reported: true), legacy);
        expect(
          await request(
            source: const AiAnswerSource(
              presetId: 'another-preset',
              format: 'another-format',
              model: 'another-model',
            ),
          ),
          legacy,
        );
      },
    );
  }
}
