import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';

void main() {
  test('SecretSetId is canonical across ordering and duplicates', () {
    final first = SecretSetId.fromSecrets(const ['beta', 'alpha', 'alpha']);
    final second = SecretSetId.fromSecrets(const ['alpha', 'beta']);
    final differentBoundary = SecretSetId.fromSecrets(const ['alphabeta']);

    expect(first, second);
    expect(first, isNot(differentBoundary));
    expect(first.toString(), isNot(matches(RegExp(r'^[0-9a-f]{64}$'))));
  });

  test('SecretSetId ignores empty values that are not redactable secrets', () {
    expect(
      SecretSetId.fromSecrets(const ['', 'alpha']),
      SecretSetId.fromSecrets(const ['alpha']),
    );
  });

  test('provider output recursively freezes a defensive JSON copy', () {
    final nested = <String, Object?>{
      'output': <Object?>[
        <String, Object?>{'text': 'original'},
      ],
    };
    final output = ProviderOutputEntry(
      AiFormat.responses,
      nested,
      toolCalls: const [],
    );
    (nested['output']! as List<Object?>).add('later');

    final frozen = output.raw as Map<String, Object?>;
    final list = frozen['output']! as List<Object?>;
    expect(list, hasLength(1));
    expect(() => list.add('mutation'), throwsUnsupportedError);
    expect(
      () => (list.single! as Map<String, Object?>)['text'] = 'mutation',
      throwsUnsupportedError,
    );
  });

  test('deep JSON is rejected with a typed invalid-response failure', () {
    Object? nested = const <Object?>[];
    for (var depth = 0; depth < 129; depth += 1) {
      nested = <Object?>[nested];
    }

    expect(
      () => deepFreezeJson(nested),
      throwsA(
        isA<AiFailure>().having(
          (failure) => failure.kind,
          'kind',
          AiFailureKind.invalidResponse,
        ),
      ),
    );
  });

  test('segment freezes tail and output once while retaining cached wire', () {
    final segment = AiSegment(
      providerId: 'provider',
      recipientRevision: 4,
      format: AiFormat.responses,
      model: 'model',
      secretSetAtStart: SecretSetId.fromSecrets(const ['secret']),
    );
    segment.setTail(
      AppUserEntry(
        text: 'question',
        context: const [AiContextBlock(source: 'file', text: 'context')],
      ),
    );
    var encodeCalls = 0;
    segment.freezeWith(
      ProviderOutputEntry(AiFormat.responses, <Object?>[
        <String, Object?>{'type': 'message'},
      ], toolCalls: const []),
      (entry) {
        encodeCalls += 1;
        return <String, Object?>{'kind': entry.runtimeType.toString()};
      },
    );

    expect(encodeCalls, 2);
    expect(segment.frozenLength, 2);
    expect(segment.frozenWire, hasLength(2));
    expect(segment.tail, isNull);
    expect(segment.contextDelivered, isTrue);
    expect(
      () => (segment.frozenWire.first! as Map<String, Object?>)['kind'] = 'x',
      throwsUnsupportedError,
    );
  });

  test('segment freeze is atomic when wire encoding fails', () {
    final segment = AiSegment(
      providerId: 'provider',
      recipientRevision: 4,
      format: AiFormat.responses,
      model: 'model',
      secretSetAtStart: SecretSetId.fromSecrets(const []),
    );
    final tail = AppUserEntry(text: 'question');
    segment.setTail(tail);
    var calls = 0;

    expect(
      () => segment.freezeWith(
        ProviderOutputEntry(
          AiFormat.responses,
          const <Object?>[],
          toolCalls: const [],
        ),
        (entry) {
          calls += 1;
          if (calls == 2) throw StateError('encode failed');
          return <String, Object?>{'ok': true};
        },
      ),
      throwsStateError,
    );
    expect(segment.frozen, isEmpty);
    expect(segment.frozenWire, isEmpty);
    expect(segment.tail, same(tail));
  });

  test(
    'tool-results tail supports clipping, follow-up, restore, and note removal',
    () {
      final segment = AiSegment(
        providerId: 'provider',
        recipientRevision: 1,
        format: AiFormat.chatCompletions,
        model: 'model',
        secretSetAtStart: SecretSetId.fromSecrets(const []),
      );
      final previous = AppToolResultsEntry(const [
        AiToolResult(callId: '1', name: 'read', content: 'abcdef'),
        AiToolResult(callId: '2', name: 'read', content: 'ghij'),
      ]);
      segment.setTail(previous);
      segment.clipTailToolResults(8);
      final clipped = segment.tail! as AppToolResultsEntry;
      expect(clipped.results.map((result) => result.content), ['abcdef', 'gh']);

      segment.addFollowUp('next');
      segment.addFinalAnswerNote();
      segment.addFinalAnswerNote();
      segment.removeFinalAnswerNote();
      expect((segment.tail! as AppToolResultsEntry).followUpText, 'next');

      segment.restoreTail(previous);
      expect(segment.tail, same(previous));
    },
  );

  test('note removal preserves user marker text and trailing whitespace', () {
    final segment = AiSegment(
      providerId: 'provider',
      recipientRevision: 1,
      format: AiFormat.chatCompletions,
      model: 'model',
      secretSetAtStart: SecretSetId.fromSecrets(const []),
    );
    const userText = 'keep $aiFinalAnswerNoteMarker inside  ';
    segment.setTail(AppToolResultsEntry(const [], followUpText: userText));
    segment.addFinalAnswerNote();
    segment.removeFinalAnswerNote();

    expect((segment.tail! as AppToolResultsEntry).followUpText, userText);
  });

  test('tool-result clipping preserves UTF-16 surrogate pairs', () {
    final segment = AiSegment(
      providerId: 'provider',
      recipientRevision: 1,
      format: AiFormat.chatCompletions,
      model: 'model',
      secretSetAtStart: SecretSetId.fromSecrets(const []),
    );
    segment.setTail(
      AppToolResultsEntry(const [
        AiToolResult(callId: '1', name: 'read', content: 'a😀b'),
      ]),
    );

    segment.clipTailToolResults(2);

    final result = (segment.tail! as AppToolResultsEntry).results.single;
    expect(result.content, 'a');
    expect(result.content.runes, [0x61]);
  });

  test('user-entry tail accepts a follow-up', () {
    final segment = AiSegment(
      providerId: 'provider',
      recipientRevision: 1,
      format: AiFormat.chatCompletions,
      model: 'model',
      secretSetAtStart: SecretSetId.fromSecrets(const []),
    );
    segment.setTail(
      AppUserEntry(
        text: 'question',
        context: const [AiContextBlock(source: 'file', text: 'context')],
      ),
    );

    segment.addFollowUp('more context');

    expect((segment.tail! as AppUserEntry).text, 'question\n\nmore context');
    expect((segment.tail! as AppUserEntry).context, hasLength(1));
  });

  test('note removal preserves an exact user-text suffix collision', () {
    final segment = AiSegment(
      providerId: 'provider',
      recipientRevision: 1,
      format: AiFormat.chatCompletions,
      model: 'model',
      secretSetAtStart: SecretSetId.fromSecrets(const []),
    );
    const userText = 'user text\n\n$aiFinalAnswerNote';
    segment.setTail(AppToolResultsEntry(const [], followUpText: 'user text'));
    segment.addFollowUp(aiFinalAnswerNote);

    segment.removeFinalAnswerNote();

    expect((segment.tail! as AppToolResultsEntry).followUpText, userText);
  });

  test('user-entry final-answer note is idempotent and removable', () {
    final segment = AiSegment(
      providerId: 'provider',
      recipientRevision: 1,
      format: AiFormat.chatCompletions,
      model: 'model',
      secretSetAtStart: SecretSetId.fromSecrets(const []),
    );
    segment.setTail(AppUserEntry(text: 'question'));

    segment.addFinalAnswerNote();
    segment.addFinalAnswerNote();
    expect(
      (segment.tail! as AppUserEntry).text,
      'question\n\n$aiFinalAnswerNote',
    );

    segment.removeFinalAnswerNote();
    expect((segment.tail! as AppUserEntry).text, 'question');
  });

  for (final toolTail in [false, true]) {
    test('follow-up removes an injected note first (tool tail: $toolTail)', () {
      final segment = AiSegment(
        providerId: 'provider',
        recipientRevision: 1,
        format: AiFormat.chatCompletions,
        model: 'model',
        secretSetAtStart: SecretSetId.fromSecrets(const []),
      );
      // User text equal to the note must survive alongside the follow-up.
      const userText = 'question\n\n$aiFinalAnswerNote';
      segment.setTail(
        toolTail
            ? AppToolResultsEntry(const [], followUpText: userText)
            : AppUserEntry(text: userText),
      );
      segment.addFinalAnswerNote();
      segment.addFollowUp('user text');
      segment.removeFinalAnswerNote();
      String? tailText() => toolTail
          ? (segment.tail! as AppToolResultsEntry).followUpText
          : (segment.tail! as AppUserEntry).text;
      expect(tailText(), '$userText\n\nuser text');
      segment.addFinalAnswerNote();
      segment.removeFinalAnswerNote();
      expect(tailText(), '$userText\n\nuser text');
    });
  }
}
