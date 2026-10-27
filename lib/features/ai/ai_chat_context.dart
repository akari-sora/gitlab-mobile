import 'dart:math';

import '../../core/ai/ai_transcript.dart' show AiContextBlock;
import '../../core/ai/app_text.dart';
import '../../core/ai/context_builders.dart';
import '../../core/ai/redaction.dart';
import '../../core/ai/tools/sensitive_paths.dart';
import '../../core/ai/tools/tool_scope.dart';
import '../../core/ai/write_text.dart'
    show AiFieldProvenance, UploadPlaceholderTable;
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/group_work_item_identity.dart';
import '../../core/models.dart';
import '../../core/request_meter.dart';
import 'ai_chat_session.dart';

/// The redacted starting context plus immutable revisions used to bind tools.
final class AiChatContext {
  const AiChatContext({
    required this.built,
    required this.scope,
    this.groupScope,
    this.groupMetadata,
    this.field,
    this.fetchedAt,
    this.readConfidential = false,
  }) : assert(scope == null || groupScope == null);

  final AiBuiltContext built;
  final AiResourceScope? scope;

  /// Group reads never acquire a project tool scope or a synthetic Project.
  final AiGroupResourceScope? groupScope;
  final AiGroupContextMetadata? groupMetadata;

  /// Trusted metadata from the REST issue read. For group Work Items consult
  /// [groupMetadata]: this legacy false default is not confidentiality proof.
  final bool readConfidential;

  /// The oldest network timestamp, or null for empty / SHA-pinned context.
  final DateTime? fetchedAt;

  bool isExpired(DateTime now) {
    final fetched = fetchedAt;
    if (fetched == null) return false;
    final age = now.difference(fetched);
    return age.isNegative || age >= _aiContextMaxAge;
  }

  /// The issue or merge request description this page context carries, a
  /// field the AI can write back whole.
  final AiContextField? field;

  /// Records on [table] whether a request that carried [sent] gave the
  /// provider the description whole. [sent] is what one request attached:
  /// this page context, a conversation summary cut from it, or nothing (the
  /// context already went out in this segment). Plan §3.1 offers no
  /// whole-field write of a value the provider saw cut, so call this for
  /// every request that carries context, before its tools run.
  void recordDelivery(UploadPlaceholderTable table, List<AiContextBlock> sent) {
    final field = this.field;
    if (field == null || sent.isEmpty) return;
    var whole = false;
    for (final block in sent) {
      final strings = block.plainData.plainStrings.toList();
      for (var i = 0; i + 1 < strings.length && !whole; i++) {
        whole = strings[i] == 'description' && strings[i + 1] == field.sent;
      }
      if (whole) break;
    }
    table.recordFieldDelivery(field.provenance, whole: whole);
  }
}

/// Source evidence from this context's fresh, account/API/generation-guarded
/// reads. Unknown values stay null, independent of the redacted display text.
final class AiGroupContextMetadata {
  const AiGroupContextMetadata({this.visibility, this.confidential});

  /// One of private/internal/public, or null when not established.
  final String? visibility;
  final bool? confidential;
}

/// A writable field in the page context, with the value as the context
/// builder redacted it for the provider.
final class AiContextField {
  const AiContextField({required this.provenance, required this.sent});

  final AiFieldProvenance provenance;
  final String sent;
}

AiContextField _descriptionField({
  required GitLabApi api,
  required Redactor redactor,
  required Project project,
  required String resource,
  required int iid,
  required String description,
}) => AiContextField(
  provenance: AiFieldProvenance.gitLab(
    instance: api.instance,
    projectId: project.id,
    projectPath: project.path,
    resource: resource,
    iid: iid,
  ),
  // The context builders strip ANSI escapes and redact every string the same
  // way. Should the two ever differ, the field reads as cut: the safe side.
  sent: redactor.redactSource(description.replaceAll(_ansi, '')).text,
);

final _ansi = RegExp(
  r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-_])',
);

Project? projectForAiChatOrigin(AiChatOrigin origin) => switch (origin) {
  AiGeneralOrigin() || AiGroupWorkItemOrigin() => null,
  AiJobOrigin(:final project) ||
  AiWorkItemOrigin(:final project) ||
  AiProjectWorkItemFromGroupPageOrigin(:final project) ||
  AiFileOrigin(:final project) => project,
};

