part of 'gitlab_api.dart';

typedef Json = Map<String, dynamic>;

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
  Future<Project> createProject({required String name, String? path, String description = '',
      String visibility = 'private', bool initialize = true}) async =>
    Project.fromJson(await writeRecord('POST', ['projects'], {
      'name': name, 'path': ?path, 'description': description, 'visibility': visibility, 'initialize_with_readme': initialize,
    }));
  Future<Project> editProject(int id, {required String name, required String description}) async =>
    Project.fromJson(await writeRecord('PUT', ['projects', '$id'], {'name': name, 'description': description}));
  Future<void> deleteProject(int id) => removeRecord(['projects', '$id']);
  Future<Json> setStar(int id, bool starred) => writeRecord('POST', ['projects', '$id', starred ? 'star' : 'unstar'], {});
  Future<Json> createIssue(int project, Json fields) => writeRecord('POST', ['projects', '$project', 'issues'], fields);
  Future<Json> updateIssue(int project, int iid, Json fields) => writeRecord('PUT', ['projects', '$project', 'issues', '$iid'], fields);
  Future<void> deleteIssue(int project, int iid) => removeRecord(['projects', '$project', 'issues', '$iid']);
  Future<Json> createMergeRequest(int project, Json fields) => writeRecord('POST', ['projects', '$project', 'merge_requests'], fields);
  Future<Json> updateMergeRequest(int project, int iid, Json fields) => writeRecord('PUT', ['projects', '$project', 'merge_requests', '$iid'], fields);
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
  Future<Json> cancelAutoMerge(int project, int iid) =>
    writeRecord('POST', ['projects', '$project', 'merge_requests', '$iid', 'cancel_merge_when_pipeline_succeeds'], {});
  Future<Json> rebaseMergeRequest(int project, int iid, {bool skipCi = false}) =>
    writeRecord('POST', ['projects', '$project', 'merge_requests', '$iid', 'rebase'], {
      if (skipCi) 'skip_ci': true,
    });
  Future<Json> createNote(int project, String resource, int iid, String body) =>
    writeRecord('POST', ['projects', '$project', resource, '$iid', 'notes'], {'body': body});
  Future<Json> updateNote(int project, String resource, int iid, int note, String body) =>
    writeRecord('PUT', ['projects', '$project', resource, '$iid', 'notes', '$note'], {'body': body});
  Future<void> deleteNote(int project, String resource, int iid, int note) =>
    removeRecord(['projects', '$project', resource, '$iid', 'notes', '$note']);
  Future<Json> createBranch(int project, String branch, String ref) =>
    writeRecord('POST', ['projects', '$project', 'repository', 'branches'], {'branch': branch, 'ref': ref});
  Future<void> deleteBranch(int project, String branch) => removeRecord(['projects', '$project', 'repository', 'branches', branch]);
  Future<Json> createTag(int project, String name, String ref, {String message = ''}) =>
    writeRecord('POST', ['projects', '$project', 'repository', 'tags'],
      {'tag_name': name, 'ref': ref, if (message.isNotEmpty) 'message': message});
  Future<void> deleteTag(int project, String name) => removeRecord(['projects', '$project', 'repository', 'tags', name]);
  Future<Json> saveFile(int project, String path, {required String branch, required String content,
      required String message, String? lastCommit}) =>
    writeRecord(lastCommit == null ? 'POST' : 'PUT', ['projects', '$project', 'repository', 'files', path], {
      'branch': branch, 'content': content, 'commit_message': message, 'last_commit_id': ?lastCommit,
    });
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
  Future<Json> createPipeline(int project, String ref) => writeRecord('POST', ['projects', '$project', 'pipeline'], {'ref': ref});
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
  Future<Json> createRelease(int project, Json fields) => writeRecord('POST', ['projects', '$project', 'releases'], fields);
  Future<Json> updateRelease(int project, String tag, Json fields) => writeRecord('PUT', ['projects', '$project', 'releases', tag], fields);
  Future<void> deleteRelease(int project, String tag) => removeRecord(['projects', '$project', 'releases', tag]);
  Future<Json> markTodoDone(int id) => writeRecord('POST', ['todos', '$id', 'mark_as_done'], {});

  Future<Json> uploadProjectFile(
    int project, {
    required String filename,
    required List<int> bytes,
    String? contentType,
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
      );
      return objectJson(jsonDecode(utf8.decode(result.bytes)));
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// `GET /projects/:id/uploads/:secret/:filename`. Binary is kept; redirects are not followed.
  Future<Uint8List> projectUpload(int project, String secret, String filename, {int maxBytes = 8 * 1024 * 1024}) async {
    if (!projectUploadNamesOk(secret, filename)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    try {
      final result = await _read(instance.api(['projects', '$project', 'uploads', secret, filename]), maxBytes: maxBytes);
      return result.bytes;
    } on ApiFailure catch (failure) {
      if (failure.kind != FailureKind.tooLarge) rethrow;
      throw const ApiFailure(FailureKind.tooLarge, title: '超過大小上限', detail: '這張圖片超過附件預覽上限。');
    }
  }
}
