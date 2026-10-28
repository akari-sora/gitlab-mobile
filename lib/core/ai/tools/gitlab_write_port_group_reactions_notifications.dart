part of 'gitlab_write_port.dart';

extension _GroupReactionsNotificationsPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupReactionsNotifications(
    AiWriteRequest request,
  ) async {
    final reaction =
        request.operationId == 'setGroupWorkItemActivityNoteReaction';
    if (!reaction && request.operationId != 'setGroupWorkItemNotifications') {
      return null;
    }
    final a = request.arguments;
    final groupId = _positive(a, 'groupId');
    final iid = _positive(a, 'iid');
    final direction = a[reaction ? 'add' : 'enabled'];
    if (direction is! bool) throw const AiWriteRefused('intentUnclear');
    final noteId = reaction ? _positive(a, 'noteId') : null;
    final name = reaction ? _text(a, 'name') : null;
    if (name != null &&
        (name.length > 80 || !RegExp(r'^[A-Za-z0-9_+\-]+$').hasMatch(name))) {
      throw const ApiFailure(FailureKind.validation);
    }
    final context = _captureGroupWriteContext(request);
    final user = await _readGroupActor(isCurrent: context.isCurrent);
    final location = await _resolveGroupWorkItem(
      request,
      actorUserId: user.id,
      generation: context.generation,
      readEpoch: context.readEpoch,
      isCurrent: context.isCurrent,
    );
    if (!context.isCurrent()) {
      throw const AiWriteRefused('workItemUnverifiable');
    }
    final verifiedOwner = location.identity;
    final detail = location.detail.withStrictGroupOwner(verifiedOwner);
    final summary = detail.summary;
    final actorId = 'gid://gitlab/User/${user.id}';
    final root = verifiedOwner.keyParts;
    final identity = <Object?>[
      accountKey,
      request.operationId,
      groupId,
      verifiedOwner.fullPath,
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
        detail,
        noteId!,
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
      final WorkItemActivityReactionAccess opening;
      try {
        opening = await _api.workItemActivityReactionAccess(
          summary,
          found.discussion,
          found.note,
          maxPages: 2,
          isCurrent: context.isCurrent,
        );
      } on ApiFailure catch (failure) {
        throw _p11Refusal(failure, reaction: true);
      }
      if (!context.isCurrent()) {
        throw const AiWriteRefused('workItemUnverifiable');
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
        releaseName: '${verifiedOwner.fullPath}#$iid',
        groupIdentity: verifiedOwner,
        groupIdentityIsCurrent: context.isCurrent,
        writeKeys: {
          _key([...root, 'notes', '$noteId']),
        },
        dependencyKeys: {_key(root)},
        bindingTargets: [
          AiTargetRef(
            kind: AiTargetKind.note,
            side: AiResourceSide.group,
            groupId: groupId,
            groupFullPath: verifiedOwner.fullPath,
            workItemGid: verifiedOwner.workItemGid,
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
              isCurrent: () => hooks.accepted
                  ? context.isSessionCurrent()
                  : context.isCurrent(),
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
        isCurrent: context.isCurrent,
      );
    } on ApiFailure catch (failure) {
      throw _p11Refusal(failure, reaction: false);
    }
    if (!context.isCurrent()) {
      throw const AiWriteRefused('workItemUnverifiable');
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
      releaseName: '${verifiedOwner.fullPath}#$iid',
      groupIdentity: verifiedOwner,
      groupIdentityIsCurrent: context.isCurrent,
      writeKeys: {_key(root)},
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: groupId,
          groupFullPath: verifiedOwner.fullPath,
          workItemGid: verifiedOwner.workItemGid,
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
            isCurrent: () => hooks.accepted
                ? context.isSessionCurrent()
                : context.isCurrent(),
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
