import 'work_item_graph_models.dart';

enum WorkItemHealthEditValue {
  onTrack('onTrack'),
  needsAttention('needsAttention'),
  atRisk('atRisk');

  const WorkItemHealthEditValue(this.graphValue);

  final String graphValue;

  static WorkItemHealthEditValue? parse(Object? raw) => switch (raw) {
    null => null,
    'onTrack' => WorkItemHealthEditValue.onTrack,
    'needsAttention' => WorkItemHealthEditValue.needsAttention,
    'atRisk' => WorkItemHealthEditValue.atRisk,
    _ => throw const FormatException('Invalid health status'),
  };
}

enum WorkItemHealthEditAvailability { present, absent, widgetsUnavailable }

enum WorkItemHealthEditSaveStatus { success, noop, notApplied }

final class WorkItemHealthEditRollup {
  factory WorkItemHealthEditRollup({
    required WorkItemHealthEditValue value,
    required int count,
  }) {
    if (count < 0) throw ArgumentError.value(count, 'count');
    return WorkItemHealthEditRollup._(value: value, count: count);
  }

  const WorkItemHealthEditRollup._({required this.value, required this.count});

  final WorkItemHealthEditValue value;
  final int count;
}

final class WorkItemHealthEditSnapshot {
  factory WorkItemHealthEditSnapshot({
    required WorkItemGraphSummary summary,
    required WorkItemHealthEditAvailability availability,
    required bool healthStatusFieldPresent,
    required WorkItemHealthEditValue? value,
    required List<WorkItemHealthEditRollup>? rolledUp,
  }) {
    if (availability == WorkItemHealthEditAvailability.present) {
      if (!healthStatusFieldPresent) {
        throw ArgumentError.value(
          healthStatusFieldPresent,
          'healthStatusFieldPresent',
        );
      }
    } else if (healthStatusFieldPresent || value != null || rolledUp != null) {
      throw ArgumentError('Unavailable health widgets cannot contain values');
    }
    if (rolledUp != null) {
      if (rolledUp.length > 32 ||
          rolledUp.any((item) => item.count < 0) ||
          rolledUp.map((item) => item.value).toSet().length !=
              rolledUp.length) {
        throw ArgumentError.value(rolledUp, 'rolledUp');
      }
    }
    return WorkItemHealthEditSnapshot._(
      summary: summary,
      availability: availability,
      healthStatusFieldPresent: healthStatusFieldPresent,
      value: value,
      rolledUp: rolledUp == null
          ? null
          : List<WorkItemHealthEditRollup>.unmodifiable(rolledUp),
    );
  }

  const WorkItemHealthEditSnapshot._({
    required this.summary,
    required this.availability,
    required this.healthStatusFieldPresent,
    required this.value,
    required this.rolledUp,
  });

  final WorkItemGraphSummary summary;
  final WorkItemHealthEditAvailability availability;
  final bool healthStatusFieldPresent;
  final WorkItemHealthEditValue? value;
  final List<WorkItemHealthEditRollup>? rolledUp;
}
