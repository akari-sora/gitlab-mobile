part of 'gitlab_write_port.dart';

extension _GroupActivityCreatePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupActivityCreate(
    AiWriteRequest request,
  ) async {
    final reply = request.operationId == 'createGroupWorkItemActivityReply';
    if (!reply && request.operationId != 'createGroupWorkItemActivityComment') {
      return null;
    }
    final context = _captureGroupWriteContext(request);
    _precheckGraphqlActivityText(request, trim: true);
    final arguments = request.arguments;
    final groupId = _positive(arguments, 'groupId');
    final iid = _positive(arguments, 'iid');
    final anchorId = reply ? _positive(arguments, 'anchorNoteId') : null;
    final body = _text(arguments, 'body').trim();
    final GitLabUser user;
    final AiGroupWorkItemLocation location;
    final WorkItemGraphDetail detail;
    final AiWorkItemActivityNoteLocation? anchor;
    final WorkItemActivityWriteAccess access;
    try {
      user = await _readGroupActor(isCurrent: context.isCurrent);
      location = await _resolveGroupWorkItem(
        request,
        actorUserId: user.id,
        generation: context.generation,
        readEpoch: context.readEpoch,
        isCurrent: context.isCurrent,
      );
      detail = location.detail.withStrictGroupOwner(location.identity);
      anchor = anchorId == null
          ? null
          : await locateAiWorkItemActivityNote(
              detail,
              anchorId,
              first: (summary) => _api.workItemActivity(
                summary,
                isCurrent: context.isCurrent,
                allowLegacyFallback: false,
              ),
              next: (continuation) => _api.workItemActivityNext(
                continuation,
                isCurrent: context.isCurrent,
                allowLegacyFallback: false,
              ),
              notesNext: (continuation) => _api.workItemDiscussionNotesNext(
                continuation,
                isCurrent: context.isCurrent,
              ),
            );
      if (!context.isCurrent()) {
        throw const AiWriteRefused('activityUnverifiable');
      }
      // Each opaque target is minted for the located note, including continuations.
      if (reply &&
          (anchor?.replyTarget == null ||
              anchor!.replyTarget!.anchorNoteId != anchor.note.id)) {
        throw const AiWriteRefused('anchorMismatch');
      }
      access = await _api.workItemActivityWriteAccess(
        detail.summary,
        isCurrent: context.isCurrent,
        requireControlsSupported: true,
      );
    } on AiWriteRefused catch (failure) {
      throw AiWriteRefused(switch (failure.reason) {
        'noteMissing' => 'anchorMismatch',
        'workItemUnverifiable' => 'activityUnverifiable',
        _ => failure.reason,
      });
    } on ApiFailure catch (failure) {
      throw AiWriteRefused(
        failure.kind == FailureKind.forbidden
            ? 'activityForbidden'
            : 'activityUnverifiable',
      );
    }
    if (!context.isCurrent() ||
        access.controlsSupported != true ||
        access.actorId != 'gid://gitlab/User/${user.id}') {
      throw const AiWriteRefused('activityUnverifiable');
    }
    if (access.discussionLocked) {
      throw const AiWriteRefused('activityLocked');
    }
    if (!access.canCreateNote || access.commentTarget == null) {
      throw const AiWriteRefused('activityForbidden');
    }
    final summary = detail.summary;
    final identity = location.identity;
    final root = identity.keyParts;
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: '${identity.fullPath}#$iid',
      groupIdentity: identity,
      groupIdentityIsCurrent: context.isCurrent,
      writeKeys: {
        _key(root),
        // Creation always fences the parent and its notes collection.
        _key([...root, 'notes']),
      },
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: groupId,
          groupFullPath: identity.fullPath,
          iid: iid,
        ),
        if (anchorId != null)
          AiTargetRef(
            kind: AiTargetKind.note,
            side: AiResourceSide.group,
            groupId: groupId,
            groupFullPath: identity.fullPath,
            parentIid: iid,
            noteId: anchorId,
          ),
      ],
      textBindingDigest: (processed) => sha256
          .convert(
            utf8.encode(
              jsonEncode([
                identity.canonicalKey,
                user.id,
                user.username,
                summary.id,
                summary.iid,
                summary.project?.id,
                summary.project?.fullPath,
                summary.namespace?.id,
                summary.namespace?.fullPath,
                summary.type.id,
                summary.updatedAt.toUtc().toIso8601String(),
                _text(processed.arguments, 'body').trim(),
                if (anchor != null) ...[
                  anchor.discussion.id,
                  anchor.discussion.replyId,
                  anchor.discussion.createdAt.toUtc().toIso8601String(),
                  anchor.note.id,
                  anchor.note.createdAt.toUtc().toIso8601String(),
                  anchor.note.updatedAt.toUtc().toIso8601String(),
                  anchor.note.author?.id,
                  anchor.note.body,
                ],
              ]),
            ),
          )
          .toString(),
      journal: AiJournalBindings(
        updatedAt: summary.updatedAt.toUtc().toIso8601String(),
      ),
      preview: AiFieldsPreview({'body': body, 'anchorNoteId': ?anchorId}),
      validatePreparedText: (processed) =>
          _precheckGraphqlActivityText(processed, trim: true),
      textMutation: (hooks, preparedRequest) async {
        final body = _text(preparedRequest.arguments, 'body').trim();
        try {
          final created = reply
              ? await _api.createWorkItemActivityReply(
                  anchor!.replyTarget!,
                  body,
                  isCurrent: () => hooks.accepted
                      ? context.isSessionCurrent()
                      : context.isCurrent(),
                  expectedActorId: access.actorId,
                  requireControlsSupported: true,
                  beforeMutation: hooks.beforeMutation,
                  mayStart: hooks.mayStart,
                )
              : await _api.createWorkItemActivityComment(
                  access.commentTarget!,
                  body,
                  isCurrent: () => hooks.accepted
                      ? context.isSessionCurrent()
                      : context.isCurrent(),
                  expectedActorId: access.actorId,
                  beforeMutation: hooks.beforeMutation,
                  mayStart: hooks.mayStart,
                );
          // The typed core result includes the exact independent readback.
          if (!context.isSessionCurrent() ||
              created.note.body != body ||
              created.note.author?.id != 'gid://gitlab/User/${user.id}' ||
              _aiNoteNumericId(created.note.id) == null ||
              (anchor != null &&
                  (created.discussionId != anchor.discussion.id ||
                      created.replyId != anchor.discussion.replyId))) {
            throw const AiWriteRefused('activityUnverifiable');
          }
          return GraphWriteResult(
            mutationSent: true,
            acknowledged: true,
            readbackVerified: true,
            projection: {'id': _aiNoteNumericId(created.note.id)},
          );
        } on ApiFailure catch (failure) {
          if (hooks.accepted) rethrow;
          throw AiWriteRefused(switch (failure.kind) {
            FailureKind.forbidden => 'activityForbidden',
            FailureKind.conflict => reply ? 'anchorMismatch' : 'activityLocked',
            _ => 'activityUnverifiable',
          });
        }
      },
    );
  }
}
