import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';

import '../support/fake_adapter.dart';

const _oauthCredential = OAuthCredential(
  accessToken: 'old-access',
  refreshToken: 'old-refresh',
  clientId: 'synthetic-app-id',
);

final _instance = GitLabInstance.parse('https://example.com/gitlab');

GitLabApi _patApi(HttpClientAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return GitLabApi(
    instance: _instance,
    token: 'synthetic-test-token',
    dio: dio,
  );
}

GitLabApi _oauthApi(
  HttpClientAdapter adapter, {
  Future<void> Function(OAuthCredential rotated)? onOAuthRotated,
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return GitLabApi(
    instance: _instance,
    credential: _oauthCredential,
    dio: dio,
    oauth: OAuthTokenClient(
      instance: _instance,
      clientId: _oauthCredential.clientId,
      dio: dio,
    ),
    onOAuthRotated: onOAuthRotated,
  );
}

Matcher _apiFailure(
  FailureKind kind, {
  required int status,
  String? resultCode,
}) => isA<ApiFailure>()
    .having((failure) => failure.kind, 'kind', kind)
    .having((failure) => failure.status, 'status', status)
    .having(gitLabMutation401ResultCode, 'resultCode', resultCode);

bool _isIssueMutation(RequestOptions request) =>
    request.method == 'POST' &&
    request.uri.path.endsWith('/projects/42/issues');

void main() {
  group('§15 row 5 real GitLabApi._send mutation 401 classification', () {
    test('PAT 401 stays unauthenticated and sends one mutation', () async {
      var mutations = 0;
      final adapter = FakeAdapter((request) {
        if (_isIssueMutation(request)) mutations += 1;
        return jsonResponse({'message': 'denied'}, status: 401);
      });
      final api = _patApi(adapter);
      addTearDown(api.close);

      await expectLater(
        api.createIssue(42, {'title': 'synthetic issue'}),
        throwsA(_apiFailure(FailureKind.unauthenticated, status: 401)),
      );

      expect(mutations, 1);
      expect(adapter.requests, hasLength(1));
    });

    test(
      'OAuth refresh failure keeps the mutation 401 unauthenticated without replay',
      () async {
        var mutations = 0;
        var refreshes = 0;
        final adapter = FakeAdapter((request) {
          if (_isIssueMutation(request)) {
            mutations += 1;
            return jsonResponse({'message': 'expired'}, status: 401);
          }
          if (request.uri.path.endsWith('/oauth/token')) {
            refreshes += 1;
            return jsonResponse({'message': 'invalid refresh'}, status: 401);
          }
          fail('unexpected request ${request.method} ${request.uri}');
        });
        final api = _oauthApi(adapter);
        addTearDown(api.close);

        await expectLater(
          api.createIssue(42, {'title': 'synthetic issue'}),
          throwsA(_apiFailure(FailureKind.unauthenticated, status: 401)),
        );

        expect(mutations, 1);
        expect(refreshes, 1);
      },
    );

    test(
      'OAuth refresh success does not replay and preserves writeUncertain status 401',
      () async {
        var mutations = 0;
        var refreshes = 0;
        final adapter = FakeAdapter((request) {
          if (_isIssueMutation(request)) {
            mutations += 1;
            return jsonResponse({'message': 'expired'}, status: 401);
          }
          if (request.uri.path.endsWith('/oauth/token')) {
            refreshes += 1;
            return jsonResponse({
              'access_token': 'rotated-access',
              'refresh_token': 'rotated-refresh',
              'token_type': 'bearer',
              'expires_in': 7200,
            });
          }
          fail('unexpected request ${request.method} ${request.uri}');
        });
        final api = _oauthApi(adapter);
        addTearDown(api.close);

        await expectLater(
          api.createIssue(42, {'title': 'synthetic issue'}),
          throwsA(
            _apiFailure(
              FailureKind.writeUncertain,
              status: 401,
              resultCode: 'refreshSucceeded',
            ),
          ),
        );

        expect(mutations, 1);
        expect(refreshes, 1);
        expect(
          (api.credential as OAuthCredential).accessToken,
          'rotated-access',
        );
      },
    );

    test(
      'OAuth refresh callback exception preserves the original mutation 401',
      () async {
        var mutations = 0;
        var refreshes = 0;
        final adapter = FakeAdapter((request) {
          if (_isIssueMutation(request)) {
            mutations += 1;
            return jsonResponse({'message': 'expired'}, status: 401);
          }
          if (request.uri.path.endsWith('/oauth/token')) {
            refreshes += 1;
            return jsonResponse({
              'access_token': 'rotated-access',
              'refresh_token': 'rotated-refresh',
              'token_type': 'bearer',
              'expires_in': 7200,
            });
          }
          fail('unexpected request ${request.method} ${request.uri}');
        });
        final api = _oauthApi(
          adapter,
          onOAuthRotated: (_) async =>
              throw StateError('synthetic store error'),
        );
        addTearDown(api.close);

        await expectLater(
          api.createIssue(42, {'title': 'synthetic issue'}),
          throwsA(
            _apiFailure(
              FailureKind.writeUncertain,
              status: 401,
              resultCode: 'sessionExpired',
            ),
          ),
        );

        expect(mutations, 1);
        expect(refreshes, 1);
      },
    );
  });

  group('§15 row 23 multipart send timeout', () {
    test('ordinary uploads retain the 15 second default', () async {
      final adapter = _VirtualUploadAdapter();
      final api = _patApi(adapter);
      addTearDown(api.close);

      await api.uploadProjectFile(
        42,
        filename: 'small.bin',
        bytes: Uint8List(1024),
      );

      expect(adapter.mutationCount, 1);
      expect(adapter.sendTimeout, const Duration(seconds: 15));
    });

    test(
      '20 MiB at a virtual 1 MiB/s succeeds with the AI 160 second timeout',
      () async {
        final adapter = _VirtualUploadAdapter();
        final api = _patApi(adapter);
        addTearDown(api.close);

        await api.uploadProjectFile(
          42,
          filename: 'twenty-mib.bin',
          bytes: Uint8List(20 * 1024 * 1024),
          sendTimeout: const Duration(seconds: 160),
        );

        expect(adapter.mutationCount, 1);
        expect(adapter.sendTimeout, const Duration(seconds: 160));
        expect(
          adapter.virtualSendTime,
          greaterThan(const Duration(seconds: 15)),
        );
        expect(adapter.virtualSendTime, lessThan(const Duration(seconds: 160)));
      },
    );
  });
}

final class _VirtualUploadAdapter implements HttpClientAdapter {
  static const _bytesPerSecond = 1024 * 1024;

  int mutationCount = 0;
  Duration? sendTimeout;
  Duration virtualSendTime = Duration.zero;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    mutationCount += 1;
    sendTimeout = options.sendTimeout;
    var sent = 0;
    await for (final chunk
        in requestStream ?? const Stream<Uint8List>.empty()) {
      sent += chunk.length;
      virtualSendTime = Duration(
        microseconds: (sent * Duration.microsecondsPerSecond / _bytesPerSecond)
            .ceil(),
      );
      final limit = sendTimeout;
      if (limit != null && virtualSendTime > limit) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.sendTimeout,
        );
      }
    }
    return jsonResponse({
      'markdown': '![twenty-mib.bin](/uploads/twenty-mib.bin)',
      'url': '/uploads/twenty-mib.bin',
      'full_path': '/group/project/uploads/twenty-mib.bin',
    }, status: 201);
  }

  @override
  void close({bool force = false}) {}
}
