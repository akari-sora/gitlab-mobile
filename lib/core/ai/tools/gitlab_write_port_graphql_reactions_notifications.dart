part of 'gitlab_write_port.dart';

extension _GraphqlReactionsNotificationsPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlReactionsNotifications(
    AiWriteRequest request,
  ) async {
    final reaction = request.operationId == 'setWorkItemActivityNoteReaction';
    if (!reaction && request.operationId != 'setWorkItemNotifications') {
      return null;
    }
    final a = request.arguments;
    final projectId = _positive(a, 'projectId');
    final iid = _positive(a, 'iid');
    final direction = a[reaction ? 'add' : 'enabled'];
    if (direction is! bool) throw const AiWriteRefused('intentUnclear');
    final noteId = reaction ? _positive(a, 'noteId') : null;
    final name = reaction ? _text(a, 'name') : null;
    if (name != null &&
        (name.length > 80 || !RegExp(r'^[A-Za-z0-9_+\-]+$').hasMatch(name))) {
      throw const ApiFailure(FailureKind.validation);
    }
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
    final actorId = 'gid://gitlab/User/${user.id}';
    final root = <String>[accountKey, 'project:$projectId', 'workItem', '$iid'];
    final identity = <Object?>[
      accountKey,
      request.operationId,
      projectId,
      location.project.path,
      iid,
      summary.id,
      summary.type.id,
      summary.namespace?.id,
      summary.namespace?.fullPath,
      summary.updatedAt.toIso8601String(),
      actorId,
      direction,
    ];

    if (reaction) {
      final found = await locateAiWorkItemActivityNote(
        location.detail,
        noteId!,
        first: (expected) =>
            _api.workItemActivity(expected, allowLegacyFallback: false),
        next: (continuation) =>
            _api.workItemActivityNext(continuation, allowLegacyFallback: false),
        notesNext: (continuation) =>
            _api.workItemDiscussionNotesNext(continuation),
      );
      final WorkItemActivityReactionAccess opening;
      try {
        opening = await _api.workItemActivityReactionAccess(
          summary,
          found.discussion,
          found.note,
          maxPages: 2,
        );
      } on ApiFailure catch (failure) {
        throw _p11Refusal(failure, reaction: true);
      }
      final target = opening.target;
      if (opening.actorId != actorId) {
        throw const AiWriteRefused('reactionConflict');
      }
      if (!opening.canAward || target == null) {
        throw const AiWriteRefused('reactionForbidden');
      }
      bool hasReaction(WorkItemActivityReactionAccess access) => access
          .reactions
          .any((award) => award.actorId == actorId && award.name == name);
      final before = hasReaction(opening);
      return AiWritePrepared.graph(
        request: request,
        owner: _owner,
        releaseName: '#$iid',
        projectPath: location.project.path,
        writeKeys: {
          _key([...root, 'notes', '$noteId']),
        },
        dependencyKeys: {_key(root)},
        bindingTargets: [
          AiTargetRef(
            kind: AiTargetKind.note,
            projectId: projectId,
            projectPath: location.project.path,
            iid: iid,
            parentIid: iid,
            noteId: noteId,
          ),
        ],
        bindingDigest: _p11Digest([
          ...identity,
          noteId,
          name,
          before,
          found.discussion.id,
          found.discussion.createdAt.toIso8601String(),
          found.note.id,
          found.note.author?.id,
          found.note.createdAt.toIso8601String(),
          found.note.updatedAt.toIso8601String(),
          found.note.body,
        ]),
        journal: AiJournalBindings(
          updatedAt: found.note.updatedAt.toIso8601String(),
        ),
        preview: AiFieldsPreview(a),
        mutation: (hooks) async {
          final WorkItemActivityReactionAccess result;
          try {
            result = await _api.setWorkItemActivityNoteReaction(
              target,
              name!,
              awarded: direction,
              beforeMutation: hooks.beforeMutation,
              mayStart: hooks.mayStart,
            );
          } on ApiFailure catch (failure) {
            if (hooks.state == GraphWriteSpanState.notHooked) {
              throw _p11Refusal(failure, reaction: true);
            }
            rethrow;
          }
          if (result.actorId != actorId || hasReaction(result) != direction) {
            throw const AiWriteRefused('reactionConflict');
          }
          return GraphWriteResult(
            noChange: before == direction && !hooks.accepted,
            mutationSent: hooks.accepted,
            acknowledged: hooks.accepted,
            readbackVerified: hooks.accepted,
            projection: {'noteId': noteId, 'name': name, 'add': direction},
          );
        },
      );
    }

    final WorkItemNotificationAccess opening;
    try {
      opening = await _api.workItemNotifications(
        summary,
        expectedUserId: user.id,
      );
    } on ApiFailure catch (failure) {
      throw _p11Refusal(failure, reaction: false);
    }
    final target = opening.target;
    if (opening.actorId != actorId) {
      throw const AiWriteRefused('notificationConflict');
    }
    if (!opening.canAttemptSubscription || target == null) {
      throw const AiWriteRefused('notificationForbidden');
    }
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: '#$iid',
      projectPath: location.project.path,
      writeKeys: {_key(root)},
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.issue,
          projectId: projectId,
          projectPath: location.project.path,
          iid: iid,
        ),
      ],
      bindingDigest: _p11Digest([...identity, opening.subscribed]),
      journal: AiJournalBindings(
        updatedAt: summary.updatedAt.toIso8601String(),
      ),
      preview: AiFieldsPreview(a),
      mutation: (hooks) async {
        final WorkItemNotificationAccess result;
        try {
          result = await _api.setWorkItemNotifications(
            target,
            subscribed: direction,
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
          );
        } on ApiFailure catch (failure) {
          if (hooks.state == GraphWriteSpanState.notHooked) {
            throw _p11Refusal(failure, reaction: false);
          }
          rethrow;
        }
        if (result.actorId != actorId || result.subscribed != direction) {
          throw const AiWriteRefused('notificationConflict');
        }
        return GraphWriteResult(
          noChange: opening.subscribed == direction && !hooks.accepted,
          mutationSent: hooks.accepted,
          acknowledged: hooks.accepted,
          readbackVerified: hooks.accepted,
          projection: {'enabled': direction},
        );
      },
    );
  }
}

AiWriteRefused _p11Refusal(ApiFailure failure, {required bool reaction}) =>
    AiWriteRefused(switch (failure.kind) {
      FailureKind.forbidden ||
      FailureKind.invisible ||
      FailureKind.unsupported =>
        reaction ? 'reactionForbidden' : 'notificationForbidden',
      _ => reaction ? 'reactionConflict' : 'notificationConflict',
    });

String _p11Digest(List<Object?> values) =>
    sha256.convert(utf8.encode(jsonEncode(values))).toString();
