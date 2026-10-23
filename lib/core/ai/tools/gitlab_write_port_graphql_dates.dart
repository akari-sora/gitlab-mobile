part of 'gitlab_write_port.dart';

extension _GraphqlDatesPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlDates(AiWriteRequest request) async {
    if (request.operationId != 'updateWorkItemDates') return null;
    final a = request.arguments;
    final projectId = _positive(a, 'projectId');
    final iid = _positive(a, 'iid');
    final mode = switch (a['mode']) {
      'manual' => WorkItemDatesMode.manual,
      'inherited' => WorkItemDatesMode.inherited,
      _ => throw const AiWriteRefused('datesNotApplied'),
    };
    for (final key in ['clearStart', 'clearDue']) {
      if (a.containsKey(key) && a[key] is! bool) {
        throw const AiWriteRefused('datesNotApplied');
      }
    }
    for (final key in ['startDate', 'dueDate']) {
      if (a.containsKey(key) && !_validAiDatesScalar(a[key])) {
        throw const AiWriteRefused('datesNotApplied');
      }
    }
    if ((a.containsKey('startDate') && a['clearStart'] == true) ||
        (a.containsKey('dueDate') && a['clearDue'] == true) ||
        (mode == WorkItemDatesMode.inherited &&
            const [
              'startDate',
              'dueDate',
              'clearStart',
              'clearDue',
            ].any(a.containsKey))) {
      throw const AiWriteRefused('datesNotApplied');
    }
    if (!_granted(request.scope, projectId, 'issues', iid)) {
      throw const AiWriteRefused('datesForbidden');
    }
    final registry = workItemWriteRegistry;
    if (registry == null) throw const AiWriteRefused('registryUnavailable');
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const AiWriteRefused('datesForbidden');
    }
    final location = await resolveAiProjectWorkItem(
      request.scope,
      projectId,
      iid,
      readDetail: (project, number) => _api.projectWorkItem(project, number),
    );
    final summary = location.detail.summary;
    if (registry.isActive(summary.id)) {
      throw const AiWriteRefused('datesConflict');
    }
    final WorkItemDatesAccess access;
    try {
      access = await _api.workItemDates(
        location.detail,
        expectedUserId: user.id,
        // This target is local to the immutable client. The coordinator fences
        // session generation; the injected registry fences UI ownership.
        generation: 0,
      );
    } on ApiFailure catch (failure) {
      throw _aiDatesRefusal(failure);
    }
    if (registry.isActive(summary.id)) {
      throw const AiWriteRefused('datesConflict');
    }
    final snapshot = access.snapshot;
    final target = access.target;
    if (!snapshot.readWorkItem || !snapshot.setWorkItemMetadata) {
      throw const AiWriteRefused('datesForbidden');
    }
    if (!access.canWrite || target == null) {
      throw const AiWriteRefused('datesNotApplied');
    }
    if (mode == WorkItemDatesMode.inherited &&
        target.edition != WorkItemDatesEdition.ee) {
      throw const AiWriteRefused('datesNotApplied');
    }
    if (mode == WorkItemDatesMode.manual &&
        snapshot.mode != WorkItemDatesMode.manual &&
        ((!a.containsKey('startDate') && a['clearStart'] != true) ||
            (!a.containsKey('dueDate') && a['clearDue'] != true))) {
      throw const AiWriteRefused('datesNotApplied');
    }
    // The core reader rejects base/probe disagreement before issuing a target.
    // Its manual snapshot therefore has the verified base column values.
    final startDate =
        mode == WorkItemDatesMode.inherited || a['clearStart'] == true
        ? null
        : a.containsKey('startDate')
        ? a['startDate']! as String
        : snapshot.startDate;
    final dueDate = mode == WorkItemDatesMode.inherited || a['clearDue'] == true
        ? null
        : a.containsKey('dueDate')
        ? a['dueDate']! as String
        : snapshot.dueDate;
    if (mode == WorkItemDatesMode.manual &&
        startDate != null &&
        dueDate != null &&
        startDate.compareTo(dueDate) > 0) {
      throw const AiWriteRefused('datesNotApplied');
    }
    final fields = <String, Object?>{
      'mode': mode.name,
      'startDate': startDate,
      'dueDate': dueDate,
    };
    final binding = <Object?>[
      accountKey,
      user.id,
      projectId,
      location.project.path,
      summary.id,
      summary.iid,
      summary.namespace?.id,
      summary.namespace?.fullPath,
      summary.type.id,
      summary.state,
      summary.updatedAt.toIso8601String(),
      snapshot.updatedAt.toIso8601String(),
      snapshot.actorId,
      snapshot.edition?.name,
      snapshot.mode.name,
      snapshot.startDate,
      snapshot.dueDate,
      snapshot.rollUp,
      snapshot.startDateSourcingWorkItemId,
      snapshot.dueDateSourcingWorkItemId,
      snapshot.startDateSourcingMilestoneId,
      snapshot.dueDateSourcingMilestoneId,
      snapshot.readWorkItem,
      snapshot.setWorkItemMetadata,
      snapshot.widgetPresent,
      fields,
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
      journal: AiJournalBindings(
        updatedAt: snapshot.updatedAt.toIso8601String(),
      ),
      preview: AiFieldsPreview(fields),
      mutation: (hooks) async {
        final lease = registry.tryStart(summary.id, AiWorkItemWriteKind.dates);
        if (lease == null) throw const AiWriteRefused('datesConflict');
        var settlement = AiWorkItemWriteResult.notSent;
        DateTime? revision;
        try {
          final result = await _api.updateWorkItemDates(
            target,
            mode: mode,
            startDate: startDate,
            dueDate: dueDate,
            onMutationSent: () {},
            beforeMutation: hooks.beforeMutation,
            mayStart: hooks.mayStart,
          );
          if (result.outcome == WorkItemDatesWriteOutcome.notApplied &&
              !result.mutationSent) {
            final before = result.snapshot;
            throw AiWriteRefused(
              before != null &&
                      (!before.readWorkItem || !before.setWorkItemMetadata)
                  ? 'datesForbidden'
                  : 'datesNotApplied',
            );
          }
          final after = result.snapshot;
          final applied = result.outcome == WorkItemDatesWriteOutcome.applied;
          final verified =
              applied &&
              result.mutationSent &&
              after != null &&
              after.summary.id == summary.id &&
              after.actorId == snapshot.actorId &&
              after.mode == mode &&
              (mode == WorkItemDatesMode.inherited ||
                  (after.startDate == startDate && after.dueDate == dueDate));
          if (hooks.accepted && verified) {
            settlement = AiWorkItemWriteResult.confirmed;
            revision = after.updatedAt;
          }
          return GraphWriteResult(
            noChange: applied && !result.mutationSent,
            mutationSent: result.mutationSent,
            acknowledged: verified,
            readbackVerified: verified,
            revision: revision,
            projection: verified
                ? {
                    'mode': after.mode.name,
                    'startDate': after.startDate,
                    'dueDate': after.dueDate,
                  }
                : const {},
          );
        } on ApiFailure catch (failure) {
          if (hooks.accepted) rethrow;
          throw _aiDatesRefusal(failure);
        } finally {
          registry.settle(
            lease,
            hooks.accepted && settlement != AiWorkItemWriteResult.confirmed
                ? AiWorkItemWriteResult.uncertain
                : settlement,
            revision,
          );
        }
      },
    );
  }
}

bool _validAiDatesScalar(Object? raw) {
  if (raw is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
    return false;
  }
  final value = DateTime.tryParse('${raw}T00:00:00Z');
  return value != null &&
      value.year >= 1000 &&
      value.year <= 9999 &&
      value.toIso8601String().substring(0, 10) == raw;
}

AiWriteRefused _aiDatesRefusal(ApiFailure failure) =>
    AiWriteRefused(switch (failure.kind) {
      FailureKind.forbidden || FailureKind.unauthenticated => 'datesForbidden',
      FailureKind.validation => 'datesNotApplied',
      _ => 'datesConflict',
    });
