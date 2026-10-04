import 'failure.dart';
import 'work_item_graph_models.dart';
import 'work_item_state_models.dart';

/// One server-returned Work Item status.
///
/// Every field is nullable upstream. Only a non-null [id] can authorize a
/// selection; the other fields are untrusted display metadata.
final class WorkItemStatusRecord {
  const WorkItemStatusRecord({
    required this.id,
    required this.name,
    required this.iconName,
    required this.color,
    required this.position,
    required this.description,
    required this.category,
  });

  final String? id;
  final String? name;
  final String? iconName;
  final String? color;
  final int? position;
  final String? description;
  final String? category;
}

enum WorkItemStatusAssignmentKind { unassigned, identified, unidentified }

/// Distinguishes an explicit `status: null` from an identified status and a
/// valid status object whose nullable server ID is unavailable.
final class WorkItemStatusAssignment {
  const WorkItemStatusAssignment._(this.kind, this.record);

  const WorkItemStatusAssignment.unassigned()
    : this._(WorkItemStatusAssignmentKind.unassigned, null);

  const WorkItemStatusAssignment.identified(WorkItemStatusRecord record)
    : this._(WorkItemStatusAssignmentKind.identified, record);

  const WorkItemStatusAssignment.unidentified(WorkItemStatusRecord record)
    : this._(WorkItemStatusAssignmentKind.unidentified, record);

  final WorkItemStatusAssignmentKind kind;
  final WorkItemStatusRecord? record;
  String? get id => record?.id;
}

/// A complete fresh STATUS capability read for one exact Work Item.
final class WorkItemStatusSnapshot {
  const WorkItemStatusSnapshot({
    required this.accountKey,
    required this.actorId,
    required this.expectedUserId,
    required this.generation,
    required this.readEpoch,
    required this.id,
    required this.iid,
    required this.project,
    required this.namespace,
    required this.typeId,
    required this.updatedAt,
    required this.lockVersion,
    required this.state,
    required this.assignment,
    required this.allowedStatuses,
    required this.readWorkItem,
    required this.setWorkItemMetadata,
  });

  final String accountKey;
  final String actorId;
  final int expectedUserId;
  final int generation;
  final int readEpoch;
  final String id;
  final int iid;
  final GraphResourceRef? project;
  final GraphResourceRef? namespace;
  final String typeId;
  final DateTime updatedAt;
  final int lockVersion;
  final WorkItemState state;
  final WorkItemStatusAssignment assignment;
  final List<WorkItemStatusRecord> allowedStatuses;
  final bool readWorkItem;
  final bool setWorkItemMetadata;

  List<String> get allowedStatusIds => List<String>.unmodifiable(
    allowedStatuses.map((status) => status.id!),
  );
}

/// Mutation acknowledgement. Publication still requires a separate snapshot.
final class WorkItemStatusAcknowledgement {
  const WorkItemStatusAcknowledgement({
    required this.accountKey,
    required this.actorId,
    required this.expectedUserId,
    required this.generation,
    required this.id,
    required this.iid,
    required this.project,
    required this.namespace,
    required this.typeId,
    required this.updatedAt,
    required this.state,
    required this.assignment,
  });

  final String accountKey;
  final String actorId;
  final int expectedUserId;
  final int generation;
  final String id;
  final int iid;
  final GraphResourceRef? project;
  final GraphResourceRef? namespace;
  final String typeId;
  final DateTime updatedAt;
  final WorkItemState state;
  final WorkItemStatusAssignment assignment;
}

enum WorkItemStatusSaveStatus { success, noop, notApplied }

enum WorkItemStatusHandoff { none, started }

enum WorkItemStatusWritePhase { start, settle }

/// The callback reports START by invoking [started] with its opaque operation
/// token. This lets a synchronous exception retain whether START was entered.
typedef WorkItemStatusMutationSent =
    void Function(void Function(Object operationToken) started);

final class WorkItemStatusSaveResult {
  const WorkItemStatusSaveResult({
    required this.status,
    required this.snapshot,
    required this.acknowledgement,
    required this.mutationSent,
    required this.handoff,
  });

  final WorkItemStatusSaveStatus status;
  final WorkItemStatusSnapshot snapshot;
  final WorkItemStatusAcknowledgement? acknowledgement;
  final bool mutationSent;
  final WorkItemStatusHandoff handoff;
}

final class WorkItemStatusWriteFailure implements Exception {
  const WorkItemStatusWriteFailure({
    required this.failure,
    required this.mutationSent,
    required this.handoff,
  });

  final ApiFailure failure;
  final bool mutationSent;
  final WorkItemStatusHandoff handoff;
}
