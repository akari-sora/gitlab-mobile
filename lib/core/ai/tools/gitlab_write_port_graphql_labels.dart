part of 'gitlab_write_port.dart';

extension _GraphqlLabelsPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlLabels(AiWriteRequest request) async {
    if (request.operationId != 'updateWorkItemLabels') return null;
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
    final projectId = _positive(request.arguments, 'projectId');
    final iid = _positive(request.arguments, 'iid');
    if (!_granted(request.scope, projectId, 'issues', iid)) {
      throw const AiWriteRefused('forbidden');
    }
    try {
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
      final access = await _api.workItemLabels(
        location.detail,
        expectedUserId: user.id,
        generation: 0,
        maxPages: 1,
      );
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
      final candidates = await _api.workItemLabelCandidates(target);
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
            before.allowsScopedLabels == WorkItemLabelAllowsScoped.allowed &&
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
            .convert(
              utf8.encode(
                jsonEncode([
                  accountKey,
                  before.actorId,
                  projectId,
                  location.project.path,
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
        mutation: (hooks) async {
          try {
            final result = await _api.updateWorkItemLabels(
              target,
              desiredLabelIds: desired,
              beforeMutation: hooks.beforeMutation,
              mayStart: hooks.mayStart,
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
            throw _graphqlLabelsRefusal(failure.failure);
          }
        },
      );
    } on ApiFailure catch (failure) {
      throw _graphqlLabelsRefusal(failure);
    }
  }
}

AiWriteRefused _graphqlLabelsRefusal(ApiFailure failure) =>
    AiWriteRefused(switch (failure.kind) {
      FailureKind.conflict || FailureKind.invisible => 'targetChanged',
      _ => failure.kind.name,
    });
