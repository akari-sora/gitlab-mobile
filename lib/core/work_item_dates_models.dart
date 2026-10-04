import 'package:flutter/foundation.dart';

import 'work_item_graph_models.dart';

enum WorkItemDatesEdition { ceFixed, ee }

enum WorkItemDatesMode { manual, inherited, unknown }

@immutable
final class WorkItemDatesSnapshot {
  const WorkItemDatesSnapshot({
    required this.summary,
    required this.updatedAt,
    required this.edition,
    required this.mode,
    required this.startDate,
    required this.dueDate,
    required this.rollUp,
    this.startDateSourcingWorkItemId,
    this.dueDateSourcingWorkItemId,
    this.startDateSourcingMilestoneId,
    this.dueDateSourcingMilestoneId,
    required this.readWorkItem,
    required this.setWorkItemMetadata,
    required this.widgetPresent,
    required this.actorId,
    required this.expectedUserId,
    required this.generation,
  });

  final WorkItemGraphSummary summary;
  final DateTime updatedAt;
  final WorkItemDatesEdition? edition;
  final WorkItemDatesMode mode;
  final String? startDate;
  final String? dueDate;
  final bool rollUp;
  final String? startDateSourcingWorkItemId;
  final String? dueDateSourcingWorkItemId;
  final String? startDateSourcingMilestoneId;
  final String? dueDateSourcingMilestoneId;
  final bool readWorkItem;
  final bool setWorkItemMetadata;
  final bool widgetPresent;
  final String actorId;
  final int expectedUserId;
  final int generation;
}

enum WorkItemDatesWriteOutcome { applied, notApplied, writeUncertain }

@immutable
final class WorkItemDatesWriteResult {
  const WorkItemDatesWriteResult({
    required this.outcome,
    this.snapshot,
    required this.mutationSent,
    this.message,
  });

  final WorkItemDatesWriteOutcome outcome;
  final WorkItemDatesSnapshot? snapshot;
  final bool mutationSent;
  final String? message;
}
