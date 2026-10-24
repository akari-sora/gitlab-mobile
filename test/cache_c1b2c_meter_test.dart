import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/request_meter.dart';

import 'support/fake_adapter.dart';

const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [];
}

final class _MeterPort implements AiGitLabReadPort {
  _MeterPort(this.onReadFile);

  final Future<AiPortRead<String>> Function(String path) onReadFile;

  @override
  Future<AiPortRead<String>> readFile(String sha, String path) =>
      onReadFile(path);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(invocation.memberName.toString());
}

AiToolCatalogue _catalogue(_MeterPort port) => AiToolCatalogue(
  port: port,
  scope: const AiResourceScope(
    accountKey: 'instance|7',
    instanceKey: 'https://gitlab.example',
    projectId: 9,
    projectPath: 'group/project',
    current: AiResourceRef(kind: AiResourceKind.file, id: 1),
    headSha: _head,
    defaultBranch: 'main',
  ),
  redactor: Redactor(secrets: _Secrets()),
);

AiToolCall _readCall(String id, String path) => AiToolCall(
  id: id,
  name: 'read_file',
  arguments: {'path': path, 'revision': 'head'},
);

AiToolCall _issueCall(String id) =>
    AiToolCall(id: id, name: 'get_issue', arguments: const {'iid': 3});

