import 'work_item_graph_models.dart';

enum WorkItemAttributeKind {
  status,
  milestone,
  weight,
  iteration,
  health,
  timeTracking,
  development,
}

enum WorkItemAttributeAvailability { present, absent, widgetsUnavailable }

sealed class WorkItemAttributeValue {
  const WorkItemAttributeValue();
}

final class WorkItemAttributeSnapshot {
  const WorkItemAttributeSnapshot({
    required this.workItemId,
    required this.iid,
    required this.project,
    required this.namespace,
    required this.kind,
    required this.availability,
    required this.value,
  });

  final String workItemId;
  final int iid;
  final GraphResourceRef? project;
  final GraphResourceRef? namespace;
  final WorkItemAttributeKind kind;
  final WorkItemAttributeAvailability availability;
  final WorkItemAttributeValue? value;
}

final class WorkItemStatusValue {
  const WorkItemStatusValue({
    required this.id,
    required this.name,
    required this.iconName,
    required this.color,
    required this.category,
  });

  final String? id;
  final String? name;
  final String? iconName;
  final String? color;
  final String? category;
}

final class WorkItemStatusAttribute extends WorkItemAttributeValue {
  const WorkItemStatusAttribute({required this.status});

  final WorkItemStatusValue? status;
}

/// A project or group returned inside an attribute widget. Some GitLab group
/// connections deliberately omit the Graph ID while retaining [fullPath].
final class WorkItemAttributeOwnerRef {
  const WorkItemAttributeOwnerRef({required this.id, required this.fullPath});

  final String? id;
  final String fullPath;
}

final class WorkItemMilestoneValue {
  const WorkItemMilestoneValue({
    required this.id,
    required this.iid,
    required this.title,
    required this.state,
    required this.webPath,
    required this.dueDate,
    required this.startDate,
    required this.project,
    required this.group,
  });

  final String id;
  final int iid;
  final String title;
  final String state;
  final String webPath;
  final DateTime? dueDate;
  final DateTime? startDate;
  final WorkItemAttributeOwnerRef? project;
  final WorkItemAttributeOwnerRef? group;
}

final class WorkItemMilestoneAttribute extends WorkItemAttributeValue {
  const WorkItemMilestoneAttribute({required this.milestone});

  final WorkItemMilestoneValue? milestone;
}

final class WorkItemWeightAttribute extends WorkItemAttributeValue {
  const WorkItemWeightAttribute({
    required this.weight,
    required this.rolledUpWeight,
    required this.rolledUpCompletedWeight,
  });

  final int? weight;
  final int? rolledUpWeight;
  final int? rolledUpCompletedWeight;
}

final class WorkItemIterationCadence {
  const WorkItemIterationCadence({required this.id, required this.title});

  final String id;
  final String? title;
}

final class WorkItemIterationValue {
  const WorkItemIterationValue({
    required this.id,
    required this.iid,
    required this.title,
    required this.state,
    required this.webUrl,
    required this.startDate,
    required this.dueDate,
    required this.group,
    required this.cadence,
  });

  final String id;
  final int iid;
  final String? title;
  final String state;
  final Uri webUrl;
  final DateTime? startDate;
  final DateTime? dueDate;
  final WorkItemAttributeOwnerRef group;
  final WorkItemIterationCadence cadence;
}

final class WorkItemIterationAttribute extends WorkItemAttributeValue {
  const WorkItemIterationAttribute({required this.iteration});

  final WorkItemIterationValue? iteration;
}

final class WorkItemHealthRollup {
  const WorkItemHealthRollup({required this.healthStatus, required this.count});

  final String healthStatus;
  final int count;
}

final class WorkItemHealthAttribute extends WorkItemAttributeValue {
  const WorkItemHealthAttribute({
    required this.healthStatus,
    required this.rolledUpHealthStatus,
  });

  final String? healthStatus;
  final List<WorkItemHealthRollup>? rolledUpHealthStatus;
}

final class WorkItemHumanReadableTime {
  const WorkItemHumanReadableTime({
    required this.timeEstimate,
    required this.totalTimeSpent,
  });

  final String? timeEstimate;
  final String? totalTimeSpent;
}

final class WorkItemTimeTrackingAttribute extends WorkItemAttributeValue {
  const WorkItemTimeTrackingAttribute({
    required this.timeEstimate,
    required this.totalTimeSpent,
    required this.humanReadable,
  });

  final int? timeEstimate;
  final int? totalTimeSpent;
  final WorkItemHumanReadableTime? humanReadable;
}

final class WorkItemDevelopmentAttribute extends WorkItemAttributeValue {
  const WorkItemDevelopmentAttribute({
    required this.closingMergeRequestsCount,
    required this.willAutoCloseByMergeRequest,
  });

  final int closingMergeRequestsCount;
  final bool willAutoCloseByMergeRequest;
}
