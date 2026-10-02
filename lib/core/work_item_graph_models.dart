/// Opaque GraphQL identity bound to one namespace path.
final class GraphResourceRef {
  const GraphResourceRef({required this.id, required this.fullPath});

  final String id;
  final String fullPath;
}

/// A server-defined work item type. The name is for display only.
final class WorkItemGraphType {
  const WorkItemGraphType({required this.id, required this.name});

  final String id;
  final String name;
}

/// One bounded GraphQL connection. [isPartial] means more server rows exist;
/// callers must not interpret the loaded item count as a total.
final class BoundedGraphConnection<T> {
  const BoundedGraphConnection({
    required this.items,
    required this.isPartial,
    required this.nextCursor,
  });

  final List<T> items;
  final bool isPartial;
  final String? nextCursor;
}

final class WorkItemGraphSummary {
  const WorkItemGraphSummary({
    required this.id,
    required this.iid,
    required this.title,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    required this.project,
    required this.namespace,
    required this.type,
  });

  /// Server-owned WorkItem global ID. It is never reconstructed by clients.
  final String id;
  final int iid;
  final String title;
  final String state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final GraphResourceRef? project;
  final GraphResourceRef? namespace;
  final WorkItemGraphType type;
}

final class WorkItemDescriptionWidget {
  const WorkItemDescriptionWidget({
    required this.description,
    required this.edited,
    required this.lastEditedAt,
  });

  /// Raw Markdown/plain source. Rendered HTML is deliberately not exposed.
  final String? description;
  final bool edited;
  final DateTime? lastEditedAt;
}

final class WorkItemGraphAssignee {
  const WorkItemGraphAssignee({
    required this.id,
    required this.name,
    required this.username,
    required this.avatarUrl,
  });

  final String id;
  final String name;
  final String username;
  final Uri? avatarUrl;
}

final class WorkItemAssigneesWidget {
  const WorkItemAssigneesWidget({required this.assignees});

  /// Null means the widget exists but its connection was unavailable.
  final BoundedGraphConnection<WorkItemGraphAssignee>? assignees;
}

final class WorkItemGraphLabel {
  const WorkItemGraphLabel({
    required this.id,
    required this.title,
    required this.color,
    required this.description,
    required this.textColor,
  });

  final String id;
  final String title;
  final String color;
  final String? description;
  final String? textColor;
}

final class WorkItemLabelsWidget {
  const WorkItemLabelsWidget({required this.labels});

  /// Null means the widget exists but its connection was unavailable.
  final BoundedGraphConnection<WorkItemGraphLabel>? labels;
}

final class WorkItemHierarchyEntry {
  const WorkItemHierarchyEntry({
    required this.id,
    required this.iid,
    required this.title,
    required this.state,
    required this.project,
    required this.namespace,
    required this.type,
  });

  final String id;
  final int iid;
  final String title;
  final String state;
  final GraphResourceRef? project;
  final GraphResourceRef? namespace;
  final WorkItemGraphType type;
}

final class WorkItemHierarchyWidget {
  const WorkItemHierarchyWidget({
    required this.hasParent,
    required this.hasChildren,
    required this.parent,
    required this.children,
  });

  final bool? hasParent;
  final bool? hasChildren;
  final WorkItemHierarchyEntry? parent;

  /// Null means the widget exists but its children connection was unavailable.
  final BoundedGraphConnection<WorkItemHierarchyEntry>? children;
}

final class WorkItemDatesWidget {
  const WorkItemDatesWidget({
    required this.startDate,
    required this.dueDate,
    required this.rollUp,
  });

  final DateTime? startDate;
  final DateTime? dueDate;
  final bool rollUp;
}

final class WorkItemGraphDetail {
  const WorkItemGraphDetail({
    required this.summary,
    required this.description,
    required this.widgetsAvailable,
    required this.widgetTypes,
    required this.descriptionWidget,
    required this.assignees,
    required this.labels,
    required this.hierarchy,
    required this.dates,
  });

  final WorkItemGraphSummary summary;
  final String? description;

  /// False means GitLab returned a null widgets collection. An empty
  /// [widgetTypes] with this set to true is a real, loaded empty collection.
  final bool widgetsAvailable;
  final Set<String> widgetTypes;
  final WorkItemDescriptionWidget? descriptionWidget;
  final WorkItemAssigneesWidget? assignees;
  final WorkItemLabelsWidget? labels;
  final WorkItemHierarchyWidget? hierarchy;
  final WorkItemDatesWidget? dates;
}

final class WorkItemGraphPage {
  const WorkItemGraphPage({required this.items, required this.nextCursor});

  final List<WorkItemGraphSummary> items;
  final String? nextCursor;
  bool get isPartial => nextCursor != null;
}

final class WorkItemTypeCapability {
  const WorkItemTypeCapability({
    required this.type,
    required this.enabled,
    required this.isGroupWorkItemType,
    required this.widgetTypes,
  });

  final WorkItemGraphType type;
  final bool enabled;
  final bool isGroupWorkItemType;

  /// Null means widget definitions were unavailable, not an empty set.
  final Set<String>? widgetTypes;
}

final class WorkItemTypePage {
  const WorkItemTypePage({
    required this.namespace,
    required this.items,
    required this.nextCursor,
  });

  final GraphResourceRef namespace;
  final List<WorkItemTypeCapability> items;
  final String? nextCursor;
  bool get isPartial => nextCursor != null;
}
