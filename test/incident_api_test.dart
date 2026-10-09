import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';

import 'support/fake_adapter.dart';

final _project = Project.fromJson(projectJson(42));
const _updated = '2026-10-02T10:00:00Z';
Json _issue({String status = 'TRIGGERED'}) => {
  'id': 'gid://gitlab/Issue/123',
  'iid': '7',
  'projectId': 42,
  'state': 'opened',
  'severity': 'HIGH',
  'escalationStatus': status,
  'updatedAt': _updated,
};
Json _read({Json? issue}) => {
  'data': {
    'project': {
      'id': 'gid://gitlab/Project/42',
      'issues': {
        'nodes': [issue ?? _issue()],
        'pageInfo': {'hasNextPage': false},
      },
    },
  },
};
Json _write({Json? issue, List<Object?> errors = const []}) => {
  'data': {
    'issueSetEscalationStatus': {
      'errors': errors,
      'issue': issue ?? _issue(status: 'ACKNOWLEDGED'),
    },
  },
};
bool _mutation(RequestOptions request) =>
    ((request.data as Map)['query'] as String).startsWith('mutation ');
Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

void main() {
  test(
    'GraphQL mutation stream reset is uncertain with one mutation',
    () async {
      final adapter = FakeAdapter(
        (request) => _mutation(request)
            ? ResponseBody(
                Stream<Uint8List>.error(
                  const SocketException('synthetic reset'),
                ),
                200,
              )
            : jsonResponse(_read()),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.setIncidentStatus(_project, 7, 'ACKNOWLEDGED'),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.map(_mutation), [false, true]);
    },
  );

  test('2xx GraphQL mutation over response budget remains uncertain', () async {
    final adapter = FakeAdapter(
      (request) => _mutation(request)
          ? jsonResponse(
              {},
              headers: {
                'content-length': ['4194305'],
              },
            )
          : jsonResponse(_read()),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.setIncidentStatus(_project, 7, 'ACKNOWLEDGED'),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests.map(_mutation), [false, true]);
  });

  test(
    'incident lifecycle fixed query binds numeric identity and exact instance',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_read()));
      final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
      addTearDown(api.close);
      expect(
        (await api.incidentStatus(_project, 7))['escalationStatus'],
        'TRIGGERED',
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
        'iid': '7',
      });
      final query = (request.data as Map)['query'] as String;
      expect(query, startsWith('query MobileIncidentStatus'));
      expect(query, contains('types: [INCIDENT]'));
      expect(query, contains('projectId'));
    },
  );

  test(
    'preflight, one mutation and independent readback retain separate issue state',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) return jsonResponse(_write());
        return jsonResponse(
          _read(
            issue: _issue(status: ++reads == 1 ? 'TRIGGERED' : 'ACKNOWLEDGED'),
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final confirmed = await api.setIncidentStatus(
        _project,
        7,
        'ACKNOWLEDGED',
        expectedUpdatedAt: _updated,
      );
      expect(confirmed['escalationStatus'], 'ACKNOWLEDGED');
      expect(confirmed['state'], 'opened');
      expect(adapter.requests, hasLength(3));
      expect(adapter.requests.map(_mutation), [false, true, false]);
      expect((adapter.requests[1].data as Map)['variables'], {
        'input': {
          'projectPath': _project.path,
          'iid': '7',
          'status': 'ACKNOWLEDGED',
        },
      });
      expect(
        (adapter.requests[1].data as Map)['query'],
        isNot(contains('state_event')),
      );
    },
  );

  test(
    'fresh preflight conflicts or already-selected status do not write',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_read()));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.setIncidentStatus(
          _project,
          7,
          'ACKNOWLEDGED',
          expectedUpdatedAt: '2026-10-01T10:00:00Z',
        ),
        throwsA(_failure(FailureKind.conflict)),
      );
      expect(
        (await api.setIncidentStatus(_project, 7, 'TRIGGERED'))['state'],
        'opened',
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    },
  );

  test(
    'owner replacement during fresh preflight cancels before mutation',
    () async {
      var current = true;
      final received = Completer<void>();
      final response = Completer<ResponseBody>();
      final adapter = FakeAdapter((_) {
        received.complete();
        return response.future;
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final operation = api.setIncidentStatus(
        _project,
        7,
        'ACKNOWLEDGED',
        isCurrent: () => current,
      );
      final rejected = expectLater(
        operation,
        throwsA(_failure(FailureKind.cancelled)),
      );
      await received.future;
      current = false;
      response.complete(jsonResponse(_read()));
      await rejected;
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.where(_mutation), isEmpty);
      await expectLater(
        api.setIncidentStatus(
          _project,
          7,
          'ACKNOWLEDGED',
          isCurrent: () => false,
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'invalid action, IID and project are rejected before transport',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_read()));
      final api = testApi(adapter);
      addTearDown(api.close);
      for (final status in [
        'IGNORED',
        'acknowledged',
        'closed',
        'future-status',
      ]) {
        await expectLater(
          api.setIncidentStatus(_project, 7, status),
          throwsA(_failure(FailureKind.validation)),
        );
      }
      await expectLater(
        api.incidentStatus(_project, 0),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'unavailable, forbidden and malformed connections are not an empty success',
    () async {
      for (final fixture in <(Json, FailureKind)>[
        (
          {
            'data': {'project': null},
          },
          FailureKind.invisible,
        ),
        (
          {
            'data': {
              'project': {'id': 'gid://gitlab/Project/42', 'issues': null},
            },
          },
          FailureKind.forbidden,
        ),
        (
          {
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'issues': {
                  'nodes': <Object?>[],
                  'pageInfo': {'hasNextPage': false},
                },
              },
            },
          },
          FailureKind.invisible,
        ),
        (
          {
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'issues': {
                  'nodes': [_issue(), _issue()],
                  'pageInfo': {'hasNextPage': false},
                },
              },
            },
          },
          FailureKind.invalidResponse,
        ),
      ]) {
        final api = testApi(FakeAdapter((_) => jsonResponse(fixture.$1)));
        await expectLater(
          api.incidentStatus(_project, 7),
          throwsA(_failure(fixture.$2)),
        );
        api.close();
      }
    },
  );

  test(
    'foreign identities, unknown status and invalid timestamps fail closed',
    () async {
      for (final field in <String, Object?>{
        'id': 'gid://gitlab/WorkItem/123',
        'iid': '8',
        'projectId': 43,
        'escalationStatus': 'UNKNOWN_FUTURE',
        'severity': 'SEV1',
        'updatedAt': 'invalid-date',
        'state': 'all',
      }.entries) {
        final issue = _issue()..[field.key] = field.value;
        final adapter = FakeAdapter((_) => jsonResponse(_read(issue: issue)));
        final api = testApi(adapter);
        await expectLater(
          api.setIncidentStatus(_project, 7, 'RESOLVED'),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        expect(adapter.requests.where(_mutation), isEmpty);
        api.close();
      }
      final issue = _issue()..['escalationStatus'] = null;
      final api = testApi(
        FakeAdapter((_) => jsonResponse(_read(issue: issue))),
      );
      await expectLater(
        api.incidentStatus(_project, 7),
        throwsA(_failure(FailureKind.unsupported)),
      );
      api.close();
    },
  );

  test(
    'schema errors reject partial data without exposing raw messages',
    () async {
      final payload = _read()
        ..['errors'] = [
          {
            'message': 'private server message',
            'extensions': {'code': 'undefinedField'},
          },
        ];
      final api = testApi(FakeAdapter((_) => jsonResponse(payload)));
      addTearDown(api.close);
      try {
        await api.incidentStatus(_project, 7);
        fail('Partial GraphQL response must fail');
      } on ApiFailure catch (error) {
        expect(error.kind, FailureKind.unsupported);
        expect(
          '${error.title} ${error.detail}',
          isNot(contains('private server message')),
        );
      }
    },
  );

  test(
    'payload errors are rejection and do not reflect private text or read back',
    () async {
      final adapter = FakeAdapter(
        (r) => jsonResponse(
          _mutation(r)
              ? _write(errors: ['private permission details'])
              : _read(),
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      try {
        await api.setIncidentStatus(_project, 7, 'RESOLVED');
        fail('Payload error must fail');
      } on ApiFailure catch (error) {
        expect(error.kind, FailureKind.validation);
        expect(
          '${error.title} ${error.detail}',
          isNot(contains('private permission details')),
        );
      }
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'malformed mutation acknowledgement does not establish completion',
    () async {
      for (final issue in [
        _issue()..['id'] = 'gid://gitlab/Issue/999',
        _issue()..['projectId'] = 43,
        _issue(status: 'RESOLVED'),
        _issue(status: 'ACKNOWLEDGED')..['escalationStatus'] = null,
      ]) {
        final adapter = FakeAdapter(
          (r) => jsonResponse(_mutation(r) ? _write(issue: issue) : _read()),
        );
        final api = testApi(adapter);
        await expectLater(
          api.setIncidentStatus(_project, 7, 'ACKNOWLEDGED'),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests.where(_mutation), hasLength(1));
        api.close();
      }
    },
  );

  test(
    'failed or concurrently changed readback is uncertain without replay',
    () async {
      for (final failure in [false, true]) {
        var reads = 0;
        final adapter = FakeAdapter((r) {
          if (_mutation(r)) return jsonResponse(_write());
          if (++reads == 1) return jsonResponse(_read());
          return failure
              ? jsonResponse({}, status: 503)
              : jsonResponse(_read(issue: _issue(status: 'RESOLVED')));
        });
        final api = testApi(adapter);
        await expectLater(
          api.setIncidentStatus(_project, 7, 'ACKNOWLEDGED'),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests.where(_mutation), hasLength(1));
        expect(adapter.requests, hasLength(3));
        api.close();
      }
    },
  );

  test(
    'mutation redirect and timeout do not follow or replay authorization',
    () async {
      for (final timeout in [false, true]) {
        final adapter = FakeAdapter((request) {
          if (!_mutation(request)) return jsonResponse(_read());
          if (timeout) {
            throw DioException(
              requestOptions: request,
              type: DioExceptionType.receiveTimeout,
            );
          }
          return jsonResponse(
            {},
            status: 307,
            headers: {
              'location': ['https://third-party.example/graphql'],
            },
          );
        });
        final api = testApi(adapter);
        await expectLater(
          api.setIncidentStatus(_project, 7, 'RESOLVED'),
          throwsA(
            _failure(
              timeout
                  ? FailureKind.writeUncertain
                  : FailureKind.redirectBlocked,
            ),
          ),
        );
        expect(adapter.requests, hasLength(2));
        expect(
          adapter.requests.every(
            (r) => r.uri.host == 'example.com' && !r.followRedirects,
          ),
          isTrue,
        );
        api.close();
      }
    },
  );

  test(
    'OAuth mutation 401 rotates credentials but never replays the write',
    () async {
      final adapter = FakeAdapter((r) {
        if (r.uri.path.endsWith('/oauth/token')) {
          return jsonResponse({
            'access_token': 'rotated-access',
            'refresh_token': 'rotated-refresh',
            'token_type': 'bearer',
            'expires_in': 7200,
          });
        }
        return _mutation(r)
            ? jsonResponse({}, status: 401)
            : jsonResponse(_read());
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
      await expectLater(
        api.setIncidentStatus(_project, 7, 'RESOLVED'),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.map((r) => r.uri.path), [
        '/gitlab/api/graphql',
        '/gitlab/api/graphql',
        '/gitlab/oauth/token',
      ]);
      expect(api.credential.accessToken, 'rotated-access');
    },
  );

  test(
    'lifecycle reads retain cached project while a mutation invalidates it',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((r) {
        if (!r.uri.path.endsWith('/graphql')) {
          return jsonResponse(projectJson(42));
        }
        if (_mutation(r)) return jsonResponse(_write());
        return jsonResponse(
          _read(
            issue: _issue(status: ++reads <= 2 ? 'TRIGGERED' : 'ACKNOWLEDGED'),
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await api.project('42');
      await api.incidentStatus(_project, 7);
      await api.project('42');
      expect(
        adapter.requests.where((r) => r.uri.path.endsWith('/projects/42')),
        hasLength(1),
      );
      await api.setIncidentStatus(_project, 7, 'ACKNOWLEDGED');
      await api.project('42');
      expect(
        adapter.requests.where((r) => r.uri.path.endsWith('/projects/42')),
        hasLength(2),
      );
    },
  );
}
