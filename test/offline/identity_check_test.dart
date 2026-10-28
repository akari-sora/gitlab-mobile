import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';

import '../support/fake_adapter.dart';

void main() {
  test('identity check sends a bounded no-redirect request', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'test'}),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final result = await api.identityCheck();
    expect((result as IdentityOk).user.id, 7);
    expect(
      adapter.requests.single.uri.toString(),
      'https://example.com/gitlab/api/v4/user',
    );
    expect(adapter.requests.single.followRedirects, isFalse);
  });

  for (final status in [401, 403]) {
    for (final contentType in [
      'text/html',
      'text/plain',
      'application/octet-stream',
    ]) {
      test('$contentType $status is unknown', () async {
        final api = testApi(
          FakeAdapter(
            (_) => ResponseBody.fromString(
              '<html>proxy</html>',
              status,
              headers: {
                'content-type': [contentType],
              },
            ),
          ),
        );
        addTearDown(api.close);
        final verdict = await api.identityCheck();
        expect(verdict, isA<IdentityUnknown>());
        expect(verdict.failure?.status, status);
      });
    }
    test('GitLab JSON $status is a refusal', () async {
      final api = testApi(
        FakeAdapter((_) => jsonResponse({'message': 'denied'}, status: status)),
      );
      addTearDown(api.close);
      expect(
        await api.identityCheck(),
        status == 401 ? isA<IdentityRefused401>() : isA<IdentityRefused403>(),
      );
    });
  }

  test('redirect, server and invalid success have no verdict', () async {
    for (final response in <ResponseBody>[
      ResponseBody.fromString('', 302),
      jsonResponse({'message': 'down'}, status: 503),
      ResponseBody.fromString(
        '<html>login</html>',
        200,
        headers: {
          'content-type': ['text/html'],
        },
      ),
      jsonResponse({'id': '7', 'username': 'test'}),
    ]) {
      final api = testApi(FakeAdapter((_) => response));
      addTearDown(api.close);
      expect(await api.identityCheck(), isA<IdentityNoVerdict>());
    }
  });

  test('malformed JSON 401 is unknown', () async {
    final api = testApi(
      FakeAdapter((_) => jsonResponse({'detail': 'proxy'}, status: 401)),
    );
    addTearDown(api.close);
    expect(await api.identityCheck(), isA<IdentityUnknown>());
  });

  test('OAuth refresh persists rotation and retries only once', () async {
    final instance = GitLabInstance.parse('https://example.com');
    final auth = FakeAdapter(
      (_) =>
          jsonResponse({'access_token': 'new', 'refresh_token': 'new-refresh'}),
    );
    final transport = FakeAdapter(
      (request) => request.headers['Authorization'] == 'Bearer new'
          ? jsonResponse({'id': 7, 'username': 'test'})
          : jsonResponse({'message': 'expired'}, status: 401),
    );
    OAuthCredential? persisted;
    final api = GitLabApi(
      instance: instance,
      credential: const OAuthCredential(
        accessToken: 'old',
        refreshToken: 'old-refresh',
        clientId: 'id',
      ),
      dio: Dio()..httpClientAdapter = transport,
      oauth: OAuthTokenClient(
        instance: instance,
        clientId: 'id',
        dio: Dio()..httpClientAdapter = auth,
      ),
      onOAuthRotated: (credential) async {
        persisted = credential;
      },
    );
    addTearDown(api.close);
    expect(await api.identityCheck(), isA<IdentityOk>());
    expect(persisted?.accessToken, 'new');
    expect(transport.requests.length, 2);
    expect(auth.requests.length, 1);
  });

  test('OAuth invalid_grant, unrelated 400 and network are distinct', () async {
    final instance = GitLabInstance.parse('https://example.com');
    for (final outcome in ['invalid_grant', 'other', 'network']) {
      final auth = FakeAdapter((request) {
        if (outcome == 'network') {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.connectionError,
          );
        }
        return jsonResponse({'error': outcome}, status: 400);
      });
      final api = GitLabApi(
        instance: instance,
        credential: const OAuthCredential(
          accessToken: 'old',
          refreshToken: 'old-refresh',
          clientId: 'id',
        ),
        dio: Dio()
          ..httpClientAdapter = FakeAdapter(
            (_) => jsonResponse({'message': 'expired'}, status: 401),
          ),
        oauth: OAuthTokenClient(
          instance: instance,
          clientId: 'id',
          dio: Dio()..httpClientAdapter = auth,
        ),
      );
      addTearDown(api.close);
      final result = await api.identityCheck();
      if (outcome == 'invalid_grant') {
        expect(result, isA<IdentityRefused401>());
      } else if (outcome == 'other') {
        expect(result, isA<IdentityUnknown>());
      } else {
        expect((result as IdentityNoVerdict).kind, FailureKind.network);
      }
    }
  });

  test('cooldown survives closing a client that shares its budget', () async {
    final instance = GitLabInstance.parse('https://example.com');
    final budget = GitLabRateBudget();
    final firstTransport = FakeAdapter(
      (_) => jsonResponse(
        {'message': 'slow down'},
        status: 429,
        headers: {
          'retry-after': ['60'],
        },
      ),
    );
    final first = GitLabApi(
      instance: instance,
      token: 'synthetic',
      dio: Dio()..httpClientAdapter = firstTransport,
      rateBudget: budget,
    );
    final result = await first.identityCheck() as IdentityNoVerdict;
    expect(result.kind, FailureKind.rateLimited);
    first.close(closeRateBudget: false);
    final secondTransport = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'test'}),
    );
    final second = GitLabApi(
      instance: instance,
      token: 'synthetic',
      dio: Dio()..httpClientAdapter = secondTransport,
      rateBudget: budget,
    );
    addTearDown(second.close);
    expect(
      (await second.identityCheck() as IdentityNoVerdict).kind,
      FailureKind.rateLimited,
    );
    expect(secondTransport.requests, isEmpty);
  });
}
