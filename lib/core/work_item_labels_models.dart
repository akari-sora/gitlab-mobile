import 'dart:math' as math;

import 'failure.dart';
import 'work_item_graph_models.dart';

/// Scope before the last `::`. No separator returns null. An empty key is real.
String? workItemLabelScopeKey(String title) {
  const separator = '::';
  final index = title.lastIndexOf(separator);
  if (index < 0) return null;
  return title.substring(0, index);
}

/// True only when both colors are `#RRGGBB` and sRGB contrast is at least 4.5.
bool workItemLabelContrastAccepted(String color, String textColor) {
  final foreground = _srgbChannels(color);
  final background = _srgbChannels(textColor);
  if (foreground == null || background == null) return false;
  final first = _relativeLuminance(foreground);
  final second = _relativeLuminance(background);
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05) >= 4.5;
}

List<int>? _srgbChannels(String color) {
  if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(color)) return null;
  return <int>[
    int.parse(color.substring(1, 3), radix: 16),
    int.parse(color.substring(3, 5), radix: 16),
    int.parse(color.substring(5, 7), radix: 16),
  ];
}

double _relativeLuminance(List<int> channels) {
  double linear(int channel) {
    final value = channel / 255;
    if (value <= 0.04045) return value / 12.92;
    return math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * linear(channels[0]) +
      0.7152 * linear(channels[1]) +
      0.0722 * linear(channels[2]);
}

/// JSON `true` is [allowed]. JSON `false` is [disabled]. Anything else is [unknown].
enum WorkItemLabelAllowsScoped { allowed, disabled, unknown }

final class WorkItemLabel {
  const WorkItemLabel({
    required this.id,
    required this.title,
    required this.color,
    required this.textColor,
  });

  final String id;
  final String title;
  final String? color;
  final String? textColor;
}

final class WorkItemLabelSnapshot {
  const WorkItemLabelSnapshot({
    required this.labels,
    required this.updatedAt,
    required this.actorId,
    required this.summary,
    required this.readWorkItem,
    required this.setWorkItemMetadata,
    required this.labelsWidgetPresent,
    required this.allowsScopedLabels,
    required this.generation,
    required this.readEpoch,
  });

  final List<WorkItemLabel> labels;
  final DateTime updatedAt;
  final String actorId;
  final WorkItemGraphSummary summary;
  final bool readWorkItem;
  final bool setWorkItemMetadata;
  final bool labelsWidgetPresent;
  final WorkItemLabelAllowsScoped allowsScopedLabels;
  final int generation;
  final int readEpoch;

  List<String> get labelIds =>
      labels.map((label) => label.id).toList(growable: false);
}

enum WorkItemLabelSaveStatus { success, noop, notApplied }

final class WorkItemLabelSaveResult {
  const WorkItemLabelSaveResult({
    required this.status,
    required this.snapshot,
    required this.acknowledgedUpdatedAt,
    required this.mutationSent,
  });

  final WorkItemLabelSaveStatus status;
  final WorkItemLabelSnapshot snapshot;
  final DateTime? acknowledgedUpdatedAt;
  final bool mutationSent;
}

final class WorkItemLabelWriteFailure implements Exception {
  const WorkItemLabelWriteFailure({
    required this.failure,
    required this.mutationSent,
  });

  final ApiFailure failure;
  final bool mutationSent;
}

final class WorkItemLabelCandidatePage {
  const WorkItemLabelCandidatePage({
    required this.labels,
    required this.endCursor,
    required this.hasNextPage,
    required this.pageIndex,
  });

  final List<WorkItemLabel> labels;
  final String? endCursor;
  final bool hasNextPage;
  final int pageIndex;
}

enum WorkItemLabelWritePhase { start, settle }

typedef WorkItemLabelWriteHook =
    void Function(WorkItemLabelWritePhase phase, Object token);
