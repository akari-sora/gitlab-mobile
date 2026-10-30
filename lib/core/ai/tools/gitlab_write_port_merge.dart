part of 'gitlab_write_port.dart';

// Conversation-local state. Neither snapshots nor old heads reach persistence.
final class _MergeMemory {
  final snapshots = <String, Map<String, Object?>>{};
  final rejectedHeads = <String, String>{};
}

extension _MergePrepare on GitLabAiWritePort {
  static final _memories = Expando<_MergeMemory>();

  Future<AiWritePrepared?> _prepareMerge(AiWriteRequest request) async {
    final op = request.operationId;
    if (!aiMergeRows.any((row) => row.operationId == op)) return null;
    final a = request.arguments;
    final project = _positive(a, 'projectId');
    final iid = _positive(a, 'iid');
    if (!_granted(request.scope, project, 'merge_requests', iid)) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final squash = a.containsKey('squash') ? _boolean(a, 'squash') : false;
    final autoMerge = a.containsKey('autoMerge') ? _boolean(a, 'autoMerge') : false;
    final remove = a.containsKey('removeSourceBranch')
        ? _boolean(a, 'removeSourceBranch') : false;
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    final p = await _api.record(['projects', '$project']);
    if (p['id'] != project) throw const ApiFailure(FailureKind.forbidden);
    final projectPath = _responseText(p, 'path_with_namespace');
    final ciConfig = AiCiConfig.fromProject(p);
    final path = ['projects', '$project', 'merge_requests', '$iid'];
    final mr = await _mergeRecord(path);
    if (mr['project_id'] != project || mr['iid'] != iid) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final state = _responseText(mr, 'state');
    if (state == 'merged') throw const AiWriteRefused('alreadyMerged');
    if (state != 'opened') throw const AiWriteRefused('mergeCheckUnsupported');
    final sha = _mergeSha(mr['sha']);
    final source = _responseText(mr, 'source_branch');
    final target = _responseText(mr, 'target_branch');
    // Cross-project MRs require source-project keys and grants not available
    // in this family. Never silently use the target project's source ref.
    if ((mr['source_project_id'] != null && mr['source_project_id'] != project) ||
        (mr['target_project_id'] != null && mr['target_project_id'] != project)) {
      throw const AiWriteRefused('mergeCheckUnsupported');
    }
    final memory = _memories[this] ??= _MergeMemory();
    final mrKey = '$project:$iid';
    final snapshotKey = '$op:${request.executionId}';
    final previous = memory.snapshots[snapshotKey];
    if (previous?['expired'] == true) {
      throw const AiWriteRefused('mergeCheckIncomplete');
    }
    if (previous != null && previous['sha'] != sha) {
      if (op == 'mergeRequest' || op == 'approveMergeRequest') {
        memory.rejectedHeads[mrKey] = previous['sha']! as String;
      }
      throw const AiWriteRefused('headMoved');
    }
    final root = [accountKey, 'project:$project'];
    final mrParts = [...root, 'mergeRequest', '$iid'];
    final mrConflict = _key(mrParts);
    var keys = <AiConflictKey>{mrConflict};
    final dependencies = <AiConflictKey>{};
    var confirmName = op == 'approveMergeRequest' || op == 'deleteDraftNote'
        ? '!$iid' : null;
    var facts = const AiTierFacts();
    AiWritePreview preview = AiFieldsPreview({'iid': iid});
    AiTextScan? scan;
    var journal = AiJournalBindings(headSha: sha);
    final binding = <String, Object?>{
      'sha': sha, 'source': source, 'target': target, 'state': state,
      'projectPath': projectPath, 'visibility': p['visibility'],
    };
    final reasons = <AiFixedConfirmReason>[];
    final movedCommits = <String>[];
    if (op == 'mergeRequest' || op == 'approveMergeRequest') {
      final old = memory.rejectedHeads[mrKey];
      if (old != null) {
        reasons.add(AiFixedConfirmReason.headMovedSincePreview);
        final comparison = await _mergeRecord(
          ['projects', '$project', 'repository', 'compare'],
          query: {'from': old, 'to': sha, 'straight': 'true'},
        );
        final commits = comparison['commits'];
        if (comparison['compare_timeout'] == true || commits is! List ||
            commits.length > 100) {
          throw const AiWriteRefused('mergeCheckIncomplete');
        }
        for (final commit in commits) {
          if (commit is! Map) throw const AiWriteRefused('mergeCheckIncomplete');
          movedCommits.add(_mergeSha(commit['id']));
        }
        binding['headMovedCommits'] = movedCommits;
      }
    }
    Future<Object?> Function() mutation;
    Future<Object?> Function(Object?)? readback = (_) => _api.record(path);
    var usedDeprecatedCancelEndpoint = false;
    int? draftNoteId;
    switch (op) {
      case 'mergeRequest':
        final refs = mr['diff_refs'];
        if (refs is! Map) throw const AiWriteRefused('mergeCheckIncomplete');
        final revisions = [
          for (final key in ['base_sha', 'start_sha', 'head_sha']) _mergeSha(refs[key]),
        ];
        if (revisions.last != sha) throw const AiWriteRefused('mergeCheckIncomplete');
        binding['refs'] = revisions;
        if (previous != null && jsonEncode(previous['refs']) != jsonEncode(revisions)) {
          throw const AiWriteRefused('headMoved');
        }
        final branch = await _mergeRecord(
          ['projects', '$project', 'repository', 'branches', target],
        );
        if (branch['name'] != target || branch['protected'] is! bool ||
            p['default_branch'] is! String) {
          throw const AiWriteRefused('mergeCheckIncomplete');
        }
        List<Map<String, dynamic>> changes;
        List<Map<String, dynamic>> commits;
        if (previous == null) {
          changes = await _mergeList([...path, 'diffs'], maxPages: 2);
          commits = await _mergeList([...path, 'commits']);
        } else {
          changes = (previous['changes']! as List).cast<Map<String, dynamic>>();
          commits = (previous['commits']! as List).cast<Map<String, dynamic>>();
        }
        final count = mr['changes_count'];
        final expected = count is int ? count :
            count is String && RegExp(r'^\d+$').hasMatch(count) ? int.tryParse(count) : null;
        if (expected == null || expected < 0 || expected != changes.length) {
          throw const AiWriteRefused('mergeCheckIncomplete');
        }
        final normalized = <List<Object>>[];
        final ciPaths = <String>{};
        final seen = <String>{};
        for (final change in changes) {
          final oldPath = change['old_path'];
          final newPath = change['new_path'];
          if (oldPath is! String || newPath is! String ||
              !_mergePathValid(oldPath) || !_mergePathValid(newPath) ||
              change['new_file'] is! bool || change['deleted_file'] is! bool ||
              change['renamed_file'] is! bool ||
              !seen.add(jsonEncode([oldPath, newPath])) ||
              change['too_large'] == true || change['collapsed'] == true) {
            throw const AiWriteRefused('mergeCheckIncomplete');
          }
          normalized.add([oldPath, newPath, change['new_file']! as bool,
            change['deleted_file']! as bool, change['renamed_file']! as bool]);
          for (final name in [oldPath, newPath]) {
            if (isCiConfigPath(name, ciConfig)) ciPaths.add(name);
          }
        }
        normalized.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
        final description = mr['description'];
        if (description != null && description is! String) {
          throw const AiWriteRefused('mergeCheckIncomplete');
        }
        final messages = <String>[];
        final commitIds = <String>{};
        for (final commit in commits) {
          if (commit['message'] is! String || !commitIds.add(_mergeSha(commit['id']))) {
            throw const AiWriteRefused('mergeCheckIncomplete');
          }
          messages.add(commit['message']! as String);
        }
        // A nonempty diff without any commits cannot prove the pinned effects.
        if (changes.isNotEmpty && commits.isEmpty) {
          throw const AiWriteRefused('mergeCheckIncomplete');
        }
        final closing = await _mergeList([...path, 'closes_issues']);
        final closingIssues = <AiClosingIssue>[];
        final closeKeys = <String>{};
        for (final issue in closing) {
          final issueProject = issue['project_id'];
          final issueIid = issue['iid'];
          final references = issue['references'];
          final fullReference = references is Map ? references['full'] : null;
          if (issueProject is! int || issueProject < 1 || issueIid is! int || issueIid < 1 ||
              (fullReference != null &&
                (fullReference is! String || fullReference.isEmpty)) ||
              !closeKeys.add('$issueProject:$issueIid')) {
            throw const AiWriteRefused('mergeCheckIncomplete');
          }
          final outside = !request.scope.grants.any((g) =>
            g.projectId == issueProject && (g.kind == AiScopeKind.project ||
              (g.kind == AiScopeKind.workItem && g.iid == issueIid)));
          closingIssues.add(AiClosingIssue(
            projectId: issueProject,
            iid: issueIid,
            outOfScope: outside,
            fullReference: fullReference as String?,
          ));
          if (outside) reasons.add(AiFixedConfirmReason.foreignClosingOrCrossProject);
        }
        // Bind the complete server text too: an existing closure or qualified
        // reference is never inferred safe from an empty closes_issues list.
        for (final text in [description as String? ?? '', ...messages]) {
          if (_mergeTextEffects(text, projectPath, project, closeKeys)) {
            reasons.add(AiFixedConfirmReason.foreignClosingOrCrossProject);
          }
        }
        final sortedCi = ciPaths.toList()..sort();
        closingIssues.sort((a, b) => '${a.projectId}:${a.iid}'.compareTo('${b.projectId}:${b.iid}'));
        binding.addAll({
          'paths': _mergeDigest(normalized),
          'closes': closeKeys.toList()..sort(),
          'description': _mergeDigest(description ?? ''),
          'commits': _mergeDigest(commits),
          'ciConfig': _mergeCiConfigBinding(ciConfig),
          'protected': branch['protected'], 'default': p['default_branch'],
          'ciPaths': sortedCi,
        });
        final summary = jsonEncode({
          'paths': changes.length, 'ciPaths': sortedCi.length,
          'closesIssues': closingIssues.length, 'digest': _mergeDigest(binding),
        });
        journal = AiJournalBindings(headSha: sha, mergeCheckSummary: summary);
        confirmName = sortedCi.isNotEmpty ? sortedCi.first : target;
        facts = AiTierFacts(
          protectedOrDefaultBranch: branch['protected'] == true || p['default_branch'] == target,
          touchesCiConfig: sortedCi.isNotEmpty, removeSourceBranch: remove,
          squash: squash, triggersPipeline: true, reasons: List.unmodifiable(reasons.toSet()),
        );
        preview = AiMergePreview(
          sourceBranch: source, targetBranch: target, shortSha: sha.substring(0, 8),
          pathCount: changes.length, squash: squash, autoMerge: autoMerge,
          removeSourceBranch: remove, ciPaths: sortedCi, closingIssues: closingIssues,
          headMovedCommits: movedCommits,
        );
        binding['changes'] = changes;
        binding['commits'] = commits;
        keys.add(_key([...root, 'ref', target]));
        if (remove) keys.add(_key([...root, 'ref', source]));
        mutation = () => _api.mergeRequest(project, iid, sha,
          squash: squash, autoMerge: autoMerge, removeSourceBranch: remove);
      case 'approveMergeRequest':
        facts = AiTierFacts(reasons: List.unmodifiable(reasons.toSet()));
        preview = AiMergePreview(sourceBranch: source, targetBranch: target,
          shortSha: sha.substring(0, 8), pathCount: 0, headMovedCommits: movedCommits);
        keys = {_key([...mrParts, 'approval'])};
        mutation = () => _api.approveMergeRequest(project, iid, sha);
      case 'rebaseMergeRequest':
        keys.add(_key([...root, 'ref', source]));
        mutation = () => _api.rebaseMergeRequest(project, iid);
      case 'cancelAutoMerge':
        if (!_mergeAutoEnabled(mr)) throw const AiWriteRefused('autoMergeNotEnabled');
        final author = mr['author'];
        final permission = mr['user'];
        binding['permission'] = permission is Map ? permission['can_merge'] : null;
        binding['author'] = author is Map ? author['id'] : null;
        preview = AiCancelAutoMergePreview(iid: iid, sourceBranch: source, targetBranch: target,
          mayLackPermission: permission is Map && permission['can_merge'] == false &&
            (author is! Map || author['id'] != user.id));
        mutation = () async {
          try {
            return await _api.cancelAutoMerge(project, iid, newEndpoint: true);
          } on ApiFailure catch (error) {
            if (error.status != 404 && error.status != 405) rethrow;
            usedDeprecatedCancelEndpoint = true;
            return _api.cancelAutoMerge(project, iid);
          }
        };
      case 'publishDraftNotes':
        final drafts = await _mergeList([...path, 'draft_notes']);
        if (drafts.length > 20) throw const AiWriteRefused('batchTooLarge');
        final items = <AiDraftPreview>[];
        final ids = <int>{};
        for (final draft in drafts) {
          final id = draft['id'];
          final body = draft['note'];
          if (id is! int || id < 1 || body is! String || !ids.add(id)) {
            throw const AiWriteRefused('draftsChanged');
          }
          final created = request.segmentCreated.contains(AiCreatedRef(
            accountKey: accountKey, kind: AiTargetKind.note,
            projectId: project, id: id, parentIid: iid));
          items.add(AiDraftPreview(id: id, body: body, createdInSegment: created));
          if (!created) reasons.add(AiFixedConfirmReason.foreignDraftsInPublish);
        }
        if (drafts.isEmpty) throw const AiWriteRefused('draftsChanged');
        items.sort((a, b) => a.id.compareTo(b.id));
        binding['drafts'] = _mergeDraftDigest(drafts);
        facts = AiTierFacts(reasons: List.unmodifiable(reasons.toSet()));
        preview = AiDraftPublishPreview(drafts: items);
        scan = AiTextScan(serverClassA: items.map((d) => d.body).toList());
        keys = {_key([...mrParts, 'draftNotes'])};
        mutation = () => _api.publishDraftNotes(project, iid);
        readback = (_) => _mergeList([...path, 'draft_notes']);
      case 'deleteDraftNote':
        final id = _positive(a, 'noteId');
        final draft = await _api.record([...path, 'draft_notes', '$id']);
        // GitLab's draft-note entity carries only author_id, and a draft is
        // visible to its author alone: it must be this account's own user.
        final authorId = draft['author_id'];
        if (draft['id'] != id || draft['note'] is! String ||
            authorId is! int ||
            '${_api.instance.key}#$authorId' != accountKey) {
          throw const AiWriteRefused('draftsChanged');
        }
        draftNoteId = id;
        binding['drafts'] = _mergeDraftDigest([draft]);
        preview = AiDeletePreview(
          targetName: '',
          parentName: '!$iid',
          excerpt: _mergeExcerpt(draft['note']! as String),
          count: 1,
        );
        keys = {_key([...mrParts, 'draftNotes', '$id'])};
        mutation = () => _api.deleteDraftNote(project, iid, id);
        readback = (_) => _mergeList([...path, 'draft_notes']);
      default:
        throw const ApiFailure(FailureKind.unsupported);
    }
    dependencies.add(mrConflict);
    final digest = _mergeDigest(binding);
    if (previous != null && _mergeDigest(previous) != digest) {
      throw AiWriteRefused(op == 'publishDraftNotes' || op == 'deleteDraftNote'
        ? 'draftsChanged' : 'headMoved');
    }
    final active = memory.snapshots.entries.where((entry) => entry.value['expired'] != true);
    if (previous == null && active.length >= 128) {
      // Keep only an expiry marker for an abandoned snapshot. An old approval
      // must be proposed again, never re-page outside its reserved HTTP cap.
      memory.snapshots[active.first.key] = {'expired': true};
    }
    memory.snapshots[snapshotKey] = binding;
    return AiWritePrepared._(
      request: request, releaseName: '!$iid', confirmName: confirmName,
      writeKeys: keys, dependencyKeys: dependencies, owner: _owner,
      projectPath: projectPath, projectVisibility: p['visibility'] is String ? p['visibility']! as String : null,
      bindingDigest: digest, facts: facts, journal: journal, preview: preview, textScan: scan,
      bindingTargets: [
        if (draftNoteId != null)
          AiTargetRef(
            kind: AiTargetKind.note,
            side: AiResourceSide.mergeRequest,
            projectId: project,
            projectPath: projectPath,
            parentIid: iid,
            noteId: draftNoteId,
          )
        else
          AiTargetRef(
            kind: op == 'mergeRequest' ? AiTargetKind.merge : AiTargetKind.mergeRequest,
            projectId: project, projectPath: projectPath, iid: iid,
            sourceRef: source, targetRef: target,
          ),
      ],
      mutation: mutation, readback: readback,
      classify: (prepared, {result, readback, mutationError, readbackError}) {
        memory.snapshots.remove(snapshotKey);
        if (op == 'cancelAutoMerge') {
          if (mutationError is ApiFailure &&
              mutationError.status == 409 &&
              !usedDeprecatedCancelEndpoint) {
            return _outcome(
              prepared,
              AiJournalState.succeeded,
              'noChange',
              status: 409,
            );
          }
          if (mutationError is ApiFailure &&
              const {405, 406, 409, 422}.contains(mutationError.status)) {
            return _outcome(
              prepared,
              AiJournalState.failedCertain,
              mutationError.kind.name,
              status: mutationError.status,
            );
          }
          if (mutationError is ApiFailure && mutationError.status == 404) {
            return _outcome(prepared, AiJournalState.failedCertain,
              'cancelEndpointUnavailable', status: 404);
          }
          if (mutationError != null) return null;
          if (usedDeprecatedCancelEndpoint && result is Map && result['status'] == 'error') {
            return _outcome(prepared, AiJournalState.failedCertain,
              'autoMergeCancelError', status: 201);
          }
          final accepted = usedDeprecatedCancelEndpoint
              ? result is Map && result['status'] == 'success'
              : result is Map<String, dynamic> &&
                _mergeMrIdentity(result, project, iid);
          if (!accepted || readbackError != null ||
              readback is! Map<String, dynamic> ||
              !_mergeMrIdentity(readback, project, iid) ||
              !_mergeAutoReadable(readback) || _mergeAutoEnabled(readback)) {
            return _outcome(prepared, AiJournalState.writeUncertain,
              'invalidResponse');
          }
          return _outcome(
            prepared,
            AiJournalState.succeeded,
            'succeeded',
            status: 201,
            readbackVerified: true,
          );
        }
        if (mutationError is ApiFailure && const {405, 406, 409, 422}.contains(mutationError.status)) {
          if (mutationError.status == 409 && (op == 'mergeRequest' || op == 'approveMergeRequest')) {
            memory.rejectedHeads[mrKey] = sha;
          }
          return _outcome(prepared, AiJournalState.failedCertain,
            mutationError.status == 409 && (op == 'mergeRequest' || op == 'approveMergeRequest')
              ? 'headMoved' : mutationError.kind.name,
            status: mutationError.status);
        }
        if (mutationError != null) return null;
        if (op == 'rebaseMergeRequest') {
          return _outcome(
            prepared,
            AiJournalState.succeeded,
            'succeeded',
          );
        }
        if (op == 'mergeRequest') {
          if (result is! Map<String, dynamic> || !_mergeMrIdentity(result, project, iid) ||
              !const {'opened', 'merged', 'closed'}.contains(result['state'])) {
            return _outcome(prepared, AiJournalState.writeUncertain, 'invalidResponse');
          }
          final value = result;
          final code = value['state'] == 'merged' ? 'merged' :
            autoMerge && _mergeAutoEnabled(result)
              ? 'autoMergeScheduled' : 'mergeAccepted';
          final verified = readbackError == null &&
            readback is Map<String, dynamic> &&
            _mergeMrIdentity(readback, project, iid) &&
            const {'opened', 'merged', 'closed'}.contains(readback['state']);
          return _outcome(
            prepared,
            AiJournalState.succeeded,
            code,
            readbackVerified: verified,
          );
        }
        if (readbackError != null) return null;
        if (op == 'publishDraftNotes' || op == 'deleteDraftNote') {
          if (readback is! List<Map<String, dynamic>>) {
            return _outcome(prepared, AiJournalState.writeUncertain, 'draftsChanged');
          }
          final oldIds = op == 'deleteDraftNote' ? {a['noteId']} :
            (preview as AiDraftPublishPreview).drafts.map((d) => d.id).toSet();
          if (readback.any((d) => oldIds.contains(d['id']))) {
            return _outcome(prepared, AiJournalState.writeUncertain, 'draftsChanged');
          }
          return _outcome(
            prepared,
            AiJournalState.succeeded,
            'succeeded',
            readbackVerified: true,
          );
        }
        return _resultClassifier?.call(prepared, result: result, readback: readback,
          mutationError: mutationError, readbackError: readbackError);
      },
    );
  }

