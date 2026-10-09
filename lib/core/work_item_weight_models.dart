import 'work_item_attribute_models.dart';
import 'work_item_graph_models.dart';

/// Fresh weight snapshot. A present widget whose own weight is null is unset;
/// zero is a stored value. Rolled-up totals are read-only and may be null
/// independently of the own weight.
final class WorkItemWeightSnapshot {
  const WorkItemWeightSnapshot({
    required this.summary,
    required this.availability,
    required this.value,
  });

  final WorkItemGraphSummary summary;
  final WorkItemAttributeAvailability availability;

  /// Non-null only when [availability] is present. Its three scalars are then
  /// each either null or a nonnegative Int32.
  final WorkItemWeightAttribute? value;
}
