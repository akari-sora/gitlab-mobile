import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'release_policy_support.dart';

const _account = 'https://example.com/gitlab#7';
const _scope = AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
  ],
);

void main() {
  late _Harness h;

  setUp(() async {
    h = await _Harness.create();
  });

  tearDown(() async {
    await h.dispose();
  });

  test(
    'enum mismatch on createIssue names fields.issue_type and allowed values without echoing argument value',
    () async {
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final call = AiToolCall(
        id: 'enum-mismatch',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic issue', 'issue_type': 'bug'},
          'reason': 'The user requested this issue.',
        },
      );

      expect(await h.coordinator.propose(call), isNull);
      final outcome = h.coordinator.outcomeFor(call.id)!;
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'invalidArguments');
      expect(outcome.modelDetail, isNotNull);

      final result = outcome.toToolResult(call);
      expect(result.isError, isTrue);
      expect(result.notExecuted, isTrue);
      expect(
        result.content,
        startsWith(
          'write createIssue: notExecuted; invalidArguments\n'
          '<gitlab_data source="write:createIssue" nonce="write-',
        ),
      );
      expect(
        result.content,
        contains(
          'validation: fields.issue_type must be one of issue, task, incident',
        ),
      );
      expect(result.content, isNot(contains('bug')));
      expect(h.nonGetRequests, 0);
    },
  );

  test(
    'local argument and preflight checks name missing, disallowed, and invalid fields without echoing values',
    () async {
      h.coordinator.beginRun('Update issue in team/example-9');
      h.coordinator.beginTurn();

      final badDisallowed = AiToolCall(
        id: 'disallowed-field',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic', 'secret_arg': 'super-secret-value'},
          'reason': 'The user requested this issue.',
        },
      );
      expect(await h.coordinator.propose(badDisallowed), isNull);
      final disallowedResult = h.coordinator
          .outcomeFor(badDisallowed.id)!
          .toToolResult(badDisallowed);
      expect(
        disallowedResult.content,
        contains('validation: fields.secret_arg is not allowed'),
      );
      expect(disallowedResult.content, isNot(contains('super-secret-value')));

      h.coordinator.beginTurn();
      final badEmptyFields = AiToolCall(
        id: 'empty-fields',
        name: 'updateIssue',
        arguments: const {
          'projectId': 9,
          'iid': 3,
          'fields': <String, Object?>{},
          'reason': 'The user requested this update.',
        },
      );
      expect(await h.coordinator.propose(badEmptyFields), isNull);
      final emptyFieldsResult = h.coordinator
          .outcomeFor(badEmptyFields.id)!
          .toToolResult(badEmptyFields);
      expect(
        emptyFieldsResult.content,
        contains('validation: fields must be a non-empty object'),
      );
    },
  );

  test(
    'GitLab 422 field error map produces a tool result naming the field and error',
    () async {
      await h.dispose();
      h = await _Harness.create(
        responder: (request) {
          if (request.method != 'GET') {
            return jsonResponse({
              'message': {
                'title': ['is too long (maximum is 255 characters)'],
              },
            }, status: 422);
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final call = AiToolCall(
        id: 'gitlab-422',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic issue'},
          'reason': 'The user requested this issue.',
        },
      );

      final proposal = (await h.coordinator.propose(call))!;
      final outcome = await h.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.failedCertain);
      expect(outcome.reasonCode, 'validation');
      expect(outcome.modelDetail, isNotNull);

      final result = outcome.toToolResult(call);
      expect(
        result.content,
        contains(
          'validation: GitLab rejected title: is too long (maximum is 255 characters)',
        ),
      );
      expect(result.content.split('\n').first, outcome.summary);
    },
  );

  test(
    'GitLab 400/422 body containing a secret-looking string or known secret is redacted in the tool result',
    () async {
      const pat = 'glpat-1234567890abcdefghijkl';
      const customSecret = 'custom-known-secret-value-999';
      await h.dispose();
      h = await _Harness.create(
        secrets: {customSecret},
        responder: (request) {
          if (request.method != 'GET') {
            return jsonResponse({
              'message': {
                'description': [
                  'rejected token $pat and secret $customSecret in value',
                ],
              },
            }, status: 400);
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final call = AiToolCall(
        id: 'gitlab-400-secret',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic issue'},
          'reason': 'The user requested this issue.',
        },
      );

      final proposal = (await h.coordinator.propose(call))!;
      final outcome = await h.coordinator.approve(proposal);
      final result = outcome.toToolResult(call);

      expect(
        result.content,
        contains('validation: GitLab rejected description:'),
      );
      expect(result.content, contains('[REDACTED]'));
      expect(result.content, isNot(contains(pat)));
      expect(result.content, isNot(contains(customSecret)));
    },
  );

  test(
    'validation detail caps field clauses to 3 and each clause to 200 characters',
    () async {
      final longError = 'x' * 260;
      await h.dispose();
      h = await _Harness.create(
        responder: (request) {
          if (request.method != 'GET') {
            return jsonResponse({
              'message': {
                'field_a': [longError],
                'field_b': ['invalid b'],
                'field_c': ['invalid c'],
                'field_d': ['invalid d'],
              },
            }, status: 422);
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final call = AiToolCall(
        id: 'gitlab-422-cap',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic issue'},
          'reason': 'The user requested this issue.',
        },
      );

      final proposal = (await h.coordinator.propose(call))!;
      final outcome = await h.coordinator.approve(proposal);
      final result = outcome.toToolResult(call);

      expect(result.content, contains('field_a'));
      expect(result.content, contains('field_b'));
      expect(result.content, contains('field_c'));
      expect(result.content, isNot(contains('field_d')));
      expect(result.content, isNot(contains(longError)));
    },
  );

  test(
    'non-validation failures keep single-line tool results with no validation detail',
    () async {
      await h.dispose();
      h = await _Harness.create(
        responder: (request) {
          if (request.method != 'GET') {
            return jsonResponse({'message': '403 Forbidden'}, status: 403);
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      final rejectedCall = AiToolCall(
        id: 'user-rejected',
        name: 'setStar',
        arguments: const {
          'projectId': 9,
          'starred': true,
          'reason': 'The user requested this star.',
        },
      );
      final rejectedProposal = (await h.coordinator.propose(rejectedCall))!;
      await h.coordinator.reject(rejectedProposal);
      final rejectedOutcome = h.coordinator.outcomeFor(rejectedCall.id)!;
      expect(rejectedOutcome.reasonCode, 'userRejected');
      expect(rejectedOutcome.modelDetail, isNull);
      expect(
        rejectedOutcome.toToolResult(rejectedCall).content,
        rejectedOutcome.summary,
      );

      h.coordinator.beginRun('Star team/example-9 again');
      h.coordinator.beginTurn();
      final forbiddenCall = AiToolCall(
        id: 'forbidden-403',
        name: 'setStar',
        arguments: const {
          'projectId': 9,
          'starred': true,
          'reason': 'The user requested this star.',
        },
      );
      final forbiddenProposal = (await h.coordinator.propose(forbiddenCall))!;
      final forbiddenOutcome = await h.coordinator.approve(forbiddenProposal);
      expect(forbiddenOutcome.reasonCode, 'forbidden');
      expect(forbiddenOutcome.modelDetail, isNull);
      expect(
        forbiddenOutcome.toToolResult(forbiddenCall).content,
        forbiddenOutcome.summary,
      );
    },
  );
}

ResponseBody _defaultGetResponder(RequestOptions request) {
  final path = request.uri.path;
  if (path.endsWith('/user')) {
    return jsonResponse({'id': 7, 'username': 'tester'});
  }
  if (path.endsWith('/projects/9')) {
    return jsonResponse(projectJson(9));
  }
  if (path.endsWith('/projects/9/issues/3')) {
    return jsonResponse({'id': 30, 'iid': 3, 'project_id': 9});
  }
  throw StateError('Unexpected request: ${request.method} ${request.uri}');
}

final class _Harness {
  _Harness._({
    required this.root,
    required this.journal,
    required this.adapter,
    required this.api,
    required this.coordinator,
  });

  final Directory root;
  final AiWriteJournal journal;
  final FakeAdapter adapter;
  final GitLabApi api;
  final PolicyAiWriteCoordinator coordinator;
  DateTime clock = DateTime.utc(2026, 10, 30, 12);

  int get nonGetRequests =>
      adapter.requests.where((request) => request.method != 'GET').length;

  static Future<_Harness> create({
    Responder? responder,
    Set<String> secrets = const {},
  }) async {
    final root = Directory.systemTemp.createTempSync('ai-val-field-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'val-field-test',
    );
    await journal.recoverAfterAccountsLoaded([_account]);
    await journal.ensureInitialized(_account);
    final adapter = FakeAdapter(
      responder ??
          (request) {
            if (request.method != 'GET') return jsonResponse(projectJson(9));
            return _defaultGetResponder(request);
          },
    );
    final api = testApi(adapter);
    late final _Harness harness;
    final coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => const AiWritePolicySnapshot(
        scope: _scope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'consent-v2',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        consentValid: true,
        alive: true,
        appInForeground: true,
        clientMayStart: true,
      ),
      createPort: () => GitLabAiWritePort(api, accountKey: _account),
      journal: journal,
      conversationId: 'conversation-1',
      budget: () => AiToolBudget(maxGitLabRequests: 40),
      readFreshness: (_) async => const AiWriteFreshness(
        updatedAt: '2026-10-30T00:00:00Z',
        visibilityUnreadable: false,
      ),
      placeholders: UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => secrets,
      safeDisplay: (value) => value,
      now: () => harness.clock,
      ledger: fixtureAiLedger,
    );
    return harness = _Harness._(
      root: root,
      journal: journal,
      adapter: adapter,
      api: api,
      coordinator: coordinator,
    );
  }

  Future<void> dispose() async {
    coordinator.stop('disposed');
    api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
