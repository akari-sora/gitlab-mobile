import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/app_text.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

import '../support/fake_adapter.dart';
import 'runner_test.dart' as base;

void main() {
  test('FIX1 final tail refresh verifies the frozen prefix again', () async {
    final h = base.Harness();
    h.respond = (_, _) async => h.turn(text: 'lateSecretValue');
    await h.runner.run('first');
    var refreshes = 0;
    h.refresh = () {
      if (++refreshes == 3) h.secrets.current.add('lateSecretValue');
    };
    final result = await h.runner.run('second');
    expect(result.reason, AiRunEnd.newSecret);
    expect(h.payloads, hasLength(1));
  });

  test(
    'FIX1 newly known secrets also redact accumulated display text',
    () async {
      final h = base.Harness();
      h.respond = (_, _) async =>
          h.turn(text: 'newDisplaySecret', calls: [base.call()]);
      h.execute = (call) async {
        h.secrets.current.add('newDisplaySecret');
        return AiToolResult(callId: call.id, name: call.name, content: 'safe');
      };
      final result = await h.runner.run('question');
      expect(result.reason, AiRunEnd.newSecret);
      expect(result.text, isNot(contains('newDisplaySecret')));
    },
  );

  test('FIX1 precheck failure preserves prior paired results', () async {
    final h = base.Harness();
    h.respond = (_, _) async =>
        h.turn(calls: [base.call()], stop: AiStopReason.maxTokens);
    await h.runner.run('first');
    final old = h.runner.segment!;
    final tail = old.tail;
    expect(tail, isA<AppToolResultsEntry>());
    h.refresh = () => throw const AiFailure(AiFailureKind.policyBlocked);
    expect((await h.runner.run('retry')).reason, AiRunEnd.failed);
    expect(h.runner.segment, same(old));
    expect(old.tail, same(tail));
  });

  test('FIX1 failed rollover preserves prior paired results', () async {
    final h = base.Harness();
    h.respond = (_, _) async =>
        h.turn(calls: [base.call()], stop: AiStopReason.maxTokens);
    await h.runner.run('first');
    final old = h.runner.segment!;
    final tail = old.tail;
    h.runner.forceProjection();
    final result = await h.runner.run('x' * 400000);
    expect(result.failure?.kind, AiFailureKind.contextTooLong);
    expect(h.runner.segment, same(old));
    expect(old.tail, same(tail));
  });

  test('FIX1 projection preserves coalesced follow-up', () {
    final text = buildAiProjection(
      context: [],
      entries: [
        AppToolResultsEntry([
          AiToolResult(callId: 'c', name: 'read_file', content: 'ok'),
        ], followUpText: 'FOLLOW_UP_KEEP'),
      ],
      budget: 5000,
      redact: (s) => s,
    );
    expect(text, contains('User: FOLLOW_UP_KEEP'));
  });

  test('FIX1 second rollover preserves the earlier summary', () async {
    final h = base.Harness();
    await h.runner.run('INITIAL_DIRECTIVE_KEEP');
    h.runner.forceProjection();
    await h.runner.run('second');
    h.runner.forceProjection();
    await h.runner.run('third');
    expect(h.payloads.last, contains('INITIAL_DIRECTIVE_KEEP'));
    expect(h.payloads.last, contains('second'));
  });

  test('FIX1 second rollover includes initial context once', () async {
    final h = base.Harness(
      context: [
        AiContextBlock(source: 'file', text: 'UNIQUE_INITIAL_CONTEXT'),
      ],
    );
    await h.runner.run('initial');
    h.runner.forceProjection();
    await h.runner.run('second');
    h.runner.forceProjection();
    await h.runner.run('third');
    expect('UNIQUE_INITIAL_CONTEXT'.allMatches(h.payloads.last), hasLength(1));
  });

  test('FIX1 late JSON XML encoded secrets cannot be replayed', () async {
    const secret = 'abc\\def\n"a&<bc>Secret';
    final h = base.Harness(
      context: [
        AiContextBlock.fromData(
          source: 'file',
          data: AiAppText.untrusted(
            source: 'file',
            nonce: 'synthetic',
            body: AiAppText.json(secret),
          ),
        ),
      ],
    );
    await h.runner.run('first');
    final old = h.runner.segment!;
    final frozen = old.frozenWireJson.toList();
    h.secrets.current.add(secret);
    await h.runner.run('second');
    expect(h.runner.segment, isNot(same(old)));
    expect(containsKnownAiSecret(h.payloads.last, [secret]), isFalse);
    expect(h.payloads.last, isNot(contains('Secret')));
    expect(old.frozenWireJson, frozen);
  });

  test(
    'FIX1 redacted marker survives repeated escaping',
    () {
      const secret = 'abc\\def\n"a&<bc>Secret';
      final h = base.Secrets()..current.add(secret);
      final redactor = Redactor(secrets: h);
      var text = AiAppText.json({
        'description': secret,
        'safe': 'keep',
      }).redact(redactor).encode();
      for (var i = 0; i < 3; i++) {
        text = text
            .replaceAll('&', '&amp;')
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;');
      }
      final safe = redactor.redactSource(text).text;
      expect(safe, contains('keep'));
      expect(safe, contains('[REDACTED]'));
      expect(containsKnownAiSecret(safe, [secret]), isFalse);
      expect(jsonDecode(safe), isA<Map<String, Object?>>());
    },
  );

  test('FIX1 redacting a closing note keeps removal metadata', () {
    final segment =
        AiSegment(
            providerId: 'p',
            recipientRevision: 1,
            format: AiFormat.chatCompletions,
            model: 'm',
            secretSetAtStart: SecretSetId.fromSecrets([]),
          )
          ..setTail(AppToolResultsEntry([]))
          ..addFinalAnswerNote();
    final tail = segment.tail! as AppToolResultsEntry;
    segment.setTail(
      tail.copyWith(
        followUpText: tail.followUpText,
        preserveFinalAnswerNote: true,
      ),
    );
    segment.removeFinalAnswerNote();
    segment.addFollowUp('next question');
    expect(
      (segment.tail! as AppToolResultsEntry).followUpText,
      'next question',
    );
  });

  test('FIX1 equivalent caps allow key replacement', () async {
    final h = base.Harness();
    await h.runner.run('first');
    final old = h.config();
    final config = AiProviderConfig(
      id: old.id,
      name: old.name,
      presetId: old.presetId,
      baseUrl: old.baseUrl,
      format: old.format,
      model: old.model,
      authStyle: old.authStyle,
      caps: AiCaps(
        tokenLimitField: old.caps.tokenLimitField,
        replayChatExtras: old.caps.replayChatExtras,
      ),
      allowLanCleartext: old.allowLanCleartext,
      toolsEnabled: old.toolsEnabled,
      recipientRevision: 2,
    );
    h.revision = 2;
    h.runner.replaceKeyRecipient(
      config: config,
      complete: h.complete,
      close: () {},
      cancelActive: () {},
    );
    expect((await h.runner.run('next')).reason, AiRunEnd.done);
  });

  test('FIX1 runner re-redaction preserves closing-note removal', () async {
    final h = base.Harness();
    h.respond = (plan, _) async {
      if (h.payloads.length == 4) {
        plan.segment.removeFinalAnswerNote();
        expect(
          (plan.segment.tail! as AppToolResultsEntry).followUpText,
          isNull,
        );
        return h.turn(text: 'done');
      }
      return h.turn(calls: [for (var i = 0; i < 4; i++) base.call('$i')]);
    };
    expect((await h.runner.run('question')).reason, AiRunEnd.done);
  });

  test('FIX1 runner clipping keeps the untrusted closing label', () async {
    final h = base.Harness();
    h.execute = (call) async => AiToolResult.fromData(
      callId: call.id,
      name: call.name,
      data: AiAppText.untrusted(
        source: 'file',
        nonce: 'synthetic',
        body: AiAppText.plain('x' * 25000),
      ),
    );
    h.respond = (_, _) async => h.payloads.length == 1
        ? h.turn(calls: [base.call()])
        : h.turn(text: 'done');
    await h.runner.run('question');
    final tools = h.runner.segment!.frozen.whereType<AppToolResultsEntry>();
    expect(tools.single.results.single.content, endsWith('</gitlab_data>'));
    expect(
      tools.single.results.single.content.length,
      lessThanOrEqualTo(20000),
    );
  });

  test('FIX1 request-size tail clipping keeps the untrusted closing label', () {
    final segment =
        AiSegment(
          providerId: 'p',
          recipientRevision: 1,
          format: AiFormat.chatCompletions,
          model: 'm',
          secretSetAtStart: SecretSetId.fromSecrets([]),
        )..setTail(
          AppToolResultsEntry([
            AiToolResult.fromData(
              callId: 'c',
              name: 'read_file',
              data: AiAppText.untrusted(
                source: 'file',
                nonce: 'synthetic',
                body: AiAppText.plain('x' * 10000),
              ),
            ),
          ]),
        );
    segment.clipTailToolResults(1000);
    final text = (segment.tail! as AppToolResultsEntry).results.single.content;
    expect(text, endsWith('</gitlab_data>'));
    expect(text.length, lessThanOrEqualTo(1000));
  });

  test(
    'FIX1 finally pairs calls even when synthetic redaction refuses',
    () async {
      final h = base.Harness();
      h.respond = (_, _) async {
        h.secrets.current.add('REDACTED');
        return h.turn(calls: [base.call()], stop: AiStopReason.maxTokens);
      };
      final result = await h.runner.run('question');
      expect(result.reason, AiRunEnd.failed);
      final tail = h.runner.segment!.tail! as AppToolResultsEntry;
      expect(tail.results, hasLength(1));
      expect(tail.results.single.content, isEmpty);
    },
  );

  for (final trigger in ['stop', 'model timeout', 'run timeout']) {
    test('FIX1 real transport recovers after $trigger', () async {
      final h = _TransportHarness(trigger: trigger);
      addTearDown(h.transport.close);
      final active = h.runner.run('first');
      await h.started.future;
      if (trigger == 'run timeout') h.expireRunDeadline();
      final old = h.runner.segment;
      if (trigger == 'stop') h.runner.stop();
      final stopped = await active;
      expect(
        stopped.reason,
        trigger == 'stop' ? AiRunEnd.stopped : AiRunEnd.failed,
      );
      if (trigger != 'stop') {
        expect(stopped.failure?.kind, AiFailureKind.timeout);
      }
      final recovered = await h.runner.run('follow up');
      expect(recovered.reason, AiRunEnd.done);
      expect(recovered.text, 'recovered');
      expect(h.runner.segment, same(old));
      expect(h.adapter.requests, hasLength(2));
      expect(h.adapter.closed, isFalse);
    });
  }

  test('FIX1 stopped Anthropic tool tail coalesces the follow-up', () async {
    final h = _TransportHarness(trigger: 'tool stop', anthropic: true);
    addTearDown(h.transport.close);
    final pending = h.runner.run('first');
    await h.toolStarted.future;
    final old = h.runner.segment;
    h.runner.stop();
    expect((await pending).reason, AiRunEnd.stopped);
    expect(h.toolResults, hasLength(2));
    expect(h.toolResults.every((result) => result.isError), isTrue);
    expect(h.toolResults.every((result) => result.notExecuted), isTrue);
    expect(h.toolResults.map((result) => result.callId).toSet(), hasLength(2));
    expect((await h.runner.run('follow up')).reason, AiRunEnd.done);
    expect(h.runner.segment, same(old));
    final request =
        jsonDecode(h.adapter.requests.last.data! as String)
            as Map<String, Object?>;
    final messages = request['messages']! as List<Object?>;
    final last = messages.last! as Map<String, Object?>;
    expect(last['role'], 'user');
    final content = last['content']! as List<Object?>;
    expect(
      content.whereType<Map<String, Object?>>().where(
        (v) => v['type'] == 'tool_result',
      ),
      hasLength(2),
    );
    expect(jsonEncode(last), contains('follow up'));
    expect(
      messages.whereType<Map<String, Object?>>().where(
        (v) => v['role'] == 'user',
      ),
      hasLength(2),
    );
    h.pendingTool.complete(
      AiToolResult(callId: 'ignored', name: 'read_file', content: 'late'),
    );
  });

  test('FIX1 stopped partial answer is freshly redacted for display', () async {
    final h = base.Harness();
    final started = Completer<void>();
    h.respond = (_, onEvent) async {
      onEvent!(const AiTextDelta('visible partialSecretValue'));
      started.complete();
      return Completer<AiDecodedTurn>().future;
    };
    final active = h.runner.run('question');
    await started.future;
    h.secrets.current.add('partialSecretValue');
    h.runner.stop();
    final result = await active;
    expect(result.text, contains('visible'));
    expect(result.text, isNot(contains('partialSecretValue')));
    expect(h.runner.segment!.frozen, isEmpty);
  });

  test('FIX1 stopped partial waits for a valid slow secret refresh', () async {
    final h = base.Harness();
    final started = Completer<void>();
    var slow = false;
    final runner = _copyRunner(
      h,
      refreshSecrets: () async {
        if (slow) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
          h.secrets.current.add('slowSecretValue');
        }
      },
      complete: (_, {onEvent}) async {
        onEvent!(const AiTextDelta('visible slowSecretValue'));
        slow = true;
        started.complete();
        return Completer<AiDecodedTurn>().future;
      },
    );
    final pending = runner.run('question');
    await started.future;
    runner.stop();
    final result = await pending;
    expect(result.text, contains('visible'));
    expect(result.text, isNot(contains('slowSecretValue')));
  });

  test('FIX1 synthetic tool rows emit correlated terminal results', () async {
    final h = base.Harness();
    final results = <AiToolResult>[];
    final started = <AiToolCall>[];
    var calls = 0;
    final runner = _copyRunner(
      h,
      onToolResult: results.add,
      onToolStarted: started.add,
      complete: (_, {onEvent}) async => ++calls == 1
          ? h.turn(calls: [base.call('first'), base.call('second')])
          : h.turn(text: 'done'),
    );
    final result = await runner.run('question');
    expect(result.toolCalls, 0);
    expect(started.map((call) => call.id), ['first', 'second']);
    expect(results.map((result) => result.callId), ['first', 'second']);
    expect(results.every((result) => result.isError), isTrue);
  });

  test('FIX1 runner surfaces safe progress and first tool metadata', () async {
    final h = base.Harness();
    final snapshots = <String>[];
    final results = <AiToolResult>[];
    final started = <AiToolCall>[];
    var exhausted = false;
    h.secrets.current.add('progressSecretValue');
    var calls = 0;
    final runner = _copyRunner(
      h,
      onTextChanged: snapshots.add,
      onToolStarted: started.add,
      onToolResult: results.add,
      exhausted: () => exhausted,
      complete: (plan, {onEvent}) async {
        h.payloads.add(h.wire.encodeJson(plan, h.caps));
        if (++calls == 1) {
          onEvent!(const AiTextDelta('progressSecret'));
          onEvent(const AiTextDelta('Value visible'));
          return h.turn(calls: [base.call()]);
        }
        return h.turn(text: 'done');
      },
      execute: (call) async {
        exhausted = true;
        return AiToolResult(
          callId: call.id,
          name: call.name,
          content: '[REDACTED:private_key_fragment]',
          withheldPrivateKeyContext: true,
          truncated: true,
          blockedSensitive: true,
        );
      },
    );
    final result = await runner.run('question');
    expect(snapshots.last, contains('visible'));
    expect(snapshots.any((s) => s.contains('progressSecretValue')), isFalse);
    expect(started.single.name, 'read_file');
    expect(started.single.id, base.call().id);
    expect(results.single.withheldPrivateKeyContext, isTrue);
    expect(results.single.truncated, isTrue);
    expect(results.single.blockedSensitive, isTrue);
    expect(result.withheldPrivateKeyContext, isTrue);
    expect(h.payloads.last, contains(aiFinalAnswerNoteMarker));
  });

  test(
    'a started tool strips controls before redacting safe arguments',
    () async {
      final h = base.Harness();
      h.secrets.current.addAll([
        'argumentSecretValue',
        'synthetic-test-token',
      ]);
      final started = <AiToolCall>[];
      var calls = 0;
      final runner = _copyRunner(
        h,
        onToolStarted: started.add,
        complete: (_, {onEvent}) async => ++calls == 1
            ? h.turn(
                calls: [
                  AiToolCall(
                    id: 'call',
                    name: 'read_file',
                    arguments: <String, Object?>{
                      'path': 'notes/argumentSecretValue.md',
                      'revision': 'synthetic-\u200btest-token',
                      'tail_lines': 20,
                      'a_valid_key_that_is_32_chars_123': true,
                      'Uppercase': 'hidden',
                      'hyphen-key': 'hidden',
                      'a_valid_key_that_is_33_chars_1234': 'hidden',
                      'nested': {'path': 'hidden'},
                      'long': 'x' * 2000,
                    },
                  ),
                ],
              )
            : h.turn(text: 'done'),
      );
      await runner.run('question');
      final shown = started.single.arguments! as Map<String, Object?>;
      expect(shown['revision'], isNot(contains('synthetic-test-token')));
      expect(shown['revision'], isNot(contains('\u200b')));
      expect(
        shown.keys,
        unorderedEquals([
          'path',
          'revision',
          'tail_lines',
          'a_valid_key_that_is_32_chars_123',
        ]),
      );
      expect(shown['path'], isNot(contains('argumentSecretValue')));
      expect(shown['path'], startsWith('notes/'));
      expect(shown['tail_lines'], 20);
    },
  );

  test('FIX1 unavailable tools do not count as executed tools', () async {
    final h = base.Harness();
    var calls = 0;
    final results = <AiToolResult>[];
    final runner = _copyRunner(
      h,
      complete: (_, {onEvent}) async =>
          ++calls == 1 ? h.turn(calls: [base.call()]) : h.turn(text: 'done'),
      onToolResult: results.add,
    );
    final result = await runner.run('question');
    expect(result.toolCalls, 0);
    expect(result.reason, AiRunEnd.done);
    expect(results.single.notExecuted, isTrue);
  });

  test('tool budget results are marked as not executed', () async {
    final h = base.Harness();
    final results = <AiToolResult>[];
    final runner = _copyRunner(
      h,
      complete: (_, {onEvent}) async => h.turn(calls: [base.call()]),
      exhausted: () => true,
      onToolResult: results.add,
    );
    expect((await runner.run('question')).reason, AiRunEnd.toolBudget);
    expect(results.single.notExecuted, isTrue);
  });

  test(
    'timed-out reads are attempted but a later pending read is not',
    () async {
      final h = base.Harness();
      final pendingRead = Completer<AiToolResult>();
      addTearDown(() {
        if (!pendingRead.isCompleted) {
          pendingRead.complete(
            AiToolResult(callId: 'late', name: 'read_file', content: 'late'),
          );
        }
      });
      final results = <AiToolResult>[];
      var calls = 0;
      final runner = _copyRunner(
        h,
        complete: (_, {onEvent}) async => switch (++calls) {
          1 || 3 => h.turn(calls: [base.call('call-$calls')]),
          _ => h.turn(text: 'done'),
        },
        execute: (_) => pendingRead.future,
        onToolResult: results.add,
        toolDeadline: const Duration(milliseconds: 10),
      );
      expect((await runner.run('first')).reason, AiRunEnd.done);
      expect((await runner.run('second')).reason, AiRunEnd.done);
      expect(results, hasLength(2));
      expect(results.first.notExecuted, isFalse);
      expect(results.last.notExecuted, isTrue);
    },
  );

  test('tool read failures are marked as attempted', () async {
    final h = base.Harness();
    final results = <AiToolResult>[];
    var calls = 0;
    final runner = _copyRunner(
      h,
      complete: (_, {onEvent}) async =>
          ++calls == 1 ? h.turn(calls: [base.call()]) : h.turn(text: 'done'),
      execute: (_) async => throw StateError('synthetic read failure'),
      onToolResult: results.add,
    );
    expect((await runner.run('question')).reason, AiRunEnd.done);
    expect(results.single.isError, isTrue);
    expect(results.single.notExecuted, isFalse);
  });
}

