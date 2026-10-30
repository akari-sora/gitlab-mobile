part of 'gitlab_write_port.dart';

extension _DeletesPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareDeletes(AiWriteRequest request) async {
    final op = request.operationId;
    if (!aiDeleteRows.any((row) => row.operationId == op)) return null;
    final a = request.arguments;
    if (op == 'markAllTodosDone') {
      if (!request.scope.grants.any(
        (g) => g.kind == AiScopeKind.accountGlobal,
      )) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      final user = await _api.currentUser();
      if ('${_api.instance.key}#${user.id}' != accountKey) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      if (user.username.trim().isEmpty) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      final page = await _api.records(
        ['todos'],
        query: {'per_page': '100', 'state': 'pending'},
      );
      final name = '@${user.username}';
      return AiWritePrepared._(
        request: request,
        classify: _resultClassifier,
        releaseName: name,
        confirmName: name,
        writeKeys: {_key([accountKey, 'todos'])},
        dependencyKeys: {},
        owner: _owner,
        mutation: () => _api.markAllTodosDone(),
        bindingDigest: _deleteDigest([
          accountKey, name, page.items.map((v) => v['id']).toList(),
          page.next != null,
        ]),
        preview: AiDeletePreview(
          targetName: name,
          count: page.items.length,
          hasMore: page.next != null,
        ),
      );
    }

