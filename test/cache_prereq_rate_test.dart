import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);

void main() {
  test(
    'repository archive 429 cools down only the exact archive endpoint',
    () async {
      var archiveRequests = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/repository/archive.zip') ||
            path.endsWith('/repository/archive.tar.gz')) {
          archiveRequests++;
          return jsonResponse(
            const {'message': 'slow down'},
            status: 429,
            headers: const {
              'retry-after': ['60'],
            },
          );
        }
        if (path.endsWith('/repository/files/archive.md') ||
            path.endsWith('/repository/files/archive-repository.md')) {
          return jsonResponse({'file_path': path.split('/').last});
        }
        if (path.endsWith('/repository/tree')) {
          return jsonResponse([
            {
              'id': 'a',
              'name': 'child',
              'type': 'blob',
              'path': 'archive/child',
            },
          ]);
        }
        if (path.endsWith('/search')) {
          return jsonResponse([
            {'id': 1},
          ]);
        }
        if (path.endsWith('/projects') || path.endsWith('/groups')) {
          return jsonResponse(const <Object>[]);
        }
        if (path.endsWith('/projects/8')) {
          return jsonResponse({'id': 8});
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.uri}',
        );
      });
      final api = GitLabApi(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        token: 'synthetic-test-token',
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(api.close);

      await expectLater(
        api
            .record(['projects', '8', 'repository', 'archive.zip'])
            .timeout(_deadline),
        throwsA(
          isA<ApiFailure>()
              .having(
                (failure) => failure.kind,
                'kind',
                FailureKind.rateLimited,
              )
              .having((failure) => failure.status, 'status', 429),
        ),
      );

      expect(
        (await api
            .record(['projects', '8', 'repository', 'files', 'archive.md'])
            .timeout(_deadline))['file_path'],
        'archive.md',
      );
      expect(
        (await api
            .record([
              'projects',
              '8',
              'repository',
              'files',
              'archive-repository.md',
            ])
            .timeout(_deadline))['file_path'],
        'archive-repository.md',
      );
      expect(
        (await api
                .records(
                  ['projects', '8', 'repository', 'tree'],
                  query: const {'path': 'archive/repository'},
                )
                .timeout(_deadline))
            .items,
        hasLength(1),
      );
      expect(
        (await api
                .records(
                  ['search'],
                  query: const {'scope': 'projects', 'search': 'archive'},
                )
                .timeout(_deadline))
            .items,
        hasLength(1),
      );
      expect(
        (await api.records(['projects']).timeout(_deadline)).items,
        isEmpty,
      );
      expect((await api.records(['groups']).timeout(_deadline)).items, isEmpty);
      expect((await api.record(['projects', '8']).timeout(_deadline))['id'], 8);

      await expectLater(
        api
            .record(['projects', '8', 'repository', 'archive.tar.gz'])
            .timeout(_deadline),
        throwsA(
          isA<ApiFailure>()
              .having(
                (failure) => failure.kind,
                'kind',
                FailureKind.rateLimited,
              )
              .having((failure) => failure.status, 'status', 429),
        ),
      );
      expect(archiveRequests, 1);
    },
  );
}
