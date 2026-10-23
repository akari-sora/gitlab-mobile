part of 'gitlab_write_port.dart';

extension _GraphqlStatePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlState(AiWriteRequest request) async {
    if (request.operationId != 'updateWorkItemState') return null;
    final projectId = _positive(request.arguments, 'projectId');
    final iid = _positive(request.arguments, 'iid');
    final event = switch (request.arguments['stateEvent']) {
      'close' => WorkItemStateEvent.close,
      'reopen' => WorkItemStateEvent.reopen,
      _ => throw const AiWriteRefused('stateNotApplied'),
    };
    try {
      final user = await _api.currentUser();
      if ('${_api.instance.key}#${user.id}' != accountKey) {
        throw const AiWriteRefused('stateForbidden');
      }
      final location = await resolveAiProjectWorkItem(
        request.scope,
        projectId,
        iid,
        readDetail: (project, iid) => _api.projectWorkItem(project, iid),
      );
      final expected = location.detail.summary;
      final opening = await _api.workItemState(expected);
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
                'actor': user.id,
                'projectId': projectId,
                'projectPath': location.project.path,
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

Object _stateWriteRefusal(ApiFailure failure) => switch (failure.kind) {
  FailureKind.conflict => const AiWriteRefused('stateConflict'),
  FailureKind.forbidden ||
  FailureKind.unauthenticated => const AiWriteRefused('stateForbidden'),
  FailureKind.validation ||
  FailureKind.unsupported => const AiWriteRefused('stateNotApplied'),
  _ => failure,
};
