part of 'gitlab_write_port.dart';

extension _GroupHealthPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupHealth(AiWriteRequest request) async {
    if (request.operationId != 'updateGroupWorkItemHealthStatus') return null;
    if (request.executionId.isEmpty ||
        request.arguments.keys.any(
          (key) => !const {'groupId', 'iid', 'healthStatus'}.contains(key),
        ) ||
        request.uploadBytes != null ||
        request.sendTimeout != null) {
      throw const ApiFailure(FailureKind.validation);
    }
    final groupId = _positive(request.arguments, 'groupId');
    final iid = _positive(request.arguments, 'iid');
    final WorkItemHealthEditValue? desired;
    switch (request.arguments['healthStatus']) {
      case 'onTrack':
        desired = WorkItemHealthEditValue.onTrack;
      case 'needsAttention':
        desired = WorkItemHealthEditValue.needsAttention;
      case 'atRisk':
        desired = WorkItemHealthEditValue.atRisk;
      case 'none':
        desired = null;
      default:
        throw const ApiFailure(FailureKind.validation);
    }
    final registry = workItemWriteRegistry;
    if (registry == null) throw const AiWriteRefused('registryUnavailable');

    final context = _captureGroupWriteContext(request);
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
    final gid = identity.workItemGid;
    if (registry.isActive(gid)) throw const AiWriteRefused('healthConflict');
    final WorkItemHealthEditAccess access;
    try {
      access = await _api.workItemHealthEdit(
        detail,
        expectedUserId: user.id,
        generation: context.generation,
        isCurrent: context.isCurrent,
      );
    } on ApiFailure catch (failure) {
      throw _aiHealthRefusal(failure);
    }
    if (!context.isCurrent()) {
      throw const AiWriteRefused('workItemUnverifiable');
    }
    final snapshot = access.snapshot;
    final target = access.target;
    if (snapshot.availability != WorkItemHealthEditAvailability.present ||
        !snapshot.healthStatusFieldPresent) {
      throw const AiWriteRefused('healthUnsupported');
    }
    if (!access.canWrite || target == null) {
      throw const AiWriteRefused('healthForbidden');
    }
    final summary = snapshot.summary;
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: '${identity.fullPath}#$iid',
      confirmName: '${identity.fullPath}#$iid',
      groupIdentity: identity,
      groupIdentityIsCurrent: context.isCurrent,
      writeKeys: {_key(identity.keyParts)},
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          origin: AiTargetOrigin.proposed,
          side: AiResourceSide.group,
          groupId: groupId,
          groupFullPath: identity.fullPath,
          workItemGid: gid,
          iid: iid,
        ),
      ],
      bindingDigest: sha256
          .convert(
            utf8.encode(
              jsonEncode([
                accountKey,
                access.actorId,
                groupId,
                identity.fullPath,
                summary.id,
                summary.iid,
                summary.project?.id,
                summary.project?.fullPath,
                summary.namespace?.id,
                summary.namespace?.fullPath,
                summary.type.id,
                summary.type.name,
                summary.state,
                summary.createdAt.toIso8601String(),
                summary.updatedAt.toIso8601String(),
                snapshot.availability.name,
                snapshot.healthStatusFieldPresent,
                snapshot.value?.graphValue,
                desired?.graphValue,
              ]),
            ),
          )
          .toString(),
      journal: AiJournalBindings(
        updatedAt: summary.updatedAt.toIso8601String(),
      ),
      preview: AiFieldsPreview({'healthStatus': desired?.graphValue}),
      mutation: (hooks) async {
        if (!context.isCurrent()) {
          throw const AiWriteRefused('workItemUnverifiable');
        }
        final lease = registry.tryStart(gid, AiWorkItemWriteKind.health);
        if (lease == null) throw const AiWriteRefused('healthConflict');
        var settled = AiWorkItemWriteResult.notSent;
        DateTime? revision;
        try {
          final result = await _api.updateWorkItemHealthStatus(
            target,
            desired: desired,
            generation: context.generation,
            isCurrent: () => hooks.accepted
                ? context.isSessionCurrent()
                : context.isCurrent(),
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
          );
          final confirmed =
              result.status == WorkItemHealthEditSaveStatus.success &&
              result.mutationSent;
          if (hooks.accepted) {
            settled = confirmed
                ? AiWorkItemWriteResult.confirmed
                : AiWorkItemWriteResult.uncertain;
            if (confirmed) revision = result.snapshot.summary.updatedAt;
          }
          return GraphWriteResult(
            noChange:
                result.status == WorkItemHealthEditSaveStatus.noop &&
                !result.mutationSent,
            mutationSent: result.mutationSent,
            acknowledged: confirmed,
            readbackVerified: confirmed,
            revision: revision,
          );
        } on WorkItemHealthEditFailure catch (failure) {
          if (!failure.mutationSent &&
              identical(failure.failure, hooks.blockedBeforeSend)) {
            throw failure.failure;
          }
          if (hooks.accepted && !hooks.definitelyBlockedBeforeSend) {
            settled = AiWorkItemWriteResult.uncertain;
          }
          throw _aiHealthRefusal(failure.failure);
        } on Object {
          if (hooks.accepted && !hooks.definitelyBlockedBeforeSend) {
            settled = AiWorkItemWriteResult.uncertain;
          }
          rethrow;
        } finally {
          registry.settle(lease, settled, revision);
        }
      },
    );
  }
}