void main() {
  test('catalogue charges one HTTP unit for a normal transport send', () async {
    final catalogue = _catalogue(
      _MeterPort((_) async {
        expect(RequestMeter.current, isNotNull);
        RequestMeter.current!.increment();
        return const AiPortRead('body', requestCount: 1);
      }),
    );
    final budget = AiToolBudget();

    final result = await catalogue.execute(
      _readCall('normal', 'normal.dart'),
      budget: budget,
    );

    expect(result.result.isError, isFalse);
    expect(result.gitLabRequests, 1);
    expect(budget.gitLabRequests, 1);
  });

  test(
    'catalogue accepts three HTTP units within the four-unit reservation',
    () async {
      final catalogue = _catalogue(
        _MeterPort((_) async {
          RequestMeter.current!
            ..increment()
            ..increment()
            ..increment();
          return const AiPortRead('body', requestCount: 2);
        }),
      );
      final budget = AiToolBudget(maxGitLabRequests: 4);

      final result = await catalogue.execute(
        _readCall('oauth-replay', 'retry.dart'),
        budget: budget,
      );

      expect(result.result.isError, isFalse);
      expect(result.gitLabRequests, 3);
      expect(budget.gitLabRequests, 3);
    },
  );

  test(
    'catalogue refunds the whole reservation for a zero-send cache hit',
    () async {
      final catalogue = _catalogue(
        _MeterPort((_) async => const AiPortRead('cached', requestCount: 0)),
      );
      final budget = AiToolBudget(maxGitLabRequests: 4);

      final result = await catalogue.execute(
        _readCall('cache-hit', 'cached.dart'),
        budget: budget,
      );

      expect(result.result.isError, isFalse);
      expect(result.gitLabRequests, 0);
      expect(budget.gitLabRequests, 0);
    },
  );

  test(
    'advisory request count cannot override a zero physical count',
    () async {
      final catalogue = _catalogue(
        _MeterPort((_) async => const AiPortRead('cached', requestCount: 9)),
      );
      final budget = AiToolBudget(maxGitLabRequests: 4);

      final result = await catalogue.execute(
        _readCall('advisory-only', 'cached.dart'),
        budget: budget,
      );

      expect(result.result.isError, isFalse);
      expect(result.gitLabRequests, 0);
      expect(budget.gitLabRequests, 0);
    },
  );

  test(
    'catalogue charges all five sends when an error exceeds reservation four',
    () async {
      final catalogue = _catalogue(
        _MeterPort((_) async {
          RequestMeter.current!
            ..increment()
            ..increment()
            ..increment()
            ..increment()
            ..increment();
          throw StateError('synthetic second-stage failure');
        }),
      );
      final budget = AiToolBudget(maxGitLabRequests: 4);

      final result = await catalogue.execute(
        _readCall('partial-failure', 'failure.dart'),
        budget: budget,
      );

      expect(result.result.isError, isTrue);
      expect(result.gitLabRequests, 5);
      expect(budget.gitLabRequests, 5);
    },
  );

  test(
    'catalogue charges all five sends when the read is cancelled',
    () async {
      final catalogue = _catalogue(
        _MeterPort((_) async {
          RequestMeter.current!
            ..increment()
            ..increment()
            ..increment()
            ..increment()
            ..increment();
          throw const ApiFailure(FailureKind.cancelled);
        }),
      );
      final budget = AiToolBudget(maxGitLabRequests: 4);

      final result = await catalogue.execute(
        _readCall('cancelled', 'cancelled.dart'),
        budget: budget,
      );

      expect(result.result.isError, isTrue);
      expect(result.gitLabRequests, 5);
      expect(budget.gitLabRequests, 5);
    },
  );

  test(
    'cache reread plus OAuth replay charges five physical requests',
    () async {
      final firstIssueStarted = Completer<void>();
      final firstIssueResponse = Completer<ResponseBody>();
      var issueGets = 0;
      var noteGets = 0;
      final apiAdapter = FakeAdapter((request) async {
        final path = request.uri.path;
        if (request.method == 'PUT') {
          return jsonResponse({'iid': 3, 'title': 'updated outside tool'});
        }
        if (path.endsWith('/issues/3/notes')) {
          noteGets += 1;
          return noteGets == 1
              ? jsonResponse({'message': 'expired'}, status: 401)
              : jsonResponse(<Object?>[]);
        }
        if (path.endsWith('/issues/3')) {
          issueGets += 1;
          if (issueGets == 1) {
            firstIssueStarted.complete();
            return firstIssueResponse.future;
          }
          return jsonResponse({'iid': 3, 'title': 'fixture'});
        }
        throw StateError('unexpected request: ${request.method} $path');
      });
      var refreshes = 0;
      final tokenAdapter = FakeAdapter((_) {
        refreshes += 1;
        return jsonResponse({
          'access_token': 'new-access-$refreshes',
          'refresh_token': 'new-refresh-$refreshes',
          'token_type': 'bearer',
        });
      });
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final api = GitLabApi(
        instance: instance,
        credential: const OAuthCredential(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          clientId: 'synthetic-client',
        ),
        dio: Dio()..httpClientAdapter = apiAdapter,
        oauth: OAuthTokenClient(
          instance: instance,
          clientId: 'synthetic-client',
          dio: Dio()..httpClientAdapter = tokenAdapter,
        ),
      );
      api.bindReadCache('${instance.key}#7', 1);
      addTearDown(api.close);
      final catalogue = AiToolCatalogue(
        port: GitLabAiReadPort(api, 9),
        scope: const AiResourceScope(
          accountKey: 'instance|7',
          instanceKey: 'https://example.com/gitlab',
          projectId: 9,
          projectPath: 'group/project',
          current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
          headSha: _head,
          defaultBranch: 'main',
        ),
        redactor: Redactor(secrets: _Secrets()),
      );
      final budget = AiToolBudget(maxGitLabRequests: 40);

      final pending = catalogue.execute(
        _issueCall('cache-reread-oauth'),
        budget: budget,
      );
      await firstIssueStarted.future.timeout(const Duration(seconds: 5));
      await api.updateIssue(9, 3, {'title': 'updated outside tool'});
      firstIssueResponse.complete(
        jsonResponse({'message': 'expired'}, status: 401),
      );
      final result = await pending.timeout(const Duration(seconds: 5));

      expect(result.result.isError, isFalse);
      expect(issueGets, 3);
      expect(noteGets, 2);
      expect(result.gitLabRequests, 5);
      expect(budget.gitLabRequests, 5);
      expect(tokenAdapter.requests, hasLength(2));
      expect(
        apiAdapter.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );
    },
  );

  test(
    'production cache reads stop before a grant that cannot cover reread replay',
    () async {
      // Each cached read holds 4 sends (one cache reread, each replayable once
      // after OAuth refresh) and then settles to its physical sends. The issue
      // record and its notes are two such reads.
      Future<
        ({
          AiToolExecution result,
          AiToolBudget budget,
          FakeAdapter apiAdapter,
          FakeAdapter tokenAdapter,
        })
      >
      run(int grant) async {
        final apiAdapter = FakeAdapter(
          (request) => request.uri.path.endsWith('/issues/3/notes')
              ? jsonResponse(<Object?>[])
              : jsonResponse({'iid': 3, 'title': 'synthetic issue'}),
        );
        final tokenAdapter = FakeAdapter(
          (_) => jsonResponse({
            'access_token': 'new-access',
            'refresh_token': 'new-refresh',
            'token_type': 'bearer',
          }),
        );
        final instance = GitLabInstance.parse('https://example.com/gitlab');
        final api = GitLabApi(
          instance: instance,
          credential: const OAuthCredential(
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            clientId: 'synthetic-client',
          ),
          dio: Dio()..httpClientAdapter = apiAdapter,
          oauth: OAuthTokenClient(
            instance: instance,
            clientId: 'synthetic-client',
            dio: Dio()..httpClientAdapter = tokenAdapter,
          ),
        );
        addTearDown(api.close);
        final catalogue = AiToolCatalogue(
          port: GitLabAiReadPort(api, 9),
          scope: const AiResourceScope(
            accountKey: 'instance|7',
            instanceKey: 'https://example.com/gitlab',
            projectId: 9,
            projectPath: 'group/project',
            current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
            headSha: _head,
            defaultBranch: 'main',
          ),
          redactor: Redactor(secrets: _Secrets()),
        );
        final budget = AiToolBudget(maxGitLabRequests: grant);
        final result = await catalogue.execute(
          _issueCall('guarded-cache-read'),
          budget: budget,
        );
        return (
          result: result,
          budget: budget,
          apiAdapter: apiAdapter,
          tokenAdapter: tokenAdapter,
        );
      }

      // Grant 3 cannot hold the first cached read: nothing is sent.
      final none = await run(3);
      expect(none.result.result.isError, isTrue);
      expect(
        none.result.result.content,
        contains('GitLab request limit reached'),
      );
      expect(none.result.gitLabRequests, 0);
      expect(none.budget.gitLabRequests, 0);
      expect(none.apiAdapter.requests, isEmpty);
      expect(none.tokenAdapter.requests, isEmpty);

      // Grant 4 admits the issue read (settled to one send), then cannot hold
      // the notes read: the notes are refused before their send.
      final partial = await run(4);
      expect(partial.result.result.isError, isTrue);
      expect(
        partial.result.result.content,
        contains('GitLab request limit reached'),
      );
      expect(partial.result.gitLabRequests, 1);
      expect(partial.budget.gitLabRequests, 1);
      expect(partial.apiAdapter.requests, hasLength(1));
      expect(
        partial.apiAdapter.requests.single.uri.path,
        endsWith('/issues/3'),
      );
      expect(partial.tokenAdapter.requests, isEmpty);

      // Grant 5 holds the notes read after the settled issue send; the tool
      // succeeds and is charged exactly its two physical sends.
      final whole = await run(5);
      expect(whole.result.result.isError, isFalse);
      expect(whole.result.gitLabRequests, 2);
      expect(whole.budget.gitLabRequests, 2);
      expect(whole.apiAdapter.requests, hasLength(2));
      expect(
        whole.apiAdapter.requests.last.uri.path,
        endsWith('/issues/3/notes'),
      );
      expect(whole.tokenAdapter.requests, isEmpty);
    },
  );

  test('concurrent catalogue calls keep independent request meters', () async {
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final catalogue = _catalogue(
      _MeterPort((path) async {
        if (path == 'first.dart') {
          RequestMeter.current!.increment();
          firstStarted.complete();
          await releaseFirst.future;
          return const AiPortRead('first', requestCount: 1);
        }
        RequestMeter.current!
          ..increment()
          ..increment();
        return const AiPortRead('second', requestCount: 2);
      }),
    );
    final firstBudget = AiToolBudget(maxGitLabRequests: 4);
    final secondBudget = AiToolBudget(maxGitLabRequests: 4);

    final first = catalogue.execute(
      _readCall('first', 'first.dart'),
      budget: firstBudget,
    );
    await firstStarted.future;
    final second = await catalogue.execute(
      _readCall('second', 'second.dart'),
      budget: secondBudget,
    );
    releaseFirst.complete();
    final firstResult = await first;

    expect(firstResult.gitLabRequests, 1);
    expect(firstBudget.gitLabRequests, 1);
    expect(second.gitLabRequests, 2);
    expect(secondBudget.gitLabRequests, 2);
  });
}
