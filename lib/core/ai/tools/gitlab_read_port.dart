import 'dart:convert';

import '../../gitlab_api.dart';

typedef AiJson = Map<String, Object?>;

final class AiPortRead<T> {
  const AiPortRead(this.value, {required this.requestCount});

  final T value;
  final int requestCount;
}

final class AiTreeItem {
  const AiTreeItem({
    required this.name,
    required this.path,
    required this.type,
  });

  final String name;
  final String path;
  final String type;
}

abstract interface class AiGitLabReadPort {
  Future<AiPortRead<String>> readFile(String sha, String path);
  Future<AiPortRead<List<AiTreeItem>>> listDirectory(String sha, String path);
  Future<AiPortRead<AiJson>> issue(int iid);
  Future<AiPortRead<AiJson>> mergeRequest(int iid);
  Future<AiPortRead<AiJson>> mergeRequestDiff(
    int iid, {
    required String headSha,
    required String baseSha,
  });
  Future<AiPortRead<List<AiJson>>> pipelineJobs(int pipelineId);
  Future<AiPortRead<String>> jobLog(int jobId);
  Future<AiPortRead<AiJson>> commit(String sha);
  Future<AiPortRead<List<AiJson>>> commitDiff(String sha);
  Future<AiPortRead<List<AiJson>>> search(String scope, String query);
}

final class GitLabAiReadPort implements AiGitLabReadPort {
  GitLabAiReadPort(this._api, this.projectId);

  final GitLabApi _api;
  final int projectId;

  @override
  Future<AiPortRead<String>> readFile(String sha, String path) async =>
      AiPortRead(await _api.textFile(projectId, sha, path), requestCount: 2);

  @override
  Future<AiPortRead<List<AiTreeItem>>> listDirectory(
    String sha,
    String path,
  ) async {
    final items = <AiTreeItem>[];
    Uri? next;
    var requests = 0;
    do {
      final page = await _api.tree(projectId, sha, path: path, next: next);
      requests++;
      items.addAll(
        page.items.map(
          (item) =>
              AiTreeItem(name: item.name, path: item.path, type: item.type),
        ),
      );
      next = page.next;
    } while (next != null && requests < 4);
    return AiPortRead(List.unmodifiable(items), requestCount: requests);
  }

  @override
  Future<AiPortRead<AiJson>> issue(int iid) =>
      _resourceWithNotes('issues', iid);

  @override
  Future<AiPortRead<AiJson>> mergeRequest(int iid) =>
      _resourceWithNotes('merge_requests', iid);

  Future<AiPortRead<AiJson>> _resourceWithNotes(
    String resource,
    int iid,
  ) async {
    final value = await _api.record([
      'projects',
      '$projectId',
      resource,
      '$iid',
    ]);
    final notes = await _api.records(
      ['projects', '$projectId', resource, '$iid', 'notes'],
      query: const {'order_by': 'created_at', 'sort': 'desc', 'per_page': '30'},
    );
    return AiPortRead(<String, Object?>{
      ...value,
      'notes': notes.items,
    }, requestCount: 2);
  }

  @override
  Future<AiPortRead<AiJson>> mergeRequestDiff(
    int iid, {
    required String headSha,
    required String baseSha,
  }) async {
    final versions = await _api.records(
      ['projects', '$projectId', 'merge_requests', '$iid', 'versions'],
      query: const {'per_page': '100'},
    );
    final version = versions.items.cast<AiJson?>().firstWhere(
      (candidate) =>
          candidate?['head_commit_sha'] == headSha &&
          candidate?['base_commit_sha'] == baseSha,
      orElse: () => null,
    );
    final versionId = version?['id'];
    if (versionId is! int) {
      throw const FormatException('Merge request has no diff version.');
    }
    final value = await _api.record([
      'projects',
      '$projectId',
      'merge_requests',
      '$iid',
      'versions',
      '$versionId',
    ]);
    return AiPortRead(<String, Object?>{
      'diff_refs': {
        'head_sha': value['head_commit_sha'] ?? version?['head_commit_sha'],
        'base_sha': value['base_commit_sha'] ?? version?['base_commit_sha'],
      },
      'changes': value['diffs'],
    }, requestCount: 2);
  }

  @override
  Future<AiPortRead<List<AiJson>>> pipelineJobs(int pipelineId) async {
    final page = await _api.records(
      ['projects', '$projectId', 'pipelines', '$pipelineId', 'jobs'],
      query: const {'per_page': '100'},
    );
    return AiPortRead(page.items, requestCount: 1);
  }

  @override
  Future<AiPortRead<String>> jobLog(int jobId) async {
    final chunk = await _api.jobTraceChunk(
      projectId,
      jobId,
      maxBytes: GitLabApi.maxTextBytes,
    );
    return AiPortRead(
      utf8.decode(chunk.bytes, allowMalformed: true),
      requestCount: 1,
    );
  }

  @override
  Future<AiPortRead<AiJson>> commit(String sha) async =>
      AiPortRead(await _api.commit(projectId, sha), requestCount: 1);

  @override
  Future<AiPortRead<List<AiJson>>> commitDiff(String sha) async {
    final page = await _api.commitDiff(
      projectId,
      sha,
      query: const {'per_page': '100'},
    );
    return AiPortRead(page.items, requestCount: 1);
  }

  @override
  Future<AiPortRead<List<AiJson>>> search(String scope, String query) async {
    final page = await _api.search(scope, query, projectId: projectId);
    return AiPortRead(page.items, requestCount: 1);
  }
}
