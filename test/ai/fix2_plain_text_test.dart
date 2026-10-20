import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/app_text.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/context_builders.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';

import 'runner_test.dart' as base;

void main() {
  for (final secret in [
    r'abc\ndef&Secret',
    'abcA&Secret',
    r'abc\u0041&Secret',
    r'abc\tdef<Secret',
    r'abc\defSYNTHETIC123',
    'a&bcDefSecret',
  ]) {
    for (final afterSend in [false, true]) {
      test('FIX2 context plain secret $secret afterSend=$afterSend', () async {
        final source = base.Secrets();
        final context = AiContextBuilders(redactor: Redactor(secrets: source))
            .file(
              AiFileContextInput(
                path: 'README.md',
                sha: 'a' * 40,
                text: secret,
              ),
              nonce: 'synthetic',
            );
        final h = base.Harness(context: context.blocks);
        if (afterSend) await h.runner.run('first');
        final old = h.runner.segment;
        final frozen = old?.frozenWireJson.toList();
        h.secrets.current.add(secret);
        expect((await h.runner.run('question')).reason, AiRunEnd.done);
        // Independent assertion on actual delivery, not the secret matcher.
        expect(h.payloads.last, isNot(contains('Secret')));
        expect(h.payloads.last, isNot(contains('SYNTHETIC123')));
        expect(h.payloads.last, contains('[REDACTED]'));
        if (afterSend) {
          expect(h.runner.segment, isNot(same(old)));
          expect(old!.frozenWireJson, frozen);
        }
      });
    }
  }

  for (final format in AiFormat.values) {
    test(
      'FIX2 frozen plain provider values never decode escapes $format',
      () async {
        const encoded = r'abc\u0041&amp;Secret';
        final h = base.Harness(format: format);
        h.respond = (_, _) async => h.turn(text: encoded);
        await h.runner.run('first');
        final segment = h.runner.segment!;
        final frozen = segment.frozenWireJson.toList();
        h.secrets.current.add('abcA&Secret');
        expect((await h.runner.run('second')).reason, AiRunEnd.done);
        expect(h.runner.segment, same(segment));
        expect(segment.frozenWireJson.take(frozen.length), frozen);
      },
    );
  }

  for (final kind in ['job', 'discussion', 'merge request']) {
    test(
      'FIX2 structured $kind retains plain values for late secrets',
      () async {
        const secret = r'abc\ndef&Secret';
        final builders = AiContextBuilders(
          redactor: Redactor(secrets: base.Secrets()),
        );
        final context = switch (kind) {
          'job' => builders.job(
            const AiJobContextInput(
              name: secret,
              stage: 'test',
              status: 'failed',
              trace: secret,
            ),
            nonce: 'synthetic',
          ),
          'discussion' => builders.discussion(
            AiDiscussionContextInput(
              kind: 'issue',
              iid: 3,
              title: secret,
              description: secret,
              state: 'opened',
              pinnedSha: 'a' * 40,
              notes: const [],
            ),
            nonce: 'synthetic',
          ),
          _ => builders.mergeRequest(
            AiMergeRequestContextInput(
              iid: 3,
              title: secret,
              description: secret,
              state: 'opened',
              headSha: 'a' * 40,
              baseSha: 'b' * 40,
              diffs: const [
                AiDiffFileInput(
                  oldPath: 'a.dart',
                  newPath: 'a.dart',
                  diff: secret,
                ),
              ],
            ),
            nonce: 'synthetic',
          ),
        };
        final h = base.Harness(context: context.blocks)
          ..secrets.current.add(secret);
        expect((await h.runner.run('question')).reason, AiRunEnd.done);
        expect(h.payloads.single, isNot(contains('Secret')));
        expect(h.payloads.single, contains('[REDACTED]'));
      },
    );
  }

  test(
    'FIX2 tool tail refresh redacts retained JSON before encoding',
    () async {
      const secret = r'abc\tdef<Secret';
      final h = base.Harness();
      h.execute = (call) async => AiToolResult.fromData(
        callId: call.id,
        name: call.name,
        data: AiAppText.untrusted(
          source: 'file',
          nonce: 'synthetic',
          body: AiAppText.json({'text': secret, 'safe': 'keep'}),
        ),
      );
      h.respond = (_, _) async {
        if (h.payloads.length == 1) return h.turn(calls: [base.call()]);
        expect(h.payloads.last, isNot(contains('Secret')));
        expect(h.payloads.last, contains('keep'));
        return h.turn(text: 'done');
      };
      // The result is formed before the secret becomes known to the runner.
      final originalExecute = h.execute!;
      h.execute = (call) async {
        final result = await originalExecute(call);
        h.secrets.current.add(secret);
        return result;
      };
      expect((await h.runner.run('question')).reason, AiRunEnd.done);
      expect(h.payloads, hasLength(2));
    },
  );

  test(
    'FIX3 redact tail revisits plain tool data after a late refresh',
    () async {
      const secret = r'abc\ndef&Secret';
      final h = base.Harness();
      var toolReturned = false;
      var refreshesAfterTool = 0;
      h.refresh = () {
        if (!toolReturned) return;
        refreshesAfterTool++;
        // Post-read checkpoint, next-loop checkpoint, then _redactTail.
        if (refreshesAfterTool == 3) h.secrets.current.add(secret);
      };
      h.execute = (call) async {
        toolReturned = true;
        return AiToolResult.fromData(
          callId: call.id,
          name: call.name,
          data: const AiAppText.untrusted(
            source: 'read_file',
            nonce: 'synthetic',
            body: AiAppText.plain('x $secret y'),
          ),
        );
      };
      h.respond = (_, _) async => h.payloads.length == 1
          ? h.turn(calls: [base.call()])
          : h.turn(text: 'done');

      expect((await h.runner.run('question')).reason, AiRunEnd.done);
      expect(refreshesAfterTool, greaterThanOrEqualTo(3));
      expect(h.runner.lateRedactions, greaterThan(0));
      expect(h.payloads, hasLength(2));
      expect(h.payloads.last, contains('[REDACTED]'));
      expect(h.payloads.last, isNot(contains('Secret')));
    },
  );

  for (final tool in ['get_issue', 'get_job_log']) {
    for (final secret in [
      r'abc\ndef&Secret',
      'abcA&Secret',
      r'abc\tdef<Secret',
    ]) {
      test('FIX3 frozen $tool result re-verifies plain $secret', () async {
        final h = base.Harness();
        h.execute = (call) async => AiToolResult.fromData(
          callId: call.id,
          name: call.name,
          data: AiAppText.untrusted(
            source: tool,
            nonce: 'synthetic',
            body: tool == 'get_issue'
                ? AiAppText.json({'description': secret, 'safe': 'keep'})
                : AiAppText.plain('[source: job live]\n$secret'),
          ),
        );
        h.respond = (_, _) async => h.payloads.length == 1
            ? h.turn(calls: [_toolCall(tool)])
            : h.turn(text: 'done');

        expect((await h.runner.run('first')).reason, AiRunEnd.done);
        final old = h.runner.segment!;
        final frozen = old.frozenWireJson.toList();
        h.secrets.current.add(secret);
        expect((await h.runner.run('follow up')).reason, AiRunEnd.done);
        expect(h.runner.segment, isNot(same(old)));
        expect(old.frozenWireJson, frozen);
        expect(h.payloads.last, isNot(contains('Secret')));
      });
    }
  }

  for (final secret in [
    r'abc\ndef&Secret',
    'abcA&Secret',
    r'abc\tdef<Secret',
  ]) {
    test(
      'FIX3 clipped tool tail keeps plain $secret for late redaction',
      () async {
        final h = base.Harness(maxChars: 12000);
        var toolReturned = false;
        var refreshesAfterTool = 0;
        h.refresh = () {
          if (!toolReturned) return;
          refreshesAfterTool++;
          // Post-read checkpoint, next-loop checkpoint, then _redactTail.
          if (refreshesAfterTool == 3) h.secrets.current.add(secret);
        };
        h.execute = (call) async {
          toolReturned = true;
          return AiToolResult.fromData(
            callId: call.id,
            name: call.name,
            data: AiAppText.untrusted(
              source: 'read_file',
              nonce: 'synthetic',
              body: AiAppText.plain('$secret${'x' * 19000}'),
            ),
          );
        };
        h.respond = (_, _) async => h.payloads.length == 1
            ? h.turn(calls: [base.call()])
            : h.turn(text: 'done');

        expect((await h.runner.run('question')).reason, AiRunEnd.done);
        expect(refreshesAfterTool, greaterThanOrEqualTo(3));
        expect(h.runner.lateRedactions, greaterThan(0));
        expect(h.payloads, hasLength(2));
        expect(h.payloads.last.length, lessThanOrEqualTo(12000));
        expect(h.payloads.last, contains('[REDACTED]'));
        expect(h.payloads.last, isNot(contains('Secret')));
      },
    );
  }

  test('FIX3 projection clips context to its escaped-width budget', () {
    const budget = 1200;
    final projection = buildAiProjection(
      context: [
        AiContextBlock.fromData(
          source: 'file',
          data: AiAppText.plain(List.filled(1000, '&<"').join()),
        ),
      ],
      entries: const [],
      budget: budget,
      redact: (text) => text,
    );

    expect(projection.length, lessThanOrEqualTo(budget));
    expect(projection, contains('&amp;'));
    expect(projection, contains('&lt;'));
    expect(projection, contains('"'));
  });

  test('FIX2 decoded citations are plain readable frozen values', () async {
    const secret = r'abc\ndef&Secret';
    final h = base.Harness(format: AiFormat.anthropicMessages);
    final decoder = h.wire.newDecoder();
    void event(Map<String, Object?> body) {
      decoder.add(SseEvent(data: jsonEncode(body)));
    }

    event({
      'type': 'message_start',
      'message': {'role': 'assistant', 'content': <Object?>[]},
    });
    event({
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'text', 'text': 'visible'},
    });
    event({
      'type': 'content_block_delta',
      'index': 0,
      'delta': {
        'type': 'citations_delta',
        'citation': {
          'type': 'web_search_result_location',
          'cited_text': secret,
          'title': 'safe',
          'url': 'https://example.test',
          'encrypted_index': 'opaque-secret',
        },
      },
    });
    event({'type': 'content_block_stop', 'index': 0});
    event({
      'type': 'message_delta',
      'delta': {'stop_reason': 'end_turn'},
    });
    event({'type': 'message_stop'});
    final turn = decoder.finish();
    h.respond = (_, _) async =>
        h.payloads.length == 1 ? turn : h.turn(text: 'done');
    expect((await h.runner.run('first')).reason, AiRunEnd.done);
    final segment = h.runner.segment!;
    final frozen = segment.frozenWireJson.toList();
    h.secrets.current.add(secret);
    expect((await h.runner.run('second')).reason, AiRunEnd.done);
    expect(h.runner.segment, isNot(same(segment)));
    expect(h.payloads.last, isNot(contains('Secret')));
    expect(segment.frozenWireJson, frozen);
    expect(
      readableAiEntry(turn.output).join(),
      isNot(contains('opaque-secret')),
    );
  });

  test(
    'FIX2 Responses annotations expose plain text without opaque fields',
    () {
      final h = base.Harness(format: AiFormat.responses);
      final decoder = h.wire.newDecoder();
      decoder.add(
        SseEvent(
          data: jsonEncode({
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {
                      'type': 'output_text',
                      'text': 'visible',
                      'annotations': [
                        {
                          'type': 'url_citation',
                          'title': r'abc\tdef<Secret',
                          'url': 'https://example.test',
                          'encrypted_index': 'opaque-secret',
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          }),
        ),
      );
      final turn = decoder.finish();
      expect(readableAiEntry(turn.output), contains(r'abc\tdef<Secret'));
      expect(
        readableAiEntry(turn.output).join(),
        isNot(contains('opaque-secret')),
      );
    },
  );

  test('FIX2 nested provider escapes remain readable and resumable', () async {
    final text = 'quote &${'amp;' * 40}';
    final h = base.Harness()..secrets.current.add('unrelatedSecret');
    h.respond = (_, _) async => h.turn(text: text);
    final first = await h.runner.run('first');
    expect(first.reason, AiRunEnd.done);
    expect(first.text, text);
    final segment = h.runner.segment;
    expect((await h.runner.run('second')).reason, AiRunEnd.done);
    expect(h.runner.segment, same(segment));
    expect(h.payloads, hasLength(2));
  });

  test('FIX2 summaries escape once through repeated segment changes', () async {
    final h = base.Harness()..secrets.current.add('unrelatedSecret');
    await h.runner.run('<b>FIRST&DIRECTIVE</b>');
    for (var i = 0; i < 35; i++) {
      h.runner.forceProjection();
      expect((await h.runner.run('turn $i')).reason, AiRunEnd.done);
      expect(
        h.payloads.last,
        contains('&lt;b&gt;FIRST&amp;DIRECTIVE&lt;/b&gt;'),
      );
      expect(h.payloads.last, isNot(contains('&amp;lt;b')));
    }
    h.secrets.current.add('FIRST&DIRECTIVE');
    expect((await h.runner.run('late secret')).reason, AiRunEnd.done);
    expect(h.payloads.last, isNot(contains('DIRECTIVE')));
  });

  test('FIX2 encoded text is never decoded by the secret matcher', () {
    final source = base.Secrets()..current.add('abcA&Secret');
    const encoded = r'abc\u0041&amp;Secret';
    expect(Redactor(secrets: source).redactSource(encoded).text, encoded);
    expect(containsKnownAiSecret(encoded, source.current), isFalse);
  });

  test('FIX2 snapshots accumulate redacted text across tool rounds', () async {
    final h = base.Harness();
    final snapshots = <String>[];
    final runner = AiRunner(
      config: h.config(),
      wire: h.wire,
      complete: (plan, {onEvent}) async {
        final first = h.payloads.isEmpty;
        h.payloads.add(h.wire.encodeJson(plan, h.caps));
        final text =
            '${first ? 'FIRST_VISIBLE_' : 'SECOND_VISIBLE_'}${'x' * 300}';
        onEvent!(AiTextDelta(text));
        if (!first) h.secrets.current.add('FIRST_VISIBLE_');
        return h.turn(text: text, calls: first ? [base.call()] : []);
      },
      secrets: h.secrets,
      refreshSecrets: () async {},
      guard: AiRunGuard(
        expectedGeneration: 1,
        ownerApi: h.owner,
        generation: () => 1,
        api: () => h.owner,
        recipientRevision: () => 1,
        consentValid: () => true,
      ),
      system: 'Synthetic system',
      tools: [base.spec],
      close: () {},
      cancelActive: () {},
      onTextChanged: snapshots.add,
      executeTool: (call) async => throw StateError('synthetic unavailable'),
    );
    final result = await runner.run('question');
    expect(result.reason, AiRunEnd.done);
    expect(snapshots[snapshots.length - 2], contains('FIRST_VISIBLE_'));
    expect(snapshots[snapshots.length - 2], contains('SECOND_VISIBLE_'));
    expect(snapshots.last, contains('[REDACTED]'));
    expect(snapshots.last, isNot(contains('FIRST_VISIBLE_')));
    expect(snapshots.last, contains('SECOND_VISIBLE_'));
  });
}

AiToolCall _toolCall(String name) =>
    AiToolCall(id: 'call', name: name, arguments: <String, Object?>{});
