import 'dart:math';

import '../../core/ai/context_builders.dart';
import '../../core/ai/redaction.dart';
import '../../core/ai/tools/sensitive_paths.dart';
import '../../core/ai/tools/tool_scope.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import 'ai_chat_session.dart';

/// The redacted starting context plus immutable revisions used to bind tools.
final class AiChatContext {
  const AiChatContext({required this.built, required this.scope});

  final AiBuiltContext built;
  final AiResourceScope? scope;
}

Project? projectForAiChatOrigin(AiChatOrigin origin) => switch (origin) {
  AiGeneralOrigin() => null,
  AiJobOrigin(:final project) ||
  AiWorkItemOrigin(:final project) ||
  AiFileOrigin(:final project) => project,
};

Future<AiChatContext> loadAiChatContext({
  required AiChatOrigin origin,
  required GitLabApi api,
  required Redactor redactor,
  required String accountKey,
  required Future<void> Function() refreshSecrets,
  required bool Function() isCurrent,
}) async {
  _requireCurrent(isCurrent);
  final builder = AiContextBuilders(redactor: redactor);
  final nonce = _nonce();

  return switch (origin) {
    AiGeneralOrigin() => AiChatContext(
      built: AiBuiltContext(
        blocks: const [],
        pinnedSha: null,
        blockedSensitivePaths: const [],
        redactions: 0,
        withheldPrivateKeyContext: false,
      ),
      scope: null,
    ),
    AiJobOrigin() => _loadJob(
      origin,
      api,
      builder,
      nonce,
      accountKey,
      refreshSecrets,
      isCurrent,
    ),
    AiWorkItemOrigin(kind: AiWorkItemKind.issue) => _loadIssue(
      origin,
      api,
      builder,
      nonce,
      accountKey,
      refreshSecrets,
      isCurrent,
    ),
    AiWorkItemOrigin(kind: AiWorkItemKind.mergeRequest) => _loadMergeRequest(
      origin,
      api,
      builder,
      nonce,
      accountKey,
      refreshSecrets,
      isCurrent,
    ),
    AiFileOrigin() => _loadFile(
      origin,
      api,
      builder,
      nonce,
      accountKey,
      refreshSecrets,
      isCurrent,
    ),
  };
}

Future<AiChatContext> _loadJob(
  AiJobOrigin origin,
  GitLabApi api,
  AiContextBuilders builder,
  String nonce,
  String accountKey,
  Future<void> Function() refreshSecrets,
  bool Function() isCurrent,
) async {
  final job = await api.record([
    'projects',
    '${origin.project.id}',
    'jobs',
    '${origin.jobId}',
  ]);
  _requireCurrent(isCurrent);
  final trace = await api.jobTrace(origin.project.id, origin.jobId);
  _requireCurrent(isCurrent);
  await refreshSecrets();
  _requireCurrent(isCurrent);

  final commitSha = _optionalNestedString(job, 'commit', 'id');
  final pipelineSha = _optionalNestedString(job, 'pipeline', 'sha');
  final pipelineId = _optionalNestedInt(job, 'pipeline', 'id');
  final built = builder.job(
    AiJobContextInput(
      name: _optionalString(job, 'name') ?? origin.jobName,
      stage: _requiredString(job, 'stage'),
      status: _requiredString(job, 'status'),
      trace: trace,
      failureReason: _optionalString(job, 'failure_reason'),
      ref: _optionalString(job, 'ref'),
      pipelineId: pipelineId,
      commitSha: commitSha,
      pipelineSha: pipelineSha,
    ),
    nonce: nonce,
  );
  return AiChatContext(
    built: built,
    scope: _scope(
      accountKey: accountKey,
      api: api,
      project: origin.project,
      current: AiResourceRef(kind: AiResourceKind.job, id: origin.jobId),
      headSha: built.pinnedSha,
      pipelineId: pipelineId,
      jobId: origin.jobId,
    ),
  );
}

Future<AiChatContext> _loadIssue(
  AiWorkItemOrigin origin,
  GitLabApi api,
  AiContextBuilders builder,
  String nonce,
  String accountKey,
  Future<void> Function() refreshSecrets,
  bool Function() isCurrent,
) async {
  final item = await api.record([
    'projects',
    '${origin.project.id}',
    'issues',
    '${origin.iid}',
  ]);
  _requireCurrent(isCurrent);
  final notes = await _recentNotes(api, [
    'projects',
    '${origin.project.id}',
    'issues',
    '${origin.iid}',
    'notes',
  ], isCurrent);
  final project = await api.record(['projects', '${origin.project.id}']);
  _requireCurrent(isCurrent);
  final defaultBranch = _optionalString(project, 'default_branch');
  String? pinnedSha;
  if (defaultBranch != null && defaultBranch.isNotEmpty) {
    try {
      final branch = await api.record([
        'projects',
        '${origin.project.id}',
        'repository',
        'branches',
        defaultBranch,
      ]);
      pinnedSha = _requiredNestedString(branch, 'commit', 'id');
    } on ApiFailure catch (failure) {
      if (failure.kind != FailureKind.forbidden &&
          failure.kind != FailureKind.invisible) {
        rethrow;
      }
    }
    _requireCurrent(isCurrent);
  }
  await refreshSecrets();
  _requireCurrent(isCurrent);

  final built = builder.discussion(
    AiDiscussionContextInput(
      kind: 'issue',
      iid: origin.iid,
      title: _requiredString(item, 'title'),
      description: _optionalString(item, 'description') ?? '',
      state: _requiredString(item, 'state'),
      pinnedSha: pinnedSha,
      labels: _labels(item),
      notes: notes.map(_discussionNote).toList(growable: false),
    ),
    nonce: nonce,
  );
  return AiChatContext(
    built: built,
    scope: _scope(
      accountKey: accountKey,
      api: api,
      project: origin.project,
      current: AiResourceRef(kind: AiResourceKind.issue, id: origin.iid),
      headSha: pinnedSha,
      defaultBranch: defaultBranch,
      useProjectDefaultBranch: false,
    ),
  );
}

