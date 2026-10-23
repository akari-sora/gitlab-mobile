part of 'gitlab_write_port.dart';

extension _GraphqlHealthPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlHealth(AiWriteRequest request) async {
    if (request.operationId != 'updateWorkItemHealthStatus') return null;
    final projectId = _positive(request.arguments, 'projectId');
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
    if (!_granted(request.scope, projectId, 'issues', iid)) {
      throw const AiWriteRefused('healthForbidden');
    }
    final registry = workItemWriteRegistry;
    if (registry == null) throw const AiWriteRefused('registryUnavailable');

    // This client is immutable per account. Core checks its closed state and
    // retains the target's API owner; coordinator/registry fence the session.
    bool isCurrent() => true;
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    final location = await resolveAiProjectWorkItem(
      request.scope,
      projectId,
      iid,
      readDetail: (project, number) =>
          _api.projectWorkItem(project, number, isCurrent: isCurrent),
    );
    final gid = location.detail.summary.id;
    if (registry.isActive(gid)) throw const AiWriteRefused('healthConflict');
    final WorkItemHealthEditAccess access;
    try {
      access = await _api.workItemHealthEdit(
        location.detail,
        expectedUserId: user.id,
        generation: 0,
        isCurrent: isCurrent,
      );
    } on ApiFailure catch (failure) {
      throw _aiHealthRefusal(failure);
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
      releaseName: '#$iid',
      confirmName: '#$iid',
      projectPath: location.project.path,
      writeKeys: {
        _key([accountKey, 'project:$projectId', 'workItem', '$iid']),
      },
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.issue,
          origin:
              request.scope.grants.any(
                (grant) =>
                    grant.kind == AiScopeKind.workItem &&
                    grant.projectId == projectId &&
                    grant.iid == iid,
              )
              ? AiTargetOrigin.currentResource
              : AiTargetOrigin.proposed,
          projectId: projectId,
          projectPath: location.project.path,
          iid: iid,
        ),
      ],
      bindingDigest: sha256
          .convert(
            utf8.encode(
              jsonEncode([
                accountKey,
                access.actorId,
                projectId,
                location.project.path,
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
        // Acquire before the method's preflight and before its journal hook.
        // A refused start never crosses the durable mutation boundary.
        final lease = registry.tryStart(gid, AiWorkItemWriteKind.health);
        if (lease == null) throw const AiWriteRefused('healthConflict');
        var settled = AiWorkItemWriteResult.notSent;
        DateTime? revision;
        try {
          final result = await _api.updateWorkItemHealthStatus(
            target,
            desired: desired,
            generation: 0,
            isCurrent: isCurrent,
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
          if (hooks.accepted) settled = AiWorkItemWriteResult.uncertain;
          throw _aiHealthRefusal(failure.failure);
        } on Object {
          if (hooks.accepted) settled = AiWorkItemWriteResult.uncertain;
          rethrow;
        } finally {
          registry.settle(lease, settled, revision);
        }
      },
    );
  }
}

AiWriteRefused _aiHealthRefusal(ApiFailure failure) =>
    AiWriteRefused(switch (failure.kind) {
      FailureKind.conflict || FailureKind.invisible => 'healthConflict',
      FailureKind.forbidden => 'healthForbidden',
      FailureKind.unsupported => 'healthUnsupported',
      _ => failure.kind.name,
    });
