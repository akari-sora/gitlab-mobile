part of 'gitlab_api.dart';

typedef Json = Map<String, dynamic>;

const _issueCreateFields = {
  'title', 'description', 'labels', 'assignee_ids', 'milestone_id',
  'confidential', 'severity', 'issue_type',
};
const _issueUpdateFields = {
  'title', 'description', 'labels', 'assignee_ids', 'milestone_id',
  'confidential', 'severity', 'state_event',
};
const _mergeRequestCreateFields = {
  'title', 'description', 'labels', 'assignee_ids', 'milestone_id',
  'reviewer_ids', 'source_branch', 'target_branch',
};
const _mergeRequestUpdateFields = {
  'title', 'description', 'labels', 'assignee_ids', 'milestone_id',
  'reviewer_ids', 'state_event',
};
const _positionFields = {
  'position_type', 'base_sha', 'start_sha', 'head_sha', 'old_path',
  'new_path', 'old_line', 'new_line',
};

Json _allowedFields(Json fields, Set<String> allowed) {
  if (!fields.keys.every(allowed.contains)) { throw const ApiFailure(FailureKind.validation); }
  return fields;
}

String _issueOrMergeRequest(String resource) {
  if (!const {'issues', 'merge_requests'}.contains(resource)) {
    throw const ApiFailure(FailureKind.validation);
  }
  return resource;
}

Json? _allowedPosition(Json? position) =>
  position == null ? null : _allowedFields(position, _positionFields);

// ApiFailure stays the existing final presentation type. Weak, process-local
// metadata preserves the two mutation-401 refresh outcomes without retaining
// failures, changing their kind, or exposing refresh details in UI copy.
final _mutation401ResultCodes = Expando<String>();

String? gitLabMutation401ResultCode(ApiFailure failure) =>
  _mutation401ResultCodes[failure];

ApiFailure _knownMutation401({required bool refreshSucceeded}) {
  const kind = FailureKind.writeUncertain;
  final failure = ApiFailure(kind, status: 401);
  _mutation401ResultCodes[failure] = refreshSucceeded ? 'refreshSucceeded' : 'sessionExpired';
  return failure;
}

extension WorkspaceApi on GitLabApi {
  Future<Json> record(List<String> path, {Map<String, String>? query}) => _object(instance.api(path, query));
  Future<ApiPage<Json>> records(List<String> path, {Map<String, String> query = const {}, Uri? next}) {
    final first = instance.api(path, {'per_page': '30', ...query});
    _validateContinuation(first, next);
    return _page(next ?? first, (value) {
      if (path.length == 1 && path.first == 'projects') { Project.fromJson(value); }
      return Map<String, dynamic>.unmodifiable(value);
    });
  }
  Future<Json> writeRecord(String method, List<String> path, Json data) {
    if (!const ['POST', 'PUT', 'PATCH'].contains(method)) { throw const ApiFailure(FailureKind.unsupported); }
    final body = <String, dynamic>{...data};
    if (method == 'PUT' && path.length == 4 && path[0] == 'projects' && path[2] == 'labels' && body.containsKey('name')) {
      body['new_name'] = body.remove('name');
    }
    return _object(instance.api(path), method: method, data: body);
  }
  Future<void> removeRecord(List<String> path, {Json? data}) async { await _read(instance.api(path), method: 'DELETE', data: data); }