Future<AiChatContext> _loadMergeRequest(
  AiWorkItemOrigin origin,
  GitLabApi api,
  AiContextBuilders builder,
  String nonce,
  String accountKey,
  Future<void> Function() refreshSecrets,
  bool Function() isCurrent,
) async {
  final item = await api.record([
    'projects',
    '${origin.project.id}',
    'merge_requests',
    '${origin.iid}',
  ]);
  _requireCurrent(isCurrent);
  final headSha = _requiredNestedString(item, 'diff_refs', 'head_sha');
  final baseSha = _requiredNestedString(item, 'diff_refs', 'base_sha');

  final versions = await api.records(
    [
      'projects',
      '${origin.project.id}',
      'merge_requests',
      '${origin.iid}',
      'versions',
    ],
    query: const {'per_page': '100'},
  );
  _requireCurrent(isCurrent);
  final version = versions.items.cast<Json?>().firstWhere(
    (candidate) =>
        candidate?['head_commit_sha'] == headSha &&
        (candidate?['base_commit_sha'] == null ||
            candidate?['base_commit_sha'] == baseSha),
    orElse: () => null,
  );
  final versionId = version?['id'];
  if (versionId is! int) {
    throw const FormatException('Merge request has no matching diff version.');
  }
  final detail = await api.record([
    'projects',
    '${origin.project.id}',
    'merge_requests',
    '${origin.iid}',
    'versions',
    '$versionId',
  ]);
  _requireCurrent(isCurrent);
  if (_requiredString(detail, 'head_commit_sha') != headSha ||
      _requiredString(detail, 'base_commit_sha') != baseSha) {
    throw const FormatException('Merge request diff revision changed.');
  }
  final notes = await _recentNotes(api, [
    'projects',
    '${origin.project.id}',
    'merge_requests',
    '${origin.iid}',
    'notes',
  ], isCurrent);
  await refreshSecrets();
  _requireCurrent(isCurrent);
  final rawDiffs = detail['diffs'];
  if (rawDiffs is! List<Object?>) {
    throw const FormatException('Merge request diff is invalid.');
  }
  final diffs = <AiDiffFileInput>[
    for (final raw in rawDiffs)
      if (raw case final Json diff)
        AiDiffFileInput(
          oldPath: _requiredString(diff, 'old_path'),
          newPath: _requiredString(diff, 'new_path'),
          diff: _requiredString(diff, 'diff'),
        )
      else
        throw const FormatException('Merge request diff entry is invalid.'),
  ];
  final built = builder.mergeRequest(
    AiMergeRequestContextInput(
      iid: origin.iid,
      title: _requiredString(item, 'title'),
      description: _optionalString(item, 'description') ?? '',
      state: _requiredString(item, 'state'),
      headSha: headSha,
      baseSha: baseSha,
      labels: _labels(item),
      diffs: diffs,
      notes: notes.map(_discussionNote).toList(growable: false),
    ),
    nonce: nonce,
  );
  return AiChatContext(
    built: built,
    scope: _scope(
      accountKey: accountKey,
      api: api,
      project: origin.project,
      current: AiResourceRef(kind: AiResourceKind.mergeRequest, id: origin.iid),
      headSha: headSha,
      baseSha: baseSha,
    ),
  );
}

