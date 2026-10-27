part of 'gitlab_write_port.dart';

extension _GraphqlActivityCreatePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlActivityCreate(
    AiWriteRequest request,
  ) async {
    final reply = request.operationId == 'createWorkItemActivityReply';
    if (!reply && request.operationId != 'createWorkItemActivityComment') {
      return null;
    }
    _precheckGraphqlActivityText(request, trim: true);
    final arguments = request.arguments;
    final projectId = _positive(arguments, 'projectId');
    final iid = _positive(arguments, 'iid');
    final anchorId = reply ? _positive(arguments, 'anchorNoteId') : null;
    final body = _text(arguments, 'body').trim();
    final GitLabUser user;
    final AiProjectWorkItemLocation location;
    final AiWorkItemActivityNoteLocation? anchor;
    final WorkItemActivityWriteAccess access;
    try {
      user = await _api.currentUser();
      if ('${_api.instance.key}#${user.id}' != accountKey) {
        throw const AiWriteRefused('activityUnverifiable');
      }
      location = await resolveAiProjectWorkItem(
        request.scope,
        projectId,
        iid,
        readDetail: (project, iid) => _api.projectWorkItem(project, iid),
      );
      anchor = anchorId == null
          ? null
          : await locateAiWorkItemActivityNote(
              location.detail,
              anchorId,
              first: (summary) =>
                  _api.workItemActivity(summary, allowLegacyFallback: false),
              next: (continuation) => _api.workItemActivityNext(
                continuation,
                allowLegacyFallback: false,
              ),
              notesNext: (continuation) =>
                  _api.workItemDiscussionNotesNext(continuation),
            );
      // Each opaque target is minted for the located note, including continuations.
      if (reply &&
          (anchor?.replyTarget == null ||
              anchor!.replyTarget!.anchorNoteId != anchor.note.id)) {
        throw const AiWriteRefused('anchorMismatch');
      }
      access = await _api.workItemActivityWriteAccess(
        location.detail.summary,
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
    if (access.controlsSupported != true ||
        access.actorId != 'gid://gitlab/User/${user.id}') {
      throw const AiWriteRefused('activityUnverifiable');
    }
    if (access.discussionLocked) {
      throw const AiWriteRefused('activityLocked');
    }
    if (!access.canCreateNote || access.commentTarget == null) {
      throw const AiWriteRefused('activityForbidden');
    }
    final summary = location.detail.summary;
    final root = [accountKey, 'project:$projectId', 'workItem', '$iid'];
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: '#$iid',
      projectPath: location.project.path,
      writeKeys: {
        _key(root),
        if (anchorId != null) _key([...root, 'note', '$anchorId']),
      },
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.issue,
          projectId: projectId,
          projectPath: location.project.path,
          iid: iid,
        ),
        if (anchorId != null)
          AiTargetRef(
            kind: AiTargetKind.note,
            projectId: projectId,
            projectPath: location.project.path,
            parentIid: iid,
            noteId: anchorId,
          ),
      ],
      textBindingDigest: (processed) => sha256
          .convert(
            utf8.encode(
              jsonEncode([
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
                  expectedActorId: access.actorId,
                  requireControlsSupported: true,
                  beforeMutation: hooks.beforeMutation,
                  mayStart: hooks.mayStart,
                )
              : await _api.createWorkItemActivityComment(
                  access.commentTarget!,
                  body,
                  expectedActorId: access.actorId,
                  beforeMutation: hooks.beforeMutation,
                  mayStart: hooks.mayStart,
                );
          // The typed core result includes the exact independent readback.
          if (created.note.body != body ||
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

void _precheckGraphqlActivityText(AiWriteRequest request, {bool trim = false}) {
  final raw = _text(request.arguments, 'body');
  final body = trim ? raw.trim() : raw;
  // GitLab only executes column-zero commands. This port deliberately keeps
  // the screen's more conservative core guard, refusing even neutralized
  // commands here with their real reason instead of after approval.
  // Fenced examples keep their fence and §5.1 one-space neutralization:
  // "unchanged" means sendable, not byte-identical.
  if (containsWorkItemActivityQuickAction(body)) {
    throw const AiWriteRefused('quickAction');
  }
  if (!isValidWorkItemActivityEditBody(body)) {
    throw const ApiFailure(FailureKind.validation);
  }
}
