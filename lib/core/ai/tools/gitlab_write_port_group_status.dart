part of 'gitlab_write_port.dart';

extension _GroupStatusPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupStatus(AiWriteRequest request) async {
    if (request.operationId != 'updateGroupWorkItemStatus') return null;
    final context = _captureGroupWriteContext(request);
    final groupId = _positive(request.arguments, 'groupId');
    final iid = _positive(request.arguments, 'iid');
    final candidateId = _text(request.arguments, 'candidateId');
    final registry = workItemWriteRegistry;
    if (registry == null) throw const AiWriteRefused('registryUnavailable');
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
    if (registry.isActive(summary.id)) {
      throw const AiWriteRefused('statusNotStarted');
    }
    final access = await _api.workItemStatus(
      detail,
      expectedUserId: actor.id,
      generation: context.generation,
      isCurrent: () => context.isCurrent() && !registry.isActive(summary.id),
    );
    if (!context.isCurrent()) {
      throw const AiWriteRefused('workItemUnverifiable');
    }
    final opening = access.snapshot;
    if (!opening.allowedStatusIds.contains(candidateId)) {
      throw const AiWriteRefused('statusInvalidCandidate');
    }
    if (opening.updatedAt != summary.updatedAt ||
        opening.state.name.toUpperCase() != summary.state) {
      throw const AiWriteRefused('statusStaleFence');
    }
    final target = access.target;
    if (!access.canWrite || target == null) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    if (registry.isActive(summary.id)) {
      throw const AiWriteRefused('statusNotStarted');
    }
    final binding = <Object?>[
      identity.canonicalKey,
      identity.fullPath,
      actor.id,
      summary.id,
      iid,
      opening.namespace?.id,
      opening.namespace?.fullPath,
      opening.typeId,
      opening.updatedAt.toIso8601String(),
      opening.lockVersion,
      opening.state.name,
      opening.assignment.kind.name,
      opening.assignment.id,
      opening.allowedStatusIds,
      opening.readWorkItem,
      opening.setWorkItemMetadata,
      candidateId,
    ];
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: '${identity.fullPath}#$iid',
      groupIdentity: identity,
      groupIdentityIsCurrent: context.isCurrent,
      writeKeys: {AiConflictKey(identity.keyParts)},
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: groupId,
          groupFullPath: identity.fullPath,
          iid: iid,
          workItemGid: identity.workItemGid,
        ),
      ],
      bindingDigest: sha256
          .convert(utf8.encode(jsonEncode(binding)))
          .toString(),
      journal: AiJournalBindings(
        updatedAt: opening.updatedAt.toIso8601String(),
      ),
      preview: AiFieldsPreview({'candidateId': candidateId}),
      mutation: (hooks) async {
        final lease = registry.tryStart(summary.id, AiWorkItemWriteKind.status);
        if (lease == null) throw const AiWriteRefused('statusNotStarted');
        var settlement = AiWorkItemWriteResult.notSent;
        DateTime? revision;
        try {
          final result = await _api.updateWorkItemStatus(
            target,
            candidateId: candidateId,
            isCurrent: () => hooks.accepted
                ? context.isSessionCurrent()
                : context.isCurrent(),
            onMutationSent: (started) => started(lease),
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
          );
          final confirmed =
              result.status == WorkItemStatusSaveStatus.success &&
              result.mutationSent &&
              result.handoff == WorkItemStatusHandoff.started &&
              result.acknowledgement != null &&
              result.snapshot.assignment.id == candidateId &&
              result.snapshot.updatedAt == result.acknowledgement!.updatedAt;
          if (hooks.accepted && confirmed) {
            settlement = AiWorkItemWriteResult.confirmed;
            revision = result.snapshot.updatedAt;
          }
          return GraphWriteResult(
            noChange:
                result.status == WorkItemStatusSaveStatus.noop &&
                !result.mutationSent,
            mutationSent: result.mutationSent,
            acknowledged: confirmed,
            // Core success includes the independent strict STATUS readback.
            readbackVerified: confirmed,
            revision: revision,
            projection: confirmed ? {'candidateId': candidateId} : const {},
          );
        } on WorkItemStatusWriteFailure catch (error) {
          if (!error.mutationSent &&
              identical(error.failure, hooks.blockedBeforeSend)) {
            throw error.failure;
          }
          if (!hooks.accepted) {
            throw AiWriteRefused(switch (error.failure.kind) {
              FailureKind.conflict => 'statusStaleFence',
              FailureKind.validation => 'statusInvalidCandidate',
              _ => 'statusNotStarted',
            });
          }
          rethrow;
        } finally {
          registry.settle(
            lease,
            hooks.accepted &&
                    !hooks.definitelyBlockedBeforeSend &&
                    settlement != AiWorkItemWriteResult.confirmed
                ? AiWorkItemWriteResult.uncertain
                : settlement,
            revision,
          );
        }
      },
    );
  }
}
