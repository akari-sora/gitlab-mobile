import 'dart:async';
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'fake_adapter.dart';

/// Synthetic stateful transport, not a claim of GitLab-server conformance.
/// Unknown endpoints fail with 404 instead of returning blanket fake success.
class WorkspaceFixture {
  late final adapter = FakeAdapter(respond);
  late final api = testApi(adapter);
  Account get account => Account(instance: api.instance,
    user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'), token: 'synthetic-test-token');
  Project get project => Project.fromJson(projectRecord);
  final Json projectRecord = {
    'id': 42, 'name': 'Mobile Workspace', 'path_with_namespace': 'studio/mobile-workspace',
    'description': 'A focused space for code, reviews and delivery.', 'visibility': 'private',
    'default_branch': 'main', 'archived': false, 'last_activity_at': '2026-09-19T08:30:00Z',
  };
  static const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final issues = <int, Json>{};
  final notes = <int, Json>{};
  int counter = 100;
  bool failWrites = false;
  final unhandled = <String>[];
  Json issue(int iid, String title) => {
    'id': iid + 1000, 'iid': iid, 'project_id': 42, 'title': title, 'description': '## Overview\nA synthetic issue for UI verification.',
    'state': 'opened', 'author': {'id': 7, 'username': 'developer'}, 'assignees': <Json>[], 'labels': <String>[],
    'updated_at': 'revision-$counter', 'created_at': '2026-09-19T08:00:00Z',
  };
  Json get mergeRequest => {
    ...issue(12, 'Improve private-project navigation'),
    'source_branch': 'feature/navigation', 'target_branch': 'main', 'sha': sha,
    'detailed_merge_status': 'mergeable', 'draft': false,
    'head_pipeline': {'id': 99, 'status': 'success'},
  };
  Json get pipeline => {'id': 99, 'ref': 'main', 'sha': sha, 'status': 'success', 'duration': 83};
  Json job(int id, {String status = 'success'}) => {
    'id': id, 'name': id == 502 ? 'Manual deploy' : 'Flutter tests', 'stage': 'verify', 'status': status,
    'artifacts_file': {'filename': 'artifacts.zip'},
  };
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final start = segments.indexOf('v4');
    final path = segments.skip(start + 1).toList();
    final joined = path.join('/');
    final method = request.method;
    final body = request.data is Json ? request.data as Json : <String, dynamic>{};
    if (method != 'GET' && method != 'HEAD' && failWrites) { return jsonResponse({'error': 'validation'}, status: 422); }
    if (joined == 'user') { return jsonResponse(account.user.toJson()); }
    if (joined == 'projects') { return jsonResponse([projectRecord]); }
    if (joined == 'todos' || joined == 'issues') { return jsonResponse([]); }
    if (joined == 'merge_requests') { return jsonResponse([mergeRequest]); }
    if (joined == 'projects/42') { return jsonResponse(projectRecord); }
    if (joined == 'projects/42/repository/branches') {
      return jsonResponse([{'name': 'main', 'default': true, 'protected': true, 'commit': {'id': sha}}]);
    }
    if (joined == 'projects/42/repository/branches/main') { return jsonResponse({'name': 'main', 'commit': {'id': sha}}); }
    if (joined == 'projects/42/repository/tree') {
      return jsonResponse([
        {'id': '1', 'name': 'lib', 'path': 'lib', 'type': 'tree', 'mode': '040000'},
        {'id': '2', 'name': 'README.md', 'path': 'README.md', 'type': 'blob', 'mode': '100644'},
      ]);
    }
    if (joined == 'projects/42/repository/files/README.md' && method == 'HEAD') {
      return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['80'], 'x-gitlab-last-commit-id': [sha]});
    }
    if (joined == 'projects/42/repository/files/README.md/raw') {
      return ResponseBody.fromString('# Mobile Workspace\n\nFocused collaboration, built for your phone.\n', 200);
    }
    if (joined == 'projects/42/issues' && method == 'POST') {
      final iid = ++counter;
      issues[iid] = {...issue(iid, body['title'] as String), ...body};
      return jsonResponse(issues[iid], status: 201);
    }
    if (joined == 'projects/42/issues') {
      final state = request.uri.queryParameters['state'];
      return jsonResponse(issues.values.where((v) => state == null || state == 'all' || v['state'] == state).toList());
    }
    if (path.length >= 4 && path[0] == 'projects' && path[1] == '42' && path[2] == 'issues') {
      final iid = int.tryParse(path[3]);
      final item = issues[iid];
      if (item == null) { return jsonResponse({}, status: 404); }
      if (path.length == 4) {
        if (method == 'DELETE') { issues.remove(iid); return ResponseBody.fromString('', 204); }
        if (method == 'PUT') {
          item.addAll(body);
          if (body['state_event'] != null) { item['state'] = body['state_event'] == 'close' ? 'closed' : 'opened'; }
          item['updated_at'] = 'revision-${++counter}';
        }
        return jsonResponse(item);
      }
      if (path[4] == 'discussions') {
        return jsonResponse(notes.values.map((v) => {'id': 'thread-${v['id']}', 'individual_note': true, 'notes': [v]}).toList());
      }
      if (path[4] == 'notes') {
        if (path.length == 5 && method == 'POST') {
          final id = ++counter;
          notes[id] = {'id': id, 'body': body['body'], 'author': {'id': 7, 'username': 'developer'}, 'system': false};
          return jsonResponse(notes[id], status: 201);
        }
        final id = path.length > 5 ? int.tryParse(path[5]) : null;
        if (id != null && method == 'DELETE') { notes.remove(id); return ResponseBody.fromString('', 204); }
        if (id != null && notes.containsKey(id)) {
          if (method == 'PUT') { notes[id]!.addAll(body); }
          return jsonResponse(notes[id]);
        }
      }
    }
    if (joined == 'projects/42/merge_requests') { return jsonResponse([mergeRequest]); }
    if (joined == 'projects/42/merge_requests/12') { return jsonResponse(mergeRequest); }
    if (joined == 'projects/42/merge_requests/12/discussions') { return jsonResponse([]); }
    if (joined == 'projects/42/merge_requests/12/approvals') { return jsonResponse({'approved_by': <Json>[]}); }
    if (joined == 'projects/42/merge_requests/12/versions') { return jsonResponse([{'id': 1, 'head_commit_sha': sha}]); }
    if (joined == 'projects/42/merge_requests/12/versions/1') {
      return jsonResponse({'id': 1, 'head_commit_sha': sha, 'base_commit_sha': sha, 'start_commit_sha': sha, 'diffs': [
        {'old_path': 'lib/session.dart', 'new_path': 'lib/session.dart', 'diff': '@@ -1 +1 @@\n-old\n+new\n'},
      ]});
    }
    if (joined == 'projects/42/pipelines') { return jsonResponse([pipeline]); }
    if (joined == 'projects/42/pipelines/99') { return jsonResponse(pipeline); }
    if (joined == 'projects/42/pipelines/99/jobs') { return jsonResponse([job(501), job(502, status: 'manual')]); }
    if (joined == 'projects/42/jobs/501') { return jsonResponse(job(501)); }
    if (joined == 'projects/42/jobs/502') { return jsonResponse(job(502, status: 'manual')); }
    if (joined == 'projects/42/jobs/501/trace') { return ResponseBody.fromString('flutter analyze\nNo issues found.\nAll tests passed.\n', 200); }
    if (joined == 'projects/42/jobs/502/trace') { return jsonResponse({}, status: 404); }
    if (const ['projects/42/labels', 'projects/42/milestones', 'projects/42/releases',
      'projects/42/repository/tags', 'projects/42/repository/commits'].contains(joined)) { return jsonResponse([]); }
    unhandled.add('$method $joined');
    return jsonResponse({'error': 'unhandled-synthetic-endpoint'}, status: 404);
  }
}
