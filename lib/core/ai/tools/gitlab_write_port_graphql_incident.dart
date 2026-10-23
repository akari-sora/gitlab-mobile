part of 'gitlab_write_port.dart';

extension _GraphqlIncidentPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlIncident(
    AiWriteRequest request,
  ) async {
    if (request.operationId != 'setIncidentStatus') return null;
    final a = request.arguments;
    final projectId = _positive(a, 'projectId');
    final iid = _positive(a, 'iid');
    final status = a['status'];
    if (status is! String ||
        !const {'TRIGGERED', 'ACKNOWLEDGED', 'RESOLVED'}.contains(status)) {
      throw const AiWriteRefused('incidentInvalidStatus');
    }
    if (!_granted(request.scope, projectId, 'issues', iid)) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final actor = await _api.currentUser();
    if ('${_api.instance.key}#${actor.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    final location = await resolveAiProjectWorkItem(
      request.scope,
      projectId,
      iid,
      readDetail: (project, iid) => _api.projectWorkItem(project, iid),
    );
    final Map<String, dynamic> incident;
    try {
      incident = await _api.incidentStatus(location.project, iid);
    } on ApiFailure {
      throw const AiWriteRefused('incidentRejected');
    }
    final rawRevision = _responseText(incident, 'updatedAt');
    final summary = location.detail.summary;
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'actor': actor.id,
              'project': projectId,
              'path': location.project.path,
              'iid': iid,
              'workItem': summary.id,
              'type': summary.type.id,
              'namespace': summary.namespace!.id,
              'incident': incident['id'],
              'incidentUpdatedAt': rawRevision,
              'beforeStatus': incident['escalationStatus'],
              'status': status,
            }),
          ),
        )
        .toString();
    return AiWritePrepared.graph(
      request: request,
      releaseName: '#$iid',
      owner: _owner,
      writeKeys: {
        _key([accountKey, 'project:$projectId', 'workItem', '$iid']),
      },
      projectPath: location.project.path,
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.issue,
          projectId: projectId,
          projectPath: location.project.path,
          iid: iid,
        ),
      ],
      bindingDigest: digest,
      journal: AiJournalBindings(updatedAt: rawRevision),
      preview: AiFieldsPreview({'status': status}),
      mutation: (hooks) async {
        final Map<String, dynamic> result;
        try {
          result = await _api.setIncidentStatus(
            location.project,
            iid,
            status,
            expectedUpdatedAt: rawRevision,
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
          );
        } on ApiFailure catch (failure) {
          throw AiWriteRefused(
            failure.kind == FailureKind.conflict
                ? 'incidentConflict'
                : 'incidentRejected',
          );
        }
        if (result['id'] != incident['id'] ||
            result['escalationStatus'] != status) {
          throw const AiWriteRefused('incidentRejected');
        }
        return GraphWriteResult(
          noChange: !hooks.accepted,
          mutationSent: hooks.accepted,
          acknowledged: hooks.accepted,
          readbackVerified: hooks.accepted,
          projection: {'status': status},
        );
      },
    );
  }
}
