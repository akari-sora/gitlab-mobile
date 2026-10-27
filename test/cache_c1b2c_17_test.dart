import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';

import 'support/fake_adapter.dart';

const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _scope = AiResourceScope(
  accountKey: 'https://example.com/gitlab#7',
  instanceKey: 'https://example.com/gitlab',
  projectId: 9,
  projectPath: 'group/project',
  current: AiResourceRef(kind: AiResourceKind.mergeRequest, id: 3),
  headSha: _head,
  baseSha: _base,
);
const _caps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxTokens,
  toolChoice: true,
);
const _config = AiProviderConfig(
  id: 'provider',
  name: 'Synthetic',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: AiFormat.chatCompletions,
  model: 'synthetic',
  authStyle: AiAuthStyle.bearer,
  caps: _caps,
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

final class _Secrets implements KnownSecretsSource {
  const _Secrets();

  @override
  Iterable<String> get current => const [];
}

GitLabApi _api(FakeAdapter adapter, {DateTime Function()? now}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheClock: now,
  );
  api.bindReadCache(_scope.accountKey, 1);
  addTearDown(api.close);
  return api;
}

AiToolCatalogue _catalogue(
  GitLabApi api, {
  DateTime Function()? now,
  UploadPlaceholderTable? placeholders,
}) => AiToolCatalogue(
  port: GitLabAiReadPort(api, 9, now: now),
  scope: _scope,
  redactor: Redactor(secrets: const _Secrets()),
  now: now,
  placeholders: placeholders,
);

AiToolCall _issue(int iid) =>
    AiToolCall(id: 'issue-$iid', name: 'get_issue', arguments: {'iid': iid});

ResponseBody _resource(RequestOptions request) {
  final path = request.uri.path;
  if (path.endsWith('/notes')) return jsonResponse(<Object?>[]);
  if (path.endsWith('/versions')) {
    return jsonResponse([
      {'id': 5, 'head_commit_sha': _head, 'base_commit_sha': _base},
    ]);
  }
  if (path.endsWith('/versions/5')) {
    return jsonResponse({
      'head_commit_sha': _head,
      'base_commit_sha': _base,
      'diffs': [
        {
          'old_path': 'lib/example.dart',
          'new_path': 'lib/example.dart',
          'diff': '@@ -1 +1 @@\n-old\n+new',
        },
      ],
    });
  }
  return jsonResponse({'iid': 3, 'title': 'synthetic resource'});
}

AiDecodedTurn _turn(List<AiToolCall> calls) => AiDecodedTurn(
  ProviderOutputEntry(AiFormat.chatCompletions, <String, Object?>{
    'role': 'assistant',
    'content': calls.isEmpty ? 'done' : '',
    if (calls.isNotEmpty)
      'tool_calls': [
        for (final call in calls)
          {
            'id': call.id,
            'type': 'function',
            'function': {
              'name': call.name,
              'arguments': jsonEncode(call.arguments),
            },
          },
      ],
  }, toolCalls: calls),
  AiStopReason.endTurn,
  null,
);

