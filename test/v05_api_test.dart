import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/project_locator.dart';
import 'support/fake_adapter.dart';

void main() {
  group('GitLabLink', () {
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    GitLabLink parse(String input) => GitLabLink.parse(input, instance);

    test('plain paths and IDs open the project', () {
      expect(parse('group/app').target, LinkTarget.project);
      expect(parse('42').project, '42');
      expect(parse('https://example.com/gitlab/group/app').target, LinkTarget.project);
    });

    test('issue, merge request, pipeline and job links name the resource', () {
      final issue = parse('https://example.com/gitlab/group/sub/app/-/issues/12');
      expect((issue.project, issue.target, issue.number), ('group/sub/app', LinkTarget.issue, 12));
      final mr = parse('https://example.com/gitlab/group/app/-/merge_requests/7/diffs');
      expect((mr.target, mr.number), (LinkTarget.mergeRequest, 7));
      expect(parse('https://example.com/gitlab/group/app/-/pipelines/99').target, LinkTarget.pipeline);
      expect(parse('https://example.com/gitlab/group/app/-/jobs/501').number, 501);
      expect(parse('https://example.com/gitlab/group/app/-/work_items/3').target, LinkTarget.issue);
    });

    test('commit and SHA-pinned file links open read-only targets', () {
      final commit = parse('https://example.com/gitlab/group/app/-/commit/0123abcd');
      expect((commit.target, commit.sha), (LinkTarget.commit, '0123abcd'));
      final file = parse('https://example.com/gitlab/group/app/-/blob/0123456789abcdef/lib/main.dart#L42');
      expect((file.target, file.sha, file.filePath, file.line), (LinkTarget.file, '0123456789abcdef', 'lib/main.dart', 42));
    });

    test('branch blob links and malformed numbers fall back to the project', () {
      expect(parse('https://example.com/gitlab/group/app/-/blob/feature/x/lib/main.dart').target, LinkTarget.project);
      expect(parse('https://example.com/gitlab/group/app/-/issues/abc').target, LinkTarget.project);
      expect(parse('https://example.com/gitlab/group/app/-/issues/0').target, LinkTarget.project);
    });

    test('links to another instance are refused', () {
      expect(() => parse('https://gitlab.com/group/app/-/issues/1'), throwsFormatException);
    });
  });

  group('workspace API additions', () {
    late List<RequestOptions> seen;
    GitLabApi apiFor(ResponseBody Function(RequestOptions request) respond) {
      seen = [];
      final adapter = FakeAdapter((request) {
        seen.add(request);
        return respond(request);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      return api;
    }

    test('search scopes instance, project and group endpoints', () async {
      final api = apiFor((_) => jsonResponse([{'id': 1, 'name': 'hit'}]));
      await api.search('projects', ' mobile ');
      await api.search('blobs', 'main', projectId: 42);
      await api.search('issues', 'bug', groupId: 9);
      expect(seen.map((r) => r.uri.path).toList(), [
        '/gitlab/api/v4/search', '/gitlab/api/v4/projects/42/search', '/gitlab/api/v4/groups/9/search',
      ]);
      expect(seen.first.uri.queryParameters, containsPair('search', 'mobile'));
      expect(seen[1].uri.queryParameters, containsPair('scope', 'blobs'));
      expect(() => api.search('projects', '  '), throwsA(isA<ApiFailure>()));
    });

    test('groups, events and award emoji use their documented paths', () async {
      final api = apiFor((request) => request.method == 'POST'
          ? jsonResponse({'id': 5, 'name': 'thumbsup'}, status: 201)
          : request.method == 'DELETE' ? ResponseBody.fromString('', 204) : jsonResponse(<Object>[]));
      await api.groups(search: 'core');
      await api.events();
      await api.events(projectId: 42);
      await api.events(userId: 7);
      await api.awardEmoji(42, 'issues', 3);
      await api.addAwardEmoji(42, 'merge_requests', 4, 'thumbsup');
      await api.removeAwardEmoji(42, 'issues', 3, 5);
      await api.awardEmoji(42, 'issues', 3, note: 11);
      expect(seen.map((r) => '${r.method} ${r.uri.path.replaceFirst('/gitlab/api/v4', '')}').toList(), [
        'GET /groups', 'GET /events', 'GET /projects/42/events', 'GET /users/7/events',
        'GET /projects/42/issues/3/award_emoji', 'POST /projects/42/merge_requests/4/award_emoji',
        'DELETE /projects/42/issues/3/award_emoji/5', 'GET /projects/42/issues/3/notes/11/award_emoji',
      ]);
      expect(seen.first.uri.queryParameters, containsPair('min_access_level', '10'));
      expect(seen[5].data, {'name': 'thumbsup'});
    });

    test('subscribing treats 304 Not Modified as already done', () async {
      final api = apiFor((_) => ResponseBody.fromString('', 304));
      await api.setSubscribed(42, 'issues', 1, true);
      expect(seen.single.uri.path, endsWith('/projects/42/issues/1/subscribe'));
      final failing = apiFor((_) => jsonResponse({'message': '403 Forbidden'}, status: 403));
      await expectLater(failing.setSubscribed(42, 'issues', 1, false), throwsA(isA<ApiFailure>()));
    });

    test('mark all todos done accepts 204 with no body', () async {
      final api = apiFor((_) => ResponseBody.fromString('', 204));
      await api.markAllTodosDone();
      expect('${seen.single.method} ${seen.single.uri.path}', 'POST /gitlab/api/v4/todos/mark_as_done');
    });

    test('languages are sorted largest first and blame is decoded', () async {
      final api = apiFor((request) => request.uri.path.endsWith('/languages')
          ? jsonResponse({'Shell': 2.5, 'Dart': 90.1, 'Kotlin': 7.4})
          : jsonResponse([{'commit': {'id': 'a'}, 'lines': ['one', 'two']}]));
      expect((await api.languages(42)).map((e) => e.$1), ['Dart', 'Kotlin', 'Shell']);
      final ranges = await api.blame(42, 'lib/main.dart', 'abc');
      expect(ranges.single['lines'], ['one', 'two']);
      expect(seen.last.uri.queryParameters, {'ref': 'abc'});
      expect(seen.last.uri.pathSegments, containsAllInOrder(['files', 'lib/main.dart', 'blame']));
    });

    test('blame rejects a non-list body', () async {
      final api = apiFor((_) => jsonResponse({'message': 'unexpected'}));
      await expectLater(api.blame(42, 'a.txt', 'abc'), throwsA(isA<ApiFailure>()));
    });

    test('star state comes from the starrers list for the exact username', () async {
      final api = apiFor((_) => jsonResponse([
        {'starred_since': '2026-01-01', 'user': {'id': 8, 'username': 'developer2'}},
        {'starred_since': '2026-01-01', 'user': {'id': 7, 'username': 'developer'}},
      ]));
      expect(await api.hasStarred(42, 'developer'), isTrue);
      expect(await api.hasStarred(42, 'dev'), isFalse);
      expect(seen.first.uri.queryParameters, containsPair('search', 'developer'));
    });

    test('file history, fork and schedule play target the project', () async {
      final api = apiFor((request) => request.method == 'POST'
          ? jsonResponse({'id': 1, 'path_with_namespace': 'me/app'}, status: 201)
          : jsonResponse(<Object>[]));
      await api.fileHistory(42, 'lib/a.dart', 'main');
      await api.forkProject(42);
      await api.playPipelineSchedule(42, 3);
      expect(seen[0].uri.queryParameters, containsPair('path', 'lib/a.dart'));
      expect(seen[0].uri.queryParameters, containsPair('ref_name', 'main'));
      expect(seen[1].uri.path, endsWith('/projects/42/fork'));
      expect(seen[1].data, <String, dynamic>{});
      expect(seen[2].uri.path, endsWith('/projects/42/pipeline_schedules/3/play'));
    });
  });
}
