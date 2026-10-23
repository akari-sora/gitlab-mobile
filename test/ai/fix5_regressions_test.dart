import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/app_text.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

import 'runner_test.dart' as base;

void main() {
  for (final format in AiFormat.values) {
    test('FIX5 colliding JSON keys preserve the cut marker $format', () async {
      final secret = 'lateOrdinalSecret-${'Q' * 70}-end';
      final h = base.Harness(format: format);
      final port = _Port()
        ..discussion = {
          'iid': 3,
          'title': 'one',
          'description': 'two',
          'state': 'opened',
          'labels': ['${'x' * 19753}$secret${'y' * 50000}'],
          'notes': <Object?>[],
        };
      final catalogue = _catalogue(port, h.secrets);
      _advertiseTools(h, catalogue.specs);
      var returned = false;
      var refreshes = 0;
      h.refresh = () {
        if (!returned) return;
        refreshes++;
        if (refreshes == 1) h.secrets.current.addAll(['title', 'description']);
        if (refreshes == 3) h.secrets.current.add(secret);
      };
      h.execute = (call) async {
        final result = await catalogue.executeResult(
          call,
          budget: AiToolBudget(),
        );
        returned = true;
        return result;
      };
      h.respond = (_, _) async => h.payloads.length == 1
          ? h.turn(calls: [_call('get_issue')])
          : h.turn(text: 'done');

      expect((await h.runner.run('question')).reason, AiRunEnd.done);
      expect(refreshes, greaterThanOrEqualTo(3));
      expect(h.payloads, hasLength(2));
      _expectNoPrefix(h.payloads.last, secret);
      final result = h.runner.segment!.entries
          .whereType<AppToolResultsEntry>()
          .single
          .results
          .single;
      expect(result.plainData.plainStrings, contains('[REDACTED]'));
      _expectNoCutPrefix(result.plainData, secret);
    });

    test(
      'FIX5 projection retains an undelivered provenance cut $format',
      () async {
        final secret = 'lateProjectionSecret-${'Q' * 70}-end';
        final h = base.Harness(format: format);
        final catalogue = _catalogue(_Port(), h.secrets);
        var returned = false;
        var refreshes = 0;
        h.refresh = () {
          if (returned && ++refreshes == 2) h.runner.stop();
        };
        h.execute = (call) async {
          final result = await catalogue.executeResult(
            call,
            budget: AiToolBudget(maxSingleOutputChars: 50),
          );
          returned = true;
          return result;
        };
        h.respond = (_, _) async =>
            h.turn(calls: [_call('read_file', path: 'sample-$secret.txt')]);
        expect((await h.runner.run('question')).reason, AiRunEnd.stopped);
        expect(h.payloads, hasLength(1));
        _expectNoPrefix(h.payloads.single, secret);
        final pending =
            (h.runner.segment!.tail! as AppToolResultsEntry).results.single;
        expect(pending.plainData.plainText, contains(secret.substring(0, 29)));

        h.runner.forceProjection();
        var nextRefreshes = 0;
        h.refresh = () {
          if (++nextRefreshes == 2) h.secrets.current.add(secret);
        };
        h.respond = (_, _) async => h.turn(text: 'done');

        expect((await h.runner.run('continue')).reason, AiRunEnd.done);
        expect(h.payloads, hasLength(2));
        expect(h.payloads.last, contains('conversation_summary'));
        _expectNoPrefix(h.payloads.last, secret);
      },
    );

    for (final shape in <(String, String)>[
      ('dot', 'sk-localdev${'A' * 16}.${'S' * 40}'),
      ('base64', 'sk-localdev${'A' * 16}+${'T' * 16}/${'U' * 14}=='),
    ]) {
      for (final cut in [false, true]) {
        for (final learnedAt in [1, 3]) {
          test(
            'FIX5 pattern alias ${shape.$1} cut=$cut refresh=$learnedAt $format',
            () async {
              final secret = shape.$2;
              final h = base.Harness(format: format);
              final port = _Port()..file = 'x' * 50000;
              final catalogue = _catalogue(port, h.secrets);
              final probe = await catalogue.executeResult(
                _call('read_file'),
                budget: AiToolBudget(),
              );
              final bodyCut = probe.plainData.plainStrings.last.length;
              port.file = cut
                  ? '${'x' * (bodyCut - 25)}api: $secret${'y' * 50000}'
                  : 'api: $secret';
              var returned = false;
              var refreshes = 0;
              h.refresh = () {
                if (returned && ++refreshes == learnedAt) {
                  h.secrets.current.add(secret);
                }
              };
              h.execute = (call) async {
                final result = await catalogue.executeResult(
                  call,
                  budget: AiToolBudget(),
                );
                // Intake matched the head, while the key was still unknown.
                expect(result.plainData.plainText, contains('[REDACTED]'));
                expect(
                  result.plainData.plainText,
                  contains(shape.$1 == 'dot' ? '.S' : '+T'),
                );
                expect(result.truncated, cut);
                returned = true;
                return result;
              };
              h.respond = (_, _) async => h.payloads.length == 1
                  ? h.turn(calls: [_call('read_file')])
                  : h.turn(text: 'done');

              expect((await h.runner.run('question')).reason, AiRunEnd.done);
              expect(refreshes, greaterThanOrEqualTo(learnedAt));
              expect(h.payloads, hasLength(2));
              expect(
                h.payloads.last,
                isNot(contains(shape.$1 == 'dot' ? '.S' : '+T')),
              );
              expect(h.payloads.last, isNot(contains('/UU')));
              final result = h.runner.segment!.entries
                  .whereType<AppToolResultsEntry>()
                  .single
                  .results
                  .single;
              expect(result.content, isNot(contains(secret)));
              if (cut) {
                final alias = Redactor(
                  secrets: base.Secrets(),
                ).redactSource(secret).text;
                _expectNoCutPrefix(result.plainData, alias);
              } else {
                expect(result.plainData.plainStrings.last, 'api: [REDACTED]');
              }
            },
          );
        }
      }
    }
  }

  test('FIX5 a colliding key retains the cut value with its marker', () {
    final secrets = base.Secrets();
    final redactor = Redactor(secrets: secrets);
    const secret = 'lateValueSecret';
    final value = AiAppText.json({
      'title': 'one',
      'description': secret,
    }).clipped(40);
    expect(value.plainStrings.last, 'lateValu');
    secrets.current.addAll(['title', 'description']);
    final collision = value.redact(redactor);
    expect(collision.plainStrings.toList(), ['[REDACTED]', 'lateValu']);
    secrets.current.add(secret);
    expect(collision.redact(redactor).plainStrings.toList(), [
      '[REDACTED]',
      '',
    ]);
  });

  for (final priorSummary in [false, true]) {
    test(
      'FIX5 projection preserves existing context cuts prior=$priorSummary',
      () {
        final secrets = base.Secrets();
        final redactor = Redactor(secrets: secrets);
        const secret = 'lateContextSecret';
        final block = AiContextBlock.fromData(
          source: priorSummary ? 'conversation_summary' : 'file',
          data: const AiAppText.plain(secret).clipped(11),
        );
        final projection = buildAiProjectionData(
          context: priorSummary ? [] : [block],
          entries: priorSummary
              ? [
                  AppUserEntry(text: 'question', context: [block]),
                ]
              : [],
          budget: 2000,
          redact: (text) => redactor.redactSource(text).text,
        );
        expect(projection.encode(), contains('lateContext'));
        secrets.current.add(secret);
        expect(
          projection.redact(redactor).encode(),
          isNot(contains('lateContext')),
        );
      },
    );
  }
}