Future<AiChatContext> loadAiChatContext({
  required AiChatOrigin origin,
  required GitLabApi api,
  required Redactor redactor,
  required String accountKey,
  required Future<void> Function() refreshSecrets,
  required bool Function() isCurrent,
  DateTime Function()? now,
  void Function(int maxRequests)? beforeRead,
}) async {
  _requireCurrent(isCurrent);
  final builder = AiContextBuilders(redactor: redactor);
  final nonce = _nonce();
  final reads = _AiContextReads(api, now ?? DateTime.now, beforeRead);

  final context = switch (origin) {
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
    AiJobOrigin() => await _loadJob(
      origin,
      api,
      reads,
      builder,
      nonce,
      accountKey,
      refreshSecrets,
      isCurrent,
    ),
    AiWorkItemOrigin(kind: AiWorkItemKind.issue) => await _loadIssue(
      origin,
      api,
      reads,
      builder,
      nonce,
      accountKey,
      refreshSecrets,
      isCurrent,
    ),
    AiWorkItemOrigin(kind: AiWorkItemKind.mergeRequest) =>
      await _loadMergeRequest(
        origin,
        api,
        reads,
        builder,
        nonce,
        accountKey,
        refreshSecrets,
        isCurrent,
      ),
    AiGroupWorkItemOrigin() => await _loadGroupWorkItem(
      origin,
      api,
      reads,
      builder,
      nonce,
      accountKey,
      refreshSecrets,
      isCurrent,
    ),
    AiProjectWorkItemFromGroupPageOrigin() => await _loadIssue(
      AiWorkItemOrigin(
        project: origin.project,
        kind: AiWorkItemKind.issue,
        iid: origin.iid,
        title: origin.title,
      ),
      api,
      reads,
      builder,
      nonce,
      accountKey,
      refreshSecrets,
      isCurrent,
    ),
    AiFileOrigin() => await _loadFile(
      origin,
      api,
      reads,
      builder,
      nonce,
      accountKey,
      refreshSecrets,
      isCurrent,
    ),
  };
  return AiChatContext(
    built: context.built,
    scope: context.scope,
    groupScope: context.groupScope,
    groupMetadata: context.groupMetadata,
    field: context.field,
    readConfidential: context.readConfidential,
    fetchedAt: origin is AiGeneralOrigin || origin is AiFileOrigin
        ? null
        : reads.fetchedAt,
  );
}

const _aiContextMaxAge = Duration(seconds: 60);