void main() {
  test(
    'N-2 MR refresh plus two reads still permits the diff within 40',
    () async {
      final adapter = FakeAdapter(_resource);
      final catalogue = _catalogue(_api(adapter));
      final budget = AiToolBudget();
      // The context refresh has already settled five physical sends.
      budget.settleRequests(reserved: 0, measured: 5);
      for (final call in [
        AiToolCall(
          id: 'mr',
          name: 'get_merge_request',
          arguments: const {'iid': 3},
        ),
        _issue(3),
      ]) {
        final result = await catalogue.execute(call, budget: budget);
        expect(result.result.isError, isFalse);
        expect(result.gitLabRequests, 2);
      }
      expect(budget.gitLabRequests, 9);

      final diff = await catalogue.execute(
        AiToolCall(id: 'diff', name: 'get_merge_request_diff', arguments: {}),
        budget: budget,
      );

      expect(diff.result.isError, isFalse);
      expect(diff.result.content, contains('+new'));
      expect(diff.gitLabRequests, 2);
      expect(budget.gitLabRequests, 11);
      expect(adapter.requests, hasLength(6));
      expect(budget.calls, 3);
    },
  );

  for (final scenario in [(grant: 3, sends: 0), (grant: 4, sends: 1)]) {
    test(
      'N-2 grant ${scenario.grant} stops before the next bounded read',
      () async {
        final adapter = FakeAdapter(_resource);
        final catalogue = _catalogue(_api(adapter));
        final budget = AiToolBudget(maxGitLabRequests: scenario.grant);

        final result = await catalogue.execute(_issue(3), budget: budget);

        expect(result.result.isError, isTrue);
        expect(result.result.content, contains('GitLab request limit reached'));
        expect(adapter.requests, hasLength(scenario.sends));
        expect(
          adapter.requests.any((r) => r.uri.path.endsWith('/notes')),
          isFalse,
        );
        expect(result.gitLabRequests, scenario.sends);
        expect(budget.gitLabRequests, scenario.sends);
      },
    );
  }

  for (final scenario in [
    (grant: 8, sends: 4, error: false),
    (grant: 4, sends: 3, error: true),
  ]) {
    test(
      'N-2 directory pages reserve individually with grant ${scenario.grant}',
      () async {
        final adapter = FakeAdapter((request) {
          final page = int.parse(request.uri.queryParameters['page'] ?? '1');
          return jsonResponse(
            [
              {
                'name': 'file$page.dart',
                'path': 'file$page.dart',
                'type': 'blob',
              },
            ],
            headers: {
              if (page < 4) 'x-next-page': ['${page + 1}'],
            },
          );
        });
        final catalogue = _catalogue(_api(adapter));
        final budget = AiToolBudget(maxGitLabRequests: scenario.grant);

        final result = await catalogue.execute(
          AiToolCall(
            id: 'tree',
            name: 'list_directory',
            arguments: {'path': '', 'revision': 'head'},
          ),
          budget: budget,
        );

        expect(result.result.isError, scenario.error);
        expect(adapter.requests, hasLength(scenario.sends));
        expect(result.gitLabRequests, scenario.sends);
        expect(budget.gitLabRequests, scenario.sends);
        if (!scenario.error) {
          expect(result.result.content, contains('file4.dart'));
        }
      },
    );
  }

  for (final scenario in [(grant: 3, sends: 0), (grant: 4, sends: 2)]) {
    test(
      'N-2 job trace bounds the 404 status fallback with grant ${scenario.grant}',
      () async {
        final adapter = FakeAdapter(
          (request) => request.uri.path.endsWith('/trace')
              ? jsonResponse({'message': 'missing'}, status: 404)
              : jsonResponse({'id': 7, 'status': 'pending'}),
        );
        final budget = AiToolBudget(maxGitLabRequests: scenario.grant);
        final result = await _catalogue(_api(adapter)).execute(
          AiToolCall(
            id: 'trace',
            name: 'get_job_log',
            arguments: const {'job_id': 7},
          ),
          budget: budget,
        );

        expect(result.result.isError, scenario.grant < 4);
        expect(adapter.requests, hasLength(scenario.sends));
        expect(result.gitLabRequests, scenario.sends);
        expect(budget.gitLabRequests, scenario.sends);
      },
    );
  }

  for (final outcome in ['oauth', 'failure', 'cancelled']) {
    test('N-2 exact physical charging survives $outcome', () async {
      var notes = 0;
      final adapter = FakeAdapter((request) {
        if (!request.uri.path.endsWith('/notes')) return _resource(request);
        notes++;
        if (outcome == 'oauth') {
          return notes == 1
              ? jsonResponse({'message': 'expired'}, status: 401)
              : jsonResponse(<Object?>[]);
        }
        throw DioException(
          requestOptions: request,
          type: outcome == 'cancelled'
              ? DioExceptionType.cancel
              : DioExceptionType.connectionError,
        );
      });
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final oauth = FakeAdapter(
        (_) => jsonResponse({
          'access_token': 'synthetic-new-access',
          'refresh_token': 'synthetic-new-refresh',
          'token_type': 'bearer',
        }),
      );
      final api = GitLabApi(
        instance: instance,
        credential: const OAuthCredential(
          accessToken: 'synthetic-access',
          refreshToken: 'synthetic-refresh',
          clientId: 'synthetic-client',
        ),
        dio: Dio()..httpClientAdapter = adapter,
        oauth: OAuthTokenClient(
          instance: instance,
          clientId: 'synthetic-client',
          dio: Dio()..httpClientAdapter = oauth,
        ),
      );
      api.bindReadCache(_scope.accountKey, 1);
      addTearDown(api.close);
      final budget = AiToolBudget(maxGitLabRequests: 7);
      final catalogue = _catalogue(api);

      final result = await catalogue.execute(_issue(3), budget: budget);
      final sends = outcome == 'oauth' ? 3 : 2;

      expect(result.result.isError, outcome != 'oauth');
      expect(result.gitLabRequests, sends);
      expect(budget.gitLabRequests, sends);
      expect(adapter.requests, hasLength(sends));
      expect(oauth.requests, hasLength(outcome == 'oauth' ? 1 : 0));
    });
  }

  for (final stop in [true, false]) {
    test(
      'N-4 held delivery settles after ${stop ? 'stop' : 'timeout'} without stale send',
      () async {
        var now = DateTime.utc(2026, 10, 23, 12);
        var firstReads = 0;
        var delayed = false;
        final started = Completer<void>();
        final release = Completer<void>();
        final settled = Completer<void>();
        final adapter = FakeAdapter((request) async {
          final parts = request.uri.pathSegments;
          final iid = int.parse(parts[parts.indexOf('issues') + 1]);
          if (parts.last == 'notes') {
            if (iid == 5 && !delayed) {
              delayed = true;
              now = now.add(const Duration(seconds: 61));
            }
            return jsonResponse(<Object?>[]);
          }
          if (iid == 4 && ++firstReads == 2) {
            started.complete();
            await release.future;
          }
          return jsonResponse({'iid': iid, 'title': 'source title $iid'});
        });
        final catalogue = _catalogue(
          _api(adapter, now: () => now),
          now: () => now,
        );
        final budget = AiToolBudget(maxCallsPerTurn: 2);
        const wire = ChatCompletionsFormat();
        final payloads = <String>[];
        final owner = Object();
        final runner = AiRunner(
          appInForeground: () => true,
          config: _config,
          wire: wire,
          complete: (plan, {void Function(AiEvent)? onEvent}) async {
            payloads.add(wire.encodeJson(plan, _caps));
            return _turn(payloads.length == 1 ? [_issue(4), _issue(5)] : []);
          },
          secrets: const _Secrets(),
          refreshSecrets: () async {},
          guard: AiRunGuard(
            expectedGeneration: 1,
            ownerApi: owner,
            generation: () => 1,
            api: () => owner,
            recipientRevision: () => 1,
            consentValid: () => true,
          ),
          now: () => now,
          system: 'Synthetic system prompt.',
          close: () {},
          cancelActive: () {},
          toolDeadline: const Duration(seconds: 1),
          tools: catalogue.specs,
          beginToolTurn: budget.beginTurn,
          executeTool: (call) => catalogue.executeResult(call, budget: budget),
          prepareToolResults: (calls, results, beforeDelivery) async {
            try {
              return await catalogue.prepareDelivery(
                calls,
                results,
                budget: budget,
                beforeDelivery: beforeDelivery,
              );
            } finally {
              settled.complete();
            }
          },
        );
        final pending = runner.run('Read both issues');
        try {
          await Future.any([started.future, pending.then((_) {})]);
          expect(started.isCompleted, isTrue);
          expect(budget.gitLabRequests, greaterThan(adapter.requests.length));
          if (stop) runner.stop();
          final result = await pending;
          expect(result.reason, stop ? AiRunEnd.stopped : AiRunEnd.done);
          expect(payloads, hasLength(stop ? 1 : 2));
          if (!stop) {
            expect(payloads.last, contains('read_failed'));
            expect(payloads.last, isNot(contains('source title 4')));
          }
        } finally {
          release.complete();
        }
        await settled.future;
        expect(budget.gitLabRequests, adapter.requests.length);
        expect(budget.calls, 2);
      },
    );
  }

  for (final notSent in [false, true]) {
    test(
      'N-4 provider retry preserves restored freshness and cuts (notSent: $notSent)',
      () async {
        var now = DateTime.utc(2026, 10, 23, 12);
        var firstReads = 0;
        var delayed = false;
        final adapter = FakeAdapter((request) {
          final parts = request.uri.pathSegments;
          final iid = int.parse(parts[parts.indexOf('issues') + 1]);
          if (parts.last == 'notes') {
            if (iid == 5 && !delayed) {
              delayed = true;
              now = now.add(const Duration(seconds: 61));
            }
            return jsonResponse(<Object?>[]);
          }
          if (iid == 4) firstReads++;
          return jsonResponse({
            'iid': iid,
            'title': iid == 4
                ? firstReads == 1
                      ? 'original first title'
                      : 'fresh first title'
                : 'second title',
            if (iid == 4)
              'description': firstReads == 1 ? 'x' * 800 : 'fresh description',
          });
        });
        final instance = GitLabInstance.parse('https://example.com/gitlab');
        final placeholders = UploadPlaceholderTable(instance: instance);
        final field = AiFieldProvenance.gitLab(
          instance: instance,
          projectId: 9,
          projectPath: 'group/project',
          resource: 'issues',
          iid: 4,
        );
        final catalogue = _catalogue(
          _api(adapter, now: () => now),
          now: () => now,
          placeholders: placeholders,
        );
        final budget = AiToolBudget(
          maxCallsPerTurn: 2,
          maxSingleOutputChars: 500,
        );
        const wire = ChatCompletionsFormat();
        final payloads = <String>[];
        final owner = Object();
        final runner = AiRunner(
          appInForeground: () => true,
          config: _config,
          wire: wire,
          complete: (plan, {void Function(AiEvent)? onEvent}) async {
            payloads.add(wire.encodeJson(plan, _caps));
            if (payloads.length == 2) {
              throw AiFailure(AiFailureKind.network, notSent: notSent);
            }
            return _turn(payloads.length == 1 ? [_issue(4), _issue(5)] : []);
          },
          secrets: const _Secrets(),
          refreshSecrets: () async {},
          guard: AiRunGuard(
            expectedGeneration: 1,
            ownerApi: owner,
            generation: () => 1,
            api: () => owner,
            recipientRevision: () => 1,
            consentValid: () => true,
          ),
          now: () => now,
          system: 'Synthetic system prompt.',
          close: () {},
          cancelActive: () {},
          tools: catalogue.specs,
          beginToolTurn: budget.beginTurn,
          executeTool: (call) => catalogue.executeResult(call, budget: budget),
          prepareToolResults: (calls, results, beforeDelivery) =>
              catalogue.prepareDelivery(
                calls,
                results,
                budget: budget,
                beforeDelivery: beforeDelivery,
              ),
        );

        expect((await runner.run('Read both issues')).reason, AiRunEnd.failed);
        expect(payloads.last, contains('fresh first title'));
        expect(placeholders.seenOnlyCut(field), isTrue);
        expect((await runner.run('Retry')).reason, AiRunEnd.done);
        expect(payloads, hasLength(3));
        expect(payloads.last, contains('fresh first title'));
        expect(payloads.last, isNot(contains('original first title')));
        expect(firstReads, 2);
        expect(
          budget.gitLabRequests,
          7,
          reason: 'the retry reuses fresh memory',
        );
        expect(budget.calls, 2);
        expect(budget.gitLabRequests, adapter.requests.length);
        expect(placeholders.seenOnlyCut(field), isFalse);
      },
    );
  }

  for (final scenario in [
    (
      name: 'rereads once',
      delay: 61,
      fail: false,
      expireAtDelivery: false,
      large: false,
    ),
    (
      name: 'fails closed on reread failure',
      delay: 61,
      fail: true,
      expireAtDelivery: false,
      large: false,
    ),
    (
      name: 'fails closed after final refresh',
      delay: 61,
      fail: false,
      expireAtDelivery: true,
      large: false,
    ),
    (
      name: 'bounds a larger reread to the original output',
      delay: 61,
      fail: false,
      expireAtDelivery: false,
      large: true,
    ),
    (
      name: 'keeps a fresh result',
      delay: 59,
      fail: false,
      expireAtDelivery: false,
      large: false,
    ),
  ]) {
    test('N-4 two-tool delivery ${scenario.name}', () async {
      var now = DateTime.utc(2026, 10, 23, 12);
      final metadata = <int, int>{};
      final notes = <int, int>{};
      var delayed = false;
      var expiredAtDelivery = false;
      final adapter = FakeAdapter((request) {
        final parts = request.uri.pathSegments;
        final iid = int.parse(parts[parts.indexOf('issues') + 1]);
        if (parts.last == 'notes') {
          notes.update(iid, (n) => n + 1, ifAbsent: () => 1);
          if (iid == 5 && !delayed) {
            delayed = true;
            now = now.add(Duration(seconds: scenario.delay));
          }
          return jsonResponse(<Object?>[]);
        }
        final reads = metadata.update(iid, (n) => n + 1, ifAbsent: () => 1);
        if (iid == 4 && reads == 2 && scenario.fail) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.connectionError,
          );
        }
        return jsonResponse({
          'iid': iid,
          'title': iid == 4
              ? reads == 1
                    ? 'original first title'
                    : 'fresh first title${scenario.large ? 'x' * 5000 : ''}'
              : 'second title',
        });
      });
      final catalogue = _catalogue(
        _api(adapter, now: () => now),
        now: () => now,
      );
      final budget = AiToolBudget(maxCallsPerTurn: 2);
      const wire = ChatCompletionsFormat();
      final payloads = <String>[];
      var originalOutputChars = 0;
      var deliveryChecks = 0;
      final owner = Object();
      final runner = AiRunner(
        appInForeground: () => true,
        config: _config,
        wire: wire,
        complete: (plan, {void Function(AiEvent)? onEvent}) async {
          payloads.add(wire.encodeJson(plan, _caps));
          return _turn(payloads.length == 1 ? [_issue(4), _issue(5)] : []);
        },
        secrets: const _Secrets(),
        refreshSecrets: () async {
          if (scenario.expireAtDelivery &&
              metadata[4] == 2 &&
              !expiredAtDelivery) {
            expiredAtDelivery = true;
            now = now.add(const Duration(seconds: 61));
          }
        },
        guard: AiRunGuard(
          expectedGeneration: 1,
          ownerApi: owner,
          generation: () => 1,
          api: () => owner,
          recipientRevision: () => 1,
          consentValid: () => true,
        ),
        now: () => now,
        system: 'Synthetic system prompt.',
        close: () {},
        cancelActive: () {},
        tools: catalogue.specs,
        beginToolTurn: budget.beginTurn,
        executeTool: (call) async {
          final result = await catalogue.executeResult(call, budget: budget);
          originalOutputChars += result.content.length;
          return result;
        },
        prepareToolResults: (calls, results, beforeDelivery) =>
            catalogue.prepareDelivery(
              calls,
              results,
              budget: budget,
              beforeDelivery: () async {
                deliveryChecks++;
                await beforeDelivery();
              },
            ),
      );

      final result = await runner.run('Read both issues');

      expect(result.reason, AiRunEnd.done);
      expect(payloads, hasLength(2));
      expect(deliveryChecks, scenario.delay < 60 ? 1 : 2);
      expect(budget.outputChars, originalOutputChars);
      final body = jsonDecode(payloads.last) as Map<String, Object?>;
      final deliveredChars = (body['messages'] as List<Object?>)
          .cast<Map<String, Object?>>()
          .where((message) => message['role'] == 'tool')
          .fold<int>(
            0,
            (sum, message) => sum + (message['content'] as String).length,
          );
      expect(deliveredChars, lessThanOrEqualTo(originalOutputChars));
      expect(
        budget.calls,
        2,
        reason: 'delivery rereads are not additional tool calls',
      );
      if (scenario.delay < 60) {
        expect(payloads.last, contains('original first title'));
        expect(metadata[4], 1);
        expect(notes[4], 1);
        expect(budget.gitLabRequests, 4);
      } else {
        expect(payloads.last, isNot(contains('original first title')));
        expect(
          metadata[4],
          2,
          reason: 'one delivery reread, with no retry loop',
        );
        if (scenario.fail || scenario.expireAtDelivery) {
          expect(payloads.last, contains('read failed'));
          expect(payloads.last, isNot(contains('fresh first title')));
        } else {
          expect(payloads.last, contains('fresh first title'));
          expect(notes[4], 2);
          expect(budget.gitLabRequests, 7);
        }
      }
      expect(budget.gitLabRequests, adapter.requests.length);
    });
  }
}
