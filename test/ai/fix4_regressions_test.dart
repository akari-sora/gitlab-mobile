import 'release_policy_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
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

const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final _lateRepeatedSecret = 'lateSECRETprefix-${'Q' * 70}-end';
final _secret108 = 'LATE-${'Q' * 98}-TAIL';
const _hexSecret =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  group('FIX4 production late-secret regression', () {
    for (final format in AiFormat.values) {
      for (final tool in ['read_file', 'get_job_log', 'get_issue']) {
        test('$tool $format trims a secret learned at final refresh', () async {
          final content = _lateRepeatedSecret * 700;
          final h = base.Harness(format: format);
          final port = _Port()..setToolContent(tool, content);
          final catalogue = _catalogue(port, h.secrets);
          _advertiseTools(h, catalogue.specs);
          AiToolResult? catalogueResult;
          var toolReturned = false;
          var refreshesAfterTool = 0;
          h.refresh = () {
            if (!toolReturned) return;
            refreshesAfterTool++;
            if (refreshesAfterTool == 3) {
              h.secrets.current.add(_lateRepeatedSecret);
            }
          };
          h.execute = (call) async {
            catalogueResult = await catalogue.executeResult(
              call,
              budget: AiToolBudget(),
            );
            toolReturned = true;
            return catalogueResult!;
          };
          h.respond = (_, _) async => h.payloads.length == 1
              ? h.turn(calls: [_call(tool)])
              : h.turn(text: 'done');

          expect((await h.runner.run('question')).reason, AiRunEnd.done);
          expect(refreshesAfterTool, greaterThanOrEqualTo(3));
          expect(
            catalogueResult!.plainData.plainText.length,
            lessThanOrEqualTo(20000),
          );
          _expectNoSecretPrefix(h.payloads.last, _lateRepeatedSecret);
          for (final entry
              in h.runner.segment!.entries.whereType<AppToolResultsEntry>()) {
            for (final result in entry.results) {
              _expectCutStringHasNoTrailingPrefix(
                result.plainData,
                _lateRepeatedSecret,
              );
            }
          }
          expect(h.payloads.last, isNot(contains('lateSECRETprefix')));
        });
      }
    }

    for (final tool in ['read_file', 'get_job_log', 'get_issue']) {
      for (final shape in <(String, String)>[
        ('108-character', _secret108),
        ('64-hex', _hexSecret),
      ]) {
        for (final separator in <(String, String)>[
          ('spaces', ' '),
          ('newlines', '\n'),
        ]) {
          for (final refresh in <(String, int)>[
            ('first post-tool', 1),
            ('final tail', 3),
          ]) {
            test(
              '$tool ${shape.$1} ${separator.$1} learned at ${refresh.$1}',
              () async {
                final secret = shape.$2;
                final h = base.Harness();
                final content = tool == 'get_job_log' && separator.$2 == '\n'
                    ? List.filled(5000, '$secret $secret').join('\n')
                    : List.filled(10000, secret).join(separator.$2);
                final port = _Port()..setToolContent(tool, content);
                final catalogue = _catalogue(port, h.secrets);
                _advertiseTools(h, catalogue.specs);
                var toolReturned = false;
                var refreshesAfterTool = 0;
                h.refresh = () {
                  if (!toolReturned) return;
                  refreshesAfterTool++;
                  if (refreshesAfterTool == refresh.$2) {
                    h.secrets.current.add(secret);
                  }
                };
                h.execute = (call) async {
                  final result = await catalogue.executeResult(
                    call,
                    budget: AiToolBudget(),
                  );
                  toolReturned = true;
                  return result;
                };
                h.respond = (_, _) async => h.payloads.length == 1
                    ? h.turn(calls: [_call(tool)])
                    : h.turn(text: 'done');

                expect((await h.runner.run('question')).reason, AiRunEnd.done);
                _expectNoSecretPrefix(h.payloads.last, secret);
                for (final entry
                    in h.runner.segment!.entries
                        .whereType<AppToolResultsEntry>()) {
                  for (final result in entry.results) {
                    _expectCutStringHasNoTrailingPrefix(
                      result.plainData,
                      secret,
                    );
                  }
                }
              },
            );
          }
        }
      }
    }
  });

  test('R4-CHAIN trims the repeated secret at the remembered cut', () {
    final secrets = base.Secrets();
    final redactor = Redactor(secrets: secrets);
    final clipped = AiAppText.untrusted(
      source: 'read_file',
      nonce: 'synthetic',
      body: AiAppText.plain(List.filled(10000, _secret108).join(' ')),
    ).clipped(20000);

    expect(clipped.encode().length, lessThanOrEqualTo(20000));
    expect(clipped.plainText.length, lessThanOrEqualTo(20000));
    secrets.current.add(_secret108);
    final safe = clipped.redact(redactor);

    _expectNoSecretPrefix(safe.encode(), _secret108);
    _expectCutStringHasNoTrailingPrefix(safe, _secret108);
    expect(safe.plainText, isNot(contains(_secret108)));
  });

  test('R4-PROJ trims a context secret learned in _setUserTail', () async {
    final context = AiContextBlock.fromData(
      source: 'synthetic context',
      data: AiAppText.plain(List.filled(3000, _secret108).join()),
    );
    final h = base.Harness(context: [context]);
    var refreshes = 0;
    h.refresh = () {
      refreshes++;
      // Initial refresh builds the projection while the secret is unknown;
      // the projected block is revisited by the next refresh in _setUserTail.
      if (refreshes == 2) h.secrets.current.add(_secret108);
    };
    h.runner.restoreFromDisplay([
      AiUserItem(text: 'old question'),
      const AiAssistantItem(text: 'old answer', state: AiAssistantState.done),
    ]);

    expect((await h.runner.run('continue')).reason, AiRunEnd.done);
    expect(h.payloads.single, contains('conversation_summary'));
    _expectNoSecretPrefix(h.payloads.single, _secret108);
  });

  test('R4-CROSS catalogue trims one secret crossing its cut', () async {
    final secrets = base.Secrets();
    final port = _Port()..file = 'x' * 50000;
    final catalogue = _catalogue(port, secrets);
    final probe = await catalogue.executeResult(
      _call('read_file'),
      budget: AiToolBudget(maxSingleOutputChars: 20000),
    );
    final cut = probe.plainData.plainStrings.last.length;
    expect(cut, greaterThan(100));
    port.file = '${'x' * (cut - 50)}$_secret108${'y' * 50000}';
    final crossed = await catalogue.executeResult(
      _call('read_file'),
      budget: AiToolBudget(maxSingleOutputChars: 20000),
    );

    secrets.current.add(_secret108);
    final safe = crossed.plainData.redact(Redactor(secrets: secrets));

    _expectNoSecretPrefix(safe.encode(), _secret108);
    _expectCutStringHasNoTrailingPrefix(safe, _secret108);
  });

  test('catalogue error clip trims late-known provenance at its cut', () async {
    final secrets = base.Secrets();
    final redactor = Redactor(secrets: secrets);
    final catalogue = AiToolCatalogue(
      releasePolicy: fixtureReleasePolicy,
      port: _Port(),
      scope: _scope(),
      redactor: redactor,
      now: () => DateTime.utc(2026, 10, 21, 12, 34, 56),
    );
    final call = _call('unknown_tool');
    final complete = await catalogue.executeResult(
      call,
      budget: AiToolBudget(),
    );
    final provenance = complete.plainData.plainStrings.first;
    expect(provenance.length, greaterThan(30));
    expect('[REDACTED]', isNot(contains(provenance)));

    final clipped = await catalogue.executeResult(
      call,
      budget: AiToolBudget(maxSingleOutputChars: 30),
    );
    expect(clipped.isError, isTrue);
    expect(clipped.truncated, isTrue);
    expect(clipped.plainData.plainStrings.single, provenance.substring(0, 30));

    secrets.current.add(provenance);
    final safe = clipped.plainData.redact(redactor);

    _expectCutStringHasNoTrailingPrefix(safe, provenance);
    expect(safe.encode(), isNot(contains(provenance.substring(0, 2))));
  });

  test('R4-CROSS clipTailToolResults trims one secret crossing its cut', () {
    final secrets = base.Secrets();
    final redactor = Redactor(secrets: secrets);
    const maximum = 1000;
    AiSegment segmentWith(String body) =>
        AiSegment(
          providerId: 'provider',
          recipientRevision: 1,
          format: AiFormat.chatCompletions,
          model: 'synthetic',
          secretSetAtStart: SecretSetId.fromSecrets(const []),
        )..setTail(
          AppToolResultsEntry([
            AiToolResult.fromData(
              callId: 'call',
              name: 'read_file',
              data: AiAppText.untrusted(
                source: 'read_file',
                nonce: 'synthetic',
                body: AiAppText.plain(body),
              ),
            ),
          ]),
        );

    final probe = segmentWith('x' * 5000)..clipTailToolResults(maximum);
    final cut = (probe.tail! as AppToolResultsEntry)
        .results
        .single
        .plainData
        .plainStrings
        .last
        .length;
    final crossed = segmentWith('${'x' * (cut - 50)}$_secret108${'y' * 5000}')
      ..clipTailToolResults(maximum);

    secrets.current.add(_secret108);
    final result = (crossed.tail! as AppToolResultsEntry).results.single;
    final safe = result.plainData.redact(redactor).encode();

    _expectNoSecretPrefix(safe, _secret108);
    expect(safe.length, lessThanOrEqualTo(maximum));
  });

  test('runner 20000 and 120000 caps trim a late cut secret', () async {
    final h = base.Harness();
    var execution = 0;
    var targetReturned = false;
    var refreshesAfterTarget = 0;
    h.refresh = () {
      if (!targetReturned) return;
      refreshesAfterTarget++;
      if (refreshesAfterTarget == 3) h.secrets.current.add(_secret108);
    };
    h.execute = (call) async {
      execution++;
      final body = switch (execution) {
        <= 5 => 'x' * 30000,
        6 => 'x' * 15000,
        _ => List.filled(1000, _secret108).join(' '),
      };
      if (execution == 7) targetReturned = true;
      return AiToolResult.fromData(
        callId: call.id,
        name: call.name,
        data: AiAppText.untrusted(
          source: 'read_file',
          nonce: 'synthetic-$execution',
          body: AiAppText.plain(body),
        ),
      );
    };
    h.respond = (_, _) async => switch (h.payloads.length) {
      1 => h.turn(calls: [for (var i = 0; i < 4; i++) base.call('a$i')]),
      2 => h.turn(calls: [for (var i = 0; i < 3; i++) base.call('b$i')]),
      _ => h.turn(text: 'done'),
    };

    expect(
      (await h.runner.run('question')).reason,
      anyOf(AiRunEnd.done, AiRunEnd.toolBudget),
    );
    expect(execution, 7);
    expect(refreshesAfterTarget, greaterThanOrEqualTo(3));
    _expectNoSecretPrefix(h.payloads.last, _secret108);
  });

  test(
    'runner request cap trims a crossing secret in clipTailToolResults',
    () async {
      final h = base.Harness(maxChars: 12000);
      var toolReturned = false;
      var refreshesAfterTool = 0;
      h.refresh = () {
        if (!toolReturned) return;
        refreshesAfterTool++;
        if (refreshesAfterTool == 3) h.secrets.current.add(_secret108);
      };
      h.execute = (call) async {
        toolReturned = true;
        return AiToolResult.fromData(
          callId: call.id,
          name: call.name,
          data: AiAppText.untrusted(
            source: 'read_file',
            nonce: 'synthetic',
            body: AiAppText.plain(List.filled(300, _secret108).join(' ')),
          ),
        );
      };
      h.respond = (_, _) async => h.payloads.length == 1
          ? h.turn(calls: [base.call()])
          : h.turn(text: 'done');

      expect((await h.runner.run('question')).reason, AiRunEnd.done);
      expect(refreshesAfterTool, greaterThanOrEqualTo(3));
      expect(h.payloads.last.length, lessThanOrEqualTo(12000));
      _expectNoSecretPrefix(h.payloads.last, _secret108);
    },
  );

  test('runner cap trims a late secret in a synthetic budget result', () async {
    const syntheticSecret = 'Not executed: budget';
    final h = base.Harness();
    var execution = 0;
    var lastExecutedReturned = false;
    var refreshesAfterLastExecuted = 0;
    var beforeRefresh = '';
    h.refresh = () {
      if (!lastExecutedReturned) return;
      refreshesAfterLastExecuted++;
      if (refreshesAfterLastExecuted == 3) {
        beforeRefresh = (h.runner.segment!.tail! as AppToolResultsEntry)
            .results
            .last
            .content;
        h.secrets.current.add(syntheticSecret);
      }
    };
    h.execute = (call) async {
      execution++;
      final body = switch (execution) {
        <= 5 => 'x' * 30000,
        6 => 'x' * 19980,
        _ => '',
      };
      if (execution == 8) lastExecutedReturned = true;
      return AiToolResult.fromData(
        callId: call.id,
        name: call.name,
        data: AiAppText.plain(body),
      );
    };
    h.respond = (_, _) async => switch (h.payloads.length) {
      1 => h.turn(calls: [for (var i = 0; i < 4; i++) base.call('a$i')]),
      2 => h.turn(calls: [for (var i = 0; i < 5; i++) base.call('b$i')]),
      _ => h.turn(text: 'done'),
    };

    expect(
      (await h.runner.run('question')).reason,
      anyOf(AiRunEnd.done, AiRunEnd.toolBudget),
    );
    expect(execution, 8);
    expect(beforeRefresh, contains('Not e'));
    expect(refreshesAfterLastExecuted, greaterThanOrEqualTo(3));
    expect(h.payloads.last, isNot(contains('Not e')));
    final synthetic = h.runner.segment!.frozen
        .whereType<AppToolResultsEntry>()
        .last
        .results
        .last;
    expect(synthetic.isError, isTrue);
    expect(synthetic.content.length, lessThanOrEqualTo(20));
    expect(synthetic.content, isNot(contains('Not e')));
  });

  test(
    'projection provenance clip trims a secret learned after projection',
    () {
      final secrets = base.Secrets();
      final redactor = Redactor(secrets: secrets);
      final provenance = '[source: ${'x' * 470}$_secret108${'y' * 100}';
      final projection = buildAiProjectionData(
        context: const [],
        entries: [
          AppToolResultsEntry([
            AiToolResult.fromData(
              callId: 'call',
              name: 'read_file',
              data: AiAppText.plain('$provenance\nbody'),
            ),
          ]),
        ],
        budget: 2000,
        redact: (text) => redactor.redactSource(text).text,
      );

      secrets.current.add(_secret108);
      final safe = projection.redact(redactor).encode();

      _expectNoSecretPrefix(safe, _secret108);
    },
  );

  test('get_issue drops container entries after the cut string', () async {
    final port = _Port()
      ..discussion = {
        'iid': 3,
        'title': 'title',
        'description': 'x' * 50000,
        'state': 'opened',
        'labels': List<String>.filled(200000, 'x'),
        'notes': <Object?>[],
      };
    final result = await _catalogue(port, base.Secrets()).executeResult(
      _call('get_issue'),
      budget: AiToolBudget(maxSingleOutputChars: 20000),
    );

    expect(result.truncated, isTrue);
    expect(result.plainData.plainStrings.length, lessThan(50));
    expect(result.plainData.plainText.length, lessThanOrEqualTo(20000));
  });

  test('get_issue retains a bounded prefix of 200000 labels', () async {
    final port = _Port()
      ..discussion = {
        'iid': 3,
        'title': 'title',
        'description': 'short',
        'state': 'opened',
        'labels': List<String>.filled(200000, 'x'),
        'notes': <Object?>[],
      };
    final result = await _catalogue(port, base.Secrets()).executeResult(
      _call('get_issue'),
      budget: AiToolBudget(maxSingleOutputChars: 20000),
    );

    expect(result.truncated, isTrue);
    expect(result.plainData.plainStrings.length, lessThan(6000));
    expect(result.plainData.plainText.length, lessThanOrEqualTo(20000));
  });
}