Future<AiChatContext> _loadFile(
  AiFileOrigin origin,
  GitLabApi api,
  AiContextBuilders builder,
  String nonce,
  String accountKey,
  Future<void> Function() refreshSecrets,
  bool Function() isCurrent,
) async {
  if (!isFullCommitSha(origin.sha)) {
    throw const FormatException('Invalid pinned SHA.');
  }
  if (isSensitiveRepositoryPath(origin.path)) {
    final built = builder.file(
      AiFileContextInput(path: origin.path, sha: origin.sha, text: ''),
      nonce: nonce,
    );
    return AiChatContext(
      built: built,
      scope: _scope(
        accountKey: accountKey,
        api: api,
        project: origin.project,
        current: AiResourceRef(
          kind: AiResourceKind.file,
          id: origin.project.id,
          path: origin.path,
        ),
        headSha: origin.sha,
      ),
    );
  }
  final text = await api.textFile(origin.project.id, origin.sha, origin.path);
  _requireCurrent(isCurrent);
  await refreshSecrets();
  _requireCurrent(isCurrent);
  final built = builder.file(
    AiFileContextInput(path: origin.path, sha: origin.sha, text: text),
    nonce: nonce,
  );
  return AiChatContext(
    built: built,
    scope: _scope(
      accountKey: accountKey,
      api: api,
      project: origin.project,
      current: AiResourceRef(
        kind: AiResourceKind.file,
        id: origin.project.id,
        path: origin.path,
      ),
      headSha: origin.sha,
    ),
  );
}

AiResourceScope _scope({
  required String accountKey,
  required GitLabApi api,
  required Project project,
  required AiResourceRef current,
  String? headSha,
  String? baseSha,
  int? pipelineId,
  int? jobId,
  String? defaultBranch,
  bool useProjectDefaultBranch = true,
}) => AiResourceScope(
  accountKey: accountKey,
  instanceKey: api.instance.key,
  projectId: project.id,
  projectPath: project.path,
  current: current,
  headSha: headSha,
  baseSha: baseSha,
  pipelineId: pipelineId,
  jobId: jobId,
  defaultBranch: useProjectDefaultBranch
      ? defaultBranch ?? project.defaultBranch
      : defaultBranch,
);

/// The newest notes, newest first, read page by page until 20 of them are not
/// system notes or the notes run out (at most five pages).
Future<List<Json>> _recentNotes(
  GitLabApi api,
  List<String> path,
  bool Function() isCurrent,
) async {
  final notes = <Json>[];
  final seen = <Object>{};
  var human = 0;
  Uri? next;
  for (var page = 0; page < 5; page++) {
    final result = await api.records(
      path,
      query: const {'order_by': 'created_at', 'sort': 'desc'},
      next: next,
    );
    _requireCurrent(isCurrent);
    for (final note in result.items) {
      // A note added between two page reads can appear on both pages.
      final Object? id = note['id'];
      if (id != null && !seen.add(id)) continue;
      notes.add(note);
      if (note['system'] != true) human++;
    }
    next = result.next;
    if (human >= 20 || next == null) break;
  }
  return notes;
}

AiDiscussionNoteInput _discussionNote(Json note) {
  final author = note['author'];
  String? authorName;
  if (author is Json) {
    authorName =
        _optionalString(author, 'username') ?? _optionalString(author, 'name');
  } else if (author != null) {
    throw const FormatException('Discussion note author is invalid.');
  }
  final createdAt = DateTime.tryParse(_requiredString(note, 'created_at'));
  if (createdAt == null) {
    throw const FormatException('Discussion note date is invalid.');
  }
  return AiDiscussionNoteInput(
    body: _requiredString(note, 'body'),
    createdAt: createdAt,
    author: authorName,
    system: note['system'] == true,
    internal: _noteFlag(note, 'internal') || _noteFlag(note, 'confidential'),
  );
}

bool _noteFlag(Json note, String key) {
  final value = note[key];
  if (value == null) return false;
  if (value is bool) return value;
  throw FormatException('Discussion note $key flag is invalid.');
}

List<String> _labels(Json item) {
  final values = item['labels'];
  if (values == null) return const [];
  if (values is! List<Object?>) {
    throw const FormatException('Labels are invalid.');
  }
  return [
    for (final value in values)
      if (value is String)
        value
      else
        throw const FormatException('Label is invalid.'),
  ];
}

String _requiredString(Json value, String key) {
  final result = value[key];
  if (result is String && result.isNotEmpty) return result;
  throw FormatException('Missing $key.');
}

String? _optionalString(Json value, String key) {
  final result = value[key];
  if (result == null) return null;
  if (result is String) return result;
  throw FormatException('Invalid $key.');
}

String _requiredNestedString(Json value, String objectKey, String key) {
  final nested = value[objectKey];
  if (nested is! Json) throw FormatException('Missing $objectKey.');
  return _requiredString(nested, key);
}

String? _optionalNestedString(Json value, String objectKey, String key) {
  final nested = value[objectKey];
  if (nested == null) return null;
  if (nested is! Json) throw FormatException('Invalid $objectKey.');
  return _optionalString(nested, key);
}

int? _optionalNestedInt(Json value, String objectKey, String key) {
  final nested = value[objectKey];
  if (nested == null) return null;
  if (nested is! Json) throw FormatException('Invalid $objectKey.');
  final result = nested[key];
  if (result == null) return null;
  if (result is int) return result;
  throw FormatException('Invalid $objectKey.$key.');
}

void _requireCurrent(bool Function() isCurrent) {
  if (!isCurrent()) throw const ApiFailure(FailureKind.cancelled);
}

String _nonce() => List<int>.generate(
  16,
  (_) => Random.secure().nextInt(256),
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
