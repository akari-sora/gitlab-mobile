import 'work_item_graph_models.dart';

enum WorkItemState { open, closed }

enum WorkItemStateEvent {
  close('CLOSE', WorkItemState.closed),
  reopen('REOPEN', WorkItemState.open);

  const WorkItemStateEvent(this.apiValue, this.result);

  final String apiValue;
  final WorkItemState result;
}

/// A fresh, permission-bearing read of one exact server-owned work item.
///
/// [state] is GitLab's top-level OPEN/CLOSED lifecycle. It is deliberately
/// separate from the optional custom STATUS widget.
final class WorkItemStateSnapshot {
  const WorkItemStateSnapshot({
    required this.id,
    required this.iid,
    required this.state,
    required this.updatedAt,
    required this.project,
    required this.namespace,
    required this.typeId,
    required this.canUpdate,
  });

  final String id;
  final int iid;
  final WorkItemState state;
  final DateTime updatedAt;
  final GraphResourceRef? project;
  final GraphResourceRef? namespace;
  final String typeId;
  final bool canUpdate;
}
