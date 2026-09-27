import 'dart:async';
import 'dart:convert';
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
  static const olderSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  final issues = <int, Json>{};
  final notes = <int, Json>{};
  final createdMergeRequests = <int, Json>{};
  final labels = <Json>[
    {'id': 1, 'name': 'a', 'color': '#d9534f', 'description': ''},
    {'id': 2, 'name': 'b', 'color': '#428bca', 'description': ''},
  ];
  final members = <Json>[
    {'id': 7, 'username': 'developer', 'name': 'Developer', 'access_level': 30},
    {'id': 8, 'username': 'reviewer', 'name': 'Reviewer', 'access_level': 30},
  ];
  final milestones = <Json>[
    {'id': 101, 'title': 'v1.0.0', 'state': 'active', 'due_date': '2026-10-01'},
    {'id': 102, 'title': 'v1.1.0', 'state': 'active', 'due_date': '2026-11-01'},
  ];
  List<Json> get branches => [
    {'name': 'main', 'default': true, 'protected': true, 'commit': {'id': sha}},
    {'name': 'feature/navigation', 'default': false, 'protected': false, 'commit': {'id': sha}},
  ];
  int counter = 100;
  bool failWrites = false;
  final unhandled = <String>[];
  final extraDiscussions = <Json>[];
  List<Json>? versionDiffs;
  bool omitSeedDiscussions = false;
  int discussionPageCount = 0;
  int? failDiscussionPage;
  int? deferDiscussionOnPage;
  Completer<ResponseBody>? deferDiscussionPage;
  bool deferDiscussionOnce = false;
  bool copyDiscussionPages = false;
  String versionBaseSha = sha;
  String versionStartSha = sha;
  String versionHeadSha = sha;
  bool _discussionDeferred = false;
  List<Json>? _pagedDiscussions;
  List<Json>? _storedDiscussions;
  var _discussionsOverridden = false;
  List<List<Json>>? discussionPages;
  bool failDiscussions = false;
  Json? testReportSummaryRecord;
  Json? testReportRecord;
  // Reading this marks the list as caller-owned so the default seed is not inserted.
  List<Json> get mrDiscussions {
    _discussionsOverridden = true;
    return _storedDiscussions ??= <Json>[];
  }
  List<Json> get mergeRequestDiscussions => storedDiscussions;
  Json issue(int iid, String title, {bool confidential = false, Json? milestone}) => {
    'id': iid + 1000, 'iid': iid, 'project_id': 42, 'title': title, 'description': '## Overview\nA synthetic issue for UI verification.',
    'state': 'opened', 'author': {'id': 7, 'username': 'developer'}, 'assignees': <Json>[], 'labels': <String>[],
    'confidential': confidential,
    'milestone': ?milestone,
    'updated_at': 'revision-$counter', 'created_at': '2026-09-19T08:00:00Z',
  };
  int mrAuthorId = 7;
  final approvalsList = <Json>[];
  int approvalsRequired = 1;
  final mergeFields = <String, dynamic>{};
  Json get mergeRequest => {
    ...issue(12, 'Improve private-project navigation'),
    'author': {'id': mrAuthorId, 'username': mrAuthorId == 7 ? 'developer' : 'external_author'},
    'source_branch': 'feature/navigation', 'target_branch': 'main', 'sha': sha,
    'detailed_merge_status': 'mergeable', 'draft': false,
    'head_pipeline': {'id': 99, 'status': 'success'},
    ...mergeFields,
  };
  Json _textThread({
    required String id, required String body, required String username, required int noteId,
    required String base, required String start, required String head, required String path,
    int? newLine, int? oldLine, bool resolvable = false, bool resolved = false,
  }) => {
    'id': id, 'individual_note': false,
    'notes': [
      {
        'id': noteId, 'body': body, 'author': {'id': noteId, 'username': username},
        'created_at': '2026-09-19T08:00:00Z', 'system': false,
        'resolvable': resolvable, 'resolved': resolved,
        'position': {
          'position_type': 'text', 'base_sha': base, 'start_sha': start, 'head_sha': head,
          'old_path': path, 'new_path': path,
          'old_line': ?oldLine,
          'new_line': ?newLine,
        },
      },
    ],
  };
  List<Json> get storedDiscussions {
    if (_discussionsOverridden) return _storedDiscussions ??= <Json>[];
    return _storedDiscussions ??= _seedDiscussions();
  }
  List<Json> _seedDiscussions() => [
    {
      ..._textThread(
        id: 'anchored-1', body: 'ANCHORED-THREAD-BODY', username: 'developer', noteId: 1,
        base: sha, start: sha, head: sha, path: 'lib/session.dart', newLine: 1, resolvable: true,
      ),
      'notes': [
        {
          'id': 1, 'body': 'ANCHORED-THREAD-BODY', 'author': {'id': 7, 'username': 'developer'},
          'created_at': '2026-09-19T08:00:00Z', 'system': false, 'resolvable': true, 'resolved': false,
          'position': {
            'position_type': 'text', 'base_sha': sha, 'start_sha': sha, 'head_sha': sha,
            'old_path': 'lib/session.dart', 'new_path': 'lib/session.dart', 'new_line': 1,
          },
        },
        {
          'id': 11, 'body': 'SECOND-NOTE-VISIBLE', 'author': {'id': 8, 'username': 'reviewer'},
          'created_at': '2026-09-19T09:00:00Z', 'system': false, 'resolvable': true, 'resolved': false,
        },
        {
          'id': 12, 'body': 'THIRD-NOTE-HIDDEN', 'author': {'id': 7, 'username': 'developer'},
          'created_at': '2026-09-19T10:00:00Z', 'system': false, 'resolvable': true, 'resolved': false,
        },
      ],
    },
    _textThread(
      id: 'older-1', body: 'OLDER-VERSION-THREAD', username: 'reviewer', noteId: 2,
      base: olderSha, start: olderSha, head: olderSha, path: 'lib/session.dart', newLine: 1, resolvable: true,
    ),
    {
      'id': 'general-1', 'individual_note': true,
      'notes': [
        {
          'id': 3, 'body': 'GENERAL-NOTE-SHOULD-NOT-APPEAR',
          'author': {'id': 7, 'username': 'developer'}, 'created_at': '2026-09-19T11:00:00Z', 'system': false,
        },
      ],
    },
  ];
  Json? _thread(String id) {
    for (final item in storedDiscussions) {
      if (item['id'] == id) return item;
    }
    final paged = _pagedDiscussions;
    if (paged != null) {
      for (final item in paged) {
        if (item['id'] == id) return item;
      }
    }
    return null;
  }

  Json _cloneDiscussion(Json value) {
    final decoded = jsonDecode(jsonEncode(value));
    if (decoded is! Json) throw StateError('discussion copy');
    return decoded;
  }

  Json _pageThread(int page) => {
    'id': 'page-$page', 'individual_note': false,
    'notes': [
      {
        'id': page, 'body': 'PAGE-$page-THREAD', 'author': {'id': 7, 'username': 'developer'},
        'created_at': '2026-09-19T08:00:00Z', 'system': false, 'resolvable': false, 'resolved': false,
        'position': {
          'position_type': 'text', 'base_sha': sha, 'start_sha': sha, 'head_sha': sha,
          'old_path': 'lib/session.dart', 'new_path': 'lib/session.dart', 'new_line': 1,
        },
      },
    ],
  };

  List<Json> _storedPages() => _pagedDiscussions ??= [
    for (var page = 1; page <= discussionPageCount; page++) _pageThread(page),
  ];

  FutureOr<ResponseBody> _discussionPage(RequestOptions request) {
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '1') ?? 1;
    if (discussionPageCount > 0) {
      if (failDiscussionPage != null && page >= failDiscussionPage!) {
        return jsonResponse({'message': 'unavailable'}, status: 500);
      }
      final deferred = deferDiscussionPage;
      if (deferDiscussionOnPage == page && deferred != null &&
          (!deferDiscussionOnce || !_discussionDeferred)) {
        _discussionDeferred = true;
        return deferred.future;
      }
      final headers = page < discussionPageCount
          ? {'x-next-page': ['${page + 1}']}
          : <String, List<String>>{};
      final thread = copyDiscussionPages ? _storedPages()[page - 1] : _pageThread(page);
      return jsonResponse([
        copyDiscussionPages ? _cloneDiscussion(thread) : thread,
      ], headers: headers);
    }
    return jsonResponse([
      if (!omitSeedDiscussions) ...storedDiscussions,
      ...extraDiscussions,
    ]);
  }

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
      return jsonResponse(_matching(branches, request.uri.queryParameters['search'], const ['name']));
    }
    if (joined == 'projects/42/labels') {
      return jsonResponse(_matching(labels, request.uri.queryParameters['search'], const ['name']));
    }
    if (joined == 'projects/42/members/all') {
      return jsonResponse(_matching(members, request.uri.queryParameters['query'], const ['username', 'name']));
    }
    if (joined == 'projects/42/milestones') {
      return jsonResponse(_matching(milestones, request.uri.queryParameters['search'], const ['title']));
    }
    if (joined == 'projects/42/uploads' && method == 'POST') {
      var name = 'file';
      final data = request.data;
      if (data is FormData && data.files.isNotEmpty) {
        name = data.files.first.value.filename ?? name;
      }
      return jsonResponse({
        'markdown': '![$name](/uploads/test/$name)',
        'url': '/uploads/test/$name',
        'full_path': '/studio/mobile-workspace/uploads/test/$name',
      }, status: 201);
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
      final mId = body['milestone_id'];
      final matchingMilestone = mId is int && mId > 0
          ? milestones.cast<Json?>().firstWhere((m) => m?['id'] == mId, orElse: () => null)
          : null;
      issues[iid] = {
        ...issue(iid, body['title'] as String),
        ...body,
        'milestone': ?matchingMilestone,
      };
      return jsonResponse(issues[iid], status: 201);
    }
    if (joined == 'projects/42/issues') {
      final state = request.uri.queryParameters['state'];
      final search = request.uri.queryParameters['search'];
      var list = issues.values.where((v) => state == null || state == 'all' || v['state'] == state);
      if (search != null && search.isNotEmpty) {
        final query = search.toLowerCase();
        list = list.where((v) => (v['title'] as String? ?? '').toLowerCase().contains(query));
      }
      return jsonResponse(list.toList());
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
          if (body.containsKey('milestone_id')) {
            final mId = body['milestone_id'];
            if (mId is int && mId > 0) {
              final matching = milestones.cast<Json?>().firstWhere((m) => m?['id'] == mId, orElse: () => null);
              if (matching != null) item['milestone'] = matching;
            } else {
              item.remove('milestone');
            }
          }
          if (body.containsKey('assignee_ids')) {
            final ids = (body['assignee_ids'] as List<dynamic>?)?.map((e) => int.tryParse('$e') ?? 0).where((id) => id > 0).toSet() ?? <int>{};
            item['assignees'] = members.where((m) => ids.contains(m['id'])).toList();
          }
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
    if (joined == 'projects/42/merge_requests' && method == 'POST') {
      final iid = ++counter;
      createdMergeRequests[iid] = {
        ...mergeRequest, ...body, 'iid': iid, 'title': body['title'] ?? mergeRequest['title'], 'updated_at': 'revision-$counter',
      };
      return jsonResponse(createdMergeRequests[iid], status: 201);
    }
    if (joined == 'projects/42/merge_requests') { return jsonResponse([mergeRequest]); }
    if (path.length == 4 && path[0] == 'projects' && path[1] == '42' && path[2] == 'merge_requests') {
      final iid = int.tryParse(path[3]);
      final created = iid == null ? null : createdMergeRequests[iid];
      if (created != null) return jsonResponse(created);
    }
    if (joined == 'projects/42/merge_requests/12') {
      if (method == 'PUT') {
        mergeRequest.addAll(body);
        if (body.containsKey('assignee_ids')) {
          final ids = (body['assignee_ids'] as List<dynamic>?)?.map((e) => int.tryParse('$e') ?? 0).where((id) => id > 0).toSet() ?? <int>{};
          mergeRequest['assignees'] = members.where((m) => ids.contains(m['id'])).toList();
        }
        if (body.containsKey('reviewer_ids')) {
          final ids = (body['reviewer_ids'] as List<dynamic>?)?.map((e) => int.tryParse('$e') ?? 0).where((id) => id > 0).toSet() ?? <int>{};
          mergeRequest['reviewers'] = members.where((m) => ids.contains(m['id'])).toList();
        }
        mergeRequest['updated_at'] = 'revision-${++counter}';
        return jsonResponse(mergeRequest);
      }
      return jsonResponse(mergeRequest);
    }
    if (path.length >= 5 && path[0] == 'projects' && path[1] == '42' && path[2] == 'merge_requests' && path[3] == '12' && path[4] == 'discussions') {
      if (path.length == 5 && method == 'GET') {
        if (failDiscussions) { return jsonResponse({'message': 'synthetic'}, status: 500); }
        final pages = discussionPages;
        if (pages != null) {
          final page = int.tryParse(request.uri.queryParameters['page'] ?? '') ?? 1;
          final index = page - 1;
          final items = index >= 0 && index < pages.length ? pages[index] : const <Json>[];
          if (page < pages.length) {
            return jsonResponse(items, headers: {'x-next-page': ['${page + 1}']});
          }
          return jsonResponse(items);
        }
        return _discussionPage(request);
      }
      if (path.length == 5 && method == 'POST') {
        final created = <String, dynamic>{
          'id': 'created-${++counter}', 'individual_note': false, 'notes': [
            {'id': counter, 'body': body['body'], 'author': {'id': 7, 'username': 'developer'}, 'created_at': '2026-09-19T12:00:00Z', 'system': false},
          ],
        };
        storedDiscussions.add(created);
        return jsonResponse(created, status: 201);
      }
      if (path.length == 6 && method == 'PUT') {
        final thread = _thread(path[5]);
        if (thread == null) return jsonResponse({'error': 'missing'}, status: 404);
        final resolved = body['resolved'] == true;
        thread['resolved'] = resolved;
        final notes = thread['notes'];
        if (notes is List<dynamic>) {
          for (final note in notes) {
            if (note is Json && note['resolvable'] == true) {
              note['resolved'] = resolved;
            }
          }
        }
        return jsonResponse(thread);
      }
      if (path.length == 7 && path[6] == 'notes' && method == 'POST') {
        final thread = _thread(path[5]);
        if (thread == null) return jsonResponse({'error': 'missing'}, status: 404);
        final note = <String, dynamic>{
          'id': ++counter, 'body': body['body'], 'author': {'id': 7, 'username': 'developer'},
          'created_at': '2026-09-19T12:00:00Z', 'system': false, 'resolvable': false, 'resolved': false,
        };
        final notes = thread['notes'];
        final existing = notes is List<dynamic> ? notes : const <dynamic>[];
        thread['notes'] = <dynamic>[...existing, note];
        return jsonResponse(note, status: 201);
      }
    }
    if (joined == 'projects/42/merge_requests/12/merge' && method == 'PUT') {
      if (body['auto_merge'] == true || body['merge_when_pipeline_succeeds'] == true || body['auto_merge_strategy'] == 'merge_when_pipeline_succeeds') {
        mergeFields['merge_when_pipeline_succeeds'] = true;
        mergeFields['auto_merge_enabled'] = true;
        mergeFields['merge_user'] = {'id': 7, 'username': 'developer', 'name': 'Developer'};
        return jsonResponse({...mergeRequest, 'merge_when_pipeline_succeeds': true, 'auto_merge_enabled': true});
      }
      return jsonResponse({...mergeRequest, 'state': 'merged'});
    }
    if (joined == 'projects/42/merge_requests/12/cancel_merge_when_pipeline_succeeds' && method == 'POST') {
      mergeFields['merge_when_pipeline_succeeds'] = false;
      mergeFields['auto_merge_enabled'] = false;
      mergeFields.remove('merge_user');
      return jsonResponse({...mergeRequest, 'merge_when_pipeline_succeeds': false, 'auto_merge_enabled': false});
    }
    if (joined == 'projects/42/merge_requests/12/approvals') {
      return jsonResponse({
        'id': 12, 'iid': 12, 'project_id': 42,
        'title': 'Improve private-project navigation',
        'approvals_required': approvalsRequired,
        'approvals_left': (approvalsRequired - approvalsList.length).clamp(0, 99),
        'approved_by': approvalsList,
      });
    }
    if (joined == 'projects/42/merge_requests/12/approve' && method == 'POST') {
      if (!approvalsList.any((v) => v['user']?['id'] == account.user.id)) {
        approvalsList.add({'user': account.user.toJson()});
      }
      return jsonResponse({
        'id': 12, 'iid': 12, 'project_id': 42,
        'title': 'Improve private-project navigation',
        'approvals_required': approvalsRequired,
        'approvals_left': (approvalsRequired - approvalsList.length).clamp(0, 99),
        'approved_by': approvalsList,
      });
    }
    if (joined == 'projects/42/merge_requests/12/unapprove' && method == 'POST') {
      approvalsList.removeWhere((v) => v['user']?['id'] == account.user.id);
      return jsonResponse({
        'id': 12, 'iid': 12, 'project_id': 42,
        'title': 'Improve private-project navigation',
        'approvals_required': approvalsRequired,
        'approvals_left': (approvalsRequired - approvalsList.length).clamp(0, 99),
        'approved_by': approvalsList,
      });
    }
    if (joined == 'projects/42/merge_requests/12/rebase' && method == 'POST') {
      mergeFields['rebase_in_progress'] = true;
      return jsonResponse({'rebase_in_progress': true});
    }
    if (joined == 'projects/42/merge_requests/12/versions') { return jsonResponse([{'id': 1, 'head_commit_sha': versionHeadSha}]); }
    if (joined == 'projects/42/merge_requests/12/versions/1') {
      return jsonResponse({'id': 1, 'head_commit_sha': versionHeadSha, 'base_commit_sha': versionBaseSha, 'start_commit_sha': versionStartSha, 'diffs': versionDiffs ?? [
        {'old_path': 'lib/session.dart', 'new_path': 'lib/session.dart', 'diff': '@@ -1 +1 @@\n-old\n+new\n'},
      ]});
    }
    if (joined == 'projects/42/pipeline' && method == 'POST') {
      final body = request.data is Json ? request.data as Json : <String, dynamic>{};
      return jsonResponse({
        ...pipeline,
        'ref': body['ref'] ?? 'main',
        if (body['variables'] != null) 'variables': body['variables'],
      }, status: 201);
    }
    if (joined == 'projects/42/pipelines') { return jsonResponse([pipeline]); }
    if (joined == 'projects/42/pipelines/99') { return jsonResponse(pipeline); }
    if (joined == 'projects/42/pipelines/99/jobs') { return jsonResponse([job(501), job(502, status: 'manual')]); }
    if (path.length == 5 && path[0] == 'projects' && path[1] == '42' && path[2] == 'pipelines' && path[4] == 'test_report_summary') {
      return jsonResponse(testReportSummaryRecord ?? {
        'total': {
          'time': 42.0, 'count': 2, 'success': 2, 'failed': 0, 'skipped': 0, 'error': 0, 'suite_error': null,
        },
        'test_suites': [
          {
            'name': 'unit', 'total_time': 42.0, 'total_count': 2, 'success_count': 2,
            'failed_count': 0, 'skipped_count': 0, 'error_count': 0, 'suite_error': null,
          }
        ],
      });
    }
    if (path.length == 5 && path[0] == 'projects' && path[1] == '42' && path[2] == 'pipelines' && path[4] == 'test_report') {
      return jsonResponse(testReportRecord ?? {
        'total_time': 42.0, 'total_count': 2, 'success_count': 2, 'failed_count': 0, 'skipped_count': 0, 'error_count': 0,
        'test_suites': [
          {
            'name': 'unit', 'total_time': 42.0, 'total_count': 2, 'success_count': 2,
            'failed_count': 0, 'skipped_count': 0, 'error_count': 0, 'suite_error': null,
            'test_cases': [
              {
                'status': 'success', 'name': 'test_one', 'classname': 'AppTest',
                'file': 'test/app_test.dart', 'execution_time': 21.0,
                'system_output': null, 'stack_trace': null, 'job_id': 501,
              },
              {
                'status': 'success', 'name': 'test_two', 'classname': 'AppTest',
                'file': 'test/app_test.dart', 'execution_time': 21.0,
                'system_output': null, 'stack_trace': null, 'job_id': 501,
              },
            ],
          }
        ],
      });
    }
    if (joined == 'projects/42/jobs/501') { return jsonResponse(job(501)); }
    if (joined == 'projects/42/jobs/502') { return jsonResponse(job(502, status: 'manual')); }
    if (joined == 'projects/42/jobs/501/trace') { return ResponseBody.fromString('flutter analyze\nNo issues found.\nAll tests passed.\n', 200); }
    if (joined == 'projects/42/jobs/502/trace') { return jsonResponse({}, status: 404); }
    if (path.length > 4 && path[0] == 'projects' && path[1] == '42' && path[2] == 'merge_requests') {
      final tail = path.sublist(4).join('/');
      if (tail == 'approvals') return jsonResponse({'approved_by': <Json>[]});
      if (tail == 'discussions' && method == 'GET') return jsonResponse([]);
      if (tail == 'versions') return jsonResponse([{'id': 1, 'head_commit_sha': sha}]);
      if (tail == 'versions/1') {
        return jsonResponse({
          'id': 1, 'head_commit_sha': sha, 'base_commit_sha': sha, 'start_commit_sha': sha, 'diffs': <Json>[],
        });
      }
    }
    if (const ['projects/42/milestones', 'projects/42/releases',
      'projects/42/repository/tags', 'projects/42/repository/commits'].contains(joined)) { return jsonResponse([]); }
    unhandled.add('$method $joined');
    return jsonResponse({'error': 'unhandled-synthetic-endpoint'}, status: 404);
  }

  List<Json> _matching(List<Json> items, String? query, List<String> keys) {
    final needle = query ?? '';
    if (needle.isEmpty) return items;
    return [
      for (final item in items)
        if (keys.any((key) => '${item[key] ?? ''}'.contains(needle))) item,
    ];
  }
}
