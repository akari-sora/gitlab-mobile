part of 'gitlab_write_port.dart';

extension _GraphqlSnoozePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlSnooze(AiWriteRequest request) async {
    final snooze = request.operationId == 'snoozeTodo';
    if (!snooze && request.operationId != 'unsnoozeTodo') return null;
    final id = _positive(request.arguments, 'todoId');
    final until = snooze
        ? _snoozeUntil(_text(request.arguments, 'until'))
        : null;
    if (request.scope.grants.isEmpty) throw const AiWriteRefused('todoForeign');

    late final GitLabUser user;
    late final ({
      String actorId,
      List<Map<String, dynamic>> items,
      Set<int> unsupportedIds,
    })
    owned;
    try {
      user = await _api.currentUser();
      if ('${_api.instance.key}#${user.id}' != accountKey) {
        throw const AiWriteRefused('todoForeign');
      }
      owned = snooze
          ? await _api.pendingTodosForSnooze(maxPages: 4)
          : await _api.snoozedTodosForUnsnooze(maxPages: 4);
    } on ApiFailure catch (failure) {
      if (const {
        FailureKind.rateLimited,
        FailureKind.network,
        FailureKind.cancelled,
        FailureKind.unsupported,
      }.contains(failure.kind)) {
        rethrow;
      }
      throw AiWriteRefused(
        failure.kind == FailureKind.unauthenticated
            ? 'todoForeign'
            : 'todoUnverifiable',
      );
    }
    if (owned.actorId != 'gid://gitlab/User/${user.id}') {
      throw const AiWriteRefused('todoForeign');
    }
    if (owned.unsupportedIds.contains(id)) {
      throw const AiWriteRefused('todoUnsupportedTarget');
    }
    final matches = owned.items.where((item) => item['id'] == id).toList();
    if (matches.isEmpty) throw const AiWriteRefused('todoNotFound');
    if (matches.length != 1) throw const AiWriteRefused('todoUnverifiable');
    final todo = matches.single;
    // The fixed reader has checked the exact GID, both projects and typed
    // entity. Unsupported IDs never get a scope-based exception, even global.
    final project = objectJson(todo['project']);
    final entity = objectJson(todo['target']);
    final projectId = _positive(project, 'id');
    final path = _responseText(project, 'path_with_namespace');
    final iid = _positive(entity, 'iid');
    final resource = switch (todo['target_type']) {
      'Issue' || 'WorkItem' => 'issues',
      'MergeRequest' => 'merge_requests',
      _ => throw const AiWriteRefused('todoUnsupportedTarget'),
    };
    final mergeRequest = resource == 'merge_requests';
    final target = AiTargetRef(
      kind: AiTargetKind.todo,
      side: mergeRequest ? AiResourceSide.mergeRequest : AiResourceSide.issue,
      projectId: projectId,
      projectPath: path,
      parentIid: iid,
      origin:
          request.scope.grants.any(
            (grant) =>
                grant.projectId == projectId &&
                grant.iid == iid &&
                grant.kind ==
                    (mergeRequest
                        ? AiScopeKind.mergeRequest
                        : AiScopeKind.workItem),
          )
          ? AiTargetOrigin.currentResource
          : AiTargetOrigin.proposed,
    );
    if (!scopeAdmits(
      request.scope,
      productionAiLedger.find(request.operationId)!,
      target,
    )) {
      throw const AiWriteRefused('todoForeign');
    }
    // A supplied grant path must still describe the project returned by GitLab.
    if (request.scope.grants.any(
      (grant) =>
          grant.projectId == projectId &&
          grant.projectPath != null &&
          grant.projectPath != path,
    )) {
      throw const AiWriteRefused('todoForeign');
    }
    final normalizedUntil = until?.toIso8601String();
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: '@${user.username}',
      todoTarget: (projectId: projectId, resource: resource, iid: iid),
      projectPath: path,
      bindingTargets: [target],
      bindingDigest: sha256
          .convert(
            utf8.encode(
              jsonEncode([
                accountKey,
                user.id,
                user.username,
                request.operationId,
                todo,
                normalizedUntil,
              ]),
            ),
          )
          .toString(),
      writeKeys: {
        _key([accountKey, 'todos', '$id']),
        _key([
          accountKey,
          'project:$projectId',
          mergeRequest ? 'mergeRequest' : 'workItem',
          '$iid',
          'todo',
          '${user.id}',
        ]),
      },
      preview: AiFieldsPreview({
        'todoId': id,
        'projectId': projectId,
        'targetType': todo['target_type'],
        'iid': iid,
        'until': normalizedUntil,
      }),
      mutation: (hooks) async {
        if (until != null) {
          final acknowledged = await _api.snoozeTodo(
            id,
            until,
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
          );
          if (!acknowledged.toUtc().isAtSameMomentAs(until)) {
            throw const AiWriteRefused('todoUnverifiable');
          }
        } else {
          await _api.unsnoozeTodo(
            id,
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
          );
        }
        return const GraphWriteResult(mutationSent: true, acknowledged: true);
      },
    );
  }
}

DateTime _snoozeUntil(String value) {
  final shape = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T([01]\d|2[0-3]):([0-5]\d):([0-5]\d)(?:\.\d{1,6})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$',
  ).firstMatch(value);
  final parsed = DateTime.tryParse(value);
  if (shape == null ||
      parsed == null ||
      !parsed.isUtc ||
      !parsed.isAfter(DateTime.now())) {
    throw const ApiFailure(FailureKind.validation);
  }
  final year = int.parse(shape.group(1)!);
  final month = int.parse(shape.group(2)!);
  final day = int.parse(shape.group(3)!);
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    throw const ApiFailure(FailureKind.validation);
  }
  final utc = parsed.toUtc();
  final normalized = DateTime.utc(
    utc.year,
    utc.month,
    utc.day,
    utc.hour,
    utc.minute,
    utc.second,
  );
  if (!normalized.isAfter(DateTime.now())) {
    throw const ApiFailure(FailureKind.validation);
  }
  return normalized;
}