void _advertiseTools(base.Harness h, List<AiToolSpec> tools) {
  h.runner = AiRunner(
    config: h.config(),
    wire: h.wire,
    complete: h.complete,
    secrets: h.secrets,
    refreshSecrets: () async => h.refresh?.call(),
    guard: AiRunGuard(
      expectedGeneration: 1,
      ownerApi: h.owner,
      generation: () => h.generation,
      api: () => h.api,
      recipientRevision: () => h.revision,
      consentValid: () => h.consent,
    ),
    system: 'You answer questions about repository data.',
    tools: tools,
    close: () => h.closed++,
    cancelActive: () => h.cancelled++,
    executeTool: (call) async => h.execute!(call),
  );
}

void _expectNoPrefix(String actual, String secret) {
  expect(actual, isNot(contains(secret.substring(0, 8))));
}

void _expectNoCutPrefix(AiAppText actual, String secret) {
  for (var length = 1; length < secret.length; length++) {
    expect(
      actual.plainStrings.last,
      isNot(endsWith(secret.substring(0, length))),
    );
  }
}

AiToolCatalogue _catalogue(_Port port, KnownSecretsSource secrets) =>
    AiToolCatalogue(
      port: port,
      scope: const AiResourceScope(
        accountKey: 'instance|7',
        instanceKey: 'https://gitlab.example',
        projectId: 9,
        projectPath: 'group/project',
        current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
        headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        defaultBranch: 'main',
      ),
      redactor: Redactor(secrets: secrets),
    );

AiToolCall _call(String name, {String path = 'README.md'}) => AiToolCall(
  id: 'call-$name',
  name: name,
  arguments: name == 'get_issue'
      ? {'iid': 3}
      : {'path': path, 'revision': 'head'},
);

final class _Port implements AiGitLabReadPort {
  String file = 'file';
  AiJson discussion = const {};

  @override
  Future<AiPortRead<AiJson>> issue(int iid) async =>
      AiPortRead(discussion, requestCount: 2);

  @override
  Future<AiPortRead<String>> readFile(String sha, String path) async =>
      AiPortRead(file, requestCount: 2);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