Future<AiChatContext> _loadGroupWorkItem(
  AiGroupWorkItemOrigin origin,
  GitLabApi api,
  _AiContextReads reads,
  AiContextBuilders builder,
  String nonce,
  String accountKey,
  Future<void> Function() refreshSecrets,
  bool Function() isCurrent,
) {
  final meter = RequestMeter.current ?? RequestMeter();
  final startingRequests = meter.count;
  return meter.runAsync(() async {
    void beforeRead() {
      // Initial preparation has no run lease yet. Bound that path here too;
      // an outer context meter/admission remains authoritative when present.
      if (meter.count - startingRequests + 2 > 4) {
        throw const ApiFailure(FailureKind.rateLimited);
      }
      reads.beforeRead?.call(2);
    }

    final groupId = origin.groupId;
    final path = origin.group.fullPath;
    final accountPrefix = '${api.instance.key}#';
    final userId = accountKey.startsWith(accountPrefix)
        ? int.tryParse(accountKey.substring(accountPrefix.length))
        : null;
    if (origin.iid <= 0 ||
        userId == null ||
        userId <= 0 ||
        accountKey != '$accountPrefix$userId' ||
        !RegExp(r'^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$').hasMatch(path) ||
        path.split('/').any((segment) => segment == '.' || segment == '..')) {
      throw const ApiFailure(FailureKind.validation);
    }
    void requireCurrent() {
      _requireCurrent(() => !api.isClosed && isCurrent());
    }

    requireCurrent();
    // Each fixed, uncached logical read allows one OAuth replay. These reads
    // use the context's admission callback, never a write operation's cap.
    beforeRead();
    final detail = await api.namespaceWorkItem(
      path,
      origin.iid,
      expectedNamespaceId: groupKeyGid(
        groupId,
        serverGroupGid: origin.group.id,
      ),
      strictIdentity: true,
      isCurrent: () => !api.isClosed && isCurrent(),
    );
    requireCurrent();
    final item = detail.summary;
    if (item.project != null ||
        item.namespace?.id != origin.group.id ||
        item.namespace?.fullPath != path ||
        groupKeyNumericId(item.namespace!.id) != groupId ||
        item.iid != origin.iid) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    beforeRead();
    final group = await api.group(groupId);
    requireCurrent();
    if (group['id'] != groupId || group['full_path'] != path) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    final visibility = switch (group['visibility']) {
      'private' => 'private',
      'internal' => 'internal',
      'public' => 'public',
      _ => null,
    };
    await refreshSecrets();
    requireCurrent();
    final built = builder.discussion(
      AiDiscussionContextInput(
        kind: 'work_item',
        iid: item.iid,
        title: item.title,
        description: detail.description ?? '',
        state: item.state,
        pinnedSha: null,
        labels:
            detail.labels?.labels?.items
                .map((label) => label.title)
                .toList(growable: false) ??
            const <String>[],
        notes: const [],
      ),
      nonce: nonce,
    );
    return AiChatContext(
      built: AiBuiltContext(
        blocks: [
          for (final block in built.blocks)
            AiContextBlock.fromData(
              source: block.source,
              data: AiAppText.join([
                block.plainData,
                // Empty projections must not claim unavailable widgets or
                // unread activity are complete. App-owned status strings also
                // participate in the controller's plain-text refresh check.
                AiAppText.json({
                  'description_status': detail.description == null
                      ? 'unavailable'
                      : 'loaded',
                  'labels_status': detail.labels?.labels?.isPartial == false
                      ? 'complete'
                      : 'incomplete',
                  'notes_status': 'not_loaded',
                }),
              ]),
            ),
        ],
        pinnedSha: built.pinnedSha,
        blockedSensitivePaths: built.blockedSensitivePaths,
        redactions: built.redactions,
        withheldPrivateKeyContext: built.withheldPrivateKeyContext,
      ),
      scope: null,
      groupScope: AiGroupResourceScope(
        accountKey: accountKey,
        instanceKey: api.instance.key,
        groupId: groupId,
        groupFullPath: path,
        iid: item.iid,
        workItemGid: item.id,
      ),
      // The fixed namespace document/model does not expose confidential. Do not
      // derive false from its absence or widen the core query in this packet.
      groupMetadata: AiGroupContextMetadata(visibility: visibility),
    );
  });
}

/// Keeps the original timestamps while composing several cache-backed reads.
final class _AiContextReads {
  _AiContextReads(this.api, this.now, this.beforeRead) : fetchedAt = now();

  final GitLabApi api;
  final DateTime Function() now;
  final void Function(int maxRequests)? beforeRead;
  DateTime fetchedAt;

  Future<Json> record(List<String> path) async {
    beforeRead?.call(4);
    var read = await api.cachedRecord(
      path,
      maxAge: _aiContextMaxAge,
      allowDisk: false,
    );
    if (!_usable(read)) {
      beforeRead?.call(4);
      read = await api.cachedRecord(
        path,
        fresh: true,
        maxAge: _aiContextMaxAge,
        allowDisk: false,
      );
    }
    return _value(read);
  }

  Future<ApiPage<Json>> records(
    List<String> path, {
    Map<String, String> query = const {},
    Uri? next,
  }) async {
    beforeRead?.call(4);
    var read = await api.cachedRecords(
      path,
      query: query,
      next: next,
      maxAge: _aiContextMaxAge,
      allowDisk: false,
    );
    if (!_usable(read)) {
      beforeRead?.call(4);
      read = await api.cachedRecords(
        path,
        query: query,
        next: next,
        fresh: true,
        maxAge: _aiContextMaxAge,
        allowDisk: false,
      );
    }
    return _value(read);
  }

