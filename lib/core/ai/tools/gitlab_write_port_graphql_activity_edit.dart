part of 'gitlab_write_port.dart';

extension _GraphqlActivityEditPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlActivityEdit(
    AiWriteRequest request,
  ) async {
    if (request.operationId != 'editWorkItemActivityNote') return null;
    final projectId = _positive(request.arguments, 'projectId');
    final iid = _positive(request.arguments, 'iid');
    final noteId = _positive(request.arguments, 'noteId');
    final body = request.arguments['body'];
    if (body is! String) throw const ApiFailure(FailureKind.validation);
    if (!_granted(request.scope, projectId, 'issues', iid)) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    final location = await resolveAiProjectWorkItem(
      request.scope,
      projectId,
      iid,
      readDetail: (project, number) => _api.projectWorkItem(project, number),
    );
    final summary = location.detail.summary;
    final located = await locateAiWorkItemActivityNote(
      location.detail,
      noteId,
      first: (expected) =>
          _api.workItemActivity(expected, allowLegacyFallback: false),
      next: (continuation) =>
          _api.workItemActivityNext(continuation, allowLegacyFallback: false),
      notesNext: (continuation) =>
          _api.workItemDiscussionNotesNext(continuation),
    );
    final note = located.note;
    final author = note.author!;
    if (!_validAiUserId(author.id) ||
        int.tryParse(author.id.split('/').last) != user.id) {
      throw const AiWriteRefused('notOwnNote');
    }
    final WorkItemActivityEditAccess access;
    try {
      access = await _api.workItemActivityEditAccess(
        summary,
        located.discussion,
        note,
      );
    } on ApiFailure catch (error) {
      _refuseChangedActivityEdit(error);
    }
    if (access.actorId != 'gid://gitlab/User/${user.id}' ||
        access.authorId != access.actorId) {
      throw const AiWriteRefused('notOwnNote');
    }
    final target = access.target;
    if (!access.canEditNote || target == null) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final current = target.note;
    final path = location.project.path;
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: '#$iid',
      confirmName: '#$iid',
      projectPath: path,
      writeKeys: {
        _key([
          accountKey,
          'project:$projectId',
          'workItem',
          '$iid',
          'notes',
          '$noteId',
        ]),
      },
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.note,
          side: AiResourceSide.issue,
          projectId: projectId,
          projectPath: path,
          parentIid: iid,
          noteId: noteId,
        ),
      ],
      bindingDigest: _deleteDigest([
        accountKey,
        user.id,
        summary.id,
        summary.iid,
        summary.project?.id,
        summary.project?.fullPath,
        summary.namespace?.id,
        summary.namespace?.fullPath,
        summary.type.id,
        summary.updatedAt.toIso8601String(),
        located.discussion.id,
        located.discussion.replyId,
        located.discussion.createdAt.toIso8601String(),
        current.id,
        current.createdAt.toIso8601String(),
        current.updatedAt.toIso8601String(),
        author.id,
        author.username,
        current.body,
      ]),
      currentFields: {'body': current.body},
      journal: AiJournalBindings(
        updatedAt: current.updatedAt.toIso8601String(),
      ),
      preview: AiFieldsPreview({'body': body}),
      textMutation: (hooks, preparedRequest) async {
        final replacement = preparedRequest.arguments['body']! as String;
        final WorkItemActivityNote saved;
        try {
          saved = await _api.editWorkItemActivityNote(
            target,
            replacement,
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
          );
        } on ApiFailure catch (error) {
          if (!hooks.accepted) _refuseChangedActivityEdit(error);
          rethrow;
        }
        final changed = current.body != replacement;
        return GraphWriteResult(
          noChange: !changed,
          mutationSent: changed,
          acknowledged: changed,
          readbackVerified: changed,
          revision: saved.updatedAt,
          projection: {'projectId': projectId, 'iid': iid, 'noteId': noteId},
        );
      },
    );
  }
}

Never _refuseChangedActivityEdit(ApiFailure error) {
  switch (error.kind) {
    case FailureKind.invisible:
      throw const AiWriteRefused('noteMissing');
    case FailureKind.conflict:
    case FailureKind.invalidResponse:
      throw const AiWriteRefused('noteChanged');
    default:
      throw error;
  }
}
