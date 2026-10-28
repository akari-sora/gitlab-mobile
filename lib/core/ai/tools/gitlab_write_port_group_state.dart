part of 'gitlab_write_port.dart';

extension _GroupStatePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupState(AiWriteRequest request) async {
    if (request.operationId != 'updateGroupWorkItemState') return null;
    final context = _captureGroupWriteContext(request);
    final event = switch (request.arguments['stateEvent']) {
      'close' => WorkItemStateEvent.close,
      'reopen' => WorkItemStateEvent.reopen,
      _ => throw const AiWriteRefused('stateNotApplied'),
    };
    try {
      final actor = await _readGroupActor(isCurrent: context.isCurrent);
      final location = await _resolveGroupWorkItem(
        request,
        actorUserId: actor.id,
        generation: context.generation,
        readEpoch: context.readEpoch,
        isCurrent: context.isCurrent,
      );
      final identity = location.identity;
      final expected = location.detail.summary.withStrictGroupOwner(identity);
      final opening = await _api.workItemState(
        expected,
        isCurrent: context.isCurrent,
      );
      if (!context.isCurrent()) {
        throw const AiWriteRefused('workItemUnverifiable');
      }
      final expectedState = switch (expected.state) {
        'OPEN' => WorkItemState.open,
        'CLOSED' => WorkItemState.closed,
        _ => throw const AiWriteRefused('stateNotApplied'),
      };
      if (opening.updatedAt != expected.updatedAt.toUtc() ||
          opening.state != expectedState) {
        throw const AiWriteRefused('stateConflict');
      }
      if (!opening.canUpdate) {
        throw const AiWriteRefused('stateForbidden');
      }
      final digest = sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'actor': actor.id,
                'groupId': identity.groupId,
                'groupPath': identity.fullPath,
                'id': expected.id,
                'iid': expected.iid,
                'namespaceId': expected.namespace?.id,
                'namespacePath': expected.namespace?.fullPath,
                'typeId': expected.type.id,
                'updatedAt': opening.updatedAt.toUtc().toIso8601String(),
                'state': opening.state.name,
                'canUpdate': opening.canUpdate,
                'stateEvent': event.apiValue,
              }),
            ),
          )
          .toString();
      return AiWritePrepared.graph(
        request: request,
        owner: _owner,
        releaseName: '${identity.fullPath}#${identity.iid}',
        groupIdentity: identity,
        groupIdentityIsCurrent: context.isCurrent,
        writeKeys: {AiConflictKey(identity.keyParts)},
        bindingTargets: [
          AiTargetRef(
            kind: AiTargetKind.groupWorkItem,
            side: AiResourceSide.group,
            groupId: identity.groupId,
            groupFullPath: identity.fullPath,
            workItemGid: identity.workItemGid,
            iid: identity.iid,
          ),
        ],
        bindingDigest: digest,
        journal: AiJournalBindings(
          updatedAt: opening.updatedAt.toUtc().toIso8601String(),
        ),
        preview: AiFieldsPreview({'stateEvent': event.name}),
        mutation: (hooks) async {
          try {
            final result = await _api.updateWorkItemState(
              expected,
              event,
              expectedUpdatedAt: opening.updatedAt,
              isCurrent: () => hooks.accepted
                  ? context.isSessionCurrent()
                  : context.isCurrent(),
              beforeMutation: hooks.beforeMutation,
              mayStart: hooks.mayStart,
            );
            if (result.id != expected.id || result.state != event.result) {
              throw const AiWriteRefused('stateNotApplied');
            }
            return GraphWriteResult(
              noChange: !hooks.accepted && opening.state == event.result,
              mutationSent: hooks.accepted,
              acknowledged: hooks.accepted,
              readbackVerified: hooks.accepted,
              revision: result.updatedAt,
              projection: {
                'id': result.id,
                'iid': result.iid,
                'state': result.state.name,
              },
            );
          } on ApiFailure catch (failure) {
            throw _stateWriteRefusal(failure);
          }
        },
      );
    } on ApiFailure catch (failure) {
      throw _stateWriteRefusal(failure);
    }
  }
}