void _advertiseTools(base.Harness h, List<AiToolSpec> tools) {
  h.runner = AiRunner(
    appInForeground: () => true,
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

void _expectNoSecretPrefix(String actual, String secret) {
  // Very short prefixes collide with ordinary JSON keys, timestamps, and
  // random wrapper nonces. Eight characters is still far below every cut
  // exposed by the regressions while keeping this assertion deterministic.
  for (var length = secret.length; length >= 8; length--) {
    expect(
      actual,
      isNot(contains(secret.substring(0, length))),
      reason: 'delivered a $length-character prefix of the synthetic secret',
    );
  }
}

void _expectCutStringHasNoTrailingPrefix(AiAppText actual, String secret) {
  final cutString = actual.plainStrings.last;
  for (var length = 1; length < secret.length; length++) {
    expect(
      cutString,
      isNot(endsWith(secret.substring(0, length))),
      reason: 'cut string retained a $length-character secret prefix',
    );
  }
}

AiToolCatalogue _catalogue(_Port port, KnownSecretsSource secrets) =>
    AiToolCatalogue(
      releasePolicy: fixtureReleasePolicy,
      port: port,
      scope: _scope(),
      redactor: Redactor(secrets: secrets),
    );

AiToolCall _call(String name) => AiToolCall(
  id: 'call-$name',
  name: name,
  arguments: switch (name) {
    'read_file' => {'path': 'README.md', 'revision': 'head'},
    'get_job_log' => {'job_id': 4},
    'get_issue' => {'iid': 3},
    _ => const <String, Object?>{},
  },
);

AiResourceScope _scope() => const AiResourceScope(
  accountKey: 'instance|7',
  instanceKey: 'https://gitlab.example',
  projectId: 9,
  projectPath: 'group/project',
  current: AiResourceRef(kind: AiResourceKind.job, id: 4),
  headSha: _head,
  baseSha: _base,
  pipelineId: 8,
  jobId: 4,
  defaultBranch: 'main',
);

final class _Port implements AiGitLabReadPort {
  String file = 'file';
  String jobLogText = 'log';
  AiJson discussion = const {
    'iid': 3,
    'title': 'title',
    'description': 'description',
    'state': 'opened',
    'notes': <Object?>[],
  };

  void setToolContent(String tool, String content) {
    switch (tool) {
      case 'read_file':
        file = content;
      case 'get_job_log':
        jobLogText = content;
      case 'get_issue':
        discussion = {...discussion, 'description': content};
    }
  }

  @override
  Future<AiPortRead<AiJson>> commit(String sha) async =>
      AiPortRead({'id': sha}, requestCount: 1);

  @override
  Future<AiPortRead<List<AiJson>>> commitDiff(String sha) async =>
      const AiPortRead([], requestCount: 1);

  @override
  Future<AiPortRead<AiJson>> issue(int iid) async =>
      AiPortRead(discussion, requestCount: 2);

  @override
  Future<AiPortRead<String>> jobLog(int jobId) async =>
      AiPortRead(jobLogText, requestCount: 1);

  @override
  Future<AiPortRead<List<AiTreeItem>>> listDirectory(
    String sha,
    String path,
  ) async => const AiPortRead([], requestCount: 1);

  @override
  Future<AiPortRead<AiJson>> mergeRequest(int iid) => issue(iid);

  @override
  Future<AiPortRead<AiJson>> mergeRequestDiff(
    int iid, {
    required String headSha,
    required String baseSha,
  }) async => AiPortRead({
    'diff_refs': {'head_sha': headSha, 'base_sha': baseSha},
    'changes': <Object?>[],
  }, requestCount: 1);

  @override
  Future<AiPortRead<List<AiJson>>> pipelineJobs(int pipelineId) async =>
      const AiPortRead([], requestCount: 1);

  @override
  Future<AiPortRead<String>> readFile(String sha, String path) async =>
      AiPortRead(file, requestCount: 2);

  @override
  Future<AiPortRead<List<AiJson>>> search(String scope, String query) async =>
      const AiPortRead([], requestCount: 1);
}
