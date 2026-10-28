part of 'gitlab_write_port.dart';

extension _GroupActivityDeletePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupActivityDelete(
    AiWriteRequest request,
  ) async {
    if (request.operationId != 'deleteGroupWorkItemActivityNote') return null;
    final context = _captureGroupWriteContext(request);
    final groupId = _positive(request.arguments, 'groupId');
    final iid = _positive(request.arguments, 'iid');
    final noteId = _positive(request.arguments, 'noteId');
    final user = await _readGroupActor(isCurrent: context.isCurrent);
    final location = await _resolveGroupWorkItem(
      request,
      actorUserId: user.id,
      generation: context.generation,
      readEpoch: context.readEpoch,
      isCurrent: context.isCurrent,
    );
    final identity = location.identity;
    final detail = location.detail.withStrictGroupOwner(identity);
    final summary = detail.summary;
    final located = await locateAiWorkItemActivityNote(
      detail,
      noteId,
      first: (expected) => _api.workItemActivity(
        expected,
        allowLegacyFallback: false,
        isCurrent: context.isCurrent,
      ),
      next: (continuation) => _api.workItemActivityNext(
        continuation,
        allowLegacyFallback: false,
        isCurrent: context.isCurrent,
      ),
      notesNext: (continuation) => _api.workItemDiscussionNotesNext(
        continuation,
        isCurrent: context.isCurrent,
      ),
    );
    if (!context.isCurrent()) {
      throw const AiWriteRefused('workItemUnverifiable');
    }
    final note = located.note;
    final author = note.author!;
    // Permission to administer notes does not grant permission to delete
    // another author's note, including when the actor is an administrator.
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
        isCurrent: context.isCurrent,
      );
    } on ApiFailure catch (error) {
      _refuseChangedActivityDelete(error);
    }
    if (!context.isCurrent()) {
      throw const AiWriteRefused('workItemUnverifiable');
    }
    if (access.actorId != 'gid://gitlab/User/${user.id}' ||
        access.authorId != access.actorId) {
      throw const AiWriteRefused('notOwnNote');
    }
    final target = access.target;
    if (!access.canDeleteNote || target == null) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final name = '${identity.fullPath}#${identity.iid}';
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: name,
      confirmName: name,
      groupIdentity: identity,
      groupIdentityIsCurrent: context.isCurrent,
      writeKeys: {
        AiConflictKey([...identity.keyParts, 'notes', '$noteId']),
      },
      dependencyKeys: {AiConflictKey(identity.keyParts)},
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.note,
          side: AiResourceSide.group,
          groupId: identity.groupId,
          groupFullPath: identity.fullPath,
          parentIid: identity.iid,
          noteId: noteId,
        ),
      ],
      bindingDigest: _deleteDigest([
        accountKey,
        user.id,
        summary.id,
        summary.iid,
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
        path: identity.fullPath,
        parentName: name,
        author: '@${author.username}',
        excerpt: _deleteNoteExcerpt({'body': note.body}),
      ),
      mutation: (hooks) async {
        try {
          // The core keeps this strict owner for its preflight and mandatory
          // independent parent + note:null readback (D29). Its own send may
          // advance the read epoch; session ownership must still be current.
          await _api.deleteWorkItemActivityNote(
            target,
            isCurrent: () => hooks.accepted
                ? context.isSessionCurrent()
                : context.isCurrent(),
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
            'groupId': groupId,
            'iid': iid,
            'noteId': noteId,
            'deleted': true,
          },
        );
      },
    );
  }
}