AiRunner _copyRunner(
  base.Harness h, {
  required AiComplete complete,
  Future<AiToolResult> Function(AiToolCall)? execute,
  void Function(String)? onTextChanged,
  void Function(AiToolCall)? onToolStarted,
  void Function(AiToolResult)? onToolResult,
  bool Function()? exhausted,
  Future<void> Function()? refreshSecrets,
  Duration toolDeadline = const Duration(seconds: 30),
}) => AiRunner(
  appInForeground: () => true,
  config: h.config(),
  wire: h.wire,
  complete: complete,
  secrets: h.secrets,
  refreshSecrets: refreshSecrets ?? () async {},
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
  executeTool: execute,
  toolBudgetExhausted: exhausted,
  onTextChanged: onTextChanged,
  onToolStarted: onToolStarted,
  onToolResult: onToolResult,
  toolDeadline: toolDeadline,
);

final class _TransportHarness {
  _TransportHarness({required String trigger, bool anthropic = false}) {
    final baseHarness = base.Harness(
      format: anthropic ? AiFormat.anthropicMessages : AiFormat.chatCompletions,
    );
    final config = baseHarness.config();
    adapter = FakeAdapter((_) {
      if (adapter.requests.length == 1) {
        started.complete();
        if (anthropic) {
          return ResponseBody.fromString(
            File(
              'test/ai/fixtures/recorded/A/loop/01-loop1.response.sse',
            ).readAsStringSync(),
            200,
          );
        }
        return ResponseBody(stall.stream, 200);
      }
      if (anthropic) {
        return ResponseBody.fromString(
          'event: message_start\ndata: {"type":"message_start","message":{"role":"assistant","content":[]}}\n\n'
          'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"recovered"}}\n\n'
          'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'
          'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n'
          'event: message_stop\ndata: {"type":"message_stop"}\n\n',
          200,
        );
      }
      return ResponseBody.fromString(
        'data: {"choices":[{"index":0,"delta":{"content":"recovered"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
        200,
      );
    });
    transport = AiTransport(
      endpoint: AiEndpoint.parse(config.baseUrl, allowLanCleartext: false),
      apiKey: 'synthetic-key',
      adapter: adapter,
    );
    final client = AiWireClient(
      transport: transport,
      wire: baseHarness.wire,
      config: config,
      conversationId: 'fix1-conversation',
      appVersion: '0.6.0',
    );
    runner = AiRunner(
      appInForeground: () => true,
      config: config,
      wire: baseHarness.wire,
      complete: client.complete,
      secrets: baseHarness.secrets,
      refreshSecrets: () async {},
      guard: AiRunGuard(
        expectedGeneration: 1,
        ownerApi: owner,
        generation: () => 1,
        api: () => owner,
        recipientRevision: () => 1,
        consentValid: () => true,
      ),
      system: 'Synthetic system',
      tools: [base.spec],
      close: transport.close,
      cancelActive: transport.cancelActive,
      modelDeadline: trigger == 'model timeout'
          ? const Duration(milliseconds: 30)
          : const Duration(minutes: 5),
      runDeadline: trigger == 'run timeout'
          ? const Duration(milliseconds: 30)
          : const Duration(minutes: 12),
      // A loaded full suite can spend the real 30 ms in preflight before Dio
      // enters the adapter. Freeze only the run-timeout fixture's logical
      // clock until [started] proves the transport request exists.
      now: trigger == 'run timeout' ? () => _runNow : null,
      executeTool: (_) {
        if (!toolStarted.isCompleted) toolStarted.complete();
        return pendingTool.future;
      },
      onToolResult: toolResults.add,
    );
  }
  final owner = Object();
  DateTime _runNow = DateTime.utc(2026, 10, 23, 12);
  final started = Completer<void>();
  final toolStarted = Completer<void>();
  final pendingTool = Completer<AiToolResult>();
  final toolResults = <AiToolResult>[];
  final stall = StreamController<Uint8List>();
  late FakeAdapter adapter;
  late AiTransport transport;
  late AiRunner runner;

  void expireRunDeadline() {
    _runNow = _runNow.add(const Duration(milliseconds: 31));
  }
}
