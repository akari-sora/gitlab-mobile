part of 'gitlab_write_port.dart';

extension _GraphqlActivityDeletePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlActivityDelete(
    AiWriteRequest request,
  ) async {
    if (request.operationId != 'deleteWorkItemActivityNote') return null;
    final projectId = _positive(request.arguments, 'projectId');
    final iid = _positive(request.arguments, 'iid');
    final noteId = _positive(request.arguments, 'noteId');
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
      readDetail: (project, iid) => _api.projectWorkItem(project, iid),
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
    // Three deliberate own-note defenses: the located note's author must be
    // the REST account (this line), and in the access read the GraphQL actor
    // must be that same REST user while still equalling the access-reported
    // author — each catches a different drift window, so none is redundant.
    if (!_validAiUserId(author.id) ||
        int.tryParse(author.id.split('/').last) != user.id) {
      throw const AiWriteRefused('notOwnNote');
    }
    final WorkItemActivityDeleteAccess access;
    try {
      access = await _api.workItemActivityDeleteAccess(
        summary,
        located.discussion,
        note,
      );
    } on ApiFailure catch (error) {
      _refuseChangedActivityDelete(error);
    }
    if (access.actorId != 'gid://gitlab/User/${user.id}' ||
        access.authorId != access.actorId) {
      throw const AiWriteRefused('notOwnNote');
    }
    final target = access.target;
    if (!access.canDeleteNote || target == null) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final name = '#$iid';
    final path = location.project.path;
    final keys = {
      _key([
        accountKey,
        'project:$projectId',
        'workItem',
        '$iid',
        'notes',
        '$noteId',
      ]),
    };
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: name,
      confirmName: name,
      writeKeys: keys,
      projectPath: path,
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
        note.id,
        note.createdAt.toIso8601String(),
        note.updatedAt.toIso8601String(),
        author.id,
        author.username,
        note.body,
      ]),
      journal: AiJournalBindings(updatedAt: note.updatedAt.toIso8601String()),
      preview: AiDeletePreview(
        targetName: '',
        path: path,
        parentName: name,
        author: '@${author.username}',
        excerpt: _deleteNoteExcerpt({'body': note.body}),
      ),
      mutation: (hooks) async {
        try {
          // The core preflight rechecks the complete displayed note, including
          // its author and parent, before either hook can run.
          await _api.deleteWorkItemActivityNote(
            target,
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
          );
        } on ApiFailure catch (error) {
          if (!hooks.accepted) _refuseChangedActivityDelete(error);
          rethrow;
        }
        return GraphWriteResult(
          mutationSent: true,
          acknowledged: true,
          readbackVerified: true,
          projection: {
            'projectId': projectId,
            'iid': iid,
            'noteId': noteId,
            'deleted': true,
          },
        );
      },
    );
  }
}

Never _refuseChangedActivityDelete(ApiFailure error) {
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
