part of 'gitlab_write_port.dart';

extension _GroupAssigneesPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupAssignees(
    AiWriteRequest request,
  ) async {
    if (request.operationId != 'updateGroupWorkItemAssignees') return null;
    final context = _captureGroupWriteContext(request);
    final usernames = _graphqlAssigneeUsernames(request.arguments);
    final registry = workItemWriteRegistry;
    if (registry == null) throw const AiWriteRefused('registryUnavailable');

    try {
      final actor = await _readGroupActor(isCurrent: context.isCurrent);
      final location = await _resolveGroupWorkItem(
        request,
        actorUserId: actor.id,
        generation: context.generation,
        readEpoch: context.readEpoch,
        isCurrent: context.isCurrent,
      );
      if (!context.isCurrent()) {
        throw const AiWriteRefused('workItemUnverifiable');
      }
      final identity = location.identity;
      final detail = location.detail.withStrictGroupOwner(identity);
      final summary = detail.summary;
      bool isCurrent() => context.isCurrent() && !registry.isActive(summary.id);
      if (!isCurrent()) throw const AiWriteRefused('assigneeConflict');
      final opening = await _api.workItemAssignees(
        detail,
        expectedUserId: actor.id,
        maxPages: 1,
        isCurrent: isCurrent,
      );
      if (!isCurrent()) throw const AiWriteRefused('assigneeConflict');
      final target = opening.target;
      if (!opening.canWrite || target == null) {
        throw const AiWriteRefused('assigneeForbidden');
      }
      if (!target.allowsMultiple && usernames.length > 1) {
        throw const AiWriteRefused('assigneeInvalidSelection');
      }

      final selected = <String, String>{};
      final newNames = <String>[];
      for (final username in usernames) {
        final current = opening.snapshot.users
            .where((user) => user.username == username)
            .toList(growable: false);
        if (current.length > 1) {
          throw const AiWriteRefused('assigneeInvalidSelection');
        }
        if (current.isEmpty) {
          newNames.add(username);
        } else {
          selected[username] = current.single.id;
        }
      }
      // Bound the entire selection before the first group autocomplete read.
      if (newNames.length > 4) {
        throw const AiWriteRefused('assigneeInvalidSelection');
      }
      for (final username in newNames) {
        final candidates = await _api.searchWorkItemAssigneeCandidates(
          target,
          search: username,
          isCurrent: isCurrent,
        );
        if (!isCurrent()) throw const AiWriteRefused('assigneeConflict');
        final matches = candidates
            .where((user) => user.username == username)
            .toList(growable: false);
        if (matches.length != 1 || selected.containsValue(matches.single.id)) {
          throw const AiWriteRefused('assigneeInvalidSelection');
        }
        selected[username] = matches.single.id;
      }
      final desired = List<String>.unmodifiable(
        usernames.map((name) => selected[name]!),
      );
      final currentIds = target.assigneeIds.toList()..sort();
      final desiredIds = desired.toList()..sort();
      final names = usernames.toList()..sort();
      final revision = target.updatedAt.toUtc().toIso8601String();
      final binding = [
        ...identity.keyParts,
        identity.fullPath,
        identity.workItemGid,
        summary.namespace?.id,
        summary.type.id,
        summary.type.name,
        target.actorId,
        revision,
        target.allowsMultiple,
        currentIds,
        [
          for (final name in names) [name, selected[name]],
        ],
      ];
      return AiWritePrepared.graph(
        request: request,
        owner: _owner,
        releaseName: '${identity.fullPath}#${identity.iid}',
        groupIdentity: identity,
        groupIdentityIsCurrent: context.isCurrent,
        writeKeys: {_key(identity.keyParts)},
        bindingTargets: [
          AiTargetRef(
            kind: AiTargetKind.groupWorkItem,
            groupId: identity.groupId,
            groupFullPath: identity.fullPath,
            iid: identity.iid,
            workItemGid: identity.workItemGid,
          ),
        ],
        bindingDigest: sha256
            .convert(utf8.encode(jsonEncode(binding)))
            .toString(),
        journal: AiJournalBindings(updatedAt: revision),
        preview: AiFieldsPreview({'assigneeUsernames': usernames}),
        mutation: (hooks) async {
          try {
            final readback = await _api.updateWorkItemAssignees(
              target,
              assigneeIds: desired,
              isCurrent: () =>
                  (hooks.accepted
                      ? context.isSessionCurrent()
                      : context.isCurrent()) &&
                  !registry.isActive(summary.id),
              beforeMutation: hooks.beforeMutation,
              onMutationSent: () {
                if (!isCurrent()) {
                  throw const AiWriteRefused('assigneeConflict');
                }
              },
              mayStart: hooks.mayStart,
            );
            final actualIds = readback.assigneeIds.toList()..sort();
            if (readback.allowsMultiple != target.allowsMultiple ||
                !_sameGraphqlAssigneeIds(actualIds, desiredIds)) {
              throw const AiWriteRefused('assigneeRejected');
            }
            return GraphWriteResult(
              noChange:
                  !hooks.accepted &&
                  _sameGraphqlAssigneeIds(currentIds, desiredIds),
              mutationSent: hooks.accepted,
              acknowledged: hooks.accepted,
              readbackVerified: hooks.accepted,
              revision: readback.updatedAt,
              projection: {'assigneeUsernames': usernames},
            );
          } on ApiFailure catch (failure) {
            if (identical(failure, hooks.blockedBeforeSend)) rethrow;
            throw AiWriteRefused(_graphqlAssigneeFailureCode(failure));
          }
        },
      );
    } on ApiFailure catch (failure) {
      throw AiWriteRefused(_graphqlAssigneeFailureCode(failure));
    }
  }
}
