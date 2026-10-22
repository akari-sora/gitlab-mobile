import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/app_text.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';

import 'runner_test.dart' as runner_test;

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [];
}

final class _Port implements AiGitLabReadPort {
  AiJson discussion = const {
    'iid': 3,
    'title': 'Synthetic discussion',
    'notes': <Object?>[],
  };
  bool fail = false;

  @override
  Future<AiPortRead<AiJson>> issue(int iid) async {
    if (fail) throw const FormatException('Synthetic read failure');
    return AiPortRead(discussion, requestCount: 2);
  }

  @override
  Future<AiPortRead<AiJson>> mergeRequest(int iid) => issue(iid);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected read: ${invocation.memberName}');
}

AiToolCatalogue _catalogue(_Port port) => AiToolCatalogue(
  port: port,
  scope: const AiResourceScope(
    accountKey: 'synthetic-account',
    instanceKey: 'https://gitlab.example',
    projectId: 42,
    projectPath: 'group/project',
    current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
    headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ),
  redactor: Redactor(secrets: _Secrets()),
);

AiToolCall _call(String name, [Map<String, Object?>? arguments]) => AiToolCall(
  id: 'synthetic-call',
  name: name,
  arguments: arguments ?? {'iid': 3},
);

void main() {
  test(
    'internal display metadata defaults false and survives result copies',
    () {
      for (final result in [
        AiToolResult(
          callId: 'call',
          name: 'get_issue',
          content: 'original',
          readInternal: true,
        ),
        const AiToolResult.fromData(
          callId: 'call',
          name: 'get_issue',
          data: AiAppText.plain('original'),
          readInternal: true,
        ),
      ]) {
        expect(
          result.copyWith(data: const AiAppText.plain('safe')).readInternal,
          isTrue,
        );
      }

      expect(
        AiToolResult(callId: 'call', name: 'tool', content: '').readInternal,
        isFalse,
      );
      expect(
        const AiToolResult.fromData(
          callId: 'call',
          name: 'tool',
          data: AiAppText.plain(''),
        ).readInternal,
        isFalse,
      );
      expect(
        const AiToolRunItem(
          name: 'tool',
          argsPreview: '',
          status: AiToolRunStatus.completed,
          sizeChars: 0,
          provenance: '',
        ).internal,
        isFalse,
      );
      expect(
        const AiContextChip(source: '', preview: '', sizeChars: 0).internal,
        isFalse,
      );
    },
  );

  test('runner reports successful confidential and internal reads', () async {
    final harness = runner_test.Harness();
    final observed = <AiToolResult>[];
    var modelCalls = 0;
    final runner = _runner(
      harness,
      complete: (_, {onEvent}) async => ++modelCalls == 1
          ? harness.turn(calls: [runner_test.call()])
          : harness.turn(text: 'done'),
      execute: (call) async => AiToolResult.fromData(
        callId: call.id,
        name: call.name,
        data: const AiAppText.plain('safe'),
        readConfidential: true,
        readInternal: true,
      ),
      onToolResult: observed.add,
    );

    expect((await runner.run('question')).reason, AiRunEnd.done);
    expect(observed, hasLength(1));
    expect(observed.single.readConfidential, isTrue);
    expect(observed.single.readInternal, isTrue);
  });

  for (final state in ['error', 'not executed', 'blocked']) {
    test('runner clears positive flags for $state results', () async {
      final harness = runner_test.Harness();
      final observed = <AiToolResult>[];
      var modelCalls = 0;
      final runner = _runner(
        harness,
        complete: (_, {onEvent}) async => ++modelCalls == 1
            ? harness.turn(calls: [runner_test.call()])
            : harness.turn(text: 'done'),
        execute: (call) async => AiToolResult.fromData(
          callId: call.id,
          name: call.name,
          data: const AiAppText.plain('safe'),
          isError: state == 'error',
          notExecuted: state == 'not executed',
          blockedSensitive: state == 'blocked',
          readConfidential: true,
          readInternal: true,
        ),
        onToolResult: observed.add,
      );

      expect((await runner.run('question')).reason, AiRunEnd.done);
      expect(observed, hasLength(1));
      expect(observed.single.readConfidential, isFalse);
      expect(observed.single.readInternal, isFalse);
    });
  }

  for (final tool in ['get_issue', 'get_merge_request']) {
    for (final field in ['internal', 'confidential']) {
      for (final value in <Object?>[true, false, null, 'true', 1]) {
        test('$tool reads strict $field note flag $value', () async {
          final note = <String, Object?>{'body': 'note', 'system': false};
          if (value != null) note[field] = value;
          final port = _Port()
            ..discussion = {
              'iid': 3,
              'notes': <Object?>[note],
            };
          final catalogue = _catalogue(port);
          final execution = await catalogue.execute(
            _call(tool),
            budget: AiToolBudget(),
          );
          final result = await catalogue.executeResult(
            _call(tool),
            budget: AiToolBudget(),
          );

          expect(execution.result.readInternal, value == true);
          expect(result.readInternal, value == true);
        });
      }
    }
  }

  test('system notes never mark a discussion as internally read', () async {
    final port = _Port()
      ..discussion = const {
        'iid': 3,
        'notes': <Object?>[
          {'body': 'system', 'system': true, 'internal': true},
          {'body': 'system legacy', 'system': true, 'confidential': true},
        ],
      };
    final catalogue = _catalogue(port);
    for (final tool in ['get_issue', 'get_merge_request']) {
      final result = await catalogue.executeResult(
        _call(tool),
        budget: AiToolBudget(),
      );
      expect(result.readInternal, isFalse);
    }
  });

  test(
    'failed, policy-blocked and budget-skipped results stay false',
    () async {
      final port = _Port()
        ..discussion = const {
          'iid': 3,
          'notes': <Object?>[
            {'body': 'internal', 'system': false, 'internal': true},
          ],
        }
        ..fail = true;
      final catalogue = _catalogue(port);

      final failed = await catalogue.executeResult(
        _call('get_issue'),
        budget: AiToolBudget(),
      );
      expect(failed.isError, isTrue);
      expect(failed.readInternal, isFalse);

      final blocked = await catalogue.executeResult(
        _call('read_file', {'path': '.env', 'revision': 'head'}),
        budget: AiToolBudget(),
      );
      expect(blocked.blockedSensitive, isTrue);
      expect(blocked.readInternal, isFalse);

      final skipped = await catalogue.executeResult(
        _call('get_issue'),
        budget: AiToolBudget(maxCallsPerRun: 0),
      );
      expect(skipped.isError, isTrue);
      expect(skipped.readInternal, isFalse);
    },
  );
}

AiRunner _runner(
  runner_test.Harness harness, {
  required AiComplete complete,
  required Future<AiToolResult> Function(AiToolCall) execute,
  required void Function(AiToolResult) onToolResult,
}) => AiRunner(
  config: harness.config(),
  wire: harness.wire,
  complete: complete,
  secrets: harness.secrets,
  refreshSecrets: () async {},
  guard: AiRunGuard(
    expectedGeneration: 1,
    ownerApi: harness.owner,
    generation: () => 1,
    api: () => harness.owner,
    recipientRevision: () => 1,
    consentValid: () => true,
  ),
  system: 'Synthetic system',
  tools: [runner_test.spec],
  close: () {},
  cancelActive: () {},
  executeTool: execute,
  onToolResult: onToolResult,
);
