part of 'gitlab_write_port.dart';

extension _GraphqlStatusPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlStatus(AiWriteRequest request) async {
    if (request.operationId != 'updateWorkItemStatus') return null;
    final projectId = _positive(request.arguments, 'projectId');
    final iid = _positive(request.arguments, 'iid');
    final candidateId = _text(request.arguments, 'candidateId');
    if (!_granted(request.scope, projectId, 'issues', iid)) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final registry = workItemWriteRegistry;
    if (registry == null) throw const AiWriteRefused('registryUnavailable');
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    final location = await resolveAiProjectWorkItem(
      request.scope,
      projectId,
      iid,
      readDetail: (project, number) => _api.projectWorkItem(project, number),
    );
    final summary = location.detail.summary;
    if (registry.isActive(summary.id)) {
      throw const AiWriteRefused('statusNotStarted');
    }
    final access = await _api.workItemStatus(
      location.detail,
      expectedUserId: user.id,
      // This target lives only within this prepared capability. The injected
      // registry and coordinator fence the owning session generation.
      generation: 0,
      isCurrent: () => !registry.isActive(summary.id),
    );
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
      user.id,
      summary.id,
      iid,
      opening.project?.id,
      opening.project?.fullPath,
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
      releaseName: '#$iid',
      projectPath: location.project.path,
      writeKeys: {
        _key([accountKey, 'project:$projectId', 'workItem', '$iid']),
      },
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.issue,
          projectId: projectId,
          projectPath: location.project.path,
          iid: iid,
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
            // Retain the registry lease as this invocation's opaque START
            // token, using the core callback's existing synchronous protocol.
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
            // Core success includes its independent exact STATUS readback.
            readbackVerified: confirmed,
            revision: revision,
            projection: confirmed ? {'candidateId': candidateId} : const {},
          );
        } on WorkItemStatusWriteFailure catch (error) {
          if (!error.mutationSent && identical(error.failure, hooks.blockedBeforeSend)) {
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
            hooks.accepted && !hooks.definitelyBlockedBeforeSend &&
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
