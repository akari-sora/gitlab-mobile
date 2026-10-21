import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

final class Secrets implements KnownSecretsSource {
  @override
  final Set<String> current = {};
}

final class Harness {
  Harness({
    this.format = AiFormat.chatCompletions,
    bool toolChoice = false,
    int maxChars = 400000,
    List<AiContextBlock> context = const [],
    int tokenCap = 500000,
    Duration deadline = const Duration(seconds: 20),
    Duration runDeadline = const Duration(minutes: 12),
  }) {
    caps = AiCaps(
      tokenLimitField: AiTokenLimitField.maxTokens,
      toolChoice: toolChoice,
      replayChatExtras: true,
      maxRequestChars: maxChars,
    );
    runner = AiRunner(
      config: config(),
      wire: wire,
      complete: complete,
      secrets: secrets,
      refreshSecrets: () async {
        refresh?.call();
      },
      guard: AiRunGuard(
        expectedGeneration: 1,
        ownerApi: owner,
        generation: () => generation,
        api: () => api,
        recipientRevision: () => revision,
        consentValid: () => consent,
      ),
      system: 'You answer questions about repository data.',
      tools: [spec],
      context: context,
      close: () {
        closed++;
      },
      cancelActive: () {
        cancelled++;
      },
      executeTool: (call) async => execute == null
          ? AiToolResult(
              callId: call.id,
              name: call.name,
              content: '[source: file pinned]\nhello',
            )
          : execute!(call),
      conversationTokenCap: tokenCap,
      toolDeadline: deadline,
      runDeadline: runDeadline,
    );
  }
  final AiFormat format;
  late AiCaps caps;
  late AiRunner runner;
  final secrets = Secrets();
  final Object owner = Object();
  late Object? api = owner;
  var generation = 1;
  int? revision = 1;
  var consent = true;
  var closed = 0;
  var cancelled = 0;
  void Function()? refresh;
  Future<AiToolResult> Function(AiToolCall)? execute;
  Future<AiDecodedTurn> Function(AiRequestPlan, void Function(AiEvent)?)?
  respond;
  final payloads = <String>[];
  final plans = <AiRequestPlan>[];
  WireFormatBase get wire => switch (format) {
    AiFormat.chatCompletions => const ChatCompletionsFormat(),
    AiFormat.responses => const ResponsesFormat(),
    AiFormat.anthropicMessages => const AnthropicMessagesFormat(),
  };
  AiProviderConfig config() => AiProviderConfig(
    id: 'provider',
    name: 'Synthetic',
    presetId: 'custom',
    baseUrl: 'https://provider.example/v1',
    format: format,
    model: 'synthetic',
    authStyle: AiAuthStyle.bearer,
    caps: caps,
    allowLanCleartext: false,
    toolsEnabled: true,
    recipientRevision: revision!,
  );
  Future<AiDecodedTurn> complete(
    AiRequestPlan plan, {
    void Function(AiEvent)? onEvent,
  }) async {
    payloads.add(wire.encodeJson(plan, caps));
    plans.add(plan);
    return respond == null ? turn(text: 'answer') : respond!(plan, onEvent);
  }

  AiDecodedTurn turn({
    String text = '',
    List<AiToolCall> calls = const [],
    AiStopReason stop = AiStopReason.endTurn,
    AiUsage? usage,
    String opaque = '',
  }) {
    final raw = switch (format) {
      AiFormat.chatCompletions => <String, Object?>{
        'role': 'assistant',
        'content': text,
        'extra_content': {'signature': opaque},
        if (calls.isNotEmpty)
          'tool_calls': [
            for (final c in calls)
              {
                'id': c.id,
                'type': 'function',
                'function': {
                  'name': c.name,
                  'arguments': jsonEncode(c.arguments),
                },
              },
          ],
      },
      AiFormat.responses => <Object?>[
        if (opaque.isNotEmpty)
          {'type': 'reasoning', 'encrypted_content': opaque},
        if (text.isNotEmpty)
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': text},
            ],
          },
        for (final c in calls)
          {
            'type': 'function_call',
            'call_id': c.id,
            'name': c.name,
            'arguments': jsonEncode(c.arguments),
          },
      ],
      AiFormat.anthropicMessages => <Object?>[
        if (opaque.isNotEmpty)
          {'type': 'thinking', 'thinking': '', 'signature': opaque},
        if (text.isNotEmpty || calls.isEmpty) {'type': 'text', 'text': text},
        for (final c in calls)
          {
            'type': 'tool_use',
            'id': c.id,
            'name': c.name,
            'input': c.arguments,
          },
      ],
    };
    return AiDecodedTurn(
      ProviderOutputEntry(format, raw, toolCalls: calls),
      stop,
      usage,
    );
  }
}

