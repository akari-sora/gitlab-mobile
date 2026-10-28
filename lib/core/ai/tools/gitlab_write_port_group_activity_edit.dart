part of 'gitlab_write_port.dart';

extension _GroupActivityEditPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupActivityEdit(
    AiWriteRequest request,
  ) async {
    if (request.operationId != 'editGroupWorkItemActivityNote') return null;
    final groupId = _positive(request.arguments, 'groupId');
    final iid = _positive(request.arguments, 'iid');
    final noteId = _positive(request.arguments, 'noteId');
    final body = request.arguments['body'];
    if (body is! String) throw const ApiFailure(FailureKind.validation);
    _precheckGraphqlActivityText(request);

    final context = _captureGroupWriteContext(request);
    final actor = await _readGroupActor(isCurrent: context.isCurrent);
    final location = await _resolveGroupWorkItem(
      request,
      actorUserId: actor.id,
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
    if (!_validAiUserId(author.id) ||
        int.tryParse(author.id.split('/').last) != actor.id) {
      throw const AiWriteRefused('notOwnNote');
    }
    final WorkItemActivityEditAccess access;
    try {
      access = await _api.workItemActivityEditAccess(
        summary,
        located.discussion,
        note,
        isCurrent: context.isCurrent,
      );
    } on ApiFailure catch (error) {
      _refuseChangedActivityEdit(error);
    }
    if (!context.isCurrent()) {
      throw const AiWriteRefused('workItemUnverifiable');
    }
    if (access.actorId != 'gid://gitlab/User/${actor.id}' ||
        access.authorId != access.actorId) {
      throw const AiWriteRefused('notOwnNote');
    }
    final target = access.target;
    if (!access.canEditNote || target == null) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final current = target.note;
    final name = '${identity.fullPath}#$iid';
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: name,
      confirmName: name,
      groupIdentity: identity,
      groupIdentityIsCurrent: context.isCurrent,
      writeKeys: {
        _key([...identity.keyParts, 'notes', '$noteId']),
      },
      dependencyKeys: {AiConflictKey(identity.keyParts)},
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.note,
          side: AiResourceSide.group,
          groupId: groupId,
          groupFullPath: identity.fullPath,
          workItemGid: identity.workItemGid,
          parentIid: iid,
          noteId: noteId,
        ),
      ],
      // Bind the original whole note independently of the final text payload.
      bindingDigest: _deleteDigest([
        accountKey,
        actor.id,
        identity.canonicalKey,
        summary.id,
        summary.iid,
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
      validatePreparedText: _precheckGraphqlActivityText,
      textMutation: (hooks, preparedRequest) async {
        final replacement = preparedRequest.arguments['body']! as String;
        final WorkItemActivityNote saved;
        try {
          saved = await _api.editWorkItemActivityNote(
            target,
            replacement,
            isCurrent: () => hooks.accepted
                ? context.isSessionCurrent()
                : context.isCurrent(),
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
          projection: {'groupId': groupId, 'iid': iid, 'noteId': noteId},
        );
      },
    );
  }
}
