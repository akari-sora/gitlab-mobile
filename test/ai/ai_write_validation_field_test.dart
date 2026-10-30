import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';
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

  test(
    'a redactor that throws during detail building leaves failedCertain and notExecuted writes with their reason codes',
    () async {
      await h.dispose();
      h = await _Harness.create(
        responder: (request) {
          if (request.method != 'GET') {
            // Returning a marker substring from knownSecrets makes
            // Redactor.redactSource throw AiFailure(policyBlocked).
            h.secrets = {'REDACTED'};
            return jsonResponse({
              'message': {
                'title': ['is invalid'],
              },
            }, status: 422);
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final call = AiToolCall(
        id: 'redactor-throw-422',
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
      expect(outcome.modelDetail, isNull);
      expect(outcome.toToolResult(call).content, outcome.summary);

      h.coordinator.beginTurn();
      final badCall = AiToolCall(
        id: 'redactor-throw-propose',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic', 'issue_type': 'bug'},
          'reason': 'The user requested this issue.',
        },
      );
      expect(await h.coordinator.propose(badCall), isNull);
      final badOutcome = h.coordinator.outcomeFor(badCall.id)!;
      expect(badOutcome.state, AiJournalState.notExecuted);
      expect(badOutcome.reasonCode, 'invalidArguments');
      expect(badOutcome.modelDetail, isNull);
    },
  );

  test(
    'close() while a 422 body is being read throws cancelled, not validation',
    () async {
      final controller = StreamController<Uint8List>();
      final entered = Completer<void>();
      late final GitLabApi api;
      final adapter = FakeAdapter((_) {
        entered.complete();
        return ResponseBody(
          controller.stream,
          422,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
      api = testApi(adapter);
      addTearDown(() async {
        api.close();
        await controller.close();
      });

      final future = api.createIssue(9, {'title': 'synthetic'});
      final expectation = expectLater(
        future,
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      await entered.future;
      controller.add(
        Uint8List.fromList(utf8.encode('{"message":{"title":["is invalid"]}}')),
      );
      api.close();
      await expectation;
    },
  );

  test(
    'keys with spaces, markup, or "sensitive" are not echoed when invalid and never set blockedSensitive',
    () async {
      final catalogue = AiToolCatalogue(
        scope: const AiResourceScope(
          accountKey: 'instance|7',
          instanceKey: 'https://gitlab.example',
          projectId: 9,
          projectPath: 'team/example-9',
          current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
        ),
        port: _EmptyReadPort(),
        redactor: Redactor(secrets: const _SetSecrets({})),
      );
      for (final badKey in const [
        'bad key <script> sensitive',
        'sensitive',
        'a_b\nc',
      ]) {
        final exec = await catalogue.execute(
          AiToolCall(
            id: 'cat-$badKey',
            name: 'get_issue',
            arguments: {'iid': 3, badKey: 'secret-val'},
          ),
          budget: AiToolBudget(),
        );
        expect(exec.blocked, isFalse, reason: badKey);
        expect(exec.result.blockedSensitive, isFalse, reason: badKey);
        if (badKey == 'sensitive') {
          expect(
            exec.result.content,
            contains('sensitive is not allowed'),
            reason: badKey,
          );
        } else {
          expect(
            exec.result.content,
            isNot(contains(badKey)),
            reason: badKey,
          );
          expect(
            exec.result.content,
            contains('an unexpected argument is not allowed'),
            reason: badKey,
          );
        }
      }

      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      const unsafeKey = 'unsafe <tag> sensitive key';
      final badCoordCall = AiToolCall(
        id: 'coord-unsafe-key',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic', unsafeKey: 'val'},
          'reason': 'The user requested this issue.',
        },
      );
      expect(await h.coordinator.propose(badCoordCall), isNull);
      final coordResult = h.coordinator
          .outcomeFor(badCoordCall.id)!
          .toToolResult(badCoordCall);
      expect(coordResult.blockedSensitive, isFalse);
      expect(coordResult.content, isNot(contains(unsafeKey)));
      expect(
        coordResult.content,
        contains('an unexpected argument is not allowed (allowed: '),
      );

      final port = GitLabAiWritePort(h.api, accountKey: _account);
      await expectLater(
        port.prepare(
          AiWriteRequest(
            operationId: 'createIssue',
            executionId: 'port-unsafe-key',
            scope: _scope,
            arguments: const {
              'projectId': 9,
              'fields': {'title': 'synthetic', unsafeKey: 'val'},
            },
          ),
        ),
        throwsA(
          isA<ApiFailure>()
              .having((f) => f.kind, 'kind', FailureKind.validation)
              .having(
                (f) => f.validationDetail,
                'validationDetail',
                allOf(
                  contains('an unexpected argument is not allowed (allowed: '),
                  isNot(contains(unsafeKey)),
                ),
              ),
        ),
      );
    },
  );

  test(
    'withheld-private-key branch and multiline draftSafe safeDisplay still enforce single-line 3x200 cap and cut-carrying redaction',
    () async {
      await h.dispose();
      h = await _Harness.create(
        responder: (request) {
          if (request.method != 'GET') {
            return jsonResponse({
              'message':
                  'clause_1; '
                  'clause_2 ${'z' * 240}; '
                  'clause_3 ${'y' * 165} -----BEGIN OPENSSH PRIVATE KEY-----\nsecret',
            }, status: 422);
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final call = AiToolCall(
        id: 'withheld-key-cap',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic issue'},
          'reason': 'The user requested this issue.',
        },
      );

      final proposal = (await h.coordinator.propose(call))!;
      final outcome = await h.coordinator.approve(proposal);
      expect(outcome.withheldPrivateKeyContext, isTrue);
      final result = outcome.toToolResult(call);
      expect(result.withheldPrivateKeyContext, isTrue);
      expect(result.content, contains('clause_1'));
      expect(result.content, contains('clause_2'));
      expect(result.content, contains('clause_3'));
      expect(result.content, isNot(contains('z' * 205)));
      expect(result.content, isNot(contains('PRIVATE KEY')));
      final lines = result.content.split('\n');
      expect(lines, hasLength(4));

      // Verify cut-carrying AiAppText.clipped: when a clause is cut right inside
      // a secret discovered on a later redaction pass, redactCutEnd strips the
      // trailing partial secret.
      const lateSecret = 'late-discovered-secret-token-value';
      final prefixToCut = 'a' * (190 - 'field_cut: '.length);
      await h.dispose();
      h = await _Harness.create(
        responder: (request) {
          if (request.method != 'GET') {
            return jsonResponse({
              'message': {
                'field_cut': ['$prefixToCut$lateSecret'],
              },
            }, status: 422);
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final cutProposal = (await h.coordinator.propose(call))!;
      final cutOutcome = await h.coordinator.approve(cutProposal);
      final cutResult = cutOutcome.toToolResult(call);
      // Before lateSecret is known, the cut prefix contains 'late-disco'.
      expect(cutResult.content, contains('late-disco'));
      final lateRedactor = Redactor(
        secrets: _SetSecrets({lateSecret}),
      );
      final reRedacted = cutResult.plainData.redact(lateRedactor).encode();
      expect(reRedacted, isNot(contains('late-disco')));
    },
  );

  test(
    'cut allowed list ends with ellipsis and fallback detail does not flag valid empty file content',
    () async {
      await h.dispose();
      h = await _Harness.create(ledger: const _LongAllowedLedger());
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final call = AiToolCall(
        id: 'cut-allowed',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic', 'unexpected_extra_key': 'val'},
          'reason': 'The user requested this issue.',
        },
      );
      expect(await h.coordinator.propose(call), isNull);
      final result = h.coordinator.outcomeFor(call.id)!.toToolResult(call);
      expect(
        result.content,
        contains('fields.unexpected_extra_key is not allowed (allowed: '),
      );
      expect(result.content, contains('…\n</gitlab_data>'));

      // Empty file content is valid for createFile; an empty-body 422 must not
      // claim "content must be a non-empty string".
      await h.dispose();
      h = await _Harness.create(
        responder: (request) {
          final path = request.uri.path;
          if (request.method == 'HEAD' && path.contains('/repository/files/')) {
            return ResponseBody.fromString('', 404);
          }
          if (request.method == 'GET' &&
              path.endsWith('/repository/branches/main')) {
            return jsonResponse({
              'name': 'main',
              'protected': false,
              'default': true,
              'commit': {'id': 'a' * 40},
            });
          }
          if (request.method != 'GET') {
            return ResponseBody.fromString('', 422);
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Create empty file in team/example-9');
      h.coordinator.beginTurn();
      final fileCall = AiToolCall(
        id: 'empty-file-422',
        name: 'createFile',
        arguments: const {
          'projectId': 9,
          'path': 'empty.txt',
          'branch': 'main',
          'content': '',
          'commitMessage': 'Add empty file',
          'reason': 'The user requested an empty file.',
        },
      );
      final fileProposal = (await h.coordinator.propose(fileCall))!;
      final fileOutcome = await h.coordinator.approve(
        fileProposal,
        typedName: fileProposal.tier.typedName,
      );
      expect(fileOutcome.state, AiJournalState.failedCertain);
      expect(fileOutcome.reasonCode, 'validation');
      expect(fileOutcome.modelDetail, isNull);
      expect(
        fileOutcome.toToolResult(fileCall).content,
        isNot(contains('content must be a non-empty string')),
      );
    },
  );

  test(
    'parseGitLabValidationDetail handles non-JSON, binary, and truncated bodies safely',
    () async {
      expect(parseGitLabValidationDetail(''), isNull);
      expect(
        parseGitLabValidationDetail('<html><body>422 Unprocessable</body></html>'),
        isNull,
      );
      expect(
        parseGitLabValidationDetail('plain text error: invalid title'),
        isNull,
      );
      expect(
        parseGitLabValidationDetail('\x00\x01\x02\uFFFDbinary-payload'),
        isNull,
      );
      expect(
        parseGitLabValidationDetail('{"message":{"title":["unterminated'),
        isNull,
      );
      final over4096 = jsonEncode({
        'message': {
          'title': ['x' * 5000],
        },
      });
      final parsedOver4096 = parseGitLabValidationDetail(over4096)!;
      expect(
        parsedOver4096.length,
        'validation: GitLab rejected '.length + 4096,
      );
      expect(parsedOver4096, isNot(contains('x' * 4097)));

      // A >16 KiB HTTP 422 response body is truncated at 16 KiB and does not
      // fail or leak unparsed content.
      await h.dispose();
      h = await _Harness.create(
        responder: (request) {
          if (request.method != 'GET') {
            return ResponseBody.fromBytes(
              Uint8List.fromList(List<int>.filled(20000, 0xFF)),
              422,
            );
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final call = AiToolCall(
        id: 'binary-422',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': 'synthetic'},
          'reason': 'The user requested this issue.',
        },
      );
      final proposal = (await h.coordinator.propose(call))!;
      final outcome = await h.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.failedCertain);
      expect(outcome.reasonCode, 'validation');
      expect(outcome.modelDetail, isNull);
    },
  );

  test(
    'modelDetail reaches the provider tool result but never UI resultExcerpt, persisted history, or the write journal',
    () async {
      final historyRoot = Directory.systemTemp.createTempSync('ai-val-hist-');
      final history = AiHistoryCoordinator.debugReset(
        files: AiHistoryFileStore(root: () async => historyRoot),
      );
      final stack = await StackHarness.create(level: AiAutonomyLevel.bypass);
      addTearDown(() {
        AiHistoryCoordinator.debugReset();
        stack.dispose();
        if (historyRoot.existsSync()) historyRoot.deleteSync(recursive: true);
      });
      expect(await history.enable(stack.account), AiHistoryState.ready);
      final currentAccount = (await stack.settings.store.loadAccount(
        stack.account,
      )).value!;
      await stack.settings.store.saveAccount(
        stack.account,
        currentAccount.copyWith(historyEnabled: true),
      );
      await stack.settings.loadAccount(stack.account);

      const echoedValue = 'sensitive-echoed-title-value';
      stack.server.overrides['POST projects/42/issues'] = (_) => jsonResponse({
        'message': {
          'title': ['$echoedValue is rejected by server rule'],
        },
      }, status: 422);
      stack.provider.script.add(
        (_) => toolTurn('createIssue', const {
          'projectId': 42,
          'fields': {'title': echoedValue},
          'reason': 'The user asked to create an issue.',
        }),
      );

      await stack.sendAndApprove('Create the issue');
      final uiToolItem = stack.controller.items
          .whereType<AiToolRunItem>()
          .single;
      final writeRow = stack.controller.writeRowFor(uiToolItem)!;
      final outcome = writeRow.outcome!;
      expect(outcome.state, AiJournalState.failedCertain);
      expect(outcome.reasonCode, 'validation');
      expect(outcome.modelDetail, isNotNull);

      // 1. Provider receives modelDetail in the second turn's tool output.
      expect(stack.provider.bodies, hasLength(2));
      expect(
        stack.provider.bodies[1],
        contains(
          'validation: GitLab rejected title: $echoedValue is rejected by server rule',
        ),
      );

      // 2. UI AiToolRunItem.resultExcerpt has only the single-line summary.
      expect(uiToolItem.resultExcerpt, outcome.summary);
      expect(uiToolItem.resultExcerpt.contains('\n'), isFalse);
      expect(uiToolItem.resultExcerpt, isNot(contains(echoedValue)));
      expect(uiToolItem.resultExcerpt, isNot(contains('GitLab rejected')));

      // 3. Persisted history conversation has only the single-line summary.
      stack.controller.markReported(
        stack.controller.items.whereType<AiAssistantItem>().single,
      );
      await waitFor(() => stack.controller.historySaved);
      final recovery = await history.read(stack.account);
      expect(recovery, isNotNull);
      final loaded = recovery!.conversations.single;
      final persistedToolItem = loaded.conversation.items
          .whereType<AiToolRunItem>()
          .single;
      expect(persistedToolItem.resultExcerpt, outcome.summary);
      expect(
        jsonEncode(aiDisplayJson(loaded.conversation)),
        isNot(contains('is rejected by server rule')),
      );

      // 4. Write journal contains only metadata, never modelDetail.
      final journalBytes = await AiJournalFiles(stack.root).read(stack.account);
      expect(journalBytes, isNotNull);
      final hJournalBytes = await AiJournalFiles(h.root).read(_account);
      if (hJournalBytes != null) {
        final hJournalJson = await AiHistoryCipher.decryptJson(
          hJournalBytes,
          h.journalKeys.keys[_account]!,
          _account,
          AiJournalFiles.fileName,
        );
        expect(
          jsonEncode(hJournalJson),
          isNot(contains('is rejected by server rule')),
        );
      }
      // Also run one 422 write on h so we decrypt and inspect its journal JSON.
      await h.dispose();
      h = await _Harness.create(
        responder: (request) {
          if (request.method != 'GET') {
            return jsonResponse({
              'message': {
                'title': ['$echoedValue is rejected by server rule'],
              },
            }, status: 422);
          }
          return _defaultGetResponder(request);
        },
      );
      h.coordinator.beginRun('Create issue in team/example-9');
      h.coordinator.beginTurn();
      final jCall = AiToolCall(
        id: 'journal-check-422',
        name: 'createIssue',
        arguments: const {
          'projectId': 9,
          'fields': {'title': echoedValue},
          'reason': 'The user requested this issue.',
        },
      );
      final jProposal = (await h.coordinator.propose(jCall))!;
      final jOutcome = await h.coordinator.approve(jProposal);
      expect(jOutcome.state, AiJournalState.failedCertain);
      final rawJournal = (await AiJournalFiles(h.root).read(_account))!;
      final decryptedJournal = await AiHistoryCipher.decryptJson(
        rawJournal,
        h.journalKeys.keys[_account]!,
        _account,
        AiJournalFiles.fileName,
      );
      expect(
        jsonEncode(decryptedJournal),
        isNot(contains('is rejected by server rule')),
      );
      expect(
        jsonEncode(decryptedJournal),
        isNot(contains(echoedValue)),
      );
    },
  );
}

final class _SetSecrets implements KnownSecretsSource {
  const _SetSecrets(this.current);
  @override
  final Set<String> current;
}

final class _LongAllowedLedger implements AiCapabilityLedger {
  const _LongAllowedLedger();

  static const _cap = AiCapability(
    operationId: 'createIssue',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: {
          'title': AiArgSpec(
            AiArgType.string,
            required: true,
            text: AiTextRole.plainContent,
          ),
          'allowed_field_alpha_01': AiArgSpec(AiArgType.string),
          'allowed_field_alpha_02': AiArgSpec(AiArgType.string),
          'allowed_field_alpha_03': AiArgSpec(AiArgType.string),
          'allowed_field_alpha_04': AiArgSpec(AiArgType.string),
          'allowed_field_alpha_05': AiArgSpec(AiArgType.string),
          'allowed_field_alpha_06': AiArgSpec(AiArgType.string),
          'allowed_field_alpha_07': AiArgSpec(AiArgType.string),
          'allowed_field_alpha_08': AiArgSpec(AiArgType.string),
          'allowed_field_alpha_09': AiArgSpec(AiArgType.string),
          'allowed_field_alpha_10': AiArgSpec(AiArgType.string),
        },
      ),
    },
  );

  @override
  AiCapability? find(String operationId) =>
      operationId == 'createIssue' ? _cap : fixtureAiLedger.find(operationId);

  @override
  List<AiCapability> get modelVisible => const [_cap];
}

final class _EmptyReadPort implements AiGitLabReadPort {
  @override
  Future<AiPortRead<String>> jobLog(int jobId) =>
      throw UnimplementedError();
  @override
  Future<AiPortRead<List<AiTreeItem>>> listDirectory(
    String sha,
    String path,
  ) => throw UnimplementedError();
  @override
  Future<AiPortRead<AiJson>> commit(String sha) =>
      throw UnimplementedError();
  @override
  Future<AiPortRead<List<AiJson>>> commitDiff(String sha) =>
      throw UnimplementedError();
  @override
  Future<AiPortRead<AiJson>> issue(int iid) =>
      throw UnimplementedError();
  @override
  Future<AiPortRead<AiJson>> mergeRequest(int iid) =>
      throw UnimplementedError();
  @override
  Future<AiPortRead<AiJson>> mergeRequestDiff(
    int iid, {
    required String headSha,
    required String baseSha,
  }) => throw UnimplementedError();
  @override
  Future<AiPortRead<List<AiJson>>> pipelineJobs(int pipelineId) =>
      throw UnimplementedError();
  @override
  Future<AiPortRead<String>> readFile(String sha, String path) =>
      throw UnimplementedError();
  @override
  Future<AiPortRead<List<AiJson>>> search(String scope, String query) =>
      throw UnimplementedError();
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
    required this.journalKeys,
    required this.journal,
    required this.adapter,
    required this.api,
    required this.coordinator,
    required this.secrets,
  });

  final Directory root;
  final MemoryAiJournalKeyStore journalKeys;
  final AiWriteJournal journal;
  final FakeAdapter adapter;
  final GitLabApi api;
  final PolicyAiWriteCoordinator coordinator;
  Set<String> secrets;
  DateTime clock = DateTime.utc(2026, 10, 30, 12);

  int get nonGetRequests =>
      adapter.requests.where((request) => request.method != 'GET').length;

  static Future<_Harness> create({
    Responder? responder,
    Set<String> secrets = const {},
    AiCapabilityLedger? ledger,
  }) async {
    final root = Directory.systemTemp.createTempSync('ai-val-field-');
    final journalKeys = MemoryAiJournalKeyStore();
    final journal = AiWriteJournal(
      keys: journalKeys,
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
      knownSecrets: () => harness.secrets,
      safeDisplay: (value) {
        try {
          final lines = value.replaceAll('\r\n', '\n').replaceAll('\r', '');
          return Redactor(secrets: _SetSecrets(harness.secrets))
              .redactSource(lines.replaceAll(_draftControls, ''))
              .text;
        } on Object {
          return '';
        }
      },
      now: () => harness.clock,
      ledger: ledger ?? fixtureAiLedger,
      checkFragments:
          (_, {required knownSecrets, required instance, required visibility}) =>
              (blockCode: null, confirmReasons: const []),
    );
    return harness = _Harness._(
      root: root,
      journalKeys: journalKeys,
      journal: journal,
      adapter: adapter,
      api: api,
      coordinator: coordinator,
      secrets: Set<String>.of(secrets),
    );
  }

  Future<void> dispose() async {
    coordinator.stop('disposed');
    api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final _draftControls = RegExp(
  r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u061c'
  r'\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]',
);
