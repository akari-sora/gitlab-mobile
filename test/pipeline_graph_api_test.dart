import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'support/fake_adapter.dart';

final _project = Project.fromJson(projectJson(42));
Map<String, dynamic> _envelope() => {
  'data': <String, dynamic>{
    'project': <String, dynamic>{
      'id': 'gid://gitlab/Project/42',
      'pipeline': <String, dynamic>{
        'id': 'gid://gitlab/Ci::Pipeline/99',
        'iid': '12',
        'stages': {
          'nodes': <Object?>[],
          'pageInfo': {'hasNextPage': false},
        },
        'jobs': {
          'nodes': <Object?>[],
          'pageInfo': {'hasNextPage': false, 'endCursor': null},
        },
      },
    },
  },
};
Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((e) => e.kind, 'kind', kind);

GitLabApi _boundApi(FakeAdapter adapter) {
  final api = testApi(adapter);
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

void main() {
  test('GraphQL allowlist is exact and independent of REST paths', () {
    final instance = GitLabInstance.parse('https://example.com:8443/gitlab');
    expect(
      instance.graphQL.toString(),
      'https://example.com:8443/gitlab/api/graphql',
    );
    expect(instance.allowsGraphQL(instance.graphQL), isTrue);
    expect(instance.allowsApi(instance.graphQL), isFalse);
    for (final uri in [
      Uri.parse('https://evil.example:8443/gitlab/api/graphql'),
      Uri.parse('https://example.com:8443/api/graphql'),
      Uri.parse('https://example.com/gitlab/api/graphql'),
      Uri.parse(
        'https://example.com:8443/gitlab/api/graphql?access_token=synthetic',
      ),
      Uri.parse('https://example.com:8443/gitlab/api/graphql#other'),
      Uri.parse('https://example.com:8443/gitlab/api/graphql/other'),
    ]) {
      expect(instance.allowsGraphQL(uri), isFalse);
    }
  });
  test(
    'fixed read-only POST preserves subpath, cursor, identities and Bearer-only auth',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_envelope()));
      final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
      addTearDown(api.close);
      expect(
        (await api.pipelineGraphPage(_project, 99, after: 'cursor+/='))['iid'],
        '12',
      );
      final request = adapter.requests.single;
      expect(
        request.uri.toString(),
        'https://example.com:8443/gitlab/api/graphql',
      );
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer synthetic-test-token');
      expect(request.headers['PRIVATE-TOKEN'], isNull);
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect((request.data as Map)['variables'], {
        'path': _project.path,
        'pipeline': 'gid://gitlab/Ci::Pipeline/99',
        'after': 'cursor+/=',
      });
      final query = (request.data as Map)['query'] as String;
      expect(query, startsWith('query MobilePipelineGraph'));
      expect(query, isNot(contains('mutation')));
      expect(query, contains('needs(first: 100)'));
    },
  );
  test(
    'GraphQL reads are fresh and do not invalidate cached projects',
    () async {
      final adapter = FakeAdapter(
        (r) => r.uri.path.endsWith('/graphql')
            ? jsonResponse(_envelope())
            : jsonResponse(projectJson(42)),
      );
      final api = _boundApi(adapter);
      addTearDown(api.close);
      await api.project('42');
      await api.pipelineGraphPage(_project, 99);
      await api.pipelineGraphPage(_project, 99);
      await api.project('42');
      expect(
        adapter.requests.where((r) => r.uri.path.endsWith('/projects/42')),
        hasLength(1),
      );
      expect(
        adapter.requests.where((r) => r.uri.path.endsWith('/graphql')),
        hasLength(2),
      );
    },
  );
  for (final status in [302, 401, 403, 404, 429, 503]) {
    test(
      'GraphQL HTTP $status retains safe failure semantics without redirect or replay',
      () async {
        final adapter = FakeAdapter(
          (_) => jsonResponse({'message': 'private response'}, status: status),
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          api.pipelineGraphPage(_project, 99),
          throwsA(_failure(ApiFailure.fromStatus(status).kind)),
        );
        expect(adapter.requests, hasLength(1));
      },
    );
  }
  test(
    'partial data with schema errors is not success and does not reveal messages',
    () async {
      final envelope = _envelope()
        ..['errors'] = [
          {
            'message': 'private response',
            'extensions': {'code': 'undefinedField'},
          },
        ];
      final adapter = FakeAdapter((_) => jsonResponse(envelope));
      final api = testApi(adapter);
      addTearDown(api.close);
      try {
        await api.pipelineGraphPage(_project, 99);
        fail('partial result must fail');
      } on ApiFailure catch (error) {
        expect(error.kind, FailureKind.unsupported);
        expect(
          '${error.title} ${error.detail}',
          isNot(contains('private response')),
        );
      }
    },
  );
  test('unknown errors and malformed envelopes fail closed', () async {
    for (final payload in [
      {
        'data': _envelope()['data'],
        'errors': [
          {'message': 'private'},
        ],
      },
      {'data': _envelope()['data'], 'errors': 'bad'},
      {'data': null},
      {'data': <Object?>[]},
    ]) {
      final api = testApi(FakeAdapter((_) => jsonResponse(payload)));
      await expectLater(
        api.pipelineGraphPage(_project, 99),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });
  test(
    'null project/pipeline is ambiguous inaccessible; null connections are not empty',
    () async {
      for (final missing in ['project', 'pipeline', 'jobs', 'stages']) {
        final envelope = _envelope();
        final data = envelope['data'] as Map;
        final project = data['project'] as Map;
        final pipeline = project['pipeline'] as Map;
        if (missing == 'project') {
          data[missing] = null;
        } else if (missing == 'pipeline') {
          project[missing] = null;
        } else {
          pipeline[missing] = null;
        }
        final api = testApi(FakeAdapter((_) => jsonResponse(envelope)));
        await expectLater(
          api.pipelineGraphPage(_project, 99),
          throwsA(
            _failure(
              missing == 'project' || missing == 'pipeline'
                  ? FailureKind.invisible
                  : FailureKind.forbidden,
            ),
          ),
        );
        api.close();
      }
    },
  );
  test(
    'renamed project path cannot bind another numeric project or pipeline response',
    () async {
      for (final mismatch in ['project', 'pipeline']) {
        final envelope = _envelope();
        final project = (envelope['data'] as Map)['project'] as Map;
        (mismatch == 'project' ? project : project['pipeline'] as Map)['id'] =
            'gid://gitlab/Other/66';
        final api = testApi(FakeAdapter((_) => jsonResponse(envelope)));
        await expectLater(
          api.pipelineGraphPage(_project, 99),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }
    },
  );
  test(
    'response byte budget and closed-client fence also cover GraphQL',
    () async {
      final oversized = testApi(
        FakeAdapter(
          (_) => ResponseBody.fromString('x' * (4 * 1024 * 1024 + 1), 200),
        ),
      );
      addTearDown(oversized.close);
      await expectLater(
        oversized.pipelineGraphPage(_project, 99),
        throwsA(_failure(FailureKind.tooLarge)),
      );
      final deferred = Completer<ResponseBody>();
      final api = testApi(FakeAdapter((_) => deferred.future));
      final result = expectLater(
        api.pipelineGraphPage(_project, 99),
        throwsA(_failure(FailureKind.cancelled)),
      );
      await Future<void>.delayed(Duration.zero);
      api.close();
      deferred.complete(jsonResponse(_envelope()));
      await result;
    },
  );
  test(
    'OAuth refresh retries only the fixed query using rotated Bearer',
    () async {
      var queries = 0;
      final adapter = FakeAdapter((r) {
        if (r.uri.path.endsWith('/oauth/token')) {
          return jsonResponse({
            'access_token': 'rotated-access',
            'refresh_token': 'rotated-refresh',
            'token_type': 'bearer',
            'expires_in': 7200,
          });
        }
        if (++queries == 1) {
          return jsonResponse({}, status: 401);
        }
        expect(r.headers['Authorization'], 'Bearer rotated-access');
        return jsonResponse(_envelope());
      });
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final dio = Dio()..httpClientAdapter = adapter;
      final api = GitLabApi(
        instance: instance,
        dio: dio,
        credential: const OAuthCredential(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          clientId: 'app',
        ),
        oauth: OAuthTokenClient(instance: instance, clientId: 'app', dio: dio),
      );
      addTearDown(api.close);
      expect((await api.pipelineGraphPage(_project, 99))['iid'], '12');
      expect(queries, 2);
      expect(adapter.requests.map((r) => r.uri.path), [
        '/gitlab/api/graphql',
        '/gitlab/oauth/token',
        '/gitlab/api/graphql',
      ]);
    },
  );
}
