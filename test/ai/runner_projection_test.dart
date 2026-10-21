import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';

import 'runner_test.dart' show Harness;

void main() {
  test(
    'model failure returns its streamed partial text after redaction',
    () async {
      final harness = Harness();
      harness.secrets.current.add('partial-secret-value');
      harness.respond = (_, onEvent) async {
        onEvent!(const AiTextDelta('visible partial-secret-value tail'));
        throw const AiFailure(AiFailureKind.invalidResponse);
      };

      final result = await harness.runner.run('question');

      expect(result.reason, AiRunEnd.failed);
      expect(result.text, 'visible [REDACTED] tail');
      expect(result.text, isNot(contains('partial-secret-value')));
    },
  );

  test(
    'stop interrupts a stalled refresh while recovering partial text',
    () async {
      final harness = _AsyncRefreshHarness();
      final run = harness.runner.run('question');
      await harness.partialRefreshStarted.future;

      harness.runner.stop();
      final result = await run.timeout(const Duration(seconds: 1));

      expect(result.reason, AiRunEnd.failed);
      expect(result.text, isEmpty);
      expect(harness.cancels, greaterThan(0));
      expect(harness.closes, 0);
    },
  );

  test('tool projection keeps provenance, resource, SHA, and size', () {
    const content =
        '[source: file studio/mobile/README.md @ 0123456789abcdef]\n'
        'synthetic contents';
    final projection = buildAiProjection(
      context: const <AiContextBlock>[],
      entries: <AiEntry>[
        AppToolResultsEntry(<AiToolResult>[
          AiToolResult(
            callId: 'read-one',
            name: 'read_file',
            content: content,
          ),
        ]),
      ],
      budget: 2000,
      redact: (text) => text,
    );

    expect(projection, contains('[source: file studio/mobile/README.md'));
    expect(projection, contains('0123456789abcdef'));
    expect(projection, contains('${content.length} chars'));
    expect(projection, contains('read_file'));
  });

  test('encoded projection overflow preserves the original segment', () async {
    final harness = Harness(maxChars: 8000);
    await harness.runner.run('first');
    final original = harness.runner.segment!;
    final originalWire = List<String>.of(original.frozenWireJson);
    final encodedProvenance =
        '[source: file ${List<String>.filled(480, '\u0001').join()}]';
    original.setTail(
      AppToolResultsEntry(<AiToolResult>[
        for (var index = 0; index < 7; index++)
          AiToolResult(
            callId: 'read-$index',
            name: 'read_file',
            content: '$encodedProvenance\n$index',
          ),
      ]),
    );
    harness.runner.forceProjection();

    final result = await harness.runner.run('second');

    expect(result.reason, AiRunEnd.contextTooLong);
    expect(harness.runner.segment, same(original));
    expect(original.frozenWireJson, originalWire);
    expect(original.tail, isA<AppToolResultsEntry>());
  });

  test(
    'restored display history is re-redacted into a fresh projection',
    () async {
      final harness = Harness();
      harness.secrets.current.add('restored-secret-value');
      harness.runner.restoreFromDisplay(<AiChatItem>[
        AiUserItem(text: 'old restored-secret-value question'),
        const AiAssistantItem(
          text: 'old restored-secret-value answer',
          state: AiAssistantState.done,
        ),
        const AiToolRunItem(
          name: 'read_file',
          argsPreview: 'README.md',
          status: AiToolRunStatus.completed,
          sizeChars: 123,
          provenance: '[source: file README.md @ deadbeef]',
          resultExcerpt: 'RAW-TOOL-RESULT-SHOULD-NOT-REPLAY',
        ),
      ]);

      final result = await harness.runner.run('continue');

      expect(result.reason, AiRunEnd.done);
      expect(harness.payloads.single, contains('conversation_summary'));
      expect(harness.payloads.single, contains('[REDACTED]'));
      expect(harness.payloads.single, isNot(contains('restored-secret-value')));
      expect(
        harness.payloads.single,
        isNot(contains('RAW-TOOL-RESULT-SHOULD-NOT-REPLAY')),
      );
      expect(harness.runner.segment!.frozen, hasLength(2));
    },
  );
}

final class _Secrets implements KnownSecretsSource {
  @override
  final Set<String> current = <String>{'partial-secret-value'};
}

final class _AsyncRefreshHarness {
  _AsyncRefreshHarness() {
    runner = AiRunner(
      config: _config,
      wire: wire,
      complete: (plan, {onEvent}) async {
        onEvent!(const AiTextDelta('partial-secret-value'));
        stallRefresh = true;
        throw const AiFailure(AiFailureKind.invalidResponse);
      },
      secrets: secrets,
      refreshSecrets: () {
        if (!stallRefresh) return Future<void>.value();
        if (!partialRefreshStarted.isCompleted) {
          partialRefreshStarted.complete();
        }
        return never.future;
      },
      guard: AiRunGuard(
        expectedGeneration: 1,
        ownerApi: owner,
        generation: () => 1,
        api: () => owner,
        recipientRevision: () => 1,
        consentValid: () => true,
      ),
      system: 'Synthetic system prompt.',
      close: () => closes += 1,
      cancelActive: () => cancels += 1,
    );
  }

  static const _caps = AiCaps(
    tokenLimitField: AiTokenLimitField.maxTokens,
    replayChatExtras: true,
    maxRequestChars: 400000,
  );
  static const _config = AiProviderConfig(
    id: 'provider',
    name: 'Synthetic',
    presetId: 'custom',
    baseUrl: 'https://provider.example/v1',
    format: AiFormat.chatCompletions,
    model: 'synthetic',
    authStyle: AiAuthStyle.bearer,
    caps: _caps,
    allowLanCleartext: false,
    toolsEnabled: false,
    recipientRevision: 1,
  );

  final wire = const ChatCompletionsFormat();
  final secrets = _Secrets();
  final owner = Object();
  final never = Completer<void>();
  final partialRefreshStarted = Completer<void>();
  late final AiRunner runner;
  var stallRefresh = false;
  var closes = 0;
  var cancels = 0;
}
