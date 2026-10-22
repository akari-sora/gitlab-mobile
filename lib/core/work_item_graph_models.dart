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
    this.author,
    this.widgets,
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
  final WorkItemGraphAuthor? author;

  /// List summary widgets. Null when widgets were not requested or unavailable.
  final WorkItemSummaryWidgets? widgets;

  /// Alias for [widgets] to support either naming.
  WorkItemSummaryWidgets? get summary => widgets;
}

final class WorkItemGraphAuthor {
  const WorkItemGraphAuthor({required this.id, required this.name, required this.username});

  final String id;
  final String name;
  final String username;
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
  });

  final String id;
  final String name;
  final String username;
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

final class WorkItemMilestoneSummary {
  const WorkItemMilestoneSummary({
    required this.id,
    this.iid,
    required this.title,
    this.dueDate,
    this.startDate,
  });

  final String id;
  final int? iid;
  final String title;
  final DateTime? dueDate;
  final DateTime? startDate;
}

final class WorkItemDatesSummary {
  const WorkItemDatesSummary({
    this.startDate,
    this.dueDate,
  });

  final DateTime? startDate;
  final DateTime? dueDate;
}

final class WorkItemHierarchySummary {
  const WorkItemHierarchySummary({
    required this.hasParent,
    this.parent,
  });

  final bool hasParent;
  final WorkItemHierarchyEntry? parent;
}

final class WorkItemStatusSummary {
  const WorkItemStatusSummary({
    this.id,
    this.name,
    this.iconName,
    this.color,
  });

  final String? id;
  final String? name;
  final String? iconName;
  final String? color;
}

final class WorkItemSummaryWidgets {
  const WorkItemSummaryWidgets({
    required this.tier,
    required this.widgetTypes,
    this.labels,
    this.assignees,
    this.milestone,
    this.dates,
    this.hierarchy,
    this.status,
  });

  const WorkItemSummaryWidgets.unavailable({required this.tier})
      : widgetTypes = null,
        labels = null,
        assignees = null,
        milestone = null,
        dates = null,
        hierarchy = null,
        status = null;

  /// The active GraphQL query tier (1: CE 5 + EE Status, 2: CE Core, 3: Baseline no widgets).
  final int tier;

  /// Null means GitLab returned null for widgets or widgets were not requested.
  /// A non-null Set means the widgets collection was present.
  final Set<String>? widgetTypes;

  final BoundedGraphConnection<WorkItemGraphLabel>? labels;
  final BoundedGraphConnection<WorkItemGraphAssignee>? assignees;
  final WorkItemMilestoneSummary? milestone;
  final WorkItemDatesSummary? dates;
  final WorkItemHierarchySummary? hierarchy;
  final WorkItemStatusSummary? status;
}

final class WorkItemDisplayPreferences {
  const WorkItemDisplayPreferences({
    this.showLabels = true,
    this.showAssignees = true,
    this.showMilestone = true,
    this.showDates = true,
    this.showHierarchy = true,
    this.showStatus = true,
  });

  final bool showLabels;
  final bool showAssignees;
  final bool showMilestone;
  final bool showDates;
  final bool showHierarchy;
  final bool showStatus;

  WorkItemDisplayPreferences copyWith({
    bool? showLabels,
    bool? showAssignees,
    bool? showMilestone,
    bool? showDates,
    bool? showHierarchy,
    bool? showStatus,
  }) {
    return WorkItemDisplayPreferences(
      showLabels: showLabels ?? this.showLabels,
      showAssignees: showAssignees ?? this.showAssignees,
      showMilestone: showMilestone ?? this.showMilestone,
      showDates: showDates ?? this.showDates,
      showHierarchy: showHierarchy ?? this.showHierarchy,
      showStatus: showStatus ?? this.showStatus,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkItemDisplayPreferences &&
          showLabels == other.showLabels &&
          showAssignees == other.showAssignees &&
          showMilestone == other.showMilestone &&
          showDates == other.showDates &&
          showHierarchy == other.showHierarchy &&
          showStatus == other.showStatus;

  @override
  int get hashCode => Object.hash(
    showLabels,
    showAssignees,
    showMilestone,
    showDates,
    showHierarchy,
    showStatus,
  );
}

final class WorkItemGraphPage {
  const WorkItemGraphPage({
    required this.items,
    required this.nextCursor,
    this.filter,
    this.summaryTier,
  });

  final List<WorkItemGraphSummary> items;
  final String? nextCursor;
  final GroupWorkItemListFilter? filter;
  final int? summaryTier;
  bool get isPartial => nextCursor != null;
}

enum GroupWorkItemState { all, opened, closed }

enum GroupWorkItemSort { createdDesc, createdAsc, updatedDesc, updatedAsc }

/// Server-side controls for one group Work Item connection.
///
/// [search] is normalized by trimming surrounding whitespace and is limited to
/// 256 Unicode scalar values. [typeId] must be a canonical GitLab
/// `WorkItems::Type` global ID and requires the exact root [typeNamespace] that
/// supplied it. The normalized value returned on a page must be reused as
/// `previousFilter` when following its cursor.
final class GroupWorkItemListFilter {
  const GroupWorkItemListFilter({
    this.includeDescendants = false,
    this.state = GroupWorkItemState.all,
    this.search = '',
    this.sort = GroupWorkItemSort.createdDesc,
    this.typeId,
    this.typeNamespace,
  });

  final bool includeDescendants;
  final GroupWorkItemState state;
  final String search;
  final GroupWorkItemSort sort;
  final String? typeId;
  final GraphResourceRef? typeNamespace;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupWorkItemListFilter &&
          includeDescendants == other.includeDescendants &&
          state == other.state &&
          search == other.search &&
          sort == other.sort &&
          typeId == other.typeId &&
          typeNamespace?.id == other.typeNamespace?.id &&
          typeNamespace?.fullPath == other.typeNamespace?.fullPath;

  @override
  int get hashCode => Object.hash(
    includeDescendants,
    state,
    search,
    sort,
    typeId,
    typeNamespace?.id,
    typeNamespace?.fullPath,
  );
}

/// One bounded page owned by an exact GitLab group identity.
final class GroupWorkItemGraphPage {
  GroupWorkItemGraphPage({
    required this.group,
    required List<WorkItemGraphSummary> items,
    required this.nextCursor,
    required this.filter,
    this.summaryTier,
  }) : items = List.unmodifiable(items);

  /// Opaque server identity returned by the same response as [items].
  final GraphResourceRef group;
  final List<WorkItemGraphSummary> items;
  final String? nextCursor;
  final GroupWorkItemListFilter filter;
  final int? summaryTier;
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
