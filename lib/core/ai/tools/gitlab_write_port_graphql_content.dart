part of 'gitlab_write_port.dart';

extension _GraphqlContentPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlContent(
    AiWriteRequest request,
  ) async {
    if (request.operationId != 'updateWorkItemContent') return null;
    final args = request.arguments;
    final projectId = _positive(args, 'projectId');
    final iid = _positive(args, 'iid');
    if (!args.containsKey('title') && !args.containsKey('description')) {
      throw const AiWriteRefused('validation');
    }
    for (final key in ['title', 'description']) {
      if (args.containsKey(key) && args[key] is! String) {
        throw const AiWriteRefused('validation');
      }
    }
    _precheckGraphqlContentText(request);
    final title = args['title'] as String?;
    final description = args['description'] as String?;
    if (!_granted(request.scope, projectId, 'issues', iid)) {
      throw const AiWriteRefused('forbidden');
    }
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
    final access = await _api.workItemContent(
      location.detail,
      expectedUserId: user.id,
    );
    final snapshot = access.snapshot;
    final summary = snapshot.summary;
    final target = access.target;
    if (!access.canUpdate || target == null) {
      throw const AiWriteRefused('forbidden');
    }
    if (args.containsKey('description') &&
        snapshot.descriptionAvailability !=
            WorkItemDescriptionAvailability.present) {
      throw const AiWriteRefused('unsupported');
    }
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
                summary.id,
                summary.iid,
                summary.project?.id,
                summary.project?.fullPath,
                summary.namespace?.id,
                summary.namespace?.fullPath,
                summary.type.id,
                summary.type.name,
                summary.updatedAt.toIso8601String(),
                summary.title,
                snapshot.descriptionAvailability.name,
                snapshot.rawDescription,
                access.canUpdate,
              ]),
            ),
          )
          .toString(),
      journal: AiJournalBindings(
        updatedAt: summary.updatedAt.toIso8601String(),
      ),
      currentFields: {
        'title': summary.title,
        if (snapshot.rawDescription != null)
          'description': snapshot.rawDescription!,
      },
      preview: AiFieldsPreview({
        if (args.containsKey('title')) 'title': title,
        if (args.containsKey('description')) 'description': description,
      }),
      validatePreparedText: _precheckGraphqlContentText,
      textMutation: (hooks, preparedRequest) async {
        final preparedTitle = preparedRequest.arguments['title'] as String?;
        final preparedDescription =
            preparedRequest.arguments['description'] as String?;
        var sent = false;
        try {
          final result = await _api.updateWorkItemContent(
            target,
            title: preparedTitle,
            description: preparedDescription,
            expectedUpdatedAt: summary.updatedAt,
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
            onMutationSent: () => sent = true,
          );
          return GraphWriteResult(
            noChange: !sent,
            mutationSent: sent,
            acknowledged: sent,
            readbackVerified: sent,
            revision: sent ? result.snapshot.summary.updatedAt : null,
          );
        } on ApiFailure catch (failure) {
          if (!hooks.accepted && failure.kind == FailureKind.conflict) {
            throw const AiWriteRefused('targetChanged');
          }
          rethrow;
        }
      },
    );
  }
}

void _precheckGraphqlContentText(AiWriteRequest request) {
  if (!isValidWorkItemContentInput(
    title: request.arguments['title'] as String?,
    description: request.arguments['description'] as String?,
  )) {
    throw const AiWriteRefused('validation');
  }
}
