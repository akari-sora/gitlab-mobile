import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/repository_reader.dart';

import '../support/fake_adapter.dart';

void main() {
  test(
    'online reader delegates identical tree, text and media calls',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/tree')) return jsonResponse([]);
        if (request.method == 'HEAD') {
          return jsonResponse(
            null,
            headers: {
              'x-gitlab-size': ['6'],
            },
          );
        }
        return jsonResponse('hello');
      });
      final api = testApi(adapter)
        ..bindReadCache('https://example.com/gitlab#1', 7);
      const owner = ReaderOwner(
        accountKey: 'https://example.com/gitlab#1',
        generation: 7,
        instanceKey: 'https://example.com/gitlab',
        projectId: 42,
        sha: 'main',
        subPath: '',
      );
      final reader = OnlineRepositoryReader(api: api, owner: owner);
      await reader.tree('docs');
      expect(adapter.requests.single.uri.queryParameters, {
        'ref': 'main',
        'path': 'docs',
        'per_page': '50',
      });
      await reader.text('docs/readme');
      expect(adapter.requests.length, 3);
      expect(adapter.requests[1].method, 'HEAD');
      expect(adapter.requests[2].uri.path, endsWith('/raw'));
      expect(reader.capabilities.ai, isTrue);
      api.close();
      await expectLater(
        reader.tree('docs'),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
    },
  );
}
