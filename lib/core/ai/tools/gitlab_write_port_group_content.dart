part of 'gitlab_write_port.dart';

extension _GroupContentPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupContent(AiWriteRequest request) async {
    if (request.operationId != 'updateGroupWorkItemContent') return null;
    final args = request.arguments;
    final context = _captureGroupWriteContext(request);
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
    final user = await _readGroupActor(isCurrent: context.isCurrent);
    final location = await _resolveGroupWorkItem(
      request,
      actorUserId: user.id,
      generation: context.generation,
      readEpoch: context.readEpoch,
      isCurrent: context.isCurrent,
    );
    final identity = location.identity;
    final access = await _api.workItemContent(
      location.detail.withStrictGroupOwner(identity),
      expectedUserId: user.id,
      isCurrent: context.isCurrent,
    );
    if (!context.isCurrent()) {
      throw const AiWriteRefused('workItemUnverifiable');
    }
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
      releaseName: '${identity.fullPath}#$iid',
      confirmName: '${identity.fullPath}#$iid',
      groupIdentity: identity,
      groupIdentityIsCurrent: context.isCurrent,
      writeKeys: {AiConflictKey(identity.keyParts)},
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: identity.groupId,
          groupFullPath: identity.fullPath,
          workItemGid: identity.workItemGid,
          iid: iid,
        ),
      ],
      // This digest binds the original content and target, excluding the final
      // payload; the coordinator binds that payload separately via previewChanged.
      bindingDigest: sha256
          .convert(
            utf8.encode(
              jsonEncode([
                accountKey,
                access.actorId,
                identity.groupId,
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
            isCurrent: () => hooks.accepted
                ? context.isSessionCurrent()
                : context.isCurrent(),
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
