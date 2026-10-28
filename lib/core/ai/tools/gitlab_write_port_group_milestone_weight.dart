part of 'gitlab_write_port.dart';

extension _GroupMilestoneWeightPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupMilestoneWeight(
    AiWriteRequest request,
  ) async {
    final op = request.operationId;
    final milestone = op == 'updateGroupWorkItemMilestone';
    if (!milestone && op != 'updateGroupWorkItemWeight') return null;
    final prefix = milestone ? 'milestone' : 'weight';
    final args = request.arguments;
    final valueKey = milestone ? 'milestoneTitle' : 'weight';
    final clearKey = milestone ? 'clearMilestone' : 'clearWeight';
    final hasValue = args.containsKey(valueKey);
    final hasClear = args.containsKey(clearKey);
    final clear = args[clearKey];
    if ((hasClear && clear is! bool) ||
        (hasValue && hasClear) ||
        (!hasValue && clear != true)) {
      throw AiWriteRefused('${prefix}Rejected');
    }
    final rawValue = args[valueKey];
    if (hasValue &&
        (milestone
            ? rawValue is! String ||
                  rawValue.trim().isEmpty ||
                  rawValue.contains('\u0000')
            : rawValue is! int || rawValue < 0 || rawValue > 2147483647)) {
      throw AiWriteRefused('${prefix}Rejected');
    }
    final context = _captureGroupWriteContext(request);
    final iid = _positive(args, 'iid');

    try {
      final user = await _readGroupActor(isCurrent: context.isCurrent);
      final location = await _resolveGroupWorkItem(
        request,
        actorUserId: user.id,
        generation: context.generation,
        readEpoch: context.readEpoch,
        isCurrent: context.isCurrent,
      );
      final identity = location.identity;
      final detail = location.detail.withStrictGroupOwner(identity);
      final summary = detail.summary;
      final binding = <String, Object?>{
        'actorId': user.id,
        'id': summary.id,
        'iid': iid,
        'groupId': identity.groupId,
        'groupPath': identity.fullPath,
        'namespaceId': summary.namespace!.id,
        'namespacePath': summary.namespace!.fullPath,
        'typeId': summary.type.id,
        'typeName': summary.type.name,
        'createdAt': summary.createdAt.toIso8601String(),
        'updatedAt': summary.updatedAt.toIso8601String(),
      };
      late Future<Object?> Function(GraphHooks hooks) mutation;
      late AiFieldsPreview preview;

      if (milestone) {
        final access = await _api.workItemMilestone(
          detail,
          expectedUserId: user.id,
          isCurrent: context.isCurrent,
        );
        if (!context.isCurrent()) {
          throw const AiWriteRefused('workItemUnverifiable');
        }
        final target = access.target;
        if (!access.canSetMilestone || target == null) {
          throw const AiWriteRefused('milestoneForbidden');
        }
        final before = access.snapshot;
        _requireP8Revision(summary, before.summary, prefix);
        var selection = target.clearSelection;
        if (hasValue) {
          final title = rawValue! as String;
          // Long titles use the existing unfiltered reader. Both paths require
          // one complete page and compare the original title exactly.
          // The fixed group connection includes self/ancestors and excludes
          // descendants/projects; selection stays bound to this opening.
          final choices = await _api.workItemMilestoneChoices(
            target,
            search: title.runes.length <= 256 ? title : '',
            isCurrent: context.isCurrent,
          );
          if (!context.isCurrent()) {
            throw const AiWriteRefused('workItemUnverifiable');
          }
          if (choices.isPartial) {
            throw const AiWriteRefused('milestoneRejected');
          }
          final matches = choices.items.where(
            (choice) => choice.milestone.title == title,
          );
          if (matches.length != 1) {
            throw const AiWriteRefused('milestoneRejected');
          }
          selection = matches.single.selection;
        }
        final desired = selection.milestone;
        final noChange = before.milestone?.id == desired?.id;
        binding.addAll({
          'title': before.summary.title,
          'state': before.summary.state,
          'createdAt': before.summary.createdAt.toIso8601String(),
          'milestoneAvailability': before.availability.name,
          'milestoneExpired': before.milestoneExpired,
          'milestoneId': before.milestone?.id,
          'milestoneIid': before.milestone?.iid,
          'milestoneTitle': before.milestone?.title,
          'milestoneState': before.milestone?.state,
          'milestoneWebPath': before.milestone?.webPath,
          'milestoneDueDate': before.milestone?.dueDate?.toIso8601String(),
          'milestoneStartDate': before.milestone?.startDate?.toIso8601String(),
          'milestoneProjectId': before.milestone?.project?.id,
          'milestoneProjectPath': before.milestone?.project?.fullPath,
          'milestoneGroupId': before.milestone?.group?.id,
          'milestoneGroupPath': before.milestone?.group?.fullPath,
          'desiredMilestoneId': desired?.id,
          'desiredMilestoneTitle': desired?.title,
        });
        preview = AiFieldsPreview({
          'milestone_id': desired?.id,
          'title': desired?.title,
        });
        mutation = (hooks) async {
          try {
            final result = await _api.updateWorkItemMilestone(
              target,
              selection: selection,
              isCurrent: () => hooks.accepted
                  ? context.isSessionCurrent()
                  : context.isCurrent(),
              beforeMutation: hooks.beforeMutation,
              mayStart: hooks.mayStart,
            );
            if (result.snapshot.availability !=
                    WorkItemMilestoneAvailability.present ||
                result.snapshot.milestone?.id != desired?.id) {
              throw const AiWriteRefused('milestoneRejected');
            }
            return GraphWriteResult(
              noChange: noChange,
              mutationSent: hooks.accepted,
              acknowledged: hooks.accepted,
              readbackVerified: hooks.accepted,
              revision: result.snapshot.summary.updatedAt,
              projection: {'milestone_id': desired?.id},
            );
          } on ApiFailure catch (failure) {
            if (identical(failure, hooks.blockedBeforeSend)) rethrow;
            throw AiWriteRefused(_p8FailureCode(prefix, failure));
          }
        };
      } else {
        final access = await _api.workItemWeight(
          detail,
          expectedUserId: user.id,
          isCurrent: context.isCurrent,
        );
        if (!context.isCurrent()) {
          throw const AiWriteRefused('workItemUnverifiable');
        }
        final target = access.target;
        if (!access.canSetWeight || target == null) {
          throw const AiWriteRefused('weightForbidden');
        }
        final before = access.snapshot;
        _requireP8Revision(summary, before.summary, prefix);
        final weight = hasValue ? rawValue! as int : null;
        final noChange = before.value!.weight == weight;
        binding.addAll({
          'weight': before.value!.weight,
          'desiredWeight': weight,
        });
        preview = AiFieldsPreview({'weight': weight});
        mutation = (hooks) async {
          try {
            final result = await _api.updateWorkItemWeight(
              target,
              weight: weight,
              isCurrent: () => hooks.accepted
                  ? context.isSessionCurrent()
                  : context.isCurrent(),
              beforeMutation: hooks.beforeMutation,
              mayStart: hooks.mayStart,
            );
            if (result.value == null || result.value!.weight != weight) {
              throw const AiWriteRefused('weightRejected');
            }
            return GraphWriteResult(
              noChange: noChange,
              mutationSent: hooks.accepted,
              acknowledged: hooks.accepted,
              readbackVerified: hooks.accepted,
              revision: result.summary.updatedAt,
              projection: {'weight': weight},
            );
          } on ApiFailure catch (failure) {
            if (identical(failure, hooks.blockedBeforeSend)) rethrow;
            throw AiWriteRefused(_p8FailureCode(prefix, failure));
          }
        };
      }

      if (!context.isCurrent()) {
        throw const AiWriteRefused('workItemUnverifiable');
      }
      return AiWritePrepared.graph(
        request: request,
        releaseName: '${identity.fullPath}#$iid',
        owner: _owner,
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
        bindingDigest: sha256
            .convert(utf8.encode(jsonEncode(binding)))
            .toString(),
        preview: preview,
        mutation: mutation,
      );
    } on ApiFailure catch (failure) {
      throw AiWriteRefused(_p8FailureCode(prefix, failure));
    }
  }
}