  Future<String> snippetText(
    int project,
    int snippet, {
    String? ref,
    String? filePath,
  }) async {
    if ((ref == null) != (filePath == null) ||
        ref?.trim().isEmpty == true ||
        filePath?.trim().isEmpty == true) {
      throw const ApiFailure(FailureKind.validation);
    }
    final path = ref == null
        ? ['projects', '$project', 'snippets', '$snippet', 'raw']
        : [
            'projects',
            '$project',
            'snippets',
            '$snippet',
            'files',
            ref,
            filePath!,
            'raw',
          ];
    final response = await _read(
      instance.api(path),
      maxBytes: GitLabApi.maxTextBytes,
      headers: {'Cache-Control': 'max-age=0'},
    );
    if (response.bytes.contains(0)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    try {
      final text = utf8.decode(response.bytes);
      if ('\n'.allMatches(text).length + 1 > GitLabApi.maxTextLines) {
        throw const ApiFailure(FailureKind.tooLarge);
      }
      return text;
    } on FormatException {
      throw const ApiFailure(FailureKind.unsupported);
    }
  }
  /// Mutations such as publishing a review may return 204 without JSON.
  Future<void> writeEmpty(String method, List<String> path, {Json data = const {}}) async {
    if (!const ['POST', 'PUT', 'PATCH'].contains(method)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    await _read(instance.api(path), method: method, data: data);
  }
  Future<Project> createProject({required String name, String? path, String description = ''}) async =>
    Project.fromJson(await writeRecord('POST', ['projects'], {
      'name': name, 'path': ?path, 'description': description, 'visibility': 'private', 'initialize_with_readme': true,
    }));
  Future<Project> editProject(int id, {required String name, required String description}) async =>
    Project.fromJson(await writeRecord('PUT', ['projects', '$id'], {'name': name, 'description': description}));
  Future<void> deleteProject(int id) => removeRecord(['projects', '$id']);
  /// `POST /projects/:id/star` or `unstar`. GitLab answers 304 when the project
  /// is already in that state, reported as success without a body.
  Future<Json?> setStar(int id, bool starred) async {
    try {
      return await writeRecord('POST', ['projects', '$id', starred ? 'star' : 'unstar'], {});
    } on ApiFailure catch (failure) {
      if (failure.status != 304) rethrow;
      return null;
    }
  }
  Future<Json> createIssue(int project, Json fields) {
    _allowedFields(fields, _issueCreateFields);
    final issueType = fields['issue_type'];
    if (issueType != null && !const {'issue', 'task', 'incident'}.contains(issueType)) {
      throw const ApiFailure(FailureKind.validation);
    }
    return writeRecord('POST', ['projects', '$project', 'issues'], fields);
  }
  Future<Json> updateIssue(int project, int iid, Json fields) {
    _allowedFields(fields, _issueUpdateFields);
    final stateEvent = fields['state_event'];
    if (stateEvent != null && !const {'close', 'reopen'}.contains(stateEvent)) {
      throw const ApiFailure(FailureKind.validation);
    }
    return writeRecord('PUT', ['projects', '$project', 'issues', '$iid'], fields);
  }
  Future<void> deleteIssue(int project, int iid) => removeRecord(['projects', '$project', 'issues', '$iid']);
  Future<Json> createMergeRequest(int project, Json fields) {
    _allowedFields(fields, _mergeRequestCreateFields);
    return writeRecord('POST', ['projects', '$project', 'merge_requests'], fields);
  }
  Future<Json> updateMergeRequest(int project, int iid, Json fields) {
    _allowedFields(fields, _mergeRequestUpdateFields);
    final stateEvent = fields['state_event'];
    if (stateEvent != null && !const {'close', 'reopen'}.contains(stateEvent)) {
      throw const ApiFailure(FailureKind.validation);
    }
    return writeRecord('PUT', ['projects', '$project', 'merge_requests', '$iid'], fields);
  }
  Future<void> deleteMergeRequest(int project, int iid) => removeRecord(['projects', '$project', 'merge_requests', '$iid']);
  Future<Json> approveMergeRequest(int project, int iid, String sha) =>
    writeRecord('POST', ['projects', '$project', 'merge_requests', '$iid', 'approve'], {'sha': sha});
  Future<Json> mergeRequest(int project, int iid, String sha, {
    bool squash = false,
    bool removeSourceBranch = false,
    bool autoMerge = false,
  }) =>
    writeRecord('PUT', ['projects', '$project', 'merge_requests', '$iid', 'merge'], {
      'sha': sha,
      'squash': squash,
      'should_remove_source_branch': removeSourceBranch,
      if (autoMerge) ...{
        'auto_merge': true,
        'merge_when_pipeline_succeeds': true,
        'auto_merge_strategy': 'merge_when_pipeline_succeeds',
      },
    });
  // `newEndpoint` sends GitLab 19.5's `cancel_auto_merge`, which returns the
  // merge request. The default stays on the deprecated endpoint the screen uses.
  Future<Json> cancelAutoMerge(int project, int iid, {bool newEndpoint = false}) =>
    writeRecord('POST', ['projects', '$project', 'merge_requests', '$iid',
      newEndpoint ? 'cancel_auto_merge' : 'cancel_merge_when_pipeline_succeeds'], {});
  Future<Json> rebaseMergeRequest(int project, int iid, {bool skipCi = false}) =>
    writeRecord('POST', ['projects', '$project', 'merge_requests', '$iid', 'rebase'], {
      if (skipCi) 'skip_ci': true,
    });
  Future<Json> unapproveMergeRequest(int project, int iid) => writeRecord('POST',
    ['projects', '$project', 'merge_requests', '$iid', 'unapprove'], {});
  Future<Json> createTodo(int project, String resource, int iid) => writeRecord('POST',
    ['projects', '$project', _issueOrMergeRequest(resource), '$iid', 'todo'], {});
  Future<Json> createNote(int project, String resource, int iid, String body) =>
    writeRecord('POST', ['projects', '$project', _issueOrMergeRequest(resource), '$iid', 'notes'], {'body': body});
  Future<Json> updateNote(int project, String resource, int iid, int note, String body) =>
    writeRecord('PUT', ['projects', '$project', _issueOrMergeRequest(resource), '$iid', 'notes', '$note'], {'body': body});
  Future<Json> createDiscussion(int project, String resource, int iid, String body, {Json? position}) =>
    writeRecord('POST', ['projects', '$project', _issueOrMergeRequest(resource), '$iid', 'discussions'],
      {'body': body, 'position': ?_allowedPosition(position)});
  Future<Json> createDiscussionNote(int project, String resource, int iid, String discussion, String body) =>
    writeRecord('POST', ['projects', '$project', _issueOrMergeRequest(resource), '$iid', 'discussions', discussion, 'notes'],
      {'body': body});
  Future<Json> updateDiscussionNote(int project, String resource, int iid, String discussion, int note, String body) =>
    writeRecord('PUT', ['projects', '$project', _issueOrMergeRequest(resource), '$iid', 'discussions', discussion, 'notes', '$note'],
      {'body': body});
  Future<Json> setDiscussionResolved(int project, String resource, int iid, String discussion, bool resolved) =>
    writeRecord('PUT', ['projects', '$project', _issueOrMergeRequest(resource), '$iid', 'discussions', discussion],
      {'resolved': resolved});
  Future<Json> createDraftNote(int project, int iid, String note, {String? commitId, Json? position}) =>
    writeRecord('POST', ['projects', '$project', 'merge_requests', '$iid', 'draft_notes'],
      {'note': note, 'commit_id': ?commitId, 'position': ?_allowedPosition(position)});
  Future<Json> updateDraftNote(int project, int iid, int note, String body) =>
    writeRecord('PUT', ['projects', '$project', 'merge_requests', '$iid', 'draft_notes', '$note'], {'note': body});
  Future<void> deleteDraftNote(int project, int iid, int note) =>
    removeRecord(['projects', '$project', 'merge_requests', '$iid', 'draft_notes', '$note']);
  Future<void> publishDraftNotes(int project, int iid) =>
    writeEmpty('POST', ['projects', '$project', 'merge_requests', '$iid', 'draft_notes', 'bulk_publish']);
  Future<void> deleteDiscussionNote(int project, String resource, int iid, String discussion, int note) =>
    removeRecord(['projects', '$project', _issueOrMergeRequest(resource), '$iid', 'discussions', discussion, 'notes', '$note']);
  Future<void> deleteNote(int project, String resource, int iid, int note) =>
    removeRecord(['projects', '$project', _issueOrMergeRequest(resource), '$iid', 'notes', '$note']);
  Future<Json> applySuggestion(int suggestionId, {String? commitMessage}) =>
    writeRecord('PUT', ['suggestions', '$suggestionId', 'apply'], {
      if (commitMessage != null && commitMessage.trim().isNotEmpty)
        'commit_message': commitMessage.trim(),
    });
  Future<Json> batchApplySuggestions(List<int> suggestionIds, {String? commitMessage}) =>
    writeRecord('PUT', ['suggestions', 'batch_apply'], {
      'ids': suggestionIds,
      if (commitMessage != null && commitMessage.trim().isNotEmpty)
        'commit_message': commitMessage.trim(),
    });
  Future<Json> createBranch(int project, String branch, String ref) =>
    writeRecord('POST', ['projects', '$project', 'repository', 'branches'], {'branch': branch, 'ref': ref});
  Future<void> deleteBranch(int project, String branch) => removeRecord(['projects', '$project', 'repository', 'branches', branch]);
  Future<Json> createTag(int project, String name, String ref, {String message = ''}) =>
    writeRecord('POST', ['projects', '$project', 'repository', 'tags'],
      {'tag_name': name, 'ref': ref, if (message.isNotEmpty) 'message': message});
  Future<void> deleteTag(int project, String name) => removeRecord(['projects', '$project', 'repository', 'tags', name]);
  Future<Json> createRepositoryFile(int project, String path, {required String branch,
      required String content, required String message}) =>
    writeRecord('POST', ['projects', '$project', 'repository', 'files', path], {
      'branch': branch, 'content': content, 'commit_message': message,
    });
  Future<Json> updateRepositoryFile(int project, String path, {required String branch,
      required String content, required String message, required String lastCommit}) {
    if (lastCommit.trim().isEmpty) { throw const ApiFailure(FailureKind.validation); }
    return writeRecord('PUT', ['projects', '$project', 'repository', 'files', path], {
      'branch': branch, 'content': content, 'commit_message': message, 'last_commit_id': lastCommit,
    });
  }
  Future<void> deleteFile(int project, String path, {required String branch, required String message, required String lastCommit}) =>
    removeRecord(['projects', '$project', 'repository', 'files', path], data: {
      'branch': branch, 'commit_message': message, 'last_commit_id': lastCommit,
    });
  Future<Json> fileMetadata(int project, String path, String ref) async {
    final value = await _read(instance.api(['projects', '$project', 'repository', 'files', path], {'ref': ref}), method: 'HEAD');
    final size = int.tryParse(value.headers.value('x-gitlab-size') ?? '');
    if (size != null && size > GitLabApi.maxTextBytes) { throw const ApiFailure(FailureKind.tooLarge); }
    final commit = value.headers.value('x-gitlab-last-commit-id');
    if (commit == null || commit.isEmpty) { throw const ApiFailure(FailureKind.invalidResponse); }
    return {'last_commit_id': commit, 'size': size};
  }
  Future<Json> commit(int project, String sha) =>
      record(['projects', '$project', 'repository', 'commits', sha]);
  Future<ApiPage<Json>> commitDiff(int project, String sha, {Map<String, String> query = const {}, Uri? next}) =>
      records(['projects', '$project', 'repository', 'commits', sha, 'diff'], query: query, next: next);
  Future<Json> createPipeline(
    int project,
    String ref, {
    List<Map<String, String>>? variables,
  }) {
    for (final variable in variables ?? const <Map<String, String>>[]) {
      _allowedFields(variable, const {'key', 'value', 'variable_type'});
      if (variable.containsKey('variable_type') &&
          !const {'env_var', 'file'}.contains(variable['variable_type'])) {
        throw const ApiFailure(FailureKind.validation);
      }
    }
    return writeRecord('POST', ['projects', '$project', 'pipeline'], {
        'ref': ref,
        if (variables != null && variables.isNotEmpty) 'variables': variables,
      });
  }
  Future<Json> pipelineAction(int project, int pipeline, String action) {
    if (!const ['retry', 'cancel'].contains(action)) { throw const ApiFailure(FailureKind.unsupported); }
    return writeRecord('POST', ['projects', '$project', 'pipelines', '$pipeline', action], {});
  }
  Future<void> deletePipeline(int project, int pipeline) => removeRecord(['projects', '$project', 'pipelines', '$pipeline']);
  Future<TestReportSummary> pipelineTestReportSummary(int project, int pipeline) async {
    final uri = instance.api(['projects', '$project', 'pipelines', '$pipeline', 'test_report_summary']);
    final json = await _object(uri);
    return TestReportSummary.fromJson(json);
  }
  Future<PipelineTestReportPage> pipelineTestReport(
    int project,
    int pipeline, {
    int perPage = 30,
    Uri? next,
  }) async {
    final effectivePerPage = next != null && next.queryParameters.containsKey('per_page')
        ? int.tryParse(next.queryParameters['per_page']!) ?? perPage
        : perPage;
    final first = instance.api(
      ['projects', '$project', 'pipelines', '$pipeline', 'test_report'],
      {'per_page': '$effectivePerPage'},
    );
    _validateContinuation(first, next);
    try {
      final target = next ?? first;
      final result = await _read(target);
      final decoded = jsonDecode(utf8.decode(result.bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected object for test report');
      }
      final nextUri = nextPageUri(
        instance: instance,
        current: target,
        headers: result.headers.map,
      );
      return PipelineTestReportPage.fromJson(decoded, next: nextUri);
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
  Future<Json> jobAction(int project, int job, String action) {
    if (!const ['retry', 'cancel', 'play'].contains(action)) { throw const ApiFailure(FailureKind.unsupported); }
    return writeRecord('POST', ['projects', '$project', 'jobs', '$job', action], {});
  }
  Future<String> jobTrace(int project, int job, {int offset = 0}) async {
    final chunk = await jobTraceChunk(project, job, offset: offset);
    return utf8.decode(chunk.bytes, allowMalformed: true);
  }
  Future<Json> createRelease(int project, Json fields) {
    _allowedFields(fields, const {'tag_name', 'name', 'description'});
    final tag = fields['tag_name'];
    if (tag is! String || tag.trim().isEmpty) { throw const ApiFailure(FailureKind.validation); }
    return writeRecord('POST', ['projects', '$project', 'releases'], fields);
  }
  Future<Json> updateRelease(int project, String tag, Json fields) {
    _allowedFields(fields, const {'name', 'description'});
    return writeRecord('PUT', ['projects', '$project', 'releases', tag], fields);
  }
  Future<void> deleteRelease(int project, String tag) => removeRecord(['projects', '$project', 'releases', tag]);
  Future<Json> createLabel(int project, Json fields) {
    _allowedFields(fields, const {'name', 'color', 'description'});
    return writeRecord('POST', ['projects', '$project', 'labels'], fields);
  }
  Future<Json> updateLabel(int project, int label, Json fields) {
    _allowedFields(fields, const {'name', 'color', 'description'});
    return writeRecord('PUT', ['projects', '$project', 'labels', '$label'], fields);
  }
  Future<void> deleteLabel(int project, int label) =>
    removeRecord(['projects', '$project', 'labels', '$label']);
  Future<Json> createMilestone(int project, Json fields) {
    _allowedFields(fields, const {'title', 'description', 'start_date', 'due_date'});
    return writeRecord('POST', ['projects', '$project', 'milestones'], fields);
  }
  Future<Json> updateMilestone(int project, int milestone, Json fields) {
    _allowedFields(fields, const {'title', 'description', 'start_date', 'due_date'});
    return writeRecord('PUT', ['projects', '$project', 'milestones', '$milestone'], fields);
  }
  Future<Json> setMilestoneState(int project, int milestone, String stateEvent) {
    if (!const {'activate', 'close'}.contains(stateEvent)) {
      throw const ApiFailure(FailureKind.validation);
    }
    return writeRecord('PUT', ['projects', '$project', 'milestones', '$milestone'], {'state_event': stateEvent});
  }
  Future<void> deleteMilestone(int project, int milestone) =>
    removeRecord(['projects', '$project', 'milestones', '$milestone']);
  Future<Json> createBoard(int project, String name) =>
    writeRecord('POST', ['projects', '$project', 'boards'], {'name': name});
  Future<Json> renameBoard(int project, int board, String name) =>
    writeRecord('PUT', ['projects', '$project', 'boards', '$board'], {'name': name});
  Future<void> deleteBoard(int project, int board) =>
    removeRecord(['projects', '$project', 'boards', '$board']);
  Future<Json> setBoardSystemListHidden(int project, int board, String list, bool hidden) {
    final field = switch (list) {
      'backlog' => 'hide_backlog_list',
      'closed' => 'hide_closed_list',
      _ => throw const ApiFailure(FailureKind.validation),
    };
    return writeRecord('PUT', ['projects', '$project', 'boards', '$board'], {field: hidden});
  }
  Future<Json> createBoardList(int project, int board, int labelId) =>
    writeRecord('POST', ['projects', '$project', 'boards', '$board', 'lists'], {'label_id': labelId});
  Future<Json> moveBoardList(int project, int board, int list, int position) =>
    writeRecord('PUT', ['projects', '$project', 'boards', '$board', 'lists', '$list'], {'position': position});
  Future<void> deleteBoardList(int project, int board, int list) =>
    removeRecord(['projects', '$project', 'boards', '$board', 'lists', '$list']);
  Future<Json> moveBoardCard(int project, int iid, Json fields) {
    _allowedFields(fields, const {'labels', 'state_event'});
    final stateEvent = fields['state_event'];
    if (stateEvent != null && !const {'close', 'reopen'}.contains(stateEvent)) {
      throw const ApiFailure(FailureKind.validation);
    }
    return writeRecord('PUT', ['projects', '$project', 'issues', '$iid'], fields);
  }
  Future<Json> createSnippet(int project, {required String title, required String description,
      required String visibility, required List<SnippetFileInput> files}) =>
    writeRecord('POST', ['projects', '$project', 'snippets'], createSnippetPayload(
      title: title, description: description, visibility: visibility, files: files,
    ));
  Future<Json> updateSnippet(int project, int snippet, {required ProjectSnippet before,
      required String title, required String description, required String visibility,
      required String fileName, required String content, required String previousContent}) {
    before.requireProject(project);
    if (before.id != snippet) { throw const ApiFailure(FailureKind.validation); }
    return writeRecord('PUT', ['projects', '$project', 'snippets', '$snippet'], updateSingleFileSnippetPayload(
      before: before, title: title, description: description, visibility: visibility,
      fileName: fileName, content: content, previousContent: previousContent,
    ));
  }
  Future<Json> updateSnippetMetadata(int project, int snippet, {required String title,
      required String description, required String visibility, required List<String> currentPaths}) =>
    writeRecord('PUT', ['projects', '$project', 'snippets', '$snippet'], updateSnippetPayload(
      title: title, description: description, visibility: visibility, currentPaths: currentPaths, actions: const [],
    ));
  Future<Json> updateSnippetFiles(int project, int snippet, {required String title,
      required String description, required String visibility, required List<String> currentPaths,
      required List<SnippetFileAction> actions}) {
    if (actions.any((action) => action.type == SnippetFileActionType.delete)) {
      throw const ApiFailure(FailureKind.validation);
    }
    return writeRecord('PUT', ['projects', '$project', 'snippets', '$snippet'], updateSnippetPayload(
      title: title, description: description, visibility: visibility, currentPaths: currentPaths, actions: actions,
    ));
  }
  Future<Json> deleteSnippetFile(int project, int snippet, {required String title,
      required String description, required String visibility, required List<String> currentPaths,
      required String path}) =>
    writeRecord('PUT', ['projects', '$project', 'snippets', '$snippet'], updateSnippetPayload(
      title: title, description: description, visibility: visibility, currentPaths: currentPaths,
      actions: [SnippetFileAction.delete(path: path)],
    ));
  Future<void> deleteSnippet(int project, int snippet) =>
    removeRecord(['projects', '$project', 'snippets', '$snippet']);
  Future<void> deletePackage(int project, int package) =>
    removeRecord(['projects', '$project', 'packages', '$package']);
  Future<void> deletePackageFile(int project, int package, int file) =>
    removeRecord(['projects', '$project', 'packages', '$package', 'package_files', '$file']);
  Future<void> deleteContainerRepository(int project, int repository) =>
    removeRecord(['projects', '$project', 'registry', 'repositories', '$repository']);
  Future<void> deleteContainerTag(int project, int repository, String tag) =>
    removeRecord(['projects', '$project', 'registry', 'repositories', '$repository', 'tags', tag]);
  Future<int> effectiveProjectAccess(int project, int userId) async {
    try {
      final member = await record(['projects', '$project', 'members', 'all', '$userId']);
      return member['access_level'] is int ? member['access_level'] as int : 0;
    } on ApiFailure catch (failure) {
      if (failure.status == 404) return 0;
      rethrow;
    }
  }
  Future<Json> markTodoDone(int id) => writeRecord('POST', ['todos', '$id', 'mark_as_done'], {});

  /// `POST /todos/mark_as_done` answers 204 with no body.
  Future<void> markAllTodosDone() async { await _read(instance.api(['todos', 'mark_as_done']), method: 'POST'); }

  /// `GET /search`, `GET /projects/:id/search` or `GET /groups/:id/search`.
  Future<ApiPage<Json>> search(String scope, String query, {int? projectId, int? groupId, Uri? next}) {
    if (query.trim().isEmpty) { throw const ApiFailure(FailureKind.validation); }
    final path = [
      if (projectId != null) ...['projects', '$projectId'] else if (groupId != null) ...['groups', '$groupId'],
      'search',
    ];
    return records(path, query: {'scope': scope, 'search': query.trim()}, next: next);
  }

  Future<ApiPage<Json>> groups({String search = '', bool mine = true, Uri? next}) => records(['groups'], query: {
    if (mine) 'min_access_level': '10' else 'all_available': 'true',
    'order_by': 'name', 'sort': 'asc',
    if (search.trim().isNotEmpty) 'search': search.trim(),
  }, next: next);
  Future<Json> group(int id) => record(['groups', '$id'], query: {'with_projects': 'false'});
  Future<Json> groupByPath(String fullPath, {bool Function()? isCurrent}) async {
    final path = _validatedGroupPath(fullPath);
    _requireCurrentGroupRequest(isCurrent);
    final value = await _cachedRead<Json>(
      'group-path:$path',
      () async {
        final result = await _read(instance.api(['groups', path], {'with_projects': 'false'}),
          headers: {'Cache-Control': 'max-age=0'});
        try {
          final decoded = objectJson(jsonDecode(utf8.decode(result.bytes)));
          final id = requiredInt(decoded, 'id');
          if (requiredString(decoded, 'full_path') != path) {
            throw const FormatException('Wrong group');
          }
          final group = Map<String, dynamic>.unmodifiable({
            'id': id,
            'name': requiredString(decoded, 'name'),
            'full_path': path,
            'visibility': optionalString(decoded, 'visibility'),
            'description': optionalString(decoded, 'description'),
          });
          return _CacheRead<Json>(group,
            _cacheTtl(result.headers, const Duration(seconds: 30)));
        } on FormatException { throw const ApiFailure(FailureKind.invalidResponse); }
      },
      cost: (group) => 256 + 2 * group.entries.fold<int>(0,
        (total, entry) => total + entry.key.length + entry.value.toString().length),
    );
    _requireCurrentGroupRequest(isCurrent);
    return value;
  }
  Future<ApiPage<Json>> subgroups(int id, {Uri? next}) =>
      records(['groups', '$id', 'subgroups'], query: {'order_by': 'name', 'sort': 'asc'}, next: next);
  Future<ApiPage<Json>> groupProjects(int id, {Uri? next}) =>
      records(['groups', '$id', 'projects'], query: {'order_by': 'last_activity_at', 'sort': 'desc'}, next: next);

  /// Activity: the signed-in user's events, a project's, or another user's.
  Future<ApiPage<Json>> events({int? projectId, int? userId, Uri? next}) => records([
    if (projectId != null) ...['projects', '$projectId', 'events']
    else if (userId != null) ...['users', '$userId', 'events']
    else 'events',
  ], next: next);

  List<String> _awardPath(int project, String resource, int iid, int? note) => [
    'projects', '$project', resource, '$iid', if (note != null) ...['notes', '$note'], 'award_emoji',
  ];
  Future<ApiPage<Json>> awardEmoji(int project, String resource, int iid, {int? note, Uri? next}) =>
      records(_awardPath(project, resource, iid, note), query: {'per_page': '100'}, next: next);
  Future<Json> addAwardEmoji(int project, String resource, int iid, String name, {int? note}) =>
      writeRecord('POST', _awardPath(project, _issueOrMergeRequest(resource), iid, note), {'name': name});
  Future<void> removeAwardEmoji(int project, String resource, int iid, int awardId, {int? note}) =>
      removeRecord([..._awardPath(project, _issueOrMergeRequest(resource), iid, note), '$awardId']);

  /// `POST .../subscribe` and `.../unsubscribe`. GitLab answers 304 when the
  /// state already matches, which the client reports as success.
  Future<void> setSubscribed(int project, String resource, int iid, bool subscribed) async {
    try {
      await _read(instance.api(['projects', '$project', _issueOrMergeRequest(resource), '$iid', subscribed ? 'subscribe' : 'unsubscribe']),
        method: 'POST');
    } on ApiFailure catch (failure) {
      if (failure.status != 304) rethrow;
    }
  }

  Future<ApiPage<Json>> fileHistory(int project, String path, String ref, {Uri? next}) =>
      records(['projects', '$project', 'repository', 'commits'], query: {'path': path, 'ref_name': ref}, next: next);

  /// Blame ranges for one file at a fixed commit: `[{commit, lines}]`.
  Future<List<Json>> blame(int project, String path, String sha) async {
    final value = await _read(instance.api(['projects', '$project', 'repository', 'files', path, 'blame'], {'ref': sha}),
      maxBytes: GitLabApi.maxTextBytes);
    try {
      final decoded = jsonDecode(utf8.decode(value.bytes));
      if (decoded is! List) throw const FormatException('Expected list');
      return decoded.whereType<Json>().toList();
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// Language name to percentage, largest first.
  Future<List<(String, double)>> languages(int project) async {
    final value = await record(['projects', '$project', 'languages']);
    final entries = <(String, double)>[
      for (final entry in value.entries)
        if (entry.value is num) (entry.key, (entry.value as num).toDouble()),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return entries;
  }

  Future<Json> wikiPage(int project, String slug) =>
      record(['projects', '$project', 'wikis', slug], query: {'render_html': 'false'});
  Future<Json> playPipelineSchedule(int project, int schedule) =>
      writeRecord('POST', ['projects', '$project', 'pipeline_schedules', '$schedule', 'play'], {});
  Future<Json> forkProject(int project, {String? namespacePath}) =>
      writeRecord('POST', ['projects', '$project', 'fork'], {'namespace_path': ?namespacePath});

  /// Whether [username] has starred the project, from `GET /projects/:id/starrers`.
  /// The search also matches display names, so pages are read until the exact
  /// username appears; past ten pages the answer is unknown and this throws.
  Future<bool> hasStarred(int project, String username) async {
    Uri? next;
    for (var pages = 0; pages < 10; pages++) {
      final page = await records(['projects', '$project', 'starrers'], query: {'search': username, 'per_page': '100'},
        next: next);
      if (page.items.any((item) {
        final user = item['user'];
        return user is Map && user['username'] == username;
      })) {
        return true;
      }
      next = page.next;
      if (next == null) return false;
    }
    throw ApiFailure(FailureKind.unsupported, title: l10n.cannotConfirmStarState,
      detail: l10n.tooManyStarrersConfirmWeb);
  }

  Future<Json> uploadProjectFile(
    int project, {
    required String filename,
    required List<int> bytes,
    String? contentType,
    Duration? sendTimeout,
  }) async {
    if (bytes.length > GitLabApi.maxUploadBytes) {
      throw const ApiFailure(FailureKind.attachmentTooLarge);
    }
    DioMediaType? type;
    final declared = contentType?.trim() ?? '';
    if (declared.isNotEmpty) {
      try {
        type = DioMediaType.parse(declared);
      } on FormatException {
        throw const ApiFailure(FailureKind.unsupported);
      }
    }
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename, contentType: type),
    });
    try {
      final result = await _send(
        instance.api(['projects', '$project', 'uploads']),
        method: 'POST',
        data: form,
        sendTimeout: sendTimeout,
      );
      return objectJson(jsonDecode(utf8.decode(result.bytes)));
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// `GET /projects/:id/uploads/:secret/:filename`. Binary is kept; redirects are not followed.
  Future<Uint8List> projectUpload(
    int project,
    String secret,
    String filename, {
    int maxBytes = 8 * 1024 * 1024,
    void Function(String contentType)? onContentType,
  }) async {
    if (!projectUploadNamesOk(secret, filename)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    try {
      final result = await _read(
        instance.api(['projects', '$project', 'uploads', secret, filename]),
        maxBytes: maxBytes,
        onContentType: onContentType,
      );
      return result.bytes;
    } on ApiFailure catch (failure) {
      if (failure.kind != FailureKind.tooLarge) rethrow;
      throw ApiFailure(FailureKind.tooLarge, title: l10n.exceedsSizeLimit, detail: l10n.imageExceedsPreviewLimit);
    }
  }
}

String _validatedGroupPath(String value) {
  final path = value.trim();
  if (path.isEmpty || path.length > 1024 ||
      path.split('/').any((part) => part == '.' || part == '..') ||
      !RegExp(r'^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$').hasMatch(path)) {
    throw const ApiFailure(FailureKind.validation);
  }
  return path;
}

void _requireCurrentGroupRequest(bool Function()? isCurrent) {
  if (isCurrent != null && !isCurrent()) throw const ApiFailure(FailureKind.cancelled);
}
