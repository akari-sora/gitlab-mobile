import 'dart:convert';

import '../../failure.dart';
import '../../gitlab_api.dart';
import '../../models.dart' show ApiPage;
import '../../request_meter.dart';
import '../../snippet_models.dart' show validatedSnippetPath;
import 'sensitive_paths.dart';

typedef AiJson = Map<String, Object?>;

final class AiPortRead<T> {
  const AiPortRead(
    this.value, {
    required this.requestCount,
    this.incomplete = false,
  });

  final T value;
  final int requestCount;
  final bool incomplete;
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

/// Additional project reads, kept separate so existing narrow read ports do
/// not advertise tools they cannot execute.
abstract interface class AiGitLabFieldReadPort {
  Future<AiPortRead<AiJson>> release(String tagName);
  Future<AiPortRead<AiJson>> milestone(int milestoneId);
  Future<AiPortRead<AiJson>> snippet(
    int snippetId, {
    String? filePath,
    String ref = 'HEAD',
  });
}

final class GitLabAiReadPort
    implements AiGitLabReadPort, AiGitLabFieldReadPort {
  GitLabAiReadPort(this._api, this.projectId);

  static const _aiMaxAge = Duration(seconds: 60);

  final GitLabApi _api;
  final int projectId;

  @override
  Future<AiPortRead<AiJson>> release(String tagName) async {
    final value = await _api.record([
      'projects', '$projectId', 'releases', tagName,
    ]);
    if (value['tag_name'] != tagName) {
      throw const FormatException('releaseIdentityMismatch');
    }
    return AiPortRead(value, requestCount: 1);
  }

  @override
  Future<AiPortRead<AiJson>> milestone(int milestoneId) async {
    final value = await _api.record([
      'projects', '$projectId', 'milestones', '$milestoneId',
    ]);
    final iid = value['iid'];
    if (value['id'] != milestoneId || value['project_id'] != projectId ||
        iid is! int || iid <= 0) {
      throw const FormatException('milestoneIdentityMismatch');
    }
    return AiPortRead(value, requestCount: 1);
  }

  @override
  Future<AiPortRead<AiJson>> snippet(
    int snippetId, {
    String? filePath,
    String ref = 'HEAD',
  }) async {
    if (filePath != null && validatedSnippetPath(filePath) != filePath) {
      throw const FormatException('invalidSnippetPath');
    }
    final value = await _api.record([
      'projects', '$projectId', 'snippets', '$snippetId',
    ]);
    if (value['id'] != snippetId || value['project_id'] != projectId) {
      throw const FormatException('snippetIdentityMismatch');
    }
    final files = value['files'];
    final paths = <String>[];
    if (files is List<Object?>) {
      for (final file in files) {
        if (file is! AiJson) {
          throw const FormatException('invalidSnippetFiles');
        }
        final path = file['path'] ?? file['file_path'];
        if (path is! String || validatedSnippetPath(path) != path ||
            paths.contains(path)) {
          throw const FormatException('invalidSnippetFiles');
        }
        paths.add(path);
      }
    } else if (files != null) {
      throw const FormatException('invalidSnippetFiles');
    }
    final result = <String, Object?>{
      ...value,
      'files': [for (final path in paths) {'path': path}],
    };
    if (paths.isEmpty) {
      result['content_unavailable'] = 'snippetFileListUnknown';
      return AiPortRead(result, requestCount: 1);
    }
    final selected = filePath ?? paths.first;
    if (!paths.contains(selected)) {
      result['content_unavailable'] = 'snippetFileNotFound';
      return AiPortRead(result, requestCount: 1);
    }
    if (isSensitiveRepositoryPath(selected)) {
      result['content_unavailable'] = 'sensitivePath';
      return AiPortRead(result, requestCount: 1);
    }
    final content = await _api.snippetText(
      projectId,
      snippetId,
      ref: ref,
      filePath: selected,
    );
    result['file'] = {'path': selected, 'ref': ref, 'content': content};
    return AiPortRead(result, requestCount: 2);
  }

  @override
  Future<AiPortRead<String>> readFile(String sha, String path) async {
    final measured = await _measure(
      () => _api.textFile(projectId, sha, path, allowDisk: false),
    );
    return AiPortRead(measured.value, requestCount: measured.requestCount);
  }

  @override
  Future<AiPortRead<List<AiTreeItem>>> listDirectory(
    String sha,
    String path,
  ) async {
    final measured = await _measure(() async {
      final items = <AiTreeItem>[];
      Uri? next;
      var pages = 0;
      do {
        final page = await _api.tree(
          projectId,
          sha,
          path: path,
          next: next,
          allowDisk: false,
        );
        pages++;
        items.addAll(
          page.items.map(
            (item) =>
                AiTreeItem(name: item.name, path: item.path, type: item.type),
          ),
        );
        next = page.next;
      } while (next != null && pages < 4);
      return (
        items: List<AiTreeItem>.unmodifiable(items),
        incomplete: next != null,
      );
    });
    return AiPortRead(
      measured.value.items,
      requestCount: measured.requestCount,
      incomplete: measured.value.incomplete,
    );
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
    final measured = await _measure(() async {
      final value = await _cachedRecord([
        'projects',
        '$projectId',
        resource,
        '$iid',
      ]);
      final notes = await _cachedRecords(
        ['projects', '$projectId', resource, '$iid', 'notes'],
        query: const {
          'order_by': 'created_at',
          'sort': 'desc',
          'per_page': '30',
        },
      );
      return <String, Object?>{...value, 'notes': notes.items};
    });
    return AiPortRead(<String, Object?>{
      ...measured.value,
    }, requestCount: measured.requestCount);
  }

  @override
  Future<AiPortRead<AiJson>> mergeRequestDiff(
    int iid, {
    required String headSha,
    required String baseSha,
  }) async {
    final measured = await _measure(() async {
      final versions = await _cachedRecords(
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
      final value = await _cachedRecord([
        'projects',
        '$projectId',
        'merge_requests',
        '$iid',
        'versions',
        '$versionId',
      ]);
      return <String, Object?>{
        'diff_refs': {
          'head_sha': value['head_commit_sha'] ?? version?['head_commit_sha'],
          'base_sha': value['base_commit_sha'] ?? version?['base_commit_sha'],
        },
        'changes': value['diffs'],
      };
    });
    return AiPortRead(measured.value, requestCount: measured.requestCount);
  }

  Future<AiJson> _cachedRecord(List<String> path) async {
    var read = await _api.cachedRecord(
      path,
      maxAge: _aiMaxAge,
      allowDisk: false,
    );
    if (read.lineage == CacheLineage.disk) {
      read = await _api.cachedRecord(
        path,
        fresh: true,
        maxAge: _aiMaxAge,
        allowDisk: false,
      );
    }
    _requirePublishable(read);
    return read.value;
  }

  Future<ApiPage<AiJson>> _cachedRecords(
    List<String> path, {
    Map<String, String> query = const {},
  }) async {
    var read = await _api.cachedRecords(
      path,
      query: query,
      maxAge: _aiMaxAge,
      allowDisk: false,
    );
    if (read.lineage == CacheLineage.disk) {
      read = await _api.cachedRecords(
        path,
        query: query,
        fresh: true,
        maxAge: _aiMaxAge,
        allowDisk: false,
      );
    }
    _requirePublishable(read);
    return read.value;
  }

  void _requirePublishable<T>(CachedRead<T> read) {
    if (read.dropped || read.superseded || read.lineage == CacheLineage.disk) {
      throw const ApiFailure(FailureKind.cancelled);
    }
  }

  Future<({T value, int requestCount})> _measure<T>(
    Future<T> Function() operation,
  ) async {
    final inherited = RequestMeter.current;
    if (inherited != null) {
      final before = inherited.count;
      final value = await operation();
      return (value: value, requestCount: inherited.count - before);
    }
    final meter = RequestMeter();
    final value = await meter.runAsync(operation);
    return (value: value, requestCount: meter.count);
  }

  @override
  Future<AiPortRead<List<AiJson>>> pipelineJobs(int pipelineId) async {
    final page = await _api.records(
      ['projects', '$projectId', 'pipelines', '$pipelineId', 'jobs'],
      query: const {'per_page': '100'},
    );
    return AiPortRead(
      page.items,
      requestCount: 1,
      incomplete: page.next != null,
    );
  }

  @override
  Future<AiPortRead<String>> jobLog(int jobId) async {
    final bytes = <int>[];
    int? declaredTotal;
    var offset = 0;
    var requests = 0;
    while (true) {
      final chunk = await _api.jobTraceChunk(
        projectId,
        jobId,
        offset: offset,
        maxBytes: GitLabApi.maxTextBytes,
      );
      requests += chunk.requestCount;
      if (chunk.startOffset != offset) {
        throw const FormatException('Job trace chunks are not contiguous.');
      }
      if (chunk.totalBytes != null) {
        if (declaredTotal != null && declaredTotal != chunk.totalBytes) {
          throw const FormatException('Job trace total changed while reading.');
        }
        declaredTotal = chunk.totalBytes;
      }
      if ((declaredTotal ?? 0) > GitLabApi.maxTextBytes ||
          bytes.length + chunk.bytes.length > GitLabApi.maxTextBytes) {
        throw const FormatException('Job trace exceeds the redaction limit.');
      }
      if (declaredTotal != null &&
          bytes.length + chunk.bytes.length > declaredTotal) {
        throw const FormatException('Job trace exceeds its declared total.');
      }
      bytes.addAll(chunk.bytes);
      final nextOffset = chunk.nextOffset ?? offset;
      if (chunk.isEof || chunk.bytes.isEmpty || nextOffset <= offset) {
        if (declaredTotal != null && bytes.length < declaredTotal) {
          throw const FormatException(
            'Job trace ended before its declared total.',
          );
        }
        break;
      }
      if (requests >= 4) {
        throw const FormatException('Job trace is incomplete.');
      }
      offset = nextOffset;
    }
    return AiPortRead(
      utf8.decode(bytes, allowMalformed: true),
      requestCount: requests,
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
    return AiPortRead(
      page.items,
      requestCount: 1,
      incomplete: page.next != null,
    );
  }

  @override
  Future<AiPortRead<List<AiJson>>> search(String scope, String query) async {
    final page = await _api.search(scope, query, projectId: projectId);
    return AiPortRead(
      page.items,
      requestCount: 1,
      incomplete: page.next != null,
    );
  }
}
