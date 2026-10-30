import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../core/gitlab_api.dart' show Json;
import 'demo_data.dart';
import 'demo_scope.dart';

/// Answers every GitLab request of the demo on the device. Nothing is ever
/// forwarded: unknown lists are empty, unknown records are 404, and changes
/// other than new issues, new comments and closing or reopening an issue are
/// refused with 403.
final class DemoGitLabAdapter implements HttpClientAdapter {
  DemoGitLabAdapter(this.server);

  final DemoGitLabServer server;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => server.handle(options);

  @override
  void close({bool force = false}) {}
}

/// The demo's GitLab: the sample data plus what the user adds during one
/// visit. It keeps no state outside this object.
final class DemoGitLabServer {
  DemoGitLabServer({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _seed();
  }

  final DateTime Function() _clock;
  final planner = demoPlanner();
  final notes = demoNotes();
  late final Map<int, DemoProject> _projects = {
    planner.id: planner,
    notes.id: notes,
  };

  /// Issues and merge requests by project, then iid.
  final Map<int, Map<int, Json>> _issues = {};
  final Map<int, Map<int, Json>> _mergeRequests = {};

  /// Discussions by `<project>/<issues|merge_requests>/<iid>`.
  final Map<String, List<Json>> _discussions = {};
  int _nextId = 7000;

  /// Requests the demo has no answer for, for tests (`METHOD path`).
  final List<String> unhandled = [];

  /// Every request answered, for tests (`METHOD path`).
  final List<String> requests = [];

  String get _now => _clock().toUtc().toIso8601String();

  // ---------------------------------------------------------------- seed

  void _seed() {
    final p = planner;
    _issues[p.id] = {
      1: _issue(
        p,
        iid: 1,
        title: 'Tasks with an empty title can be saved',
        description:
            'Steps to reproduce:\n\n1. Tap **Add task**\n2. Leave the title '
            'empty\n3. Tap **Save**\n\nThe task is saved without a title. '
            '`Task.create` should reject a blank title.',
        state: 'opened',
        author: 4102,
        assignees: [demoUserId],
        labels: ['bug'],
        milestone: true,
        created: '2026-10-20T09:14:00.000Z',
        updated: '2026-10-27T10:02:00.000Z',
      ),
      2: _issue(
        p,
        iid: 2,
        title: 'Add due dates to tasks',
        description:
            'Let people set an optional due date and sort the list by it.\n\n'
            '- [x] Store the date on `Task`\n- [ ] Pick a date in the editor',
        state: 'opened',
        author: demoUserId,
        assignees: [4103],
        labels: ['feature'],
        milestone: true,
        created: '2026-10-21T13:30:00.000Z',
        updated: '2026-10-27T15:50:00.000Z',
      ),
      3: _issue(
        p,
        iid: 3,
        title: 'Crash when a list is empty',
        description: 'Opening a list with no tasks throws a `RangeError`.',
        state: 'closed',
        author: 4103,
        assignees: [demoUserId],
        labels: ['bug'],
        milestone: false,
        created: '2026-10-18T08:05:00.000Z',
        updated: '2026-10-22T11:31:00.000Z',
        closedAt: '2026-10-22T11:31:00.000Z',
        closedBy: demoUserId,
      ),
    };
    _issues[notes.id] = {};
    _thread(p.id, 'issues', 1, [
      _note(4102, 'Reproduced on Android and iOS.', '2026-10-20T10:00:00.000Z'),
    ]);
    _thread(p.id, 'issues', 1, [
      _note(
        demoUserId,
        'I will take this one. We should trim whitespace before checking, too.',
        '2026-10-27T10:02:00.000Z',
      ),
    ]);
    _thread(p.id, 'issues', 2, [
      _note(
        4103,
        'The date picker design is in the Design Notes project.',
        '2026-10-22T09:20:00.000Z',
      ),
    ]);
    _thread(p.id, 'issues', 3, [
      _note(demoUserId, 'Fixed by !2.', '2026-10-22T11:30:00.000Z'),
    ]);
    _thread(p.id, 'issues', 3, [
      _note(demoUserId, 'closed', '2026-10-22T11:31:00.000Z', system: true),
    ]);

    _mergeRequests[p.id] = {
      1: _mergeRequest(
        p,
        iid: 1,
        title: 'Add due dates to tasks',
        description:
            'Adds an optional due date to `Task` and sorts open tasks by it.'
            '\n\nCloses #2',
        state: 'opened',
        author: 4103,
        reviewers: [demoUserId],
        source: 'feature/due-dates',
        head: plannerShas.dueDates,
        base: plannerShas.emptyList,
        labels: ['feature'],
        created: '2026-10-27T15:50:00.000Z',
        updated: '2026-10-28T16:20:00.000Z',
        pipeline: true,
      ),
      2: _mergeRequest(
        p,
        iid: 2,
        title: 'Show a message when the list is empty',
        description: 'Opening a list with no tasks crashed.\n\nCloses #3',
        state: 'merged',
        author: demoUserId,
        reviewers: [4103],
        source: 'fix/empty-list',
        head: plannerShas.emptyList,
        base: plannerShas.ci,
        labels: ['bug'],
        created: '2026-10-22T09:00:00.000Z',
        updated: '2026-10-22T11:31:00.000Z',
        pipeline: false,
      ),
    };
    _mergeRequests[notes.id] = {};
    final position = {
      'base_sha': plannerShas.emptyList,
      'start_sha': plannerShas.emptyList,
      'head_sha': plannerShas.dueDates,
      'old_path': 'lib/task.dart',
      'new_path': 'lib/task.dart',
      'position_type': 'text',
      'old_line': null,
      'new_line': 7,
    };
    _thread(p.id, 'merge_requests', 1, [
      _note(
        demoUserId,
        'Should this be a date without a time? A `DateTime` at midnight can '
            'move to another day in a different time zone.',
        '2026-10-28T09:10:00.000Z',
        position: position,
      ),
      _note(
        4103,
        'Good point. I will store it as a UTC date.',
        '2026-10-28T10:45:00.000Z',
        position: position,
      ),
    ], individual: false);
    _thread(p.id, 'merge_requests', 1, [
      _note(
        4102,
        'The pipeline is green. Looks good to me once the time zone question '
            'is settled.',
        '2026-10-28T16:20:00.000Z',
      ),
    ]);
    _thread(p.id, 'merge_requests', 2, [
      _note(
        4103,
        'Thanks, this fixes the crash for me.',
        '2026-10-22T10:40:00.000Z',
      ),
    ]);
    _thread(p.id, 'merge_requests', 2, [
      _note(demoUserId, 'merged', '2026-10-22T11:31:00.000Z', system: true),
    ]);
    _countNotes();
  }

  Json _issue(
    DemoProject project, {
    required int iid,
    required String title,
    required String description,
    required String state,
    required int author,
    required List<int> assignees,
    required List<String> labels,
    required bool milestone,
    required String created,
    required String updated,
    String? closedAt,
    int? closedBy,
  }) {
    final users = assignees.map(demoUser).toList();
    return {
      'id': project.id * 100 + iid,
      'iid': iid,
      'project_id': project.id,
      'title': title,
      'description': description,
      'state': state,
      'created_at': created,
      'updated_at': updated,
      'closed_at': closedAt,
      'closed_by': closedBy == null ? null : demoUser(closedBy),
      'labels': labels,
      'milestone': milestone ? demoMilestone : null,
      'assignees': users,
      'assignee': users.firstOrNull,
      'author': demoUser(author),
      'type': 'ISSUE',
      'issue_type': 'issue',
      'user_notes_count': 0,
      'merge_requests_count': 0,
      'upvotes': 0,
      'downvotes': 0,
      'due_date': null,
      'confidential': false,
      'discussion_locked': null,
      'web_url': '${project.web}/-/issues/$iid',
      'time_stats': _timeStats,
      'task_completion_status': {'count': 0, 'completed_count': 0},
      'has_tasks': false,
      'references': {
        'short': '#$iid',
        'relative': '#$iid',
        'full': '${project.fullPath}#$iid',
      },
      'severity': 'UNKNOWN',
      'subscribed': true,
      'moved_to_id': null,
      'service_desk_reply_to': null,
    };
  }

  static const _timeStats = {
    'time_estimate': 0,
    'total_time_spent': 0,
    'human_time_estimate': null,
    'human_total_time_spent': null,
  };

  Json _mergeRequest(
    DemoProject project, {
    required int iid,
    required String title,
    required String description,
    required String state,
    required int author,
    required List<int> reviewers,
    required String source,
    required String head,
    required String base,
    required List<String> labels,
    required String created,
    required String updated,
    required bool pipeline,
  }) {
    final merged = state == 'merged';
    return {
      'id': project.id * 100 + 50 + iid,
      'iid': iid,
      'project_id': project.id,
      'title': title,
      'description': description,
      'state': state,
      'created_at': created,
      'updated_at': updated,
      'merged_by': merged ? demoUser(demoUserId) : null,
      'merge_user': merged ? demoUser(demoUserId) : null,
      'merged_at': merged ? updated : null,
      'closed_by': null,
      'closed_at': null,
      'target_branch': project.defaultBranch,
      'source_branch': source,
      'user_notes_count': 0,
      'upvotes': 0,
      'downvotes': 0,
      'author': demoUser(author),
      'assignees': [demoUser(author)],
      'assignee': demoUser(author),
      'reviewers': reviewers.map(demoUser).toList(),
      'source_project_id': project.id,
      'target_project_id': project.id,
      'labels': labels,
      'draft': false,
      'work_in_progress': false,
      'milestone': merged ? null : demoMilestone,
      'merge_when_pipeline_succeeds': false,
      'merge_status': merged ? 'merged' : 'can_be_merged',
      'detailed_merge_status': merged ? 'merged' : 'mergeable',
      'sha': head,
      'merge_commit_sha': null,
      'squash_commit_sha': null,
      'discussion_locked': null,
      'should_remove_source_branch': null,
      'force_remove_source_branch': true,
      'prepared_at': created,
      'references': {
        'short': '!$iid',
        'relative': '!$iid',
        'full': '${project.fullPath}!$iid',
      },
      'web_url': '${project.web}/-/merge_requests/$iid',
      'time_stats': _timeStats,
      'squash': false,
      'squash_on_merge': false,
      'task_completion_status': {'count': 0, 'completed_count': 0},
      'has_conflicts': false,
      'blocking_discussions_resolved': true,
      'subscribed': true,
      'changes_count': '2',
      'latest_build_started_at': pipeline ? '2026-10-27T15:51:00.000Z' : null,
      'latest_build_finished_at': pipeline ? '2026-10-27T15:54:00.000Z' : null,
      'first_deployed_to_production_at': null,
      'pipeline': pipeline ? _pipelineSummary : null,
      'head_pipeline': pipeline ? _pipeline : null,
      'diff_refs': {'base_sha': base, 'head_sha': head, 'start_sha': base},
      'merge_error': null,
      'first_contribution': false,
      'user': {'can_merge': !merged},
      'approvals_before_merge': null,
    };
  }

  Json _note(
    int author,
    String body,
    String created, {
    bool system = false,
    Json? position,
  }) => {
    'id': _nextId++,
    'type': position == null ? null : 'DiffNote',
    'body': body,
    'attachment': null,
    'author': demoUser(author),
    'created_at': created,
    'updated_at': created,
    'system': system,
    'resolvable': position != null,
    'resolved': false,
    'resolved_by': null,
    'confidential': false,
    'internal': false,
    'noteable_id': null,
    'noteable_type': null,
    'noteable_iid': null,
    'commands_changes': <String, dynamic>{},
    'position': ?position,
  };

  Json _thread(
    int project,
    String kind,
    int iid,
    List<Json> notes, {
    bool individual = true,
  }) {
    final key = '$project/$kind/$iid';
    final owner = (kind == 'issues' ? _issues : _mergeRequests)[project]?[iid];
    for (final note in notes) {
      note['noteable_id'] = owner?['id'];
      note['noteable_type'] = kind == 'issues' ? 'Issue' : 'MergeRequest';
      note['noteable_iid'] = iid;
      note['project_id'] = project;
    }
    final thread = <String, dynamic>{
      'id': sha1.convert(utf8.encode('discussion-${_nextId++}')).toString(),
      'individual_note': individual,
      'notes': notes,
    };
    (_discussions[key] ??= []).add(thread);
    return thread;
  }

  void _countNotes() {
    for (final kind in ['issues', 'merge_requests']) {
      final records = kind == 'issues' ? _issues : _mergeRequests;
      records.forEach((project, items) {
        items.forEach((iid, item) {
          item['user_notes_count'] = _notes(
            project,
            kind,
            iid,
          ).where((note) => note['system'] != true).length;
        });
      });
    }
  }

  List<Json> _notes(int project, String kind, int iid) => [
    for (final thread in _discussions['$project/$kind/$iid'] ?? const <Json>[])
      ...(thread['notes'] as List<dynamic>).cast<Json>(),
  ];

  // ------------------------------------------------------------ pipeline

  Json get _pipelineSummary => {
    'id': demoPipelineId,
    'iid': 41,
    'project_id': demoPlannerId,
    'sha': plannerShas.dueDates,
    'ref': 'feature/due-dates',
    'status': 'success',
    'source': 'push',
    'created_at': '2026-10-27T15:50:30.000Z',
    'updated_at': '2026-10-27T15:54:10.000Z',
    'web_url': '${planner.web}/-/pipelines/$demoPipelineId',
  };

  Json get _pipeline => {
    ..._pipelineSummary,
    'before_sha': plannerShas.emptyList,
    'tag': false,
    'yaml_errors': null,
    'user': demoUser(4103),
    'started_at': '2026-10-27T15:51:00.000Z',
    'finished_at': '2026-10-27T15:54:10.000Z',
    'committed_at': null,
    'duration': 190,
    'queued_duration': 2.1,
    'coverage': null,
    'name': null,
    'detailed_status': _status('success'),
  };

  static Json _status(String status) => {
    'icon': 'status_$status',
    'text': status == 'success' ? 'Passed' : status,
    'label': status == 'success' ? 'passed' : status,
    'group': status,
    'tooltip': status == 'success' ? 'passed' : status,
    'has_details': true,
    'details_path': null,
    'illustration': null,
    'favicon': null,
  };

  List<Json> get _jobs => [
    _job(3301, 'analyze', 'lint', 21.4, '2026-10-27T15:51:00.000Z'),
    _job(3302, 'test', 'test', 48.9, '2026-10-27T15:51:30.000Z'),
    _job(3303, 'build', 'build', 95.2, '2026-10-27T15:52:30.000Z'),
  ];

  Json _job(
    int id,
    String name,
    String stage,
    double duration,
    String started,
  ) {
    final commit = _commit(planner, planner.commit(plannerShas.dueDates)!);
    return {
      'id': id,
      'status': 'success',
      'stage': stage,
      'name': name,
      'ref': 'feature/due-dates',
      'tag': false,
      'coverage': null,
      'allow_failure': false,
      'created_at': '2026-10-27T15:50:30.000Z',
      'started_at': started,
      'finished_at': started,
      'erased_at': null,
      'duration': duration,
      'queued_duration': 1.2,
      'user': demoUser(4103),
      'commit': commit,
      'pipeline': _pipelineSummary,
      'web_url': '${planner.web}/-/jobs/$id',
      'project': {'ci_job_token_scope_enabled': false},
      'artifacts': <Json>[],
      'runner': null,
      'artifacts_expire_at': null,
      'archived': false,
      'tag_list': <String>[],
      'failure_reason': null,
    };
  }

  // ------------------------------------------------------------ commits

  Json _commit(DemoProject project, DemoCommit commit) {
    final author = demoUser(commit.author);
    final message = commit.message.isEmpty
        ? '${commit.title}\n'
        : '${commit.title}\n\n${commit.message}\n';
    return {
      'id': commit.sha,
      'short_id': commit.sha.substring(0, 8),
      'created_at': commit.date,
      'parent_ids': [?commit.parent],
      'title': commit.title,
      'message': message,
      'author_name': author['name'],
      'author_email': '${author['username']}@example.invalid',
      'authored_date': commit.date,
      'committer_name': author['name'],
      'committer_email': '${author['username']}@example.invalid',
      'committed_date': commit.date,
      'trailers': <String, dynamic>{},
      'extended_trailers': <String, dynamic>{},
      'web_url': '${project.web}/-/commit/${commit.sha}',
    };
  }

  Json _commitDetail(DemoProject project, DemoCommit commit) {
    final diffs = _commitDiffs(project, commit);
    var additions = 0;
    var deletions = 0;
    for (final diff in diffs) {
      for (final line in (diff['diff'] as String).split('\n')) {
        if (line.startsWith('+')) additions++;
        if (line.startsWith('-')) deletions++;
      }
    }
    return {
      ..._commit(project, commit),
      'stats': {
        'additions': additions,
        'deletions': deletions,
        'total': additions + deletions,
      },
      'status': commit.sha == plannerShas.dueDates ? 'success' : null,
      'last_pipeline': commit.sha == plannerShas.dueDates
          ? _pipelineSummary
          : null,
      'project_id': project.id,
    };
  }

  List<Json> _commitDiffs(DemoProject project, DemoCommit commit) {
    final before = commit.parent == null
        ? const <String, String>{}
        : project.tree(project.commit(commit.parent!)!);
    return [
      for (final MapEntry(key: path, value: after) in commit.files.entries)
        _fileDiff(path, before[path], after),
    ];
  }

  List<Json> _rangeDiffs(DemoProject project, String base, String head) {
    final from = project.tree(project.commit(base)!);
    final to = project.tree(project.commit(head)!);
    return [
      for (final path in {...from.keys, ...to.keys}.toList()..sort())
        if (from[path] != to[path]) _fileDiff(path, from[path], to[path]),
    ];
  }

  Json _fileDiff(String path, String? before, String? after) => {
    'old_path': path,
    'new_path': path,
    'a_mode': before == null ? '0' : '100644',
    'b_mode': after == null ? '0' : '100644',
    'new_file': before == null,
    'renamed_file': false,
    'deleted_file': after == null,
    'generated_file': false,
    'diff': demoUnifiedDiff(before ?? '', after ?? ''),
  };

  List<DemoCommit> _log(DemoProject project, DemoCommit head, String? path) => [
    for (final commit in project.history(head).reversed)
      if (path == null || commit.files.containsKey(path)) commit,
  ];

  // ------------------------------------------------------------ requests

  ResponseBody handle(RequestOptions options) {
    final uri = options.uri;
    final method = options.method.toUpperCase();
    final segments = uri.pathSegments;
    final api = segments.indexOf('v4');
    final path = api < 0 ? segments : segments.sublist(api + 1);
    requests.add('$method ${path.join('/')}');
    if (uri.host != demoHost) {
      unhandled.add('$method $uri');
      return _error(404);
    }
    if (method == 'POST' &&
        segments.length == 2 &&
        segments.last == 'graphql') {
      return _graphQL(_body(options.data));
    }
    if (api < 0) {
      unhandled.add('$method ${uri.path}');
      return _error(404);
    }
    final query = uri.queryParameters;
    if (method == 'GET' || method == 'HEAD') {
      final reply = _read(path, query, head: method == 'HEAD');
      if (reply == null) {
        unhandled.add('$method ${path.join('/')}');
        return _fallback(path, query);
      }
      return reply;
    }
    return _write(method, path, _body(options.data)) ?? _refuse();
  }

  static Json _body(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } on FormatException {
        return <String, dynamic>{};
      }
    }
    return <String, dynamic>{};
  }

  /// Unknown lists are empty and unknown records are 404 (shown as the
  /// ambiguous "cannot open" state, as for any invisible resource).
  ResponseBody _fallback(List<String> path, Map<String, String> query) {
    final last = path.isEmpty ? '' : path.last;
    final record =
        int.tryParse(last) != null ||
        RegExp(r'^[0-9a-f]{8,40}$').hasMatch(last) ||
        const {'raw', 'trace', 'artifacts', 'statistics'}.contains(last);
    return record ? _error(404) : _list(const <Json>[], query);
  }

  ResponseBody? _read(
    List<String> path,
    Map<String, String> query, {
    required bool head,
  }) {
    switch (path) {
      case ['user']:
        return _json(demoUser(demoUserId));
      case ['users', final id]:
        final user = int.tryParse(id);
        if (user == null || !const {demoUserId, 4102, 4103}.contains(user)) {
          return _error(404);
        }
        return _json(demoUser(user));
      case ['users', _, 'events'] || ['events']:
        return _list(_events(), query);
      case ['version'] || ['metadata']:
        return _json({
          'version': '17.5.0',
          'revision': 'demo',
          'enterprise': false,
        });
      case ['projects']:
        return _list(_filterProjects(query), query);
      case ['groups']:
        return _list([demoGroup], query);
      case ['groups', final id]:
        return _isGroup(id) ? _json(demoGroup) : _error(404);
      case ['groups', final id, 'projects']:
        return _isGroup(id)
            ? _list(_filterProjects(query), query)
            : _error(404);
      case ['todos']:
        return _list(query['state'] == 'done' ? const [] : _todos(), query);
      case ['issues']:
        return _list(_filterItems(_allItems(_issues), query), query);
      case ['merge_requests']:
        return _list(_filterItems(_allItems(_mergeRequests), query), query);
      case ['search']:
        return _list(_search(query), query);
    }
    if (path.length >= 2 && path[0] == 'projects') {
      final project = _project(path[1]);
      if (project == null) return path.length == 2 ? _error(404) : null;
      return _readProject(project, path.sublist(2), query, head: head);
    }
    return null;
  }

  bool _isGroup(String id) =>
      id == '$demoGroupId' || Uri.decodeComponent(id) == demoGroup['full_path'];

  DemoProject? _project(String id) {
    final numeric = int.tryParse(id);
    if (numeric != null) return _projects[numeric];
    final path = Uri.decodeComponent(id);
    return _projects.values.where((p) => p.fullPath == path).firstOrNull;
  }

  Json _projectRecord(DemoProject project) => project.record(
    openIssues: _issues[project.id]!.values
        .where((issue) => issue['state'] == 'opened')
        .length,
  );

  List<Json> _filterProjects(Map<String, String> query) {
    final search = (query['search'] ?? '').toLowerCase();
    final starred = query['starred'] == 'true';
    return [
      for (final project in _projects.values)
        if ((!starred || project.starCount > 0) &&
            (search.isEmpty ||
                project.name.toLowerCase().contains(search) ||
                project.fullPath.contains(search)))
          _projectRecord(project),
    ];
  }

  ResponseBody? _readProject(
    DemoProject project,
    List<String> path,
    Map<String, String> query, {
    required bool head,
  }) {
    final p = project.id;
    switch (path) {
      case []:
        return _json(_projectRecord(project));
      case ['starrers'] || ['forks'] || ['releases'] || ['environments']:
        return _list(const [], query);
      case ['languages']:
        return _json(
          p == demoPlannerId
              ? {'Dart': 93.1, 'YAML': 6.9}
              : {'Markdown': 100.0},
        );
      case ['labels']:
        return _list(p == demoPlannerId ? demoLabels : const [], query);
      case ['milestones']:
        return _list(p == demoPlannerId ? [demoMilestone] : const [], query);
      case ['milestones', '3501'] when p == demoPlannerId:
        return _json(demoMilestone);
      case ['members'] || ['members', 'all']:
        return _list(_members(), query);
      case ['members', final user] || ['members', 'all', final user]:
        final member = _members()
            .where((row) => '${row['id']}' == user)
            .firstOrNull;
        return member == null ? _error(404) : _json(member);
      case ['users']:
        return _list([
          for (final id in const [demoUserId, 4102, 4103]) demoUser(id),
        ], query);
      case ['events']:
        return _list(
          _events().where((event) => event['project_id'] == p).toList(),
          query,
        );
      case ['issues']:
        return _list(_filterItems(_issues[p]!.values.toList(), query), query);
      case ['merge_requests']:
        return _list(
          _filterItems(_mergeRequests[p]!.values.toList(), query),
          query,
        );
      case ['pipelines']:
        final rows = p == demoPlannerId ? [_pipelineSummary] : const <Json>[];
        final ref = query['ref'];
        final sha = query['sha'];
        return _list(
          rows
              .where(
                (row) =>
                    (ref == null || row['ref'] == ref) &&
                    (sha == null || row['sha'] == sha),
              )
              .toList(),
          query,
        );
      case ['pipelines', 'latest'] when p == demoPlannerId:
        return _json(_pipeline);
      case ['pipelines', final id]:
        return id == '$demoPipelineId' && p == demoPlannerId
            ? _json(_pipeline)
            : _error(404);
      case ['pipelines', final id, 'jobs']:
        if (id != '$demoPipelineId' || p != demoPlannerId) return _error(404);
        return _list(_jobs, query);
      case ['pipelines', final id, 'test_report_summary']:
        if (id != '$demoPipelineId' || p != demoPlannerId) return _error(404);
        return _json(_testSummary);
      case ['jobs']:
        return _list(p == demoPlannerId ? _jobs : const [], query);
      case ['jobs', final id]:
        final job = _jobs.where((row) => '${row['id']}' == id).firstOrNull;
        return job == null || p != demoPlannerId ? _error(404) : _json(job);
      case ['jobs', final id, 'trace']:
        final log = demoJobLogs[int.tryParse(id)];
        if (log == null || p != demoPlannerId) return _error(404);
        return _text(log, head: head);
    }
    if (path.isNotEmpty && path[0] == 'repository') {
      return _readRepository(project, path.sublist(1), query, head: head);
    }
    if (path.length >= 2 &&
        (path[0] == 'issues' || path[0] == 'merge_requests')) {
      return _readItem(project, path[0], path.sublist(1), query);
    }
    return null;
  }

  ResponseBody? _readRepository(
    DemoProject project,
    List<String> path,
    Map<String, String> query, {
    required bool head,
  }) {
    switch (path) {
      case ['branches']:
        final search = query['search'] ?? '';
        return _list([
          for (final name in project.branches.keys)
            if (name.contains(search)) _branch(project, name),
        ], query);
      case ['branches', final name]:
        return project.branches.containsKey(name)
            ? _json(_branch(project, name))
            : _error(404);
      case ['tags']:
        return _list(const [], query);
      case ['contributors']:
        return _list(const [], query);
      case ['tree']:
        final commit = project.resolve(query['ref']);
        if (commit == null) return _error(404);
        return _list(
          _tree(
            project.tree(commit),
            query['path'] ?? '',
            query['recursive'] == 'true',
          ),
          query,
        );
      case ['commits']:
        final commit = project.resolve(query['ref_name']);
        if (commit == null) return _error(404);
        return _list([
          for (final entry in _log(project, commit, query['path']))
            _commit(project, entry),
        ], query);
      case ['commits', final sha]:
        final commit = project.resolve(sha);
        return commit == null
            ? _error(404)
            : _json(_commitDetail(project, commit));
      case ['commits', final sha, 'diff']:
        final commit = project.resolve(sha);
        return commit == null
            ? _error(404)
            : _list(_commitDiffs(project, commit), query);
      case ['commits', final sha, 'refs']:
        final commit = project.resolve(sha);
        if (commit == null) return _error(404);
        return _list([
          for (final MapEntry(key: name, value: head)
              in project.branches.entries)
            if (project.history(project.commit(head)!).contains(commit))
              {'type': 'branch', 'name': name},
        ], query);
      case ['commits', final sha, 'merge_requests']:
        return _list([
          for (final item in _mergeRequests[project.id]!.values)
            if (item['sha'] == project.resolve(sha)?.sha) item,
        ], query);
      case ['compare']:
        final from = project.resolve(query['from']);
        final to = project.resolve(query['to']);
        if (from == null || to == null) return _error(404);
        final range = project
            .history(to)
            .where((commit) => !project.history(from).contains(commit))
            .toList();
        return _json({
          'commit': _commit(project, to),
          'commits': [for (final commit in range) _commit(project, commit)],
          'diffs': _rangeDiffs(project, from.sha, to.sha),
          'compare_timeout': false,
          'compare_same_ref': from.sha == to.sha,
          'web_url': '${project.web}/-/compare/${from.sha}...${to.sha}',
        });
      case ['files', final file] || ['files', final file, 'raw']:
        final commit = project.resolve(query['ref']);
        final content = commit == null ? null : project.tree(commit)[file];
        if (commit == null || content == null) return _error(404);
        final headers = _fileHeaders(project, commit, file, content);
        if (path.length == 3) {
          return _text(content, head: head, headers: headers);
        }
        if (head) return _empty(headers);
        return _json({
          'file_name': file.split('/').last,
          'file_path': file,
          'size': utf8.encode(content).length,
          'encoding': 'base64',
          'content': base64.encode(utf8.encode(content)),
          'content_sha256': sha256.convert(utf8.encode(content)).toString(),
          'ref': query['ref'] ?? project.defaultBranch,
          'blob_id': demoBlobId(content),
          'commit_id': commit.sha,
          'last_commit_id': _lastCommit(project, commit, file).sha,
          'execute_filemode': false,
        });
      case ['blobs', final blob] || ['blobs', final blob, 'raw']:
        for (final commit in project.commits) {
          for (final content in project.tree(commit).values) {
            if (demoBlobId(content) != blob) continue;
            if (path.length == 3) return _text(content, head: head);
            return _json({
              'size': utf8.encode(content).length,
              'encoding': 'base64',
              'content': base64.encode(utf8.encode(content)),
              'sha': blob,
            });
          }
        }
        return _error(404);
    }
    return null;
  }

  Map<String, List<String>> _fileHeaders(
    DemoProject project,
    DemoCommit commit,
    String file,
    String content,
  ) => {
    'x-gitlab-blob-id': [demoBlobId(content)],
    'x-gitlab-commit-id': [commit.sha],
    'x-gitlab-last-commit-id': [_lastCommit(project, commit, file).sha],
    'x-gitlab-file-name': [file.split('/').last],
    'x-gitlab-file-path': [file],
    'x-gitlab-ref': [commit.sha],
    'x-gitlab-size': ['${utf8.encode(content).length}'],
    'x-gitlab-encoding': ['base64'],
    'x-gitlab-execute-filemode': ['false'],
  };

  DemoCommit _lastCommit(DemoProject project, DemoCommit head, String file) =>
      _log(project, head, file).first;

  Json _branch(DemoProject project, String name) => {
    'name': name,
    'commit': _commit(project, project.commit(project.branches[name]!)!),
    'merged': name == 'fix/empty-list',
    'protected': name == project.defaultBranch,
    'developers_can_push': false,
    'developers_can_merge': false,
    'can_push': true,
    'default': name == project.defaultBranch,
    'web_url': '${project.web}/-/tree/$name',
  };

  List<Json> _tree(
    Map<String, String> files,
    String directory,
    bool recursive,
  ) {
    final prefix = directory.isEmpty ? '' : '$directory/';
    final trees = <String>{};
    final blobs = <String>[];
    for (final path in files.keys) {
      if (!path.startsWith(prefix)) continue;
      final rest = path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0 || recursive) {
        blobs.add(path);
      }
      if (slash >= 0) trees.add('$prefix${rest.substring(0, slash)}');
    }
    String id(String path) =>
        sha1.convert(utf8.encode('tree:$path')).toString();
    return [
      for (final path in trees.toList()..sort())
        {
          'id': id(path),
          'name': path.split('/').last,
          'type': 'tree',
          'path': path,
          'mode': '040000',
        },
      for (final path in blobs..sort())
        {
          'id': demoBlobId(files[path]!),
          'name': path.split('/').last,
          'type': 'blob',
          'path': path,
          'mode': '100644',
        },
    ];
  }

  ResponseBody? _readItem(
    DemoProject project,
    String kind,
    List<String> path,
    Map<String, String> query,
  ) {
    final iid = int.tryParse(path[0]);
    final records = kind == 'issues' ? _issues : _mergeRequests;
    final item = iid == null ? null : records[project.id]![iid];
    if (item == null || iid == null) return _error(404);
    final rest = path.sublist(1);
    final mergeRequest = kind == 'merge_requests';
    switch (rest) {
      case []:
        return _json(item);
      case ['notes']:
        final rows = _notes(project.id, kind, iid);
        if (query['sort'] != 'asc') {
          rows.sort(
            (a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'),
          );
        }
        return _list(rows, query);
      case ['notes', final id]:
        final note = _notes(
          project.id,
          kind,
          iid,
        ).where((row) => '${row['id']}' == id).firstOrNull;
        return note == null ? _error(404) : _json(note);
      case ['discussions']:
        return _list(
          _discussions['${project.id}/$kind/$iid'] ?? const [],
          query,
        );
      case ['discussions', final id]:
        final thread =
            (_discussions['${project.id}/$kind/$iid'] ?? const <Json>[])
                .where((row) => row['id'] == id)
                .firstOrNull;
        return thread == null ? _error(404) : _json(thread);
      case ['participants']:
        return _list(
          {
            for (final note in _notes(project.id, kind, iid))
              (note['author'] as Json)['id']: note['author'] as Json,
            (item['author'] as Json)['id']: item['author'] as Json,
          }.values.toList(),
          query,
        );
      case ['time_stats']:
        return _json(_timeStats);
      case ['award_emoji'] ||
          ['links'] ||
          ['resource_label_events'] ||
          ['resource_state_events'] ||
          ['resource_milestone_events']:
        return _list(const [], query);
      case ['related_merge_requests'] || ['closed_by'] when !mergeRequest:
        return _list([
          for (final candidate in _mergeRequests[project.id]!.values)
            if ('${candidate['description']}'.contains('Closes #$iid'))
              candidate,
        ], query);
      case ['closes_issues'] when mergeRequest:
        final match = RegExp(
          r'Closes #(\d+)',
        ).firstMatch('${item['description']}');
        final closed = match == null
            ? null
            : _issues[project.id]![int.parse(match.group(1)!)];
        return _list([?closed], query);
      case ['commits'] when mergeRequest:
        final head = project.commit('${item['sha']}')!;
        final base = (item['diff_refs'] as Json)['base_sha'] as String;
        return _list([
          for (final commit in project.history(head).reversed)
            if (!project.history(project.commit(base)!).contains(commit))
              _commit(project, commit),
        ], query);
      case ['pipelines'] when mergeRequest:
        return _list([?item['pipeline'] as Json?], query);
      case ['approvals'] when mergeRequest:
        return _json(_approvals(item));
      case ['approval_state'] when mergeRequest:
        return _json({'approval_rules_overwritten': false, 'rules': <Json>[]});
      case ['reviewers'] when mergeRequest:
        return _list([
          for (final user in (item['reviewers'] as List<dynamic>).cast<Json>())
            {
              'user': user,
              'state': 'unreviewed',
              'created_at': item['created_at'],
            },
        ], query);
      case ['changes'] when mergeRequest:
        return _json({
          ...item,
          'changes': _mergeRequestDiffs(project, item),
          'overflow': false,
        });
      case ['diffs'] when mergeRequest:
        return _list(_mergeRequestDiffs(project, item), query);
      case ['versions'] when mergeRequest:
        return _list([_version(item)], query);
      case ['versions', final id] when mergeRequest:
        if (id != '${_version(item)['id']}') return _error(404);
        return _json({
          ..._version(item),
          'commits': [_commit(project, project.commit('${item['sha']}')!)],
          'diffs': _mergeRequestDiffs(project, item),
        });
    }
    return null;
  }

  List<Json> _mergeRequestDiffs(DemoProject project, Json item) {
    final refs = item['diff_refs'] as Json;
    return _rangeDiffs(project, '${refs['base_sha']}', '${refs['head_sha']}');
  }

  Json _version(Json item) {
    final refs = item['diff_refs'] as Json;
    return {
      'id': (item['id'] as int) * 10 + 1,
      'head_commit_sha': refs['head_sha'],
      'base_commit_sha': refs['base_sha'],
      'start_commit_sha': refs['start_sha'],
      'created_at': item['created_at'],
      'merge_request_id': item['id'],
      'state': 'collected',
      'real_size': '2',
      'patch_id_sha': null,
    };
  }

  Json _approvals(Json item) => {
    'id': item['id'],
    'iid': item['iid'],
    'project_id': item['project_id'],
    'title': item['title'],
    'description': item['description'],
    'state': item['state'],
    'created_at': item['created_at'],
    'updated_at': item['updated_at'],
    'merge_status': item['merge_status'],
    'approved': item['state'] == 'merged',
    'approvals_required': 1,
    'approvals_left': item['state'] == 'merged' ? 0 : 1,
    'require_password_to_approve': false,
    'approved_by': item['state'] == 'merged'
        ? [
            {'user': demoUser(4103)},
          ]
        : <Json>[],
    'suggested_approvers': <Json>[],
    'approvers': <Json>[],
    'approver_groups': <Json>[],
    'user_has_approved': false,
    'user_can_approve': item['state'] != 'merged',
    'approval_rules_left': <Json>[],
    'has_approval_rules': false,
    'merge_request_approvers_available': false,
    'multiple_approval_rules_available': false,
    'invalid_approvers_rules': <Json>[],
  };

  static const _testSummary = {
    'total': {
      'time': 3.1,
      'count': 2,
      'success': 2,
      'failed': 0,
      'skipped': 0,
      'error': 0,
      'suite_error': null,
    },
    'test_suites': [
      {
        'name': 'test',
        'total_time': 3.1,
        'total_count': 2,
        'success_count': 2,
        'failed_count': 0,
        'skipped_count': 0,
        'error_count': 0,
        'build_ids': [3302],
        'suite_error': null,
      },
    ],
  };

  List<Json> _members() => [
    for (final (id, level) in const [(demoUserId, 40), (4102, 30), (4103, 30)])
      {
        ...demoUser(id),
        'access_level': level,
        'created_at': '2026-09-01T09:00:00.000Z',
        'expires_at': null,
        'membership_state': 'active',
      },
  ];

  List<Json> _allItems(Map<int, Map<int, Json>> records) => [
    for (final items in records.values) ...items.values,
  ];

  List<Json> _filterItems(List<Json> items, Map<String, String> query) {
    final state = query['state'] ?? 'all';
    final scope = query['scope'] ?? 'all';
    final search = (query['search'] ?? '').toLowerCase();
    final labels = query['labels']
        ?.split(',')
        .where((l) => l.isNotEmpty)
        .toSet();
    final author = query['author_id'] ?? query['author_username'];
    final assignee = query['assignee_id'] ?? query['assignee_username'];
    final reviewer = query['reviewer_id'] ?? query['reviewer_username'];
    bool names(Object? users, String value) => [
      for (final user in (users as List<dynamic>? ?? const []).cast<Json>())
        if ('${user['id']}' == value || user['username'] == value) user,
    ].isNotEmpty;
    final rows = [
      for (final item in items)
        if ((state == 'all' || item['state'] == state) &&
            (scope != 'assigned_to_me' ||
                names(item['assignees'], '$demoUserId')) &&
            (scope != 'created_by_me' ||
                (item['author'] as Json)['id'] == demoUserId) &&
            (search.isEmpty ||
                '${item['title']}'.toLowerCase().contains(search)) &&
            (labels == null ||
                labels.every(
                  (label) => (item['labels'] as List).contains(label),
                )) &&
            (author == null ||
                '${(item['author'] as Json)['id']}' == author ||
                (item['author'] as Json)['username'] == author) &&
            (assignee == null || names(item['assignees'], assignee)) &&
            (reviewer == null || names(item['reviewers'], reviewer)))
          item,
    ];
    rows.sort((a, b) => '${b['updated_at']}'.compareTo('${a['updated_at']}'));
    return rows;
  }

  List<Json> _search(Map<String, String> query) {
    final term = query['search'] ?? '';
    return switch (query['scope']) {
      'projects' => _filterProjects(query),
      'issues' => _filterItems(_allItems(_issues), {'search': term}),
      'merge_requests' => _filterItems(_allItems(_mergeRequests), {
        'search': term,
      }),
      _ => const [],
    };
  }

  List<Json> _todos() {
    final p = planner;
    Json todo(
      int id,
      String action,
      int author,
      String type,
      Json target,
      String body,
      String created,
    ) => {
      'id': id,
      'project': {
        'id': p.id,
        'name': p.name,
        'name_with_namespace': 'Mergeline Demo / ${p.name}',
        'path': p.path,
        'path_with_namespace': p.fullPath,
      },
      'group': null,
      'author': demoUser(author),
      'action_name': action,
      'target_type': type,
      'target': target,
      'target_url': target['web_url'],
      'body': body,
      'state': 'pending',
      'created_at': created,
      'updated_at': created,
    };
    return [
      todo(
        3402,
        'review_requested',
        4103,
        'MergeRequest',
        _mergeRequests[p.id]![1]!,
        'Add due dates to tasks',
        '2026-10-27T15:51:00.000Z',
      ),
      todo(
        3401,
        'assigned',
        4102,
        'Issue',
        _issues[p.id]![1]!,
        'Tasks with an empty title can be saved',
        '2026-10-20T09:15:00.000Z',
      ),
    ];
  }

  List<Json> _events() {
    final p = planner;
    Json event(
      int id,
      String action,
      int author,
      String created, {
      String? type,
      int? target,
      int? iid,
      String? title,
      Json? push,
      Json? note,
    }) => {
      'id': id,
      'project_id': p.id,
      'action_name': action,
      'target_id': target,
      'target_iid': iid,
      'target_type': type,
      'author_id': author,
      'target_title': title,
      'created_at': created,
      'author': demoUser(author),
      'author_username': demoUser(author)['username'],
      'imported': false,
      'imported_from': 'none',
      'push_data': ?push,
      'note': ?note,
    };
    final review = _notes(p.id, 'merge_requests', 1).last;
    return [
      event(
        3709,
        'commented on',
        4102,
        '2026-10-28T16:20:00.000Z',
        type: 'Note',
        target: review['id'] as int,
        title: 'Add due dates to tasks',
        note: review,
      ),
      event(
        3708,
        'opened',
        4103,
        '2026-10-27T15:50:00.000Z',
        type: 'MergeRequest',
        target: p.id * 100 + 51,
        iid: 1,
        title: 'Add due dates to tasks',
      ),
      event(
        3707,
        'pushed to',
        4103,
        '2026-10-27T15:45:00.000Z',
        push: {
          'commit_count': 1,
          'action': 'pushed',
          'ref_type': 'branch',
          'commit_from': null,
          'commit_to': plannerShas.dueDates,
          'ref': 'feature/due-dates',
          'commit_title': 'Add due dates to tasks',
          'ref_count': null,
        },
      ),
      event(
        3706,
        'closed',
        demoUserId,
        '2026-10-22T11:31:00.000Z',
        type: 'Issue',
        target: p.id * 100 + 3,
        iid: 3,
        title: 'Crash when a list is empty',
      ),
    ];
  }

  // ------------------------------------------------------------ writes

  /// The changes the demo keeps. Anything else is null, which refuses it.
  ResponseBody? _write(String method, List<String> path, Json body) {
    if (path.length < 3 || path[0] != 'projects') return null;
    final project = _project(path[1]);
    if (project == null) return _error(404);
    final rest = path.sublist(2);
    switch (rest) {
      case ['issues'] when method == 'POST':
        final title = '${body['title'] ?? ''}'.trim();
        if (title.isEmpty) {
          return _json({
            'message': {
              'title': ["can't be blank"],
            },
          }, status: 400);
        }
        final iid =
            (_issues[project.id]!.keys.fold(0, (a, b) => a > b ? a : b)) + 1;
        final issue = _issue(
          project,
          iid: iid,
          title: title,
          description: '${body['description'] ?? ''}',
          state: 'opened',
          author: demoUserId,
          assignees: const [],
          labels: '${body['labels'] ?? ''}'
              .split(',')
              .map((label) => label.trim())
              .where((label) => label.isNotEmpty)
              .toList(),
          milestone: false,
          created: _now,
          updated: _now,
        );
        _issues[project.id]![iid] = issue;
        return _json(issue, status: 201);
      case ['issues', final id] when method == 'PUT':
        final issue = _issues[project.id]![int.tryParse(id)];
        if (issue == null) return _error(404);
        final event = body['state_event'];
        if (body.keys.any((key) => key != 'state_event') ||
            (event != 'close' && event != 'reopen')) {
          return null;
        }
        final closing = event == 'close';
        if ((issue['state'] == 'closed') != closing) {
          issue['state'] = closing ? 'closed' : 'opened';
          issue['closed_at'] = closing ? _now : null;
          issue['closed_by'] = closing ? demoUser(demoUserId) : null;
          issue['updated_at'] = _now;
          _thread(project.id, 'issues', issue['iid'] as int, [
            _note(
              demoUserId,
              closing ? 'closed' : 'reopened',
              _now,
              system: true,
            ),
          ]);
        }
        return _json(issue);
      case [final kind, final id, 'notes'] ||
              [final kind, final id, 'discussions']
          when method == 'POST' &&
              (kind == 'issues' || kind == 'merge_requests'):
        return _addNote(
          project,
          kind,
          id,
          body,
          thread: null,
          discussion: rest.last == 'discussions',
        );
      case [final kind, final id, 'discussions', final thread, 'notes']
          when method == 'POST' &&
              (kind == 'issues' || kind == 'merge_requests'):
        return _addNote(
          project,
          kind,
          id,
          body,
          thread: thread,
          discussion: false,
        );
    }
    return null;
  }

  ResponseBody _addNote(
    DemoProject project,
    String kind,
    String id,
    Json body, {
    required String? thread,
    required bool discussion,
  }) {
    final iid = int.tryParse(id);
    final records = kind == 'issues' ? _issues : _mergeRequests;
    final item = iid == null ? null : records[project.id]![iid];
    final text = '${body['body'] ?? ''}';
    if (item == null || iid == null) return _error(404);
    if (text.trim().isEmpty) {
      return _json({
        'message': {
          'note': ["can't be blank"],
        },
      }, status: 400);
    }
    final note = _note(demoUserId, text, _now);
    note['noteable_id'] = item['id'];
    note['noteable_type'] = kind == 'issues' ? 'Issue' : 'MergeRequest';
    note['noteable_iid'] = iid;
    note['project_id'] = project.id;
    item['updated_at'] = _now;
    final key = '${project.id}/$kind/$iid';
    if (thread != null) {
      final existing = (_discussions[key] ?? const <Json>[])
          .where((row) => row['id'] == thread)
          .firstOrNull;
      if (existing == null) return _error(404);
      (existing['notes'] as List<dynamic>).add(note);
      _countNotes();
      return _json(note, status: 201);
    }
    final created = _thread(project.id, kind, iid, [note]);
    _countNotes();
    // POST …/notes returns the note; POST …/discussions the new thread.
    return _json(discussion ? created : note, status: 201);
  }

  // ------------------------------------------------------------ GraphQL

  /// The queries the demo's pages issue, answered from the same records as
  /// REST. Other queries get empty data, and every mutation is refused.
  ResponseBody _graphQL(Json body) {
    final query = '${body['query'] ?? ''}'.trimLeft();
    final match = RegExp(r'^(query|mutation)\s+(\w+)').firstMatch(query);
    if (match?.group(1) == 'mutation' || query.startsWith('mutation')) {
      return _refuse();
    }
    final variables = body['variables'] is Json
        ? body['variables'] as Json
        : <String, dynamic>{};
    final name = match?.group(2) ?? '';
    switch (name) {
      case 'MobileProjectWorkItem':
        final project = _project('${variables['path']}');
        if (project == null) {
          return _json({
            'data': {'project': null},
          });
        }
        final issue = _issues[project.id]![int.tryParse('${variables['iid']}')];
        return _json({
          'data': {
            'project': {
              'id': _projectGid(project),
              'fullPath': project.fullPath,
              'workItems': {
                'nodes': [?issue == null ? null : _workItem(project, issue)],
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        });
    }
    unhandled.add('GRAPHQL $name');
    return _json({'data': <String, dynamic>{}});
  }

  static String _projectGid(DemoProject project) =>
      'gid://gitlab/Project/${project.id}';

  static String _userGid(Json user) => 'gid://gitlab/User/${user['id']}';

  Json _workItem(DemoProject project, Json issue) {
    final connection = {'hasNextPage': false, 'endCursor': null};
    final author = issue['author'] as Json;
    return {
      'id': 'gid://gitlab/WorkItem/${issue['id']}',
      'iid': '${issue['iid']}',
      'title': issue['title'],
      'state': issue['state'] == 'closed' ? 'CLOSED' : 'OPEN',
      'createdAt': issue['created_at'],
      'updatedAt': issue['updated_at'],
      'project': {'id': _projectGid(project), 'fullPath': project.fullPath},
      'namespace': {
        'id': 'gid://gitlab/Namespaces::ProjectNamespace/${project.id + 1000}',
        'fullPath': project.fullPath,
      },
      'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Issue'},
      'author': {
        'id': _userGid(author),
        'name': author['name'],
        'username': author['username'],
      },
      'description': issue['description'],
      'widgets': [
        {
          'type': 'DESCRIPTION',
          'description': issue['description'],
          'edited': false,
          'lastEditedAt': null,
        },
        {
          'type': 'ASSIGNEES',
          'assignees': {
            'nodes': [
              for (final user
                  in (issue['assignees'] as List<dynamic>).cast<Json>())
                {
                  'id': _userGid(user),
                  'name': user['name'],
                  'username': user['username'],
                },
            ],
            'pageInfo': connection,
          },
        },
        {
          'type': 'LABELS',
          'labels': {
            'nodes': [
              for (final label in demoLabels)
                if ((issue['labels'] as List<dynamic>).contains(label['name']))
                  {
                    'id': 'gid://gitlab/ProjectLabel/${label['id']}',
                    'title': label['name'],
                    'color': label['color'],
                    'description': label['description'],
                    'textColor': label['text_color'],
                  },
            ],
            'pageInfo': connection,
          },
        },
        {
          'type': 'HIERARCHY',
          'hasParent': false,
          'hasChildren': false,
          'parent': null,
          'children': {'nodes': <Json>[], 'pageInfo': connection},
        },
        {
          'type': 'START_AND_DUE_DATE',
          'startDate': null,
          'dueDate': null,
          'rollUp': false,
        },
      ],
    };
  }

  // ------------------------------------------------------------ replies

  static const _jsonType = ['application/json'];

  ResponseBody _json(Object? value, {int status = 200}) =>
      ResponseBody.fromString(
        jsonEncode(value),
        status,
        headers: {Headers.contentTypeHeader: _jsonType},
      );

  ResponseBody _list(List<Json> rows, Map<String, String> query) {
    final perPage = (int.tryParse(query['per_page'] ?? '') ?? 20).clamp(1, 100);
    final page = (int.tryParse(query['page'] ?? '') ?? 1).clamp(1, 1000);
    final pages = rows.isEmpty ? 1 : (rows.length / perPage).ceil();
    final start = (page - 1) * perPage;
    final slice = start >= rows.length
        ? const <Json>[]
        : rows.sublist(start, (start + perPage).clamp(0, rows.length));
    return ResponseBody.fromString(
      jsonEncode(slice),
      200,
      headers: {
        Headers.contentTypeHeader: _jsonType,
        'x-page': ['$page'],
        'x-per-page': ['$perPage'],
        'x-total': ['${rows.length}'],
        'x-total-pages': ['$pages'],
        'x-prev-page': [page > 1 ? '${page - 1}' : ''],
        'x-next-page': [page < pages ? '${page + 1}' : ''],
      },
    );
  }

  ResponseBody _text(
    String value, {
    required bool head,
    Map<String, List<String>> headers = const {},
  }) {
    final all = {
      Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
      ...headers,
    };
    return head
        ? _empty(all)
        : ResponseBody.fromBytes(utf8.encode(value), 200, headers: all);
  }

  ResponseBody _empty(Map<String, List<String>> headers) =>
      ResponseBody.fromBytes(const [], 200, headers: headers);

  ResponseBody _error(int status) => _json({
    'message': status == 404 ? '404 Not found' : '$status',
  }, status: status);

  ResponseBody _refuse() => _json({'message': '403 Forbidden'}, status: 403);
}

/// A unified diff of two small texts, as GitLab returns it in `diff`.
String demoUnifiedDiff(String before, String after) {
  List<String> lines(String text) {
    if (text.isEmpty) return const [];
    final parts = text.split('\n');
    if (parts.last.isEmpty) parts.removeLast();
    return parts;
  }

  final a = lines(before);
  final b = lines(after);
  if (a.isEmpty) {
    return '@@ -0,0 +1,${b.length} @@\n${b.map((line) => '+$line\n').join()}';
  }
  if (b.isEmpty) {
    return '@@ -1,${a.length} +0,0 @@\n${a.map((line) => '-$line\n').join()}';
  }
  // Longest common subsequence; the sample files are a few dozen lines.
  final table = List.generate(
    a.length + 1,
    (_) => List.filled(b.length + 1, 0),
  );
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      table[i][j] = a[i] == b[j]
          ? table[i + 1][j + 1] + 1
          : (table[i + 1][j] > table[i][j + 1]
                ? table[i + 1][j]
                : table[i][j + 1]);
    }
  }
  final ops = <(String, int, int)>[];
  var i = 0;
  var j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] == b[j]) {
      ops.add((' ', i++, j++));
    } else if (j < b.length &&
        (i == a.length || table[i][j + 1] >= table[i + 1][j])) {
      ops.add(('+', i, j++));
    } else {
      ops.add(('-', i++, j));
    }
  }
  // One hunk per run of changes, with three lines of context.
  final out = StringBuffer();
  var index = 0;
  while (index < ops.length) {
    if (ops[index].$1 == ' ') {
      index++;
      continue;
    }
    var start = index;
    var context = 0;
    while (start > 0 && context < 3 && ops[start - 1].$1 == ' ') {
      start--;
      context++;
    }
    var end = index;
    while (end < ops.length) {
      if (ops[end].$1 != ' ') {
        end++;
        continue;
      }
      var run = end;
      while (run < ops.length && ops[run].$1 == ' ') {
        run++;
      }
      if (run == ops.length || run - end > 6) {
        end = (end + 3).clamp(0, ops.length);
        break;
      }
      end = run;
    }
    final hunk = ops.sublist(start, end);
    final oldStart = hunk.first.$2 + 1;
    final newStart = hunk.first.$3 + 1;
    final oldCount = hunk.where((op) => op.$1 != '+').length;
    final newCount = hunk.where((op) => op.$1 != '-').length;
    out.write('@@ -$oldStart,$oldCount +$newStart,$newCount @@\n');
    for (final (kind, oldIndex, newIndex) in hunk) {
      out.write('$kind${kind == '+' ? b[newIndex] : a[oldIndex]}\n');
    }
    index = end;
  }
  return out.toString();
}
