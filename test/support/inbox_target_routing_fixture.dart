import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'fake_adapter.dart';

/// Synthetic todo server for the inbox routing tests. Pending todos are
/// served from [todos]; completion removes a row; only project 10 and its
/// issue 42 / commit [inboxCommitSha] resolve, every other project is a 404.
final class InboxTodoServer {
  InboxTodoServer(this.todos);

  final List<Json> todos;
  final List<RequestOptions> requests = [];
  final Set<int> completed = {};
  int todoGets = 0;

  /// Held project reads, completed by the test to simulate a slow lookup.
  Future<ResponseBody> Function()? projectGate;

  late final FakeAdapter adapter = FakeAdapter(_respond);

  Future<ResponseBody> _respond(RequestOptions request) async {
    requests.add(request);
    final path = request.uri.path;
    if (path.endsWith('/todos') && request.method == 'GET') {
      todoGets++;
      return jsonResponse([
        for (final todo in todos)
          if (!completed.contains(todo['id'])) todo,
      ]);
    }
    final done = RegExp(r'/todos/(\d+)/mark_as_done$').firstMatch(path);
    if (done != null && request.method == 'POST') {
      final id = int.parse(done.group(1)!);
      completed.add(id);
      return jsonResponse({'id': id, 'state': 'done'});
    }
    if (request.method != 'GET') {
      return jsonResponse({'message': '404 Not Found'}, status: 404);
    }
    // The other inbox panes list across projects; these tests keep them empty.
    if (path.endsWith('/api/v4/issues') ||
        path.endsWith('/api/v4/merge_requests')) {
      return jsonResponse(<Json>[]);
    }
    if (path.endsWith('/projects/10')) {
      final gate = projectGate;
      if (gate != null) return gate();
      return jsonResponse(inboxProject);
    }
    if (path.endsWith('/projects/10/issues/42')) {
      return jsonResponse(inboxIssue);
    }
    if (path.endsWith('/projects/10/repository/commits/$inboxCommitSha')) {
      return jsonResponse(inboxCommit);
    }
    if (path.endsWith('/projects/10/repository/commits/$inboxCommitSha/diff')) {
      return jsonResponse(<Json>[]);
    }
    // Secondary detail-page reads (discussions, reactions, labels) are empty.
    if (path.contains('/projects/10/')) return jsonResponse(<Json>[]);
    return jsonResponse({'message': '404 Not Found'}, status: 404);
  }

  Iterable<RequestOptions> get nonTodoRequests =>
      requests.where((request) => !request.uri.path.endsWith('/todos'));
}

final inboxInstance = GitLabInstance.parse('https://example.com/gitlab');

Account inboxAccount({int id = 7, String username = 'tester'}) => Account(
  instance: inboxInstance,
  user: GitLabUser(id: id, username: username, name: username),
  token: 'synthetic-test-token-$id',
);

const inboxCommitSha = '0123456789abcdef0123456789abcdef01234567';

Json inboxTodo(
  int id,
  String targetType,
  String title, {
  Json? target,
  Object? targetUrl,
  Json? project = const {'id': 10, 'path_with_namespace': 'team/core'},
}) => {
  'id': id,
  'target_type': targetType,
  'action_name': 'mentioned',
  'target': target ?? {'id': 900 + id, 'title': title},
  'project': ?project,
  'target_url': ?targetUrl,
  'state': 'pending',
  'body': title,
  'created_at': '2026-10-04T00:00:00Z',
};

const inboxProject = {
  'id': 10,
  'name': 'Core',
  'path': 'core',
  'path_with_namespace': 'team/core',
  'description': 'Main repo',
  'visibility': 'private',
  'default_branch': 'main',
  'archived': false,
  'last_activity_at': '2026-10-04T00:00:00Z',
};

const inboxIssue = {
  'id': 501,
  'iid': 42,
  'project_id': 10,
  'title': 'Native issue todo',
  'description': 'Issue body',
  'state': 'opened',
  'author': {'id': 7, 'username': 'tester'},
};

const inboxCommit = {
  'id': inboxCommitSha,
  'short_id': '01234567',
  'title': 'Native commit todo',
  'message': 'Native commit todo',
  'author_name': 'Tester',
  'created_at': '2026-10-04T00:00:00Z',
};

class InboxFakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}
