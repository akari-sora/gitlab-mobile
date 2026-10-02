import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import 'support/fake_adapter.dart';

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

void main() {
  test(
    'response stream reset keeps mutation uncertain and read retryable',
    () async {
      for (final writing in [true, false]) {
        final adapter = FakeAdapter(
          (_) => ResponseBody(
            Stream<Uint8List>.error(const SocketException('synthetic reset')),
            200,
          ),
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          writing
              ? api.createIssue(42, {'title': 'Synthetic task'})
              : api.record(['projects', '42', 'issues', '7']),
          throwsA(
            _failure(
              writing ? FailureKind.writeUncertain : FailureKind.network,
            ),
          ),
        );
        expect(adapter.requests, hasLength(1));
      }
    },
  );

  test('2xx mutation with no response body is uncertain', () async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          response.data = null;
          handler.next(response);
        },
      ),
    );
    final api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: dio,
    );
    addTearDown(api.close);
    await expectLater(
      api.createIssue(42, {'title': 'Synthetic task'}),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests, hasLength(1));
  });

  for (final declaredLength in [true, false]) {
    test(
      '2xx mutation exceeds ${declaredLength ? 'declared' : 'streamed'} response budget without replay',
      () async {
        final adapter = FakeAdapter(
          (_) => declaredLength
              ? jsonResponse(
                  {},
                  headers: {
                    'content-length': ['4194305'],
                  },
                )
              : ResponseBody.fromString('x' * 4194305, 200),
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          api.createIssue(42, {'title': 'Synthetic task'}),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests, hasLength(1));
      },
    );
  }

  for (final body in ['not-json', 'null', '[]', '42']) {
    test(
      '2xx mutation acknowledgement $body is uncertain without replay',
      () async {
        final adapter = FakeAdapter((_) => ResponseBody.fromString(body, 201));
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          api.createIssue(42, {
            'title': 'Synthetic task',
            'issue_type': 'task',
          }),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests, hasLength(1));
        expect(adapter.requests.single.method, 'POST');
      },
    );
  }

  test(
    'malformed read remains invalid response and explicit rejection is validation',
    () async {
      final readAdapter = FakeAdapter(
        (_) => ResponseBody.fromString('[]', 200),
      );
      final readApi = testApi(readAdapter);
      addTearDown(readApi.close);
      await expectLater(
        readApi.record(['projects', '42', 'issues', '7']),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      final writeAdapter = FakeAdapter(
        (_) => jsonResponse({'message': 'synthetic rejection'}, status: 422),
      );
      final writeApi = testApi(writeAdapter);
      addTearDown(writeApi.close);
      await expectLater(
        writeApi.createIssue(42, {'title': 'Synthetic task'}),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(writeAdapter.requests, hasLength(1));
    },
  );
}
