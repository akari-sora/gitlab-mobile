part of 'gitlab_write_port.dart';

extension _GraphqlMilestoneWeightPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlMilestoneWeight(
    AiWriteRequest request,
  ) async {
    final op = request.operationId;
    final milestone = op == 'updateWorkItemMilestone';
    if (!milestone && op != 'updateWorkItemWeight') return null;
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
    final projectId = _positive(args, 'projectId');
    final iid = _positive(args, 'iid');
    if (!_granted(request.scope, projectId, 'issues', iid)) {
      throw AiWriteRefused('${prefix}Forbidden');
    }

    try {
      final user = await _api.currentUser();
      if ('${_api.instance.key}#${user.id}' != accountKey) {
        throw AiWriteRefused('${prefix}Forbidden');
      }
      final location = await resolveAiProjectWorkItem(
        request.scope,
        projectId,
        iid,
        readDetail: (project, iid) => _api.projectWorkItem(project, iid),
      );
      final detail = location.detail;
      final summary = detail.summary;
      final binding = <String, Object?>{
        'actorId': user.id,
        'id': summary.id,
        'iid': iid,
        'projectId': summary.project!.id,
        'projectPath': summary.project!.fullPath,
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
        );
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
          final choices = await _api.workItemMilestoneChoices(
            target,
            search: title.runes.length <= 256 ? title : '',
          );
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
            throw AiWriteRefused(_p8FailureCode(prefix, failure));
          }
        };
      } else {
        final access = await _api.workItemWeight(
          detail,
          expectedUserId: user.id,
        );
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
            throw AiWriteRefused(_p8FailureCode(prefix, failure));
          }
        };
      }

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

void _requireP8Revision(
  WorkItemGraphSummary expected,
  WorkItemGraphSummary fresh,
  String prefix,
) {
  if (fresh.updatedAt != expected.updatedAt) {
    throw AiWriteRefused('${prefix}Conflict');
  }
}

String _p8FailureCode(String prefix, ApiFailure failure) =>
    switch (failure.kind) {
      FailureKind.conflict || FailureKind.cancelled => '${prefix}Conflict',
      FailureKind.forbidden ||
      FailureKind.unauthenticated => '${prefix}Forbidden',
      _ => '${prefix}Rejected',
    };
