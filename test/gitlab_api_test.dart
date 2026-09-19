import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/projects/project_controller.dart';
import 'support/fake_adapter.dart';

Matcher failure(FailureKind kind) => isA<ApiFailure>().having((e) => e.kind, 'kind', kind);

void main() {
  test('A04 GET /user validates identity and sends token only in header', () async {
    final adapter = FakeAdapter((_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}));
    final api = testApi(adapter); addTearDown(api.close);
    final user = await api.currentUser();
    expect(user.id, 7);
    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.uri.toString(), 'https://example.com/gitlab/api/v4/user');
    expect(request.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
    expect(request.uri.toString(), isNot(contains('synthetic-test-token')));
    expect(request.followRedirects, isFalse);
    expect(request.maxRedirects, 0);
  });
  for (final pair in [(401, FailureKind.unauthenticated), (403, FailureKind.forbidden),
    (404, FailureKind.invisible), (429, FailureKind.rateLimited),
    (503, FailureKind.server), (302, FailureKind.redirectBlocked)]) {
    test('HTTP ${pair.$1} has distinct semantics; never exposes response body', () async {
      final adapter = FakeAdapter((_) => jsonResponse({'message': 'private-server-content'}, status: pair.$1));
      final api = testApi(adapter); addTearDown(api.close);
      await expectLater(api.currentUser(), throwsA(failure(pair.$2)));
      expect(adapter.requests.length, 1); // No hidden automatic retry.
    });
  }
  test('P01 accessible search omits membership and starred filters', () async {
    final adapter = FakeAdapter((_) => jsonResponse([projectJson(8)]));
    final api = testApi(adapter); addTearDown(api.close);
    await api.projects(scope: ProjectScope.accessibleSearch, search: 'repo');
    expect(adapter.requests.single.uri.queryParameters.containsKey('membership'), isFalse);
    expect(adapter.requests.single.uri.queryParameters.containsKey('starred'), isFalse);
  });
  test('P01 membership filter is explicit', () async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final api = testApi(adapter); addTearDown(api.close);
    await api.projects(scope: ProjectScope.member);
    expect(adapter.requests.single.uri.queryParameters['membership'], 'true');
  });
  test('P01 rejects off-origin continuation before issuing any request', () async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final api = testApi(adapter); addTearDown(api.close);
    expect(() => api.projects(scope: ProjectScope.member,
      next: Uri.parse('https://evil.example/api/v4/projects')), throwsA(failure(FailureKind.unsupported)));
    expect(adapter.requests, isEmpty);
  });
  test('P02 full namespace resolves to a numeric canonical project', () async {
    final adapter = FakeAdapter((_) => jsonResponse(projectJson(8)));
    final api = testApi(adapter); addTearDown(api.close);
    final project = await api.project('team/sub/project');
    expect(project.id, 8);
    expect(adapter.requests.single.uri.pathSegments.last, 'team/sub/project');
  });
  test('R01 tree preserves SHA and path and accepts an empty tree', () async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final api = testApi(adapter); addTearDown(api.close);
    final page = await api.tree(8, 'd' * 40, path: 'lib/nested');
    expect(page.items, isEmpty);
    expect(adapter.requests.single.uri.queryParameters['ref'], 'd' * 40);
    expect(adapter.requests.single.uri.queryParameters['path'], 'lib/nested');
  });
  test('429 Retry-After blocks early manual retry without another network call', () async {
    final adapter = FakeAdapter((_) => jsonResponse({}, status: 429,
      headers: {'retry-after': ['60']}));
    final api = testApi(adapter); addTearDown(api.close);
    await expectLater(api.currentUser(), throwsA(failure(FailureKind.rateLimited)));
    await expectLater(api.currentUser(), throwsA(failure(FailureKind.rateLimited)));
    expect(adapter.requests.length, 1);
  });
  test('R06 branch with slash resolves to a fixed SHA', () async {
    final sha = 'a' * 40;
    final adapter = FakeAdapter((_) => jsonResponse({'commit': {'id': sha}}));
    final api = testApi(adapter); addTearDown(api.close);
    final project = Project.fromJson(projectJson(8, branch: 'feature/session'));
    expect(await api.defaultBranchSha(project), sha);
    expect(adapter.requests.single.uri.pathSegments.last, 'feature/session');
    expect(adapter.requests.single.uri.toString(), contains('feature%2Fsession'));
  });
  test('R02/R04 metadata then exactly one raw fetch, both at same SHA', () async {
    final sha = 'b' * 40;
    final adapter = FakeAdapter((r) => r.method == 'HEAD'
      ? ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['12']})
      : ResponseBody.fromString('hello\nworld', 200));
    final api = testApi(adapter); addTearDown(api.close);
    expect(await api.textFile(8, sha, 'lib/nested.dart'), 'hello\nworld');
    expect(adapter.requests.map((r) => r.method), ['HEAD', 'GET']);
    expect(adapter.requests.every((r) => r.uri.queryParameters['ref'] == sha), isTrue);
    expect(adapter.requests.last.uri.pathSegments.last, 'raw');
    expect(adapter.requests.last.uri.toString(), contains('lib%2Fnested.dart'));
  });
  test('R02 refuses excessive size without raw-content request', () async {
    final adapter = FakeAdapter((_) => ResponseBody.fromString('', 200,
      headers: {'x-gitlab-size': ['999999999']}));
    final api = testApi(adapter); addTearDown(api.close);
    await expectLater(api.textFile(8, 'c' * 40, 'large.bin'), throwsA(failure(FailureKind.tooLarge)));
    expect(adapter.requests.length, 1);
  });
  test('R04 binary file does not become an invalid text preview', () async {
    final adapter = FakeAdapter((r) => ResponseBody.fromString(r.method == 'HEAD' ? '' : 'a\u0000b', 200));
    final api = testApi(adapter); addTearDown(api.close);
    await expectLater(api.textFile(8, 'c' * 40, 'file.bin'), throwsA(failure(FailureKind.unsupported)));
  });
  test('P01 page-two error preserves existing rows and retry cursor', () async {
    final adapter = FakeAdapter((r) => r.uri.queryParameters['page'] == '2'
      ? jsonResponse({}, status: 503)
      : jsonResponse([projectJson(8)], headers: {'x-next-page': ['2']}));
    final api = testApi(adapter); addTearDown(api.close);
    final controller = ProjectController(api); addTearDown(controller.dispose);
    await controller.refresh(); await controller.loadMore();
    expect(controller.items.single.id, 8);
    expect(controller.pageError?.kind, FailureKind.server);
    expect(controller.next?.queryParameters['page'], '2');
  });
  test('P01 stale search response cannot replace a newer scope', () async {
    final slow = Completer<ResponseBody>();
    final adapter = FakeAdapter((r) => r.uri.queryParameters['search'] == 'old'
      ? slow.future : jsonResponse([projectJson(9)]));
    final api = testApi(adapter); addTearDown(api.close);
    final controller = ProjectController(api); addTearDown(controller.dispose);
    final older = controller.search(ProjectScope.member, 'old');
    await Future<void>.delayed(Duration.zero);
    await controller.search(ProjectScope.accessibleSearch, 'new');
    slow.complete(jsonResponse([projectJson(8)])); await older;
    expect(controller.items.single.id, 9);
  });
  test('closed session never sends a new authenticated request', () async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final api = testApi(adapter); api.close();
    await expectLater(api.currentUser(), throwsA(failure(FailureKind.cancelled)));
    expect(adapter.requests, isEmpty);
  });
}
