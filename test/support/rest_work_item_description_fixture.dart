import 'dart:async';
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'fake_adapter.dart';

/// Synthetic stateful transport for REST issue and merge-request details.
/// It answers only the reads a summary tab performs. Unknown endpoints and
/// every write fail with 404 and are recorded, never faked as success.
class RestWorkItemDescriptionFixture {
  late final adapter = FakeAdapter(respond);
  late final api = testApi(adapter);
  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'reader', name: 'Reader'),
    token: 'synthetic-test-token',
  );
  final project = const Project(id: 42, name: 'Example', path: 'team/example');
  static const sha = 'cccccccccccccccccccccccccccccccccccccccc';

  final issues = <int, Json>{};
  final mergeRequests = <int, Json>{};
  final relatedMergeRequests = <int, List<Json>>{};
  final linkedIssues = <int, List<Json>>{};
  final unhandled = <String>[];
  var _revision = 0;

  String _nextRevision() => DateTime.utc(
    2026,
    9,
    2,
  ).add(Duration(minutes: ++_revision)).toIso8601String();

  Map<int, Json> _records(String resource) => switch (resource) {
    'issues' => issues,
    'merge_requests' => mergeRequests,
    _ => throw ArgumentError.value(resource, 'resource'),
  };

  void putIssue(int iid, String description, {String? title}) {
    issues[iid] = {
      'id': 1000 + iid,
      'iid': iid,
      'project_id': 42,
      'title': title ?? 'Issue $iid',
      'description': description,
      'state': 'opened',
      'author': {'id': 9, 'username': 'author', 'name': 'Author'},
      'assignees': <Json>[],
      'labels': <String>[],
      'created_at': '2026-09-01T01:02:03Z',
      'updated_at': _nextRevision(),
    };
  }

  void putMergeRequest(int iid, String description, {String? title}) {
    mergeRequests[iid] = {
      'id': 2000 + iid,
      'iid': iid,
      'project_id': 42,
      'title': title ?? 'Merge request $iid',
      'description': description,
      'state': 'opened',
      'sha': sha,
      'source_branch': 'feature/description',
      'target_branch': 'main',
      'detailed_merge_status': 'mergeable',
      'author': {'id': 9, 'username': 'author', 'name': 'Author'},
      'assignees': <Json>[],
      'reviewers': <Json>[],
      'labels': <String>[],
      'created_at': '2026-09-01T01:02:03Z',
      'updated_at': _nextRevision(),
    };
  }

  /// Changes metadata and the revision; the description stays byte-identical.
  void touchMetadata(
    String resource,
    int iid, {
    List<String> labels = const ['triage'],
  }) {
    final record = _records(resource)[iid]!;
    record['labels'] = [...labels];
    record['updated_at'] = _nextRevision();
  }

  /// Gives an issue [count] related merge requests and [count] linked issues,
  /// rendered as list rows after the description.
  void putRelations(int iid, int count) {
    relatedMergeRequests[iid] = [
      for (var i = 0; i < count; i++)
        {
          'id': 3000 + i,
          'iid': 300 + i,
          'project_id': 42,
          'title': 'Related merge request $i',
          'state': 'opened',
        },
    ];
    linkedIssues[iid] = [
      for (var i = 0; i < count; i++)
        {
          'id': 4000 + i,
          'iid': 400 + i,
          'project_id': 42,
          'title': 'Linked issue $i',
          'state': 'opened',
          'link_type': 'relates_to',
        },
    ];
  }

  void replaceDescription(String resource, int iid, String description) {
    final record = _records(resource)[iid]!;
    record['description'] = description;
    record['updated_at'] = _nextRevision();
  }

  static List<String> _path(RequestOptions request) {
    final segments = request.uri.pathSegments;
    return segments.skip(segments.indexOf('v4') + 1).toList();
  }

  /// GETs of the work item record itself, excluding sub-resources.
  int recordReads(String resource, int iid) => adapter.requests
      .where(
        (request) =>
            request.method == 'GET' &&
            _path(request).join('/') == 'projects/42/$resource/$iid',
      )
      .length;

  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = _path(request);
    if (request.method == 'GET' &&
        path.length >= 4 &&
        path[0] == 'projects' &&
        path[1] == '42') {
      final records = switch (path[2]) {
        'issues' => issues,
        'merge_requests' => mergeRequests,
        _ => null,
      };
      final iid = int.tryParse(path[3]);
      final record = records == null || iid == null ? null : records[iid];
      if (record != null) {
        if (path.length == 4) return jsonResponse(record);
        if (path.length == 5) {
          final tail = path[4];
          if (tail == 'award_emoji') return jsonResponse(<Json>[]);
          if (tail == 'discussions') return jsonResponse(<Json>[]);
          if (path[2] == 'issues' && tail == 'related_merge_requests') {
            return jsonResponse(relatedMergeRequests[iid] ?? <Json>[]);
          }
          if (path[2] == 'issues' && tail == 'links') {
            return jsonResponse(linkedIssues[iid] ?? <Json>[]);
          }
          if (path[2] == 'merge_requests' && tail == 'approvals') {
            return jsonResponse({
              'approved_by': <Json>[],
              'approvals_required': 0,
              'approvals_left': 0,
            });
          }
        }
      }
    }
    unhandled.add('${request.method} ${path.join('/')}');
    return jsonResponse({'message': '404 Not Found'}, status: 404);
  }
}