    final project = _positive(a, 'projectId');
    final note = op == 'deleteNote' || op == 'deleteDiscussionNote';
    final parent = note || op == 'deleteIssue' || op == 'deleteMergeRequest';
    final resource = note ? _resource(a)
        : op == 'deleteMergeRequest' ? 'merge_requests' : 'issues';
    final iid = parent ? _positive(a, 'iid') : null;
    final noteId = note ? _positive(a, 'noteId') : null;
    final discussion = op == 'deleteDiscussionNote'
        ? _text(a, 'discussionId') : null;
    if (discussion != null && !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(discussion)) {
      throw const ApiFailure(
        FailureKind.validation,
        validationDetail:
            'validation: discussionId must contain only [a-zA-Z0-9_-]',
      );
    }
    final targetId = switch (op) {
      'deleteLabel' => _positive(a, 'labelId'),
      'deleteMilestone' => _positive(a, 'milestoneId'),
      'deleteBoard' || 'deleteBoardList' => _positive(a, 'boardId'),
      _ => null,
    };
    final listId = op == 'deleteBoardList' ? _positive(a, 'listId') : null;
    if (!_granted(request.scope, project, resource, iid, projectOnly: !parent)) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final p = await _api.record(['projects', '$project']);
    _deleteVerify(p, project);
    final projectPath = _deleteName(p, 'path_with_namespace');
    final prefix = [accountKey, 'project:$project'];
    late List<String> key;
    late String name;
    late Map<String, dynamic> target;
    Map<String, dynamic>? parentRecord;
    late Future<Object?> Function() mutation;
    if (parent) {
      parentRecord = await _api.record(['projects', '$project', resource, '$iid']);
      if (parentRecord['project_id'] != project || parentRecord['iid'] != iid) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      name = '${resource == 'issues' ? '#' : '!'}${parentRecord['iid']}';
      key = [...prefix, resource == 'issues' ? 'workItem' : 'mergeRequest', '$iid'];
      target = parentRecord;
      if (note) {
        if (discussion != null) {
          final thread = await _api.record([
            'projects', '$project', resource, '$iid', 'discussions', discussion,
          ]);
          final notes = thread['notes'];
          if (thread['id'] != discussion || notes is! List) {
            throw const ApiFailure(FailureKind.forbidden);
          }
          final matches = notes.whereType<Map<String, dynamic>>()
              .where((v) => v['id'] == noteId).toList();
          if (matches.length != 1) {
            throw const ApiFailure(FailureKind.forbidden);
          }
          target = matches.single;
          mutation = () => _api.deleteDiscussionNote(
            project, resource, iid!, discussion, noteId!,
          );
        } else {
          target = await _api.record([
            'projects', '$project', resource, '$iid', 'notes', '$noteId',
          ]);
          _deleteVerify(target, noteId!);
          mutation = () => _api.deleteNote(project, resource, iid!, noteId);
        }
        key = [...key, 'notes', '$noteId'];
      } else if (op == 'deleteIssue') {
        mutation = () => _api.deleteIssue(project, iid!);
      } else {
        mutation = () => _api.deleteMergeRequest(project, iid!);
      }
    } else {
      final collection = switch (op) {
        'deleteLabel' => 'labels',
        'deleteMilestone' => 'milestones',
        _ => 'boards',
      };
      target = await _api.record(['projects', '$project', collection, '$targetId']);
      _deleteVerify(target, targetId!, project: project);
      key = [...prefix, collection, '$targetId'];
      if (op == 'deleteBoardList') {
        target = await _api.record([
          'projects', '$project', 'boards', '$targetId', 'lists', '$listId',
        ]);
        _deleteVerify(target, listId!, project: project);
        if (target['board_id'] != null && target['board_id'] != targetId) {
          throw const ApiFailure(FailureKind.forbidden);
        }
        final label = target['label'];
        if (label is! Map<String, dynamic> || label['id'] is! int ||
            (label['id'] as int) <= 0) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
        name = _deleteName(label, 'name');
        mutation = () => _api.deleteBoardList(project, targetId, listId);
      } else {
        name = _deleteName(target, op == 'deleteMilestone' ? 'title' : 'name');
        mutation = switch (op) {
          'deleteLabel' => () => _api.deleteLabel(project, targetId),
          'deleteMilestone' => () => _api.deleteMilestone(project, targetId),
          _ => () => _api.deleteBoard(project, targetId),
        };
      }
    }
    final updatedAt = target['updated_at'];
    final bindingTarget = switch (op) {
      'deleteLabel' => AiTargetRef(
          kind: AiTargetKind.label,
          projectId: project,
          projectPath: projectPath,
          name: name,
        ),
      'deleteMilestone' => AiTargetRef(
          kind: AiTargetKind.milestone,
          projectId: project,
          projectPath: projectPath,
          name: name,
        ),
      'deleteBoard' || 'deleteBoardList' => AiTargetRef(
          kind: AiTargetKind.other,
          projectId: project,
          projectPath: projectPath,
          name: name,
        ),
      'deleteNote' || 'deleteDiscussionNote' => AiTargetRef(
          kind: AiTargetKind.note,
          side: resource == 'issues'
              ? AiResourceSide.issue
              : AiResourceSide.mergeRequest,
          projectId: project,
          projectPath: projectPath,
          parentIid: iid,
          noteId: noteId,
        ),
      'deleteIssue' => AiTargetRef(
          kind: AiTargetKind.issue,
          projectId: project,
          projectPath: projectPath,
          iid: iid,
        ),
      'deleteMergeRequest' => AiTargetRef(
          kind: AiTargetKind.mergeRequest,
          projectId: project,
          projectPath: projectPath,
          iid: iid,
        ),
      _ => null,
    };
    final noteAuthor = note ? _deleteNoteAuthor(target) : null;
    final noteExcerpt = note ? _deleteNoteExcerpt(target) : null;
    return AiWritePrepared._(
      request: request,
      classify: _resultClassifier,
      releaseName: parent ? name : projectPath,
      confirmName: name,
      writeKeys: {_key(key)},
      dependencyKeys: {},
      owner: _owner,
      mutation: mutation,
      projectPath: projectPath,
      projectVisibility: p['visibility'] is String ? p['visibility'] as String : null,
      bindingTargets: [?bindingTarget],
      bindingDigest: _deleteDigest([
        key, name, projectPath, p['visibility'], target['id'], updatedAt,
        parentRecord?['updated_at'],
        if (op == 'deleteBoardList') target['label'],
      ]),
      journal: AiJournalBindings(updatedAt: updatedAt is String ? updatedAt : null),
      preview: AiDeletePreview(
        targetName: note ? '' : name,
        path: projectPath,
        parentName: note ? name : null,
        author: noteAuthor,
        excerpt: noteExcerpt,
      ),
    );
  }
}

String _deleteNoteAuthor(Map<String, dynamic> note) {
  final author = note['author'];
  if (author is! Map<String, dynamic>) {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  return '@${_deleteName(author, 'username')}';
}

String _deleteNoteExcerpt(Map<String, dynamic> note) {
  final body = note['body'];
  if (body is! String) throw const ApiFailure(FailureKind.invalidResponse);
  final excerpt = const LineSplitter().convert(body).take(3).join('\n');
  return String.fromCharCodes(excerpt.runes.take(200));
}

void _deleteVerify(Map<String, dynamic> value, int id, {int? project}) {
  if (value['id'] != id || (project != null && value['project_id'] != null &&
      value['project_id'] != project)) {
    throw const ApiFailure(FailureKind.forbidden);
  }
}

String _deleteName(Map<String, dynamic> value, String field) {
  final name = _responseText(value, field);
  if (name.trim().isEmpty) throw const ApiFailure(FailureKind.invalidResponse);
  return name;
}

String _deleteDigest(List<Object?> values) =>
    sha256.convert(utf8.encode(jsonEncode(values))).toString();
