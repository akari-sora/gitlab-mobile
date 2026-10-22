import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import '../support/fake_adapter.dart';

typedef _Call = Future<Object?> Function(GitLabApi api);

Matcher get _validation => isA<ApiFailure>().having(
  (failure) => failure.kind,
  'kind',
  FailureKind.validation,
);

void main() {
  // §15 row 21: each named wrapper fixes the method, path and body shape.
  final wrappers =
      <(String, String, List<String>, Map<String, Object?>, _Call)>[
        (
          'unapprove MR',
          'POST',
          ['projects', '42', 'merge_requests', '7', 'unapprove'],
          {},
          (api) => api.unapproveMergeRequest(42, 7),
        ),
        (
          'create todo',
          'POST',
          ['projects', '42', 'issues', '7', 'todo'],
          {},
          (api) => api.createTodo(42, 'issues', 7),
        ),
        (
          'create discussion',
          'POST',
          ['projects', '42', 'merge_requests', '7', 'discussions'],
          {'body': 'body'},
          (api) => api.createDiscussion(42, 'merge_requests', 7, 'body'),
        ),
        (
          'create positioned discussion',
          'POST',
          ['projects', '42', 'merge_requests', '7', 'discussions'],
          {
            'body': 'line',
            'position': {'position_type': 'text', 'new_line': 3},
          },
          (api) => api.createDiscussion(
            42,
            'merge_requests',
            7,
            'line',
            position: {'position_type': 'text', 'new_line': 3},
          ),
        ),
        (
          'create discussion note',
          'POST',
          ['projects', '42', 'issues', '7', 'discussions', 'thread', 'notes'],
          {'body': 'reply'},
          (api) => api.createDiscussionNote(42, 'issues', 7, 'thread', 'reply'),
        ),
        (
          'update discussion note',
          'PUT',
          [
            'projects',
            '42',
            'issues',
            '7',
            'discussions',
            'thread',
            'notes',
            '9',
          ],
          {'body': 'edit'},
          (api) =>
              api.updateDiscussionNote(42, 'issues', 7, 'thread', 9, 'edit'),
        ),
        (
          'resolve discussion',
          'PUT',
          ['projects', '42', 'merge_requests', '7', 'discussions', 'thread'],
          {'resolved': true},
          (api) => api.setDiscussionResolved(
            42,
            'merge_requests',
            7,
            'thread',
            true,
          ),
        ),
        (
          'create draft note',
          'POST',
          ['projects', '42', 'merge_requests', '7', 'draft_notes'],
          {'note': 'draft', 'commit_id': 'head'},
          (api) => api.createDraftNote(42, 7, 'draft', commitId: 'head'),
        ),
        (
          'create positioned draft note',
          'POST',
          ['projects', '42', 'merge_requests', '7', 'draft_notes'],
          {
            'note': 'draft',
            'position': {'position_type': 'text', 'old_line': 2},
          },
          (api) => api.createDraftNote(
            42,
            7,
            'draft',
            position: {'position_type': 'text', 'old_line': 2},
          ),
        ),
        (
          'update draft note',
          'PUT',
          ['projects', '42', 'merge_requests', '7', 'draft_notes', '9'],
          {'note': 'edit'},
          (api) => api.updateDraftNote(42, 7, 9, 'edit'),
        ),
        (
          'create label',
          'POST',
          ['projects', '42', 'labels'],
          {'name': 'ready', 'color': '#4763e4', 'description': 'Ready'},
          (api) => api.createLabel(42, {
            'name': 'ready',
            'color': '#4763e4',
            'description': 'Ready',
          }),
        ),
        (
          'update label',
          'PUT',
          ['projects', '42', 'labels', '5'],
          {'new_name': 'done', 'color': '#112233'},
          (api) => api.updateLabel(42, 5, {'name': 'done', 'color': '#112233'}),
        ),
        (
          'create milestone',
          'POST',
          ['projects', '42', 'milestones'],
          {'title': 'M1', 'due_date': '2026-12-31'},
          (api) => api.createMilestone(42, {
            'title': 'M1',
            'due_date': '2026-12-31',
          }),
        ),
        (
          'update milestone',
          'PUT',
          ['projects', '42', 'milestones', '6'],
          {'description': 'Next', 'start_date': null},
          (api) => api.updateMilestone(42, 6, {
            'description': 'Next',
            'start_date': null,
          }),
        ),
        (
          'close milestone',
          'PUT',
          ['projects', '42', 'milestones', '6'],
          {'state_event': 'close'},
          (api) => api.setMilestoneState(42, 6, 'close'),
        ),
        (
          'create board',
          'POST',
          ['projects', '42', 'boards'],
          {'name': 'Delivery'},
          (api) => api.createBoard(42, 'Delivery'),
        ),
        (
          'rename board',
          'PUT',
          ['projects', '42', 'boards', '8'],
          {'name': 'Planning'},
          (api) => api.renameBoard(42, 8, 'Planning'),
        ),
        (
          'hide backlog',
          'PUT',
          ['projects', '42', 'boards', '8'],
          {'hide_backlog_list': true},
          (api) => api.setBoardSystemListHidden(42, 8, 'backlog', true),
        ),
        (
          'show closed',
          'PUT',
          ['projects', '42', 'boards', '8'],
          {'hide_closed_list': false},
          (api) => api.setBoardSystemListHidden(42, 8, 'closed', false),
        ),
        (
          'create board list',
          'POST',
          ['projects', '42', 'boards', '8', 'lists'],
          {'label_id': 11},
          (api) => api.createBoardList(42, 8, 11),
        ),
        (
          'move board list',
          'PUT',
          ['projects', '42', 'boards', '8', 'lists', '12'],
          {'position': 2},
          (api) => api.moveBoardList(42, 8, 12, 2),
        ),
        (
          'move board card',
          'PUT',
          ['projects', '42', 'issues', '7'],
          {'labels': 'ready,backend', 'state_event': 'reopen'},
          (api) => api.moveBoardCard(42, 7, {
            'labels': 'ready,backend',
            'state_event': 'reopen',
          }),
        ),
      ];

  for (final wrapper in wrappers) {
    test('§15 row 21 ${wrapper.$1} has a fixed REST shape', () async {
      final adapter = FakeAdapter(
        (request) =>
            jsonResponse({}, status: request.method == 'POST' ? 201 : 200),
      );
      final api = testApi(adapter);
      addTearDown(api.close);

      await wrapper.$5(api);

      final request = adapter.requests.single;
      expect(request.method, wrapper.$2);
      expect(request.uri.pathSegments, ['gitlab', 'api', 'v4', ...wrapper.$3]);
      expect(request.data, wrapper.$4);
    });
  }

  // §15 row 10: model-controlled maps and string enums are closed sets.
  test(
    '§15 row 10 issue and merge request field allowlists reject unknown keys',
    () {
      final adapter = FakeAdapter((_) => jsonResponse({}));
      final api = testApi(adapter);
      addTearDown(api.close);

      expect(
        () => api.createIssue(42, {'title': 'x', 'web_url': 'https://invalid'}),
        throwsA(_validation),
      );
      expect(
        () => api.createIssue(42, {'title': 'x', 'issue_type': 'epic'}),
        throwsA(_validation),
      );
      expect(
        () => api.updateIssue(42, 7, {'issue_type': 'task'}),
        throwsA(_validation),
      );
      expect(
        () => api.updateIssue(42, 7, {'due_date': '2026-12-31'}),
        throwsA(_validation),
      );
      expect(
        () => api.updateIssue(42, 7, {'state_event': 'delete'}),
        throwsA(_validation),
      );
      expect(
        () =>
            api.createMergeRequest(42, {'title': 'x', 'target_project_id': 99}),
        throwsA(_validation),
      );
      expect(
        () => api.updateMergeRequest(42, 7, {'source_branch': 'other'}),
        throwsA(_validation),
      );
      expect(
        () => api.updateMergeRequest(42, 7, {'state_event': 'merge'}),
        throwsA(_validation),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    '§15 row 10 resource, position and wrapper enums reject before transport',
    () {
      final adapter = FakeAdapter((_) => jsonResponse({}));
      final api = testApi(adapter);
      addTearDown(api.close);

      final calls = <Future<Object?> Function()>[
        () => api.createNote(42, 'snippets', 7, 'body'),
        () => api.updateNote(42, 'epics', 7, 9, 'body'),
        () => api.createTodo(42, 'projects', 7),
        () => api.addAwardEmoji(42, 'snippets', 7, 'thumbsup'),
        () => api.removeAwardEmoji(42, 'snippets', 7, 3),
        () => api.setSubscribed(42, 'snippets', 7, true),
        () => api.createDiscussion(
          42,
          'issues',
          7,
          'body',
          position: {'url': 'invalid'},
        ),
        () => api.createDraftNote(
          42,
          7,
          'body',
          position: {'line_code': 'invalid'},
        ),
        () => api.setMilestoneState(42, 6, 'destroy'),
        () => api.setBoardSystemListHidden(42, 8, 'assignee', true),
        () => api.moveBoardCard(42, 7, {'milestone_id': 1}),
        () => api.moveBoardCard(42, 7, {'state_event': 'destroy'}),
      ];
      for (final call in calls) {
        expect(call, throwsA(_validation));
      }
      expect(adapter.requests, isEmpty);
    },
  );

  test('§15 row 10 label and milestone wrappers reject extra fields', () {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);

    expect(
      () => api.createLabel(42, {'name': 'x', 'priority': 1}),
      throwsA(_validation),
    );
    expect(
      () => api.updateLabel(42, 5, {'name': 'x', 'lock_on_merge': true}),
      throwsA(_validation),
    );
    expect(
      () => api.createMilestone(42, {'title': 'x', 'state_event': 'close'}),
      throwsA(_validation),
    );
    expect(
      () => api.updateMilestone(42, 6, {'title': 'x', 'web_url': 'invalid'}),
      throwsA(_validation),
    );
    expect(adapter.requests, isEmpty);
  });

  test('upload wrapper forwards its optional send timeout', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({'markdown': '[file](/uploads/file)'}),
    );
    final api = testApi(adapter);
    addTearDown(api.close);

    await api.uploadProjectFile(
      42,
      filename: 'file.txt',
      bytes: [1, 2, 3],
      sendTimeout: const Duration(minutes: 2),
    );

    final request = adapter.requests.single;
    expect(request.data, isA<FormData>());
    expect(request.sendTimeout, const Duration(minutes: 2));
  });
}