  Future<Map<String, dynamic>> _mergeRecord(List<String> path, {Map<String, String> query = const {}}) async {
    try {
      return await _api.record(path, query: query);
    } on ApiFailure catch (error) {
      if (error.status == 404 || error.kind == FailureKind.unsupported) {
        throw const AiWriteRefused('mergeCheckUnsupported');
      }
      throw const AiWriteRefused('mergeCheckIncomplete');
    }
  }

  Future<List<Map<String, dynamic>>> _mergeList(List<String> path, {int maxPages = 1}) async {
    final rows = <Map<String, dynamic>>[];
    Uri? next;
    try {
      for (var page = 0; page < maxPages; page++) {
        final values = await _api.records(path, query: const {'per_page': '100'}, next: next);
        rows.addAll(values.items);
        next = values.next;
        if (next == null) return rows;
      }
    } on ApiFailure catch (error) {
      if (error.status == 404 || error.kind == FailureKind.unsupported) {
        throw const AiWriteRefused('mergeCheckUnsupported');
      }
      throw const AiWriteRefused('mergeCheckIncomplete');
    }
    throw const AiWriteRefused('mergeCheckIncomplete');
  }
}

String _mergeSha(Object? value) {
  if (value is! String || !RegExp(r'^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$').hasMatch(value)) {
    throw const AiWriteRefused('mergeCheckIncomplete');
  }
  return value;
}

