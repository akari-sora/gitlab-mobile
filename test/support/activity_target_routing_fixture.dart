import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'fake_adapter.dart';

/// Synthetic server for activity routing tests.
///
/// Events are served from [events]; only project 10 and configured
/// resources (issue 42, issue 377, MR 84, 40-hex and 64-hex commits) resolve.
/// Unknown resources return 404.
final class ActivityEventServer {
  ActivityEventServer(this.events, {this.projectHeaders = const {}});

  final List<Json> events;
  final Map<String, List<String>> projectHeaders;
  final List<RequestOptions> requests = [];
  int eventGets = 0;
  int projectGets = 0;
  int commitGets = 0;
  int diffGets = 0;
  int issueGets = 0;
  int mrGets = 0;

  /// Held project reads, completed by the test to simulate slow lookup / race.
  Future<ResponseBody> Function()? projectGate;

  late final FakeAdapter adapter = FakeAdapter(_respond);

  Future<ResponseBody> _respond(RequestOptions request) async {
    requests.add(request);
    final path = request.uri.path;

    if (request.method == 'GET' &&
        (path.endsWith('/events') || path.contains('/events'))) {
      eventGets++;
      return jsonResponse(events);
    }

    if (request.method == 'GET' && path.endsWith('/user')) {
      return jsonResponse({'id': 7, 'username': 'tester', 'name': 'Tester'});
    }

    if (request.method != 'GET') {
      return jsonResponse({'message': '404 Not Found'}, status: 404);
    }

    if (path.endsWith('/projects/10')) {
      projectGets++;
      final gate = projectGate;
      if (gate != null) return await gate();
      return jsonResponse(activityProject, headers: projectHeaders);
    }

    if (path.endsWith('/projects/10/issues/42')) {
      issueGets++;
      return jsonResponse(activityIssue42);
    }

    if (path.endsWith('/projects/10/issues/377')) {
      issueGets++;
      return jsonResponse(activityIssue377);
    }

    if (path.endsWith('/projects/10/merge_requests/84')) {
      mrGets++;
      return jsonResponse(activityMergeRequest84);
    }

    if (path.endsWith('/projects/10/repository/commits/$activityCommit40Sha')) {
      commitGets++;
      return jsonResponse(activityCommit40);
    }

    if (path.endsWith('/projects/10/repository/commits/$activityCommit64Sha')) {
      commitGets++;
      return jsonResponse(activityCommit64);
    }

    if (path.endsWith('/diff')) {
      diffGets++;
      return jsonResponse(<Json>[]);
    }

    if (path.contains('/repository/commits/')) {
      commitGets++;
      return jsonResponse({'message': '404 Commit Not Found'}, status: 404);
    }

    // Secondary detail-page reads (notes, discussions, reactions, labels) are empty.
    if (path.contains('/projects/10/')) {
      return jsonResponse(<Json>[]);
    }

    return jsonResponse({'message': '404 Not Found'}, status: 404);
  }

  Iterable<RequestOptions> get nonEventRequests =>
      requests.where((r) => !r.uri.path.endsWith('/events'));
}

final activityInstance = GitLabInstance.parse('https://example.com/gitlab');

Account activityAccount({int id = 7, String username = 'tester'}) => Account(
      instance: activityInstance,
      user: GitLabUser(id: id, username: username, name: username),
      token: 'synthetic-test-token-$id',
    );

const activityCommit40Sha = '0123456789abcdef0123456789abcdef01234567';
const activityCommit64Sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Json activityEvent({
  int id = 1,
  int projectId = 10,
  String actionName = 'opened',
  String? targetType,
  int targetId = 100,
  int targetIid = 42,
  String targetTitle = 'Event Target Title',
  String? targetUrl,
  Json? pushData,
  Json? note,
  Json? author = const {'id': 7, 'name': 'Tester', 'username': 'tester'},
  String createdAt = '2026-10-04T00:00:00Z',
}) =>
    {
      'id': id,
      'project_id': projectId,
      'action_name': actionName,
      'target_type': ?targetType,
      'target_id': targetId,
      'target_iid': targetIid,
      'target_title': targetTitle,
      'target_url': ?targetUrl,
      'push_data': ?pushData,
      'note': ?note,
      'author': ?author,
      'created_at': createdAt,
    };

const activityProject = {
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

const activityIssue42 = {
  'id': 501,
  'iid': 42,
  'project_id': 10,
  'title': 'Native issue 42',
  'description': 'Issue body',
  'state': 'opened',
  'author': {'id': 7, 'username': 'tester'},
};

const activityIssue377 = {
  'id': 502,
  'iid': 377,
  'project_id': 10,
  'title': 'Native issue 377',
  'description': 'Project note target',
  'state': 'opened',
  'author': {'id': 7, 'username': 'tester'},
};

const activityMergeRequest84 = {
  'id': 601,
  'iid': 84,
  'project_id': 10,
  'title': 'Native MR 84',
  'description': 'MR body',
  'state': 'opened',
  'author': {'id': 7, 'username': 'tester'},
};

const activityCommit40 = {
  'id': activityCommit40Sha,
  'short_id': '01234567',
  'title': 'Native 40hex commit',
  'message': 'Native 40hex commit',
  'author_name': 'Tester',
  'created_at': '2026-10-04T00:00:00Z',
};

const activityCommit64 = {
  'id': activityCommit64Sha,
  'short_id': '01234567',
  'title': 'Native 64hex commit',
  'message': 'Native 64hex commit',
  'author_name': 'Tester',
  'created_at': '2026-10-04T00:00:00Z',
};

class ActivityFakeUrlLauncher extends UrlLauncherPlatform
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
