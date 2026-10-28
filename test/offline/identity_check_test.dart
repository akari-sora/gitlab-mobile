import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/offline/offline_gate.dart';

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

  for (final outcome in [
    'HTML 401',
    'HTML 403',
    'unrelated JSON 401',
    'unrelated JSON 403',
    'server 503',
    'malformed invalid_grant',
    'oversized invalid_grant',
  ]) {
    test('OAuth token endpoint $outcome cannot establish refusal', () async {
      final instance = GitLabInstance.parse('https://example.com');
      final auth = FakeAdapter((request) {
        expect(request.uri, instance.oauth('token'));
        return switch (outcome) {
          'HTML 401' || 'HTML 403' => ResponseBody.fromString(
            '<html>proxy</html>',
            outcome == 'HTML 401' ? 401 : 403,
            headers: {
              'content-type': ['text/html'],
            },
          ),
          'unrelated JSON 401' || 'unrelated JSON 403' => jsonResponse({
            'error': 'invalid_client',
          }, status: outcome == 'unrelated JSON 401' ? 401 : 403),
          'server 503' => jsonResponse({'error': 'invalid_grant'}, status: 503),
          'malformed invalid_grant' => ResponseBody.fromString(
            '{"error":"invalid_grant"',
            400,
            headers: {
              'content-type': ['application/json'],
            },
          ),
          _ => jsonResponse({
            'error': 'invalid_grant',
            'padding': 'x' * 4096,
          }, status: 400),
        };
      });
      final transport = FakeAdapter(
        (_) => jsonResponse({'message': 'expired'}, status: 401),
      );
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
      );
      addTearDown(api.close);

      final verdict = await api.identityCheck();
      expect(verdict, anyOf(isA<IdentityUnknown>(), isA<IdentityNoVerdict>()));
      expect(transport.requests, hasLength(1));
      expect(auth.requests, hasLength(1));
    });
  }

  for (final retry in [
    (header: '3600', seconds: 3600),
    (header: '172800', seconds: 172800),
    (header: 'Fri, 30 Oct 2026 00:00:00 GMT', seconds: 172800),
  ]) {
    testWidgets(
      'OAuth token 429 defers identity probes until Retry-After ${retry.header}',
      (tester) async {
        var now = DateTime.utc(2026, 10, 28);
        final deadline = now.add(Duration(seconds: retry.seconds));
        final gate = OfflineGate(
          readCache: ReadCacheDiskCoordinator(coordinationScope: Object()),
          clock: () => now,
        );
        addTearDown(gate.dispose);
        final instance = GitLabInstance.parse('https://example.com');
        final auth = FakeAdapter(
          (_) => jsonResponse(
            {'error': 'rate_limited'},
            status: 429,
            headers: {
              'retry-after': [retry.header],
            },
          ),
        );
        final transport = FakeAdapter(
          (_) => now.isBefore(deadline)
              ? jsonResponse({'message': 'expired'}, status: 401)
              : jsonResponse({'id': 7, 'username': 'test'}),
        );
        GitLabApi client() => GitLabApi(
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
          rateBudget: gate.rateBudget,
          readCacheClock: () => now,
        );
        final verdicts = <IdentityVerdict>[];
        Future<void> probe() async {
          final api = client();
          try {
            final verdict = await gate.probe(api.identityCheck);
            verdicts.add(verdict);
            if (verdict is IdentityNoVerdict) gate.scheduleRetry();
          } finally {
            api.close(closeRateBudget: false);
          }
        }

        // Run transport streams outside fake time, then drive the retry timer with
        // the same injected clock as the shared budget.
        await tester.runAsync(probe);
        final verdict = verdicts.single as IdentityNoVerdict;
        expect(verdict.kind, FailureKind.rateLimited);
        expect(verdict.failure.status, 429);
        expect(verdict.failure.retryAt, deadline);
        Future<void>? background;
        gate.start(
          lastValidatedAt: now,
          onProbe: () => background = () async {
            await tester.runAsync(probe);
          }(),
          onExpire: () => fail('recent identity must not expire'),
        );
        gate.scheduleRetry();
        expect(gate.nextRetryAt, deadline);
        expect(transport.requests, hasLength(1));
        expect(auth.requests, hasLength(1));

        for (final seconds in [15, 885, retry.seconds - 901]) {
          now = now.add(Duration(seconds: seconds));
          await tester.pump(Duration(seconds: seconds));
          final api = client();
          try {
            final blocked = await gate.probe(api.identityCheck, manual: true);
            expect((blocked as IdentityNoVerdict).failure.retryAt, deadline);
          } finally {
            api.close(closeRateBudget: false);
          }
          expect(transport.requests, hasLength(1));
          expect(auth.requests, hasLength(1));
          expect(verdicts, hasLength(1));
        }
        now = deadline;
        await tester.pump(const Duration(seconds: 1));
        expect(background, isNotNull);
        await background;
        expect(verdicts, hasLength(2));
        expect(verdicts.last, isA<IdentityOk>());
        expect(transport.requests, hasLength(2));
        expect(auth.requests, hasLength(1));
        gate.dispose();
      },
    );
  }

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