bool _mergeMrIdentity(Map<String, dynamic> mr, int project, int iid) =>
    mr['project_id'] == project && mr['iid'] == iid;

bool _mergeAutoReadable(Map<String, dynamic> mr) =>
    mr['state'] == 'merged' || mr['state'] == 'closed' ||
    mr['merge_when_pipeline_succeeds'] is bool || mr['auto_merge_enabled'] is bool;

bool _mergeAutoEnabled(Map<String, dynamic> mr) =>
    mr['state'] != 'merged' && mr['state'] != 'closed' &&
    (mr['merge_when_pipeline_succeeds'] == true || mr['auto_merge_enabled'] == true);

bool _mergePathValid(String path) => path.isNotEmpty && !path.contains('\\') &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) &&
    path.split('/').every((p) => p.isNotEmpty && p != '..' && p != '.');

List<String> _mergeCiConfigBinding(AiCiConfig config) => switch (config) {
  AiCiConfigLocal(:final path) => ['local', path],
  AiCiConfigExternal() => const ['external'],
  AiCiConfigUnreadable() => const ['unreadable'],
};

String _mergeExcerpt(String body) {
  final firstLines = body.split(RegExp(r'\r?\n')).take(3).join('\n');
  return String.fromCharCodes(firstLines.runes.take(200));
}

