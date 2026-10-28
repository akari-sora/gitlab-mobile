part of 'gitlab_write_port.dart';

extension _GroupDatesPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupDates(AiWriteRequest request) async {
    if (request.operationId != 'updateGroupWorkItemDates') return null;
    final context = _captureGroupWriteContext(request);
    if (!aiGroupWorkItemWritesAreEnabled) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final a = request.arguments;
    final groupId = _positive(a, 'groupId');
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
    if (!request.scope.grants.any(
      (grant) =>
          grant.kind == AiScopeKind.groupWorkItem &&
          grant.groupId == groupId &&
          grant.iid == iid &&
          grant.projectId == null &&
          grant.projectPath == null,
    )) {
      throw const AiWriteRefused('datesForbidden');
    }
    final registry = workItemWriteRegistry;
    if (registry == null) throw const AiWriteRefused('registryUnavailable');
    final user = await _readGroupActor(isCurrent: context.isCurrent);
    final location = await _resolveGroupWorkItem(
      request,
      actorUserId: user.id,
      generation: context.generation,
      readEpoch: context.readEpoch,
      isCurrent: context.isCurrent,
    );
    final detail = location.detail.withStrictGroupOwner(location.identity);
    final summary = detail.summary;
    if (registry.isActive(summary.id)) {
      throw const AiWriteRefused('datesConflict');
    }
    // Core retains this predicate in its opaque target. Opening and pre-send
    // checks require the captured epoch; accepted readback must tolerate this
    // write's own epoch advance while still requiring the original session.
    GraphHooks? saveHooks;
    bool datesCurrent() => saveHooks?.accepted == true
        ? context.isSessionCurrent()
        : context.isCurrent();
    final WorkItemDatesAccess access;
    try {
      access = await _api.workItemDates(
        detail,
        expectedUserId: user.id,
        generation: context.generation,
        isCurrent: datesCurrent,
      );
    } on ApiFailure catch (failure) {
      throw _aiDatesRefusal(failure);
    }
    if (!context.isCurrent()) {
      throw const AiWriteRefused('workItemUnverifiable');
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
      groupId,
      location.identity.fullPath,
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
      releaseName: '${location.identity.fullPath}#$iid',
      groupIdentity: location.identity,
      groupIdentityIsCurrent: context.isCurrent,
      writeKeys: {_key(location.identity.keyParts)},
      bindingTargets: [
        AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: groupId,
          groupFullPath: location.identity.fullPath,
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
        saveHooks = hooks;
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
            isCurrent: () => hooks.accepted
                ? context.isSessionCurrent()
                : context.isCurrent(),
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
          if (hooks.accepted || failure.kind == FailureKind.unsupported) {
            rethrow;
          }
          throw _aiDatesRefusal(failure);
        } finally {
          registry.settle(
            lease,
            hooks.accepted &&
                    !hooks.definitelyBlockedBeforeSend &&
                    settlement != AiWorkItemWriteResult.confirmed
                ? AiWorkItemWriteResult.uncertain
                : settlement,
            revision,
          );
        }
      },
    );
  }
}
