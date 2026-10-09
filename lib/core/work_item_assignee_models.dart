import 'work_item_graph_models.dart';

/// One GitLab user selected or offered as a work-item assignee.
///
/// [id] is the server global id `gid://gitlab/User/<digits>`.
final class WorkItemAssigneeUser {
  const WorkItemAssigneeUser({
    required this.id,
    required this.name,
    required this.username,
  });

  final String id;
  final String name;
  final String username;
}

/// One page of `WorkItemWidgetAssignees.assignees`.
///
/// The editable set is every page after `hasNextPage` is false. A single page,
/// including the detail view's first 20 rows, is not a write set.
final class WorkItemAssigneePage {
  const WorkItemAssigneePage({
    required this.users,
    required this.endCursor,
    required this.hasNextPage,
  });

  final List<WorkItemAssigneeUser> users;
  final String? endCursor;
  final bool hasNextPage;
}

/// Complete logical assignee set for one fresh read.
///
/// [users] may be longer than the detail view's first 20 rows. Callers must
/// not paint this list into that bounded wrap. [updatedAt] is the work item
/// revision observed on every page of this read. It fences the next write. A
/// later timestamp is not publication authority.
final class WorkItemAssigneeSnapshot {
  const WorkItemAssigneeSnapshot({
    required this.users,
    required this.allowsMultiple,
    required this.updatedAt,
    required this.actorId,
    required this.summary,
  });

  final List<WorkItemAssigneeUser> users;
  final bool allowsMultiple;
  final DateTime updatedAt;
  final String actorId;
  final WorkItemGraphSummary summary;

  List<String> get assigneeIds =>
      List<String>.unmodifiable(users.map((user) => user.id));
}