bool _mergeTextEffects(String text, String projectPath, int project, Set<String> closed) {
  final qualified = RegExp(r'([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)[#!][0-9]+');
  if (qualified.allMatches(text).any((m) => m[1] != projectPath)) return true;
  for (final clause in RegExp(r'\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b([^\n]*)',
      caseSensitive: false).allMatches(text)) {
    final tail = clause[2]!;
    final refs = RegExp(r'([#!])([0-9]+)').allMatches(tail);
    if (refs.any((ref) => ref[1] != '#' || !closed.contains('$project:${ref[2]}'))) return true;
    // A closing expression with an unparsed reference must never execute itself.
    if ((tail.contains('#') || tail.contains('!')) && refs.isEmpty) return true;
  }
  return RegExp(r'https?://[^\s]+/-/(issues|merge_requests)/\d+').hasMatch(text);
}

String _mergeDigest(Object? value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

String _mergeDraftDigest(List<Map<String, dynamic>> drafts) {
  final ordered = drafts.map((d) => <String, Object?>{
    'id': d['id'], 'note': d['note'], 'position': d['position'],
    'commit_id': d['commit_id'], 'discussion_id': d['discussion_id'],
    'resolve_discussion': d['resolve_discussion'],
  }).toList()..sort((a, b) => (a['id']! as int).compareTo(b['id']! as int));
  return _mergeDigest(ordered);
}
