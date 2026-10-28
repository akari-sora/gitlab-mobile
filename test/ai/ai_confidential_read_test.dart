import 'release_policy_support.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/app_text.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';

import '../support/workspace_fixture.dart';

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [];
}

final class _Port implements AiGitLabReadPort {
  AiJson value = {'iid': 3, 'title': 'Synthetic issue', 'notes': <Object?>[]};
  List<AiJson> hits = [];
  bool fail = false;
  int reads = 0;

  @override
  Future<AiPortRead<AiJson>> issue(int iid) async {
    reads++;
    if (fail) throw const FormatException('Synthetic read failure');
    return AiPortRead(value, requestCount: 2);
  }

  @override
  Future<AiPortRead<AiJson>> mergeRequest(int iid) => issue(iid);

  @override
  Future<AiPortRead<List<AiJson>>> search(String scope, String query) async {
    reads++;
    if (fail) throw const FormatException('Synthetic search failure');
    return AiPortRead(hits, requestCount: 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected read: ${invocation.memberName}');
}

AiToolCatalogue _catalogue(_Port port) => AiToolCatalogue(
  releasePolicy: fixtureReleasePolicy,
  port: port,
  scope: AiResourceScope(
    accountKey: 'synthetic-account',
    instanceKey: 'https://gitlab.example',
    projectId: 42,
    projectPath: 'group/project',
    current: const AiResourceRef(kind: AiResourceKind.issue, id: 3),
    headSha: WorkspaceFixture.sha,
  ),
  redactor: Redactor(secrets: _Secrets()),
);

AiToolCall _call(String name, Map<String, Object?> arguments) =>
    AiToolCall(id: 'synthetic-call', name: name, arguments: arguments);

Map<String, Object?> _toolRecord() => {
  'kind': 'tool',
  'name': 'get_issue',
  'argsPreview': '#3',
  'status': 'completed',
  'sizeChars': 12,
  'provenance': 'issue #3',
  'truncated': false,
  'blocked': false,
  'resultExcerpt': 'Synthetic issue',
};

void main() {
  for (final field in [true, false, null, 'true', 1]) {
    test('get_issue reads only boolean true as confidential: $field', () async {
      final port = _Port();
      if (field != null) port.value['confidential'] = field;
      final catalogue = _catalogue(port);
      final call = _call('get_issue', {'iid': 3});
      final execution = await catalogue.execute(call, budget: AiToolBudget());
      expect(execution.result.isError, isFalse);
      expect(execution.result.readConfidential, field == true);
      final result = await catalogue.executeResult(
        call,
        budget: AiToolBudget(),
      );
      expect(result.isError, isFalse);
      expect(result.readConfidential, field == true);
    });
  }

  for (final scope in ['issues', 'merge_requests', 'commits', 'blobs']) {
    test('search_project tracks confidential hits only for $scope', () async {
      final port = _Port()
        ..hits = [
          {'iid': 1, 'path': 'a.dart', 'confidential': false},
          {'iid': 2, 'path': 'b.dart', 'confidential': true},
        ];
      final result = await _catalogue(port).executeResult(
        _call('search_project', {'scope': scope, 'query': 'synthetic'}),
        budget: AiToolBudget(),
      );
      expect(result.isError, isFalse);
      expect(result.readConfidential, scope == 'issues');
    });
  }

  test('search without a boolean true confidential hit is public', () async {
    final port = _Port()
      ..hits = [
        {'iid': 1},
        {'iid': 2, 'confidential': 'true'},
        {'iid': 3, 'confidential': false},
      ];
    final catalogue = _catalogue(port);
    for (final hits in [port.hits, <AiJson>[]]) {
      port.hits = hits;
      final result = await catalogue.executeResult(
        _call('search_project', {'scope': 'issues', 'query': 'synthetic'}),
        budget: AiToolBudget(),
      );
      expect(result.isError, isFalse);
      expect(result.readConfidential, isFalse);
    }
  });

  test('merge request JSON cannot mark an issue read', () async {
    final port = _Port()..value['confidential'] = true;
    final result = await _catalogue(port).executeResult(
      _call('get_merge_request', {'iid': 3}),
      budget: AiToolBudget(),
    );
    expect(result.isError, isFalse);
    expect(result.readConfidential, isFalse);
  });

  test('truncation keeps the flag from the decoded issue JSON', () async {
    final port = _Port()..value['confidential'] = true;
    final result = await _catalogue(port).executeResult(
      _call('get_issue', {'iid': 3}),
      budget: AiToolBudget(maxSingleOutputChars: 1),
    );
    expect(result.truncated, isTrue);
    expect(result.readConfidential, isTrue);
  });

  test('failed, policy-blocked and budget-skipped reads are false', () async {
    final port = _Port()
      ..value['confidential'] = true
      ..fail = true;
    final catalogue = _catalogue(port);
    for (final call in [
      _call('get_issue', {'iid': 3}),
      _call('search_project', {'scope': 'issues', 'query': 'synthetic'}),
    ]) {
      final failed = await catalogue.executeResult(
        call,
        budget: AiToolBudget(),
      );
      expect(failed.isError, isTrue);
      expect(failed.readConfidential, isFalse);
    }
    final reads = port.reads;
    final blocked = await catalogue.executeResult(
      _call('read_file', {'path': '.env', 'revision': 'head'}),
      budget: AiToolBudget(),
    );
    expect(blocked.blockedSensitive, isTrue);
    expect(blocked.readConfidential, isFalse);
    final skipped = await catalogue.executeResult(
      _call('get_issue', {'iid': 3}),
      budget: AiToolBudget(maxCallsPerRun: 0),
    );
    expect(skipped.isError, isTrue);
    expect(skipped.readConfidential, isFalse);
    expect(port.reads, reads);
    expect(
      const AiToolResult.fromData(
        callId: 'skip',
        name: 'get_issue',
        data: AiAppText.plain('Not executed'),
        notExecuted: true,
      ).readConfidential,
      isFalse,
    );
    expect(
      AiToolResult(
        callId: 'error',
        name: 'get_issue',
        content: '',
        isError: true,
      ).readConfidential,
      isFalse,
    );
  });

  test('tool result copies retain display metadata', () {
    for (final result in [
      AiToolResult(
        callId: 'read',
        name: 'get_issue',
        content: 'original',
        readConfidential: true,
        readInternal: true,
      ),
      const AiToolResult.fromData(
        callId: 'read',
        name: 'get_issue',
        data: AiAppText.plain('original'),
        readConfidential: true,
        readInternal: true,
      ),
    ]) {
      expect(
        result
            .copyWith(data: const AiAppText.plain('redacted'))
            .readConfidential,
        isTrue,
      );
      expect(
        result.copyWith(data: const AiAppText.plain('redacted')).readInternal,
        isTrue,
      );
    }
  });

  test(
    'history writes true, accepts legacy rows and preserves their bytes',
    () {
      final legacy = {
        'items': [_toolRecord()],
      };
      final decoded = aiDisplayFromJson(legacy);
      expect((decoded.items.single as AiToolRunItem).confidential, isFalse);
      expect(jsonEncode(aiDisplayJson(decoded)), jsonEncode(legacy));

      final marked = {
        'items': [
          {..._toolRecord(), 'confidential': true},
        ],
      };
      final restored = aiDisplayFromJson(marked);
      expect((restored.items.single as AiToolRunItem).confidential, isTrue);
      expect(aiDisplayJson(restored), marked);
      expect(
        (aiDisplayFromJson(aiDisplayJson(restored)).items.single
                as AiToolRunItem)
            .confidential,
        isTrue,
      );
      final explicitFalse = aiDisplayFromJson({
        'items': [
          {..._toolRecord(), 'confidential': false},
        ],
      });
      expect(
        (explicitFalse.items.single as AiToolRunItem).confidential,
        isFalse,
      );
      expect(aiDisplayJson(explicitFalse), legacy);
    },
  );

  for (final invalid in ['true', 1, null, <Object?>[], <String, Object?>{}]) {
    test('history rejects non-bool confidential: $invalid', () {
      expect(
        () => aiDisplayFromJson({
          'items': [
            {..._toolRecord(), 'confidential': invalid},
          ],
        }),
        throwsA(isA<AiHistoryUnsupportedFormat>()),
      );
    });
  }

  for (final wire in <AiWireFormat>[
    const ChatCompletionsFormat(),
    const ResponsesFormat(),
    const AnthropicMessagesFormat(),
  ]) {
    test(
      '${wire.format.name} request bytes ignore disclosure metadata',
      () {
        String request({bool confidential = false, bool internal = false}) {
          final segment =
              AiSegment(
                providerId: 'synthetic',
                recipientRevision: 1,
                format: wire.format,
                model: 'synthetic-model',
                secretSetAtStart: SecretSetId.fromSecrets(const []),
              )..setTail(
                AppToolResultsEntry([
                  AiToolResult.fromData(
                    callId: 'synthetic-call',
                    name: 'get_issue',
                    data: const AiAppText.plain(
                      'Identical synthetic tool content',
                    ),
                    readConfidential: confidential,
                    readInternal: internal,
                  ),
                ]),
              );
          return jsonEncode(
            wire.encode(
              AiRequestPlan(
                model: 'synthetic-model',
                system: '',
                segment: segment,
              ),
              AiCaps(
                tokenLimitField: wire.format == AiFormat.responses
                    ? AiTokenLimitField.maxOutputTokens
                    : AiTokenLimitField.maxTokens,
              ),
            ),
          );
        }

        final unmarked = request();
        expect(request(confidential: true), unmarked);
        expect(request(internal: true), unmarked);
        expect(request(confidential: true, internal: true), unmarked);
      },
    );
  }
}
