part of 'gitlab_write_port.dart';

extension _GraphqlAssigneesPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlAssignees(
    AiWriteRequest request,
  ) async {
    if (request.operationId != 'updateWorkItemAssignees') return null;
    final usernames = _graphqlAssigneeUsernames(request.arguments);
    final projectId = _positive(request.arguments, 'projectId');
    final iid = _positive(request.arguments, 'iid');
    if (!_granted(request.scope, projectId, 'issues', iid)) {
      throw const AiWriteRefused('assigneeForbidden');
    }
    final registry = workItemWriteRegistry;
    if (registry == null) throw const AiWriteRefused('registryUnavailable');

    try {
      final user = await _api.currentUser();
      if ('${_api.instance.key}#${user.id}' != accountKey) {
        throw const AiWriteRefused('assigneeForbidden');
      }
      final location = await resolveAiProjectWorkItem(
        request.scope,
        projectId,
        iid,
        readDetail: (project, iid) => _api.projectWorkItem(project, iid),
      );
      final summary = location.detail.summary;
      bool isCurrent() => !registry.isActive(summary.id);
      if (!isCurrent()) throw const AiWriteRefused('assigneeConflict');
      final opening = await _api.workItemAssignees(
        location.detail,
        expectedUserId: user.id,
        maxPages: 1,
        isCurrent: isCurrent,
      );
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
      // Check the whole proposal before the first candidate request.
      if (newNames.length > 4) {
        throw const AiWriteRefused('assigneeInvalidSelection');
      }
      for (final username in newNames) {
        final candidates = await _api.searchWorkItemAssigneeCandidates(
          target,
          search: username,
          isCurrent: isCurrent,
        );
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
        accountKey,
        projectId,
        location.project.path,
        iid,
        summary.id,
        summary.namespace?.id,
        summary.namespace?.fullPath,
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
        journal: AiJournalBindings(updatedAt: revision),
        preview: AiFieldsPreview({'assigneeUsernames': usernames}),
        mutation: (hooks) async {
          try {
            final readback = await _api.updateWorkItemAssignees(
              target,
              assigneeIds: desired,
              isCurrent: isCurrent,
              beforeMutation: hooks.beforeMutation,
              onMutationSent: () {
                if (!isCurrent()) {
                  throw const AiWriteRefused('assigneeConflict');
                }
              },
              mayStart: hooks.mayStart,
            );
            // Sorting retains multiplicity. A normal return is only a noop
            // when the opening already contained the exact desired multiset.
            final actualIds = readback.assigneeIds.toList()..sort();
            if (!_sameGraphqlAssigneeIds(actualIds, desiredIds)) {
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

List<String> _graphqlAssigneeUsernames(Map<String, Object?> arguments) {
  final raw = arguments['assigneeUsernames'];
  if (raw is! List || raw.length > 5) {
    throw const AiWriteRefused('assigneeInvalidSelection');
  }
  final names = <String>[];
  final seen = <String>{};
  for (final item in raw) {
    if (item is! String) {
      throw const AiWriteRefused('assigneeInvalidSelection');
    }
    // Mirror the core candidate search's trim, rune bound and NUL rule;
    // proposals also require non-empty, unique usernames.
    final name = item.trim();
    if (name.isEmpty ||
        name.runes.length > 256 ||
        name.contains('\u0000') ||
        !seen.add(name)) {
      throw const AiWriteRefused('assigneeInvalidSelection');
    }
    names.add(name);
  }
  return List<String>.unmodifiable(names);
}

bool _sameGraphqlAssigneeIds(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _graphqlAssigneeFailureCode(ApiFailure failure) =>
    switch (failure.kind) {
      FailureKind.forbidden ||
      FailureKind.unauthenticated ||
      FailureKind.invisible => 'assigneeForbidden',
      FailureKind.validation => 'assigneeRejected',
      _ => 'assigneeConflict',
    };
