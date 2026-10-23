import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import '../support/fake_adapter.dart';

void main() {
  // docs.gitlab.com/api/merge_requests: "Cancel auto merge", introduced in
  // GitLab 19.5, is POST …/merge_requests/:merge_request_iid/cancel_auto_merge.
  // The screen keeps the deprecated endpoint, which every supported version has.
  test(
    'cancel auto-merge wrapper sends the 19.5 path only when asked',
    () async {
      final adapter = FakeAdapter((request) {
        return jsonResponse(<String, Object?>{
          'status': 'success',
        }, status: 201);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await api.cancelAutoMerge(9, 3, newEndpoint: true);
      await api.cancelAutoMerge(9, 3);

      expect(
        adapter.requests.map((request) => (request.method, request.uri.path)),
        <(String, String)>[
          (
            'POST',
            '/gitlab/api/v4/projects/9/merge_requests/3/cancel_auto_merge',
          ),
          (
            'POST',
            '/gitlab/api/v4/projects/9/merge_requests/3/cancel_merge_when_pipeline_succeeds',
          ),
        ],
      );
      expect(
        adapter.requests.every((RequestOptions request) => request.data is Map),
        isTrue,
      );
    },
  );
}
