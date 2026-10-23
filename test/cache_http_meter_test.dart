import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/request_meter.dart';

import 'support/fake_adapter.dart';

const _timeout = Timeout(Duration(seconds: 20));

GitLabApi _boundApi(FakeAdapter adapter) {
  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final api = GitLabApi(
    instance: instance,
    token: 'synthetic-pat',
    dio: Dio()..httpClientAdapter = adapter,
  );
  api.bindReadCache('${instance.key}#7', 1);
  return api;
}

final class _CancelAwareAdapter implements HttpClientAdapter {
  final Completer<void> started = Completer<void>();

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    started.complete();
    await cancelFuture;
    throw DioException.requestCancelled(
      requestOptions: options,
      reason: 'synthetic cancellation',
    );
  }
}

void main() {
  test(
    'uncached REST response and failure each count a physical send',
    () async {
      var status = 200;
      final adapter = FakeAdapter(
        (_) => jsonResponse(
          status == 200
              ? <String, Object?>{'id': 7, 'username': 'tester'}
              : <String, Object?>{'message': 'failure'},
          status: status,
        ),
      );
      final api = _boundApi(adapter);
      addTearDown(api.close);
      final meter = RequestMeter();

      await meter.runAsync(api.currentUser);
      status = 500;
      await expectLater(
        meter.runAsync(api.currentUser),
        throwsA(isA<ApiFailure>()),
      );

      expect(meter.count, 2);
      expect(adapter.requests, hasLength(2));
    },
    timeout: _timeout,
  );

  test('cache hit and joined in-flight read add no physical sends', () async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => pending.future);
    final api = _boundApi(adapter);
    addTearDown(api.close);
    final firstMeter = RequestMeter();
    final joinedMeter = RequestMeter();
    final first = firstMeter.runAsync(
      () => api.cachedRecord(<String>['projects', '1', 'issues', '2']),
    );
    await Future<void>.delayed(Duration.zero);
    final joined = joinedMeter.runAsync(
      () => api.cachedRecord(<String>['projects', '1', 'issues', '2']),
    );
    pending.complete(jsonResponse({'id': 2, 'title': 'fixture'}));
    await Future.wait(<Future<Object?>>[
      first,
      joined,
    ]).timeout(const Duration(seconds: 20));

    final hitMeter = RequestMeter();
    await hitMeter.runAsync(
      () => api.cachedRecord(<String>['projects', '1', 'issues', '2']),
    );

    expect(firstMeter.count, 1);
    expect(joinedMeter.count, 0);
    expect(hitMeter.count, 0);
    expect(adapter.requests, hasLength(1));
  }, timeout: _timeout);

  test('fresh reads do not coalesce and each count their send', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 2, 'title': 'fixture'}),
    );
    final api = _boundApi(adapter);
    addTearDown(api.close);
    final meter = RequestMeter();

    await meter.runAsync(
      () => Future.wait(<Future<Object?>>[
        api.cachedRecord(<String>['projects', '1', 'issues', '2'], fresh: true),
        api.cachedRecord(<String>['projects', '1', 'issues', '2'], fresh: true),
      ]),
    );

    expect(meter.count, 2);
    expect(adapter.requests, hasLength(2));
  }, timeout: _timeout);

  test('text file HEAD plus GET counts two HTTP requests', () async {
    final adapter = FakeAdapter((request) {
      if (request.method == 'HEAD') {
        return ResponseBody.fromString(
          '',
          200,
          headers: <String, List<String>>{
            'x-gitlab-size': <String>['5'],
          },
        );
      }
      return ResponseBody.fromString('hello', 200);
    });
    final api = _boundApi(adapter);
    addTearDown(api.close);
    final meter = RequestMeter();

    expect(
      await meter.runAsync(() => api.textFile(1, 'main', 'README.md')),
      'hello',
    );

    expect(meter.count, 2);
    expect(adapter.requests.map((request) => request.method), <String>[
      'HEAD',
      'GET',
    ]);
  }, timeout: _timeout);

  test(
    'OAuth API replay counts twice while token refresh is excluded',
    () async {
      var apiRequests = 0;
      final apiAdapter = FakeAdapter((_) {
        apiRequests += 1;
        return apiRequests == 1
            ? jsonResponse({'message': 'expired'}, status: 401)
            : jsonResponse({'id': 7, 'username': 'tester'});
      });
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
      final meter = RequestMeter();

      await meter.runAsync(api.currentUser);

      expect(meter.count, 2);
      expect(apiAdapter.requests, hasLength(2));
      expect(tokenAdapter.requests, hasLength(1));
    },
    timeout: _timeout,
  );

  test('a cancelled request counts after transport dispatch', () async {
    final adapter = _CancelAwareAdapter();
    final api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-pat',
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(api.close);
    final cancel = CancelToken();
    final meter = RequestMeter();
    final request = meter.runAsync(
      () => api.rawFileBytes('1', 'main', 'README.md', cancelToken: cancel),
    );
    await adapter.started.future.timeout(const Duration(seconds: 20));
    cancel.cancel('synthetic cancellation');

    await expectLater(request, throwsA(isA<ApiFailure>()));
    expect(meter.count, 1);
  }, timeout: _timeout);
}
