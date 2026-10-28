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

    final global = request.scope.grants.any(
      (grant) => grant.kind == AiScopeKind.accountGlobal,
    );
    final groups = request.scope.grants
        .where((grant) => grant.kind == AiScopeKind.groupWorkItem)
        .toList();
    final context =
        aiGroupWorkItemWritesAreEnabled && (global || groups.isNotEmpty)
        ? _captureGroupWriteContext(request)
        : null;
    ({int groupId, int parentIid})? exactGroup;
    if (context != null && !global) {
      if (groups.length != 1 ||
          groups.single.groupId == null ||
          groups.single.iid == null) {
        throw const AiWriteRefused('todoForeign');
      }
      exactGroup = (
        groupId: groups.single.groupId!,
        parentIid: groups.single.iid!,
      );
    }
    late final GitLabUser user;
    VerifiedGroupTodo? selectedGroupTodo;
    late final ({
      String actorId,
      List<Map<String, dynamic>> items,
      Set<int> unsupportedIds,
    })
    owned;
    try {
      user = context == null
          ? await _api.currentUser()
          : await _readGroupActor(isCurrent: context.isCurrent);
      if ('${_api.instance.key}#${user.id}' != accountKey) {
        throw const AiWriteRefused('todoForeign');
      }
      if (context == null) {
        owned = snooze
            ? await _api.pendingTodosForSnooze(maxPages: 4)
            : await _api.snoozedTodosForUnsnooze(maxPages: 4);
      } else {
        final selected = snooze
            ? await _api.selectedTodoForSnooze(
                id,
                expectedUserId: user.id,
                generation: context.generation,
                readEpoch: context.readEpoch,
                isCurrent: context.isCurrent,
                exactGroup: exactGroup,
                maxPages: 4,
              )
            : await _api.selectedTodoForUnsnooze(
                id,
                expectedUserId: user.id,
                generation: context.generation,
                readEpoch: context.readEpoch,
                isCurrent: context.isCurrent,
                exactGroup: exactGroup,
                maxPages: 4,
              );
        if (!context.isCurrent()) {
          throw const AiWriteRefused('todoUnverifiable');
        }
        selectedGroupTodo = selected.selectedGroupTodo;
        owned = (
          actorId: selected.actorId,
          items: selected.items,
          unsupportedIds: selected.unsupportedIds,
        );
      }
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
    if (selectedGroupTodo != null) {
      // Discovery binds the numeric tuple; also prove the grant's exact path.
      if (exactGroup != null &&
          selectedGroupTodo.owner.fullPath != groups.single.groupFullPath) {
        throw const AiWriteRefused('todoForeign');
      }
      return _prepareGroupTodoSnooze(
        request,
        selected: selectedGroupTodo,
        context: context!,
        user: user,
        until: until,
      );
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

  AiWritePrepared _prepareGroupTodoSnooze(
    AiWriteRequest request, {
    required VerifiedGroupTodo selected,
    required _AiGroupWriteContext context,
    required GitLabUser user,
    required DateTime? until,
  }) {
    final id = selected.todoId;
    final owner = selected.owner;
    final target = AiTargetRef(
      kind: AiTargetKind.todo,
      side: AiResourceSide.group,
      groupId: owner.groupId,
      groupFullPath: owner.fullPath,
      workItemGid: owner.workItemGid,
      parentIid: owner.iid,
      origin:
          request.scope.grants.any(
            (grant) =>
                grant.kind == AiScopeKind.groupWorkItem &&
                grant.groupId == owner.groupId &&
                grant.groupFullPath == owner.fullPath &&
                grant.iid == owner.iid,
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
    final normalizedUntil = until?.toIso8601String();
    return AiWritePrepared.graph(
      request: request,
      owner: _owner,
      releaseName: '@${user.username}',
      groupTodoTarget: (
        groupId: owner.groupId,
        groupFullPath: owner.fullPath,
        iid: owner.iid,
        workItemGid: owner.workItemGid,
      ),
      groupIdentity: owner,
      groupIdentityIsCurrent: context.isCurrent,
      bindingTargets: [target],
      bindingDigest: sha256
          .convert(
            utf8.encode(
              jsonEncode([
                accountKey,
                user.id,
                user.username,
                request.operationId,
                id,
                owner.groupId,
                owner.fullPath,
                owner.iid,
                owner.workItemGid,
                selected.snoozedUntil?.toUtc().toIso8601String(),
                normalizedUntil,
              ]),
            ),
          )
          .toString(),
      writeKeys: {
        _key([accountKey, 'todos', '$id']),
        _key([...owner.keyParts, 'todo', '${user.id}']),
      },
      dependencyKeys: {_key(owner.keyParts)},
      preview: AiFieldsPreview({
        'todoId': id,
        'groupId': owner.groupId,
        'groupFullPath': owner.fullPath,
        'targetType': 'WorkItem',
        'iid': owner.iid,
        'until': normalizedUntil,
      }),
      mutation: (hooks) async {
        bool isCurrent() =>
            hooks.accepted ? context.isSessionCurrent() : context.isCurrent();
        if (!isCurrent()) throw const AiWriteRefused('todoUnverifiable');
        bool mayStart() => isCurrent() && hooks.mayStart();
        final markSent =
            Zone.current[#graphMutationSendStarted] as void Function()?;
        await runZoned(
          () async {
            if (until != null) {
              final acknowledged = await _api.snoozeTodo(
                id,
                until,
                beforeMutation: hooks.beforeMutation,
                mayStart: mayStart,
              );
              if (!acknowledged.toUtc().isAtSameMomentAs(until)) {
                throw const AiWriteRefused('todoUnverifiable');
              }
            } else {
              await _api.unsnoozeTodo(
                id,
                beforeMutation: hooks.beforeMutation,
                mayStart: mayStart,
              );
            }
          },
          zoneValues: {
            // The transport invokes this after its disk barrier and before HTTP.
            // Keep its existing send proof; our own write advances the epoch.
            #graphMutationSendStarted: () {
              if (!context.isSessionCurrent()) {
                throw const ApiFailure(FailureKind.cancelled);
              }
              markSent?.call();
            },
          },
        );
        if (!isCurrent()) throw const AiWriteRefused('todoUnverifiable');
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
