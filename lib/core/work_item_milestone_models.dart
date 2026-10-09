import 'work_item_attribute_models.dart';
import 'work_item_graph_models.dart';

enum WorkItemMilestoneAvailability { present, absent, widgetsUnavailable }

/// A fresh, actor-bound Work Item milestone snapshot.
final class WorkItemMilestoneSnapshot {
  const WorkItemMilestoneSnapshot({
    required this.summary,
    required this.availability,
    required this.milestone,
    required this.milestoneExpired,
  });

  final WorkItemGraphSummary summary;
  final WorkItemMilestoneAvailability availability;
  final WorkItemMilestoneValue? milestone;

  /// Server-owned expiry state. Null means no milestone or no usable widget.
  final bool? milestoneExpired;
}