  bool _usable<T>(CachedRead<T> read) =>
      !read.dropped &&
      !read.superseded &&
      read.lineage != CacheLineage.disk &&
      !now().isBefore(read.fetchedAt) &&
      now().difference(read.fetchedAt) < _aiContextMaxAge;

  T _value<T>(CachedRead<T> read) {
    if (!_usable(read)) throw const ApiFailure(FailureKind.network);
    if (read.fetchedAt.isBefore(fetchedAt)) fetchedAt = read.fetchedAt;
    return read.value;
  }
}

Future<AiChatContext> _loadJob(
  AiJobOrigin origin,
  GitLabApi api,
  _AiContextReads reads,
  AiContextBuilders builder,
  String nonce,
  String accountKey,
  Future<void> Function() refreshSecrets,
  bool Function() isCurrent,
) async {
  final job = await reads.record([
    'projects',
    '${origin.project.id}',
    'jobs',
    '${origin.jobId}',
  ]);
  _requireCurrent(isCurrent);
  reads.beforeRead?.call(2);
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
  _AiContextReads reads,
  AiContextBuilders builder,
  String nonce,
  String accountKey,
  Future<void> Function() refreshSecrets,
  bool Function() isCurrent,
) async {
  final item = await reads.record([
    'projects',
    '${origin.project.id}',
    'issues',
    '${origin.iid}',
  ]);
  _requireCurrent(isCurrent);
  final notes = await _recentNotes(reads, [
    'projects',
    '${origin.project.id}',
    'issues',
    '${origin.iid}',
    'notes',
  ], isCurrent);
  final project = await reads.record(['projects', '${origin.project.id}']);
  _requireCurrent(isCurrent);
  final defaultBranch = _optionalString(project, 'default_branch');
  String? pinnedSha;
  if (defaultBranch != null && defaultBranch.isNotEmpty) {
    try {
      final branch = await reads.record([
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

  final description = _optionalString(item, 'description') ?? '';
  final built = builder.discussion(
    AiDiscussionContextInput(
      kind: 'issue',
      iid: origin.iid,
      title: _requiredString(item, 'title'),
      description: description,
      state: _requiredString(item, 'state'),
      pinnedSha: pinnedSha,
      labels: _labels(item),
      notes: notes.map(_discussionNote).toList(growable: false),
    ),
    nonce: nonce,
  );
  return AiChatContext(
    built: built,
    readConfidential: item['confidential'] == true,
    field: _descriptionField(
      api: api,
      redactor: builder.redactor,
      project: origin.project,
      resource: 'issues',
      iid: origin.iid,
      description: description,
    ),
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
  _AiContextReads reads,
  AiContextBuilders builder,
  String nonce,
  String accountKey,
  Future<void> Function() refreshSecrets,
  bool Function() isCurrent,
) async {
  final item = await reads.record([
    'projects',
    '${origin.project.id}',
    'merge_requests',
    '${origin.iid}',
  ]);
  _requireCurrent(isCurrent);
  final headSha = _requiredNestedString(item, 'diff_refs', 'head_sha');
  final baseSha = _requiredNestedString(item, 'diff_refs', 'base_sha');

  final versions = await reads.records(
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
  final detail = await reads.record([
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
  final notes = await _recentNotes(reads, [
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
  final description = _optionalString(item, 'description') ?? '';
  final built = builder.mergeRequest(
    AiMergeRequestContextInput(
      iid: origin.iid,
      title: _requiredString(item, 'title'),
      description: description,
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
    field: _descriptionField(
      api: api,
      redactor: builder.redactor,
      project: origin.project,
      resource: 'merge_requests',
      iid: origin.iid,
      description: description,
    ),
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
  _AiContextReads reads,
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
  reads.beforeRead?.call(8);
  final text = await api.textFile(
    origin.project.id,
    origin.sha,
    origin.path,
    refresh: true,
    allowDisk: false,
  );
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
  _AiContextReads reads,
  List<String> path,
  bool Function() isCurrent,
) async {
  final notes = <Json>[];
  final seen = <Object>{};
  var human = 0;
  Uri? next;
  for (var page = 0; page < 5; page++) {
    final result = await reads.records(
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
