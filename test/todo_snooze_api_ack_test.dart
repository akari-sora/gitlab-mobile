import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import 'support/fake_adapter.dart';

void main() {
  for (final (name, fields, succeeds) in <(String, Json, bool)>[
    ('key present with null succeeds', {'snoozedUntil': null}, true),
    ('key omitted is invalid', {}, false),
    (
      'key present with timestamp is invalid',
      {'snoozedUntil': '2030-01-01T00:00:00Z'},
      false,
    ),
  ]) {
    test('unsnoozeTodo acknowledgement: $name', () async {
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        expect(request.method, 'POST');
        expect(request.uri.path, '/gitlab/api/graphql');
        expect(body['query'], contains('todoUnSnooze(input: {id: \$id})'));
        expect(body['query'], contains('todo { id snoozedUntil }'));
        expect(body['variables'], {'id': 'gid://gitlab/Todo/7'});
        return jsonResponse({
          'data': {
            'todoUnSnooze': {
              'todo': {'id': 'gid://gitlab/Todo/7', ...fields},
              'errors': <Object>[],
            },
          },
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      if (succeeds) {
        await expectLater(api.unsnoozeTodo(7), completes);
      } else {
        await expectLater(
          api.unsnoozeTodo(7),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.invalidResponse,
            ),
          ),
        );
      }
      expect(adapter.requests, hasLength(1), reason: 'never replay a mutation');
    });
  }
}
