part of 'gitlab_write_port.dart';

extension _GroupLabelsPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupLabels(AiWriteRequest request) async {
    if (request.operationId != 'updateGroupWorkItemLabels') return null;
    final raw = request.arguments['labels'];
    if (raw is! List ||
        raw.length > 10 ||
        raw.any(
          (value) =>
              value is! String ||
              value.isEmpty ||
              value.length > 255 ||
              value.contains('\u0000'),
        ) ||
        raw.toSet().length != raw.length) {
      throw const AiWriteRefused('validation');
    }
    final names = List<String>.unmodifiable(raw.cast<String>());
    final context = _captureGroupWriteContext(request);
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
      final access = await _api.workItemLabels(
        location.detail.withStrictGroupOwner(identity),
        expectedUserId: actor.id,
        generation: context.generation,
        maxPages: 1,
        isCurrent: context.isCurrent,
      );
      if (!context.isCurrent()) {
        throw const AiWriteRefused('workItemUnverifiable');
      }
      final target = access.target;
      if (!access.canWrite || target == null) {
        throw const AiWriteRefused('forbidden');
      }
      final before = access.snapshot;
      final summary = before.summary;
      if (summary.updatedAt != location.detail.summary.updatedAt) {
        throw const AiWriteRefused('targetChanged');
      }
      // Always require the complete candidate catalog, including for clearing.
      // Current assignments may be retained even when omitted from the catalog.
      final candidates = await _api.workItemLabelCandidates(
        target,
        maxPages: 1,
        isCurrent: context.isCurrent,
      );
      if (!context.isCurrent()) {
        throw const AiWriteRefused('workItemUnverifiable');
      }
      final desired = <String>[];
      final scopes = <String>{};
      for (final name in names) {
        final matches = <String>{
          for (final label in candidates)
            if (label.title == name) label.id,
          for (final label in before.labels)
            if (label.title == name) label.id,
        };
        if (matches.length != 1) throw const AiWriteRefused('labelUnknown');
        final scope = workItemLabelScopeKey(name);
        if (scope != null &&
            before.allowsScopedLabels != WorkItemLabelAllowsScoped.disabled &&
            !scopes.add(scope)) {
          throw const AiWriteRefused('validation');
        }
        desired.add(matches.single);
      }
      final currentIds = before.labelIds.toList()..sort();
      final desiredIds = desired.toList()..sort();
      final candidateBindings = [
        for (final label in candidates) [label.id, label.title],
      ]..sort((left, right) => left.first.compareTo(right.first));
      final revision = summary.updatedAt.toUtc().toIso8601String();
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
            groupId: identity.groupId,
            groupFullPath: identity.fullPath,
            iid: identity.iid,
          ),
        ],
        bindingDigest: sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  accountKey,
                  before.actorId,
                  identity.groupId,
                  identity.fullPath,
                  identity.generation,
                  summary.id,
                  summary.iid,
                  summary.namespace?.id,
                  summary.namespace?.fullPath,
                  summary.type.id,
                  summary.type.name,
                  summary.state,
                  summary.title,
                  summary.createdAt.toIso8601String(),
                  revision,
                  before.allowsScopedLabels.name,
                  currentIds,
                  desiredIds,
                  candidateBindings,
                ]),
              ),
            )
            .toString(),
        journal: AiJournalBindings(updatedAt: revision),
        preview: AiFieldsPreview({'labels': names}),
        currentFields: {
          'labels': jsonEncode([
            for (final label in before.labels) label.title,
          ]),
        },
        mutation: (hooks) async {
          try {
            final result = await _api.updateWorkItemLabels(
              target,
              desiredLabelIds: desired,
              isCurrent: () => hooks.accepted
                  ? context.isSessionCurrent()
                  : context.isCurrent(),
              beforeMutation: hooks.beforeMutation,
              mayStart: () => context.isCurrent() && hooks.mayStart(),
            );
            final confirmed =
                result.status == WorkItemLabelSaveStatus.success &&
                result.mutationSent;
            return GraphWriteResult(
              noChange:
                  result.status == WorkItemLabelSaveStatus.noop &&
                  !result.mutationSent,
              mutationSent: result.mutationSent,
              acknowledged: confirmed,
              readbackVerified: confirmed,
              revision: result.snapshot.updatedAt,
            );
          } on WorkItemLabelWriteFailure catch (failure) {
            if (!failure.mutationSent &&
                identical(failure.failure, hooks.blockedBeforeSend)) {
              throw failure.failure;
            }
            throw _groupLabelsRefusal(failure.failure);
          }
        },
      );
    } on ApiFailure catch (failure) {
      throw _groupLabelsRefusal(failure);
    }
  }
}

AiWriteRefused _groupLabelsRefusal(ApiFailure failure) =>
    AiWriteRefused(switch (failure.kind) {
      FailureKind.conflict || FailureKind.invisible => 'targetChanged',
      _ => failure.kind.name,
    });
