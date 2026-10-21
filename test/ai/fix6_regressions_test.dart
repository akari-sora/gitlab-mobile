import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';

import 'runner_test.dart' as base;

void main() {
  for (final secret in [
    'glpat-${'A' * 30}',
    'sk-proj-${'B' * 30}',
    'glpat-${'A' * 30}sk-proj-${'B' * 30}',
  ]) {
    test('R6-COUNT existing markers have zero redactions for $secret', () {
      final secrets = base.Secrets()..current.add(secret);
      final redactor = Redactor(secrets: secrets);
      const text = 'config pw=[REDACTED]\nother=[REDACTED]';
      final result = redactor.redactSource(text);
      expect(result.text, text);
      expect(result.redactions, 0);
    });
  }

  test('R6-OVERTRIM keeps a complete marker at a cut', () {
    final secrets = base.Secrets()
      ..current.add('sk-localdev${'A' * 16}.${'S' * 40}');
    final redactor = Redactor(secrets: secrets);
    const text = 'config pw=[REDACTED]';
    final result = redactor.redactCutEnd(text);
    expect(result.text, text);
    expect(result.redactions, 0);
    for (final tail in ['.', '.S', '.${'S' * 39}']) {
      expect(redactor.redactCutEnd('$text$tail').text, 'config pw=');
    }
  });

  for (final format in AiFormat.values) {
    test('R6-COUNT-RUNNER markers cause no late redactions $format', () async {
      final h = base.Harness(format: format);
      h.secrets.current.addAll(['glpat-${'A' * 30}', 'sk-proj-${'B' * 30}']);
      h.respond = (_, _) async => h.turn(text: 'answer [REDACTED]');
      expect((await h.runner.run('config [REDACTED]')).reason, AiRunEnd.done);
      expect((await h.runner.run('continue [REDACTED]')).reason, AiRunEnd.done);
      expect(h.payloads, hasLength(2));
      expect(h.runner.lateRedactions, 0);
    });

    for (final shape in <(String, String, String, bool)>[
      ('dot', 'sk-localdev${'A' * 16}.${'S' * 40}', '.${'S' * 40}', true),
      ('full', 'lateKnownValue-${'S' * 40}', 'lateKnownValue-', true),
      ('short', 'sk-localdev${'A' * 16}.x', '.x', false),
      ('three', 'sk-localdev${'A' * 16}.xy', '.xy', false),
      ('four', 'sk-localdev${'A' * 16}.xyz', '.xyz', true),
    ]) {
      test('R6-VERIFY-ALIAS ${shape.$1} $format', () async {
        final h = base.Harness(format: format);
        final catalogue = AiToolCatalogue(
          port: _Port('config:\n  api: ${shape.$2}\nend\n'),
          scope: const AiResourceScope(
            accountKey: 'instance|7',
            instanceKey: 'https://gitlab.example',
            projectId: 9,
            projectPath: 'group/project',
            current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
            headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            defaultBranch: 'main',
          ),
          redactor: Redactor(secrets: h.secrets),
        );
        var learned = false;
        h.refresh = () {
          if (!learned && h.payloads.length == 2) {
            learned = true;
            h.secrets.current.add(shape.$2);
          }
        };
        h.execute = (call) =>
            catalogue.executeResult(call, budget: AiToolBudget());
        h.respond = (_, _) async => h.payloads.length <= 2
            ? h.turn(
                calls: [
                  AiToolCall(
                    id: 'read-${h.payloads.length}',
                    name: 'read_file',
                    arguments: const {'path': 'README.md', 'revision': 'head'},
                  ),
                ],
              )
            : h.turn(text: 'done');

        expect(
          (await h.runner.run('question')).reason,
          shape.$4 ? AiRunEnd.newSecret : AiRunEnd.done,
        );
        expect(learned, isTrue);
        expect(h.payloads[1], contains(shape.$3));
        expect(h.payloads, hasLength(shape.$4 ? 2 : 3));
        h.respond = (_, _) async => h.turn(text: 'done');
        expect((await h.runner.run('continue')).reason, AiRunEnd.done);
        for (final payload in h.payloads.skip(2)) {
          if (shape.$4) expect(payload, isNot(contains(shape.$3)));
        }
        if (shape.$4) {
          expect(h.payloads.last, contains('conversation_summary'));
        }
      });
    }
  }
}

final class _Port implements AiGitLabReadPort {
  _Port(this.file);

  final String file;

  @override
  Future<AiPortRead<String>> readFile(String sha, String path) async =>
      AiPortRead(file, requestCount: 2);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