final spec = AiToolSpec(
  name: 'read_file',
  description: 'Read the pinned file.',
  parameters: {'type': 'object', 'properties': <String, Object?>{}},
);
AiToolCall call([String id = 'call']) =>
    AiToolCall(id: id, name: 'read_file', arguments: <String, Object?>{});

void main() {
  test(
    'cross-run app prefix and new provider-output secret roll over unchanged',
    () async {
      for (final format in AiFormat.values) {
        final h = Harness(format: format);
        h.respond = (_, _) async => h.turn(text: 'newSecretValue');
        await h.runner.run('earlier user newSecretValue');
        final old = h.runner.segment!;
        final oldJson = List<String>.of(old.frozenWireJson);
        final oldRaw = jsonEncode((old.frozen.last as ProviderOutputEntry).raw);
        h.secrets.current.add('newSecretValue');
        final result = await h.runner.run('follow up');
        expect(result.reason, AiRunEnd.done);
        expect(h.runner.segment, isNot(same(old)));
        expect(h.payloads.last, isNot(contains('newSecretValue')));
        expect(h.payloads.last, contains('conversation_summary'));
        expect(old.frozenWireJson, oldJson);
        expect(
          jsonEncode((old.frozen.last as ProviderOutputEntry).raw),
          oldRaw,
        );
        expect(h.runner.lateRedactions, 0);
      }
    },
  );

  test('only-key revision opens a segment without old opaque output', () async {
    for (final format in AiFormat.values) {
      final h = Harness(format: format);
      h.respond = (_, _) async =>
          h.turn(text: 'answer', opaque: 'opaque-original');
      await h.runner.run('one');
      final old = h.runner.segment;
      h.revision = 2;
      h.runner.replaceKeyRecipient(
        config: h.config(),
        complete: h.complete,
        close: () {},
        cancelActive: () {},
      );
      await h.runner.run('two');
      expect(h.consent, isTrue);
      expect(h.runner.segment, isNot(same(old)));
      expect(h.payloads.last, isNot(contains('opaque-original')));
    }
  });

  test(
    'OAuth refresh after read redacts new and retained tokens before send',
    () async {
      final h = Harness();
      h.secrets.current.add('oldOAuthValue');
      h.respond = (_, _) async => h.payloads.length == 1
          ? h.turn(calls: [call()])
          : h.turn(text: 'done');
      h.execute = (c) async {
        h.secrets.current.add('newOAuthValue');
        return AiToolResult(
          callId: c.id,
          name: c.name,
          content: '[source: job live]\noldOAuthValue newOAuthValue',
        );
      };
      final result = await h.runner.run('question');
      expect(result.reason, AiRunEnd.done);
      expect(h.payloads.last, isNot(contains('oldOAuthValue')));
      expect(h.payloads.last, isNot(contains('newOAuthValue')));
      expect(h.payloads.last, contains('[REDACTED]'));
    },
  );

  test(
    'mid-run prefix verification stops readable text and arguments but ignores opaque fields',
    () async {
      for (final format in AiFormat.values) {
        for (final location in ['app', 'text', 'arguments', 'opaque']) {
          final h = Harness(format: format);
          final tc = AiToolCall(
            id: 'id',
            name: 'read_file',
            arguments: {
              'value': location == 'arguments' ? 'newOAuthValue' : 'safe',
            },
          );
          h.respond = (_, _) async => h.payloads.length == 1
              ? h.turn(
                  text: location == 'text' ? 'newOAuthValue' : '',
                  calls: [tc],
                  opaque: location == 'opaque' ? 'newOAuthValue' : '',
                )
              : h.turn(text: 'done');
          h.execute = (c) async {
            h.secrets.current.add('newOAuthValue');
            return AiToolResult(callId: c.id, name: c.name, content: 'safe');
          };
          final result = await h.runner.run(
            location == 'app' ? 'newOAuthValue' : 'safe',
          );
          expect(
            result.reason,
            location == 'opaque' ? AiRunEnd.done : AiRunEnd.newSecret,
            reason: '$format $location',
          );
          expect(h.payloads.length, location == 'opaque' ? 2 : 1);
          expect(
            h.runner.segment!.tail,
            location == 'opaque' ? isNull : isA<AppToolResultsEntry>(),
          );
        }
      }
    },
  );

  test(
    'readable replay verification covers reasoning fields and decoded arguments',
    () {
      final chat = ProviderOutputEntry(
        AiFormat.chatCompletions,
        {
          'content': 'visible',
          'reasoning_content': 'reasoning-a',
          'reasoning': 'reasoning-b',
          'reasoning_details': [
            {
              'type': 'reasoning.text',
              'text': 'detail-text',
              'summary': 'detail-summary',
            },
            {
              'type': 'reasoning.encrypted',
              'data': 'opaque-data',
              'text': 'opaque-text',
            },
          ],
          'extra_content': {'signature': 'opaque-extra'},
        },
        toolCalls: [
          AiToolCall(
            id: 'c',
            name: 'read_file',
            arguments: {'key': 'line1\nline2'},
          ),
        ],
      );
      final values = readableAiEntry(chat).toList();
      expect(
        values,
        containsAll([
          'visible',
          'reasoning-a',
          'reasoning-b',
          'detail-text',
          'detail-summary',
          'line1\nline2',
        ]),
      );
      expect(values.join(), isNot(contains('opaque-')));
      final responses = ProviderOutputEntry(AiFormat.responses, [
        {
          'type': 'reasoning',
          'encrypted_content': 'opaque-encrypted',
          'summary': [
            {'type': 'summary_text', 'text': 'visible-summary'},
          ],
        },
        {
          'type': 'message',
          'content': [
            {'type': 'refusal', 'refusal': 'visible-refusal'},
          ],
        },
      ], toolCalls: const []);
      expect(
        readableAiEntry(responses),
        containsAll(['visible-summary', 'visible-refusal']),
      );
      expect(readableAiEntry(responses).join(), isNot(contains('opaque-')));
      final anthropic = ProviderOutputEntry(AiFormat.anthropicMessages, [
        {
          'type': 'thinking',
          'thinking': 'visible-thinking',
          'signature': 'opaque-signature',
        },
        {'type': 'fallback', 'text': 'visible-fallback'},
        {
          'type': 'server_tool_use',
          'input': {'query': 'visible-query'},
        },
        {'type': 'redacted_thinking', 'data': 'opaque-data'},
      ], toolCalls: const []);
      expect(
        readableAiEntry(anthropic),
        containsAll(['visible-thinking', 'visible-fallback', 'visible-query']),
      );
      expect(readableAiEntry(anthropic).join(), isNot(contains('opaque-')));
    },
  );

  for (final format in AiFormat.values) {
    for (final supportsChoice in [false, true]) {
      test(
        'finishing retains tools $format choice=$supportsChoice and pairs every call',
        () async {
          final h = Harness(format: format, toolChoice: supportsChoice);
          h.respond = (_, _) async =>
              h.turn(calls: [call('a'), call('b'), call('c'), call('d')]);
          final result = await h.runner.run('question');
          expect(result.reason, AiRunEnd.toolBudget);
          expect(h.payloads, hasLength(4)); // 12 reads then one closing call
          final first = jsonDecode(h.payloads.first)! as Map<String, Object?>;
          final last = jsonDecode(h.payloads.last)! as Map<String, Object?>;
          expect(last['tools'], first['tools']);
          expect(last.containsKey('tool_choice'), supportsChoice);
          if (!supportsChoice) {
            expect(h.payloads.last, contains(aiFinalAnswerNoteMarker));
          }
          final tail = h.runner.segment!.tail! as AppToolResultsEntry;
          expect(tail.results.map((r) => r.callId), ['a', 'b', 'c', 'd']);
          expect(tail.results.every((r) => r.isError), isTrue);
          final key = format == AiFormat.responses ? 'input' : 'messages';
          final prefix = first[key]! as List<Object?>;
          expect((last[key]! as List<Object?>).take(prefix.length), prefix);
        },
      );
    }
  }

  test('valid empty final answers terminate as toolBudgetNoAnswer', () async {
    final h = Harness();
    h.respond = (_, _) async => h.payloads.length < 4
        ? h.turn(calls: [call('a'), call('b'), call('c'), call('d')])
        : h.turn();
    expect(
      (await h.runner.run('question')).reason,
      AiRunEnd.toolBudgetNoAnswer,
    );
    expect(h.payloads, hasLength(4));
  });

  test(
    'A incomplete tool output is not frozen and restores initial context',
    () async {
      final h = Harness(
        context: [
          AiContextBlock(source: 'file', text: 'initial context'),
        ],
      );
      h.respond = (_, _) async =>
          throw const AiFailure(AiFailureKind.interrupted);
      expect(
        (await h.runner.run('question')).failure!.kind,
        AiFailureKind.interrupted,
      );
      expect(h.runner.segment!.entries, isEmpty);
      h.respond = (_, _) async => h.turn(text: 'answer');
      await h.runner.run('question');
      expect(h.payloads.last, contains('initial context'));
      expect(h.runner.segment!.frozen, hasLength(2));
    },
  );

  test(
    'B stop inside a read writes all synthetic results; C followup shares user tail',
    () async {
      final h = Harness(format: AiFormat.anthropicMessages);
      final pending = Completer<AiToolResult>();
      final entered = Completer<void>();
      h.respond = (_, _) async => h.turn(calls: [call('a'), call('b')]);
      h.execute = (_) {
        entered.complete();
        return pending.future;
      };
      final run = h.runner.run('first');
      await entered.future;
      h.runner.stop();
      expect((await run).reason, AiRunEnd.stopped);
      final tail = h.runner.segment!.tail! as AppToolResultsEntry;
      expect(tail.results, hasLength(2));
      expect(tail.results.every((r) => r.isError), isTrue);
      h.respond = (_, _) async => h.turn(text: 'answer');
      await h.runner.run('followup');
      final body = jsonDecode(h.payloads.last)! as Map<String, Object?>;
      final messages = (body['messages']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(messages.map((m) => m['role']), ['user', 'assistant', 'user']);
      expect(jsonEncode(messages.last), contains('followup'));
      pending.complete(
        AiToolResult(callId: 'a', name: 'read_file', content: 'late result'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(h.payloads.last, isNot(contains('late result')));
    },
  );

  test(
    'tail snapshot restores followup exactly once after first-request failure',
    () async {
      final h = Harness();
      h.respond = (_, _) async =>
          h.turn(calls: [call()], stop: AiStopReason.maxTokens);
      await h.runner.run('first');
      final snapshot = h.runner.segment!.tail;
      h.respond = (_, _) async => throw const AiFailure(AiFailureKind.network);
      await h.runner.run('retry-text');
      expect(h.runner.segment!.tail, same(snapshot));
      h.respond = (_, _) async => h.turn(text: 'answer');
      await h.runner.run('retry-text');
      expect('retry-text'.allMatches(h.payloads.last), hasLength(1));
    },
  );

  test('a request refused before sending uses no token budget', () async {
    final h = Harness(
      context: [AiContextBlock(source: 'file', text: 'synthetic context')],
    );
    h.respond = (plan, onEvent) async => throw const AiFailure(
      AiFailureKind.rateLimited,
      status: 429,
      notSent: true,
    );
    for (var run = 0; run < 3; run++) {
      final result = await h.runner.run('explain');
      expect(result.modelCalls, 0);
      expect(result.failure?.kind, AiFailureKind.rateLimited);
    }
    expect(h.runner.estimatedInputTokens, 0);
    expect(h.runner.actualInputTokens, 0);
  });

  test('sentContext is the context as last redacted before sending', () async {
    const late = 'synthetic-late-runner-0042';
    // Learn the secret at each refresh of the run in turn; what the runner
    // reports must match what the request carried.
    for (var k = 1; k <= 6; k++) {
      final h = Harness(
        context: [AiContextBlock(source: 'file', text: 'value $late here')],
      );
      var refreshes = 0;
      h.refresh = () {
        if (++refreshes == k) h.secrets.current.add(late);
      };
      await h.runner.run('explain');
      expect(
        h.runner.sentContext.single.text.contains(late),
        h.payloads.first.contains(late),
        reason: 'k=$k',
      );
    }
  });

  test(
    'context attaches once over three sends, frozen bytes never change',
    () async {
      final h = Harness(
        context: [AiContextBlock(source: 'file', text: 'unique-context')],
      );
      await h.runner.run('one');
      final prefix = List<String>.of(h.runner.segment!.frozenWireJson);
      await h.runner.run('two');
      await h.runner.run('three');
      expect('unique-context'.allMatches(h.payloads.last), hasLength(1));
      expect(h.runner.segment!.frozenWireJson.take(prefix.length), prefix);
    },
  );

  test(
    'projection starts with context, keeps recent turns, omits oldest, respects budget',
    () {
      final projection = buildAiProjection(
        context: [
          AiContextBlock(source: 'file', text: 'context SENSITIVE'),
        ],
        entries: [
          AppUserEntry(text: 'old' * 500),
          AppUserEntry(text: 'recent SENSITIVE'),
        ],
        budget: 200,
        redact: (s) => s.replaceAll('SENSITIVE', '[REDACTED]'),
      );
      expect(projection, contains('context [REDACTED]'));
      expect(projection, contains('recent'));
      expect(projection, contains('[earlier turns omitted]'));
      expect(projection.length, lessThanOrEqualTo(200));
      expect(projection, isNot(contains('SENSITIVE')));
    },
  );

  test('too little projection space fails without sending', () async {
    final h = Harness(maxChars: 700);
    await h.runner.run('one');
    h.runner.forceProjection();
    final before = h.payloads.length;
    final result = await h.runner.run('two');
    expect(result.failure!.kind, AiFailureKind.contextTooLong);
    expect(h.payloads.length, before);
  });

  for (final supportsChoice in [false, true]) {
    test(
      'truncation itself is finishing, final note redacted and within size choice=$supportsChoice',
      () async {
        final h = Harness(maxChars: 2400, toolChoice: supportsChoice);
        h.secrets.current.add('Tool budget');
        h.respond = (_, _) async => h.payloads.length == 1
            ? h.turn(calls: [call()])
            : h.turn(text: 'answer');
        h.execute = (c) async =>
            AiToolResult(callId: c.id, name: c.name, content: 'x' * 12000);
        expect((await h.runner.run('question')).reason, AiRunEnd.done);
        expect(h.payloads, hasLength(2));
        expect(h.payloads.last.length, lessThanOrEqualTo(2400));
        expect(h.payloads.last, isNot(contains('Tool budget')));
        final body = jsonDecode(h.payloads.last)! as Map<String, Object?>;
        if (supportsChoice) {
          expect(body['tool_choice'], 'none');
        } else {
          expect(h.payloads.last, contains('[REDACTED] is exhausted'));
        }
      },
    );
  }

  test(
    'no usage is estimated at ceil(request code units / 3); cap includes both counters',
    () async {
      final h = Harness(tokenCap: 100);
      await h.runner.run('one');
      expect(
        h.runner.estimatedInputTokens,
        (h.payloads.single.length + 2) ~/ 3,
      );
      expect(h.runner.actualInputTokens, 0);
      expect((await h.runner.run('two')).reason, AiRunEnd.tokenBudget);
      final other = Harness(tokenCap: 100);
      other.respond = (_, _) async => other.turn(
        text: 'done',
        usage: const AiUsage(inputTokens: 101, cacheReadInputTokens: 5),
      );
      await other.runner.run('one');
      expect(other.runner.actualInputTokens, 106);
      expect(other.runner.estimatedInputTokens, 0);
      expect((await other.runner.run('two')).reason, AiRunEnd.tokenBudget);
    },
  );

  for (final change in [
    'consent',
    'generation',
    'api',
    'revision',
    'delete',
    'tools',
  ]) {
    test(
      'stream checkpoint stops $change without freezing or next request',
      () async {
        final h = Harness();
        h.respond = (_, onEvent) async {
          switch (change) {
            case 'consent':
              h.consent = false;
            case 'generation':
              h.generation++;
            case 'api':
              h.api = Object();
            case 'delete':
              h.revision = null;
            default:
              h.revision = 2;
          }
          onEvent!(const AiTextDelta('late'));
          return h.turn(text: 'late', calls: [call()]);
        };
        expect((await h.runner.run('one')).reason, AiRunEnd.stoppedBySettings);
        expect(h.payloads, hasLength(1));
        expect(h.runner.segment!.entries, isEmpty);
        expect(h.closed, greaterThan(0));
      },
    );
  }

  test('settings listener stops a stalled stream immediately', () async {
    final h = Harness();
    final started = Completer<void>();
    final pending = Completer<AiDecodedTurn>();
    h.respond = (_, _) {
      started.complete();
      return pending.future;
    };
    final run = h.runner.run('one');
    await started.future;
    h.consent = false;
    h.runner.checkNow();
    expect((await run).reason, AiRunEnd.stoppedBySettings);
    pending.complete(h.turn(text: 'late'));
    expect(h.runner.segment!.entries, isEmpty);
  });

  test('soft timeout retains single pending read across sends', () async {
    final h = Harness(deadline: const Duration(milliseconds: 5));
    final pending = Completer<AiToolResult>();
    var reads = 0;
    h.execute = (_) {
      reads++;
      return pending.future;
    };
    h.respond = (_, _) async => h.payloads.length.isOdd
        ? h.turn(calls: [call('a'), call('b')])
        : h.turn(text: 'done');
    await h.runner.run('one');
    expect(reads, 1);
    expect(h.payloads.last, contains('timeout'));
    expect(h.payloads.last, contains('read_pending'));
    await h.runner.run('two');
    expect(reads, 1);
    pending.complete(
      AiToolResult(callId: 'a', name: 'read_file', content: 'late'),
    );
    await Future<void>.delayed(Duration.zero);
    await h.runner.run('three');
    expect(reads, 3);
  });

  test(
    'binding error starts next send from fresh redacted projection',
    () async {
      final h = Harness();
      await h.runner.run('one');
      final old = h.runner.segment;
      h.respond = (_, _) async => throw const AiFailure(
        AiFailureKind.invalidResponse,
        requiresNewSegment: true,
      );
      await h.runner.run('two');
      h.respond = (_, _) async => h.turn(text: 'done');
      await h.runner.run('three');
      expect(h.runner.segment, isNot(same(old)));
      expect(h.payloads.last, contains('conversation_summary'));
    },
  );

  test(
    'ANSI removed before exact redaction, private-key notice retained, oversize refused',
    () async {
      final h = Harness();
      h.secrets.current.add('knownValue');
      await h.runner.run('known\x1b[31mValue');
      expect(h.payloads.last, isNot(contains('knownValue')));
      expect(h.payloads.last, contains('[REDACTED]'));
      final result = await h.runner.run(
        '-----BEGIN PRIVATE KEY-----\nwithheld body',
      );
      expect(result.withheldPrivateKeyContext, isTrue);
      expect(h.payloads.last, isNot(contains('withheld body')));
      final before = h.payloads.length;
      expect(
        (await h.runner.run('x' * (2 * 1024 * 1024 + 1))).failure!.kind,
        AiFailureKind.policyBlocked,
      );
      expect(h.payloads.length, before);
    },
  );

  test('UTF16 clipping keeps surrogate pairs intact', () {
    expect(clipAiText('a\u{1f600}b', 2), 'a');
    expect(clipAiText('a\u{1f600}b', 3), 'a\u{1f600}');
  });

  for (final format in AiFormat.values) {
    test(
      'recorded decode-next-request chain $format preserves replay output',
      () async {
        final column = switch (format) {
          AiFormat.chatCompletions => 'C',
          AiFormat.responses => 'R',
          AiFormat.anthropicMessages => 'A',
        };
        final h = Harness(format: format);
        final turns = <AiDecodedTurn>[];
        for (final n in ['01', '02', '03']) {
          final decoder = h.wire.newDecoder();
          final file = File(
            'test/ai/fixtures/recorded/$column/loop/$n-loop${int.parse(n)}.response.sse',
          );
          await for (final event in const SseDecoder().decode(
            Stream.value(file.readAsBytesSync()),
          )) {
            decoder.add(event);
          }
          turns.add(decoder.finish());
        }
        var next = 0;
        h.respond = (_, _) async => turns[next++];
        await h.runner.run('recorded two-tool chain');
        expect(next, 3);
        h.respond = (_, _) async => h.turn(text: 'next');
        await h.runner.run('follow up');
        final body = jsonDecode(h.payloads.last)! as Map<String, Object?>;
        final items =
            body[format == AiFormat.responses ? 'input' : 'messages']!
                as List<Object?>;
        for (var index = 0; index < turns.length; index++) {
          final turn = turns[index];
          final output = h.runner.segment!.frozen
              .whereType<ProviderOutputEntry>()
              .elementAt(index);
          expect(jsonEncode(output.raw), jsonEncode(turn.output.raw));
          for (final raw in h.wire.encodeEntry(output, h.caps)) {
            expect(items.map(jsonEncode), contains(jsonEncode(raw)));
          }
          // Each decoded output is present in the immediately following real
          // request, including both tool results in the recorded chain.
          expect(
            h.payloads[index + 1],
            contains(h.wire.encodeEntry(output, h.caps).map(jsonEncode).first),
          );
        }
      },
    );
  }
}
