import 'graphql_write_hooks.dart';

/// Evidence normalized by each family from its typed, checked core result.
/// A normal return alone is never evidence of a successful graph write.
final class GraphWriteResult {
  const GraphWriteResult({
    this.noChange = false,
    this.mutationSent = false,
    this.acknowledged = false,
    this.readbackVerified = false,
    this.revision,
    this.projection = const {},
  });

  final bool noChange;
  final bool mutationSent;
  final bool acknowledged;
  final bool readbackVerified;
  final DateTime? revision;
  final Map<String, Object?> projection;
}

final class GraphWriteRule {
  const GraphWriteRule({required this.allowsNoop, this.readback = true});
  final bool allowsNoop;
  final bool readback;
}

/// MR6b-3 §3.1. Core methods verify exact identity, actor and desired values;
/// families must retain that evidence, including each independent readback.
const graphWriteRules = <String, GraphWriteRule>{
  'updateWorkItemState': GraphWriteRule(allowsNoop: true),
  'updateWorkItemStatus': GraphWriteRule(allowsNoop: true),
  'updateWorkItemDates': GraphWriteRule(allowsNoop: true),
  'updateWorkItemHealthStatus': GraphWriteRule(allowsNoop: true),
  'updateWorkItemAssignees': GraphWriteRule(allowsNoop: true),
  'updateWorkItemMilestone': GraphWriteRule(allowsNoop: true),
  'updateWorkItemWeight': GraphWriteRule(allowsNoop: true),
  'createWorkItemActivityComment': GraphWriteRule(allowsNoop: false),
  'createWorkItemActivityReply': GraphWriteRule(allowsNoop: false),
  'deleteWorkItemActivityNote': GraphWriteRule(allowsNoop: false),
  'editWorkItemActivityNote': GraphWriteRule(allowsNoop: true),
  'updateWorkItemContent': GraphWriteRule(allowsNoop: true),
  'updateWorkItemLabels': GraphWriteRule(allowsNoop: true),
  'setWorkItemActivityNoteReaction': GraphWriteRule(allowsNoop: true),
  'setWorkItemNotifications': GraphWriteRule(allowsNoop: true),
  'setIncidentStatus': GraphWriteRule(allowsNoop: true),
  // Group aliases retain the original operation's noop and readback contract.
  'updateGroupWorkItemState': GraphWriteRule(allowsNoop: true),
  'updateGroupWorkItemStatus': GraphWriteRule(allowsNoop: true),
  'updateGroupWorkItemDates': GraphWriteRule(allowsNoop: true),
  'updateGroupWorkItemHealthStatus': GraphWriteRule(allowsNoop: true),
  'updateGroupWorkItemAssignees': GraphWriteRule(allowsNoop: true),
  'updateGroupWorkItemMilestone': GraphWriteRule(allowsNoop: true),
  'updateGroupWorkItemWeight': GraphWriteRule(allowsNoop: true),
  'createGroupWorkItemActivityComment': GraphWriteRule(allowsNoop: false),
  'createGroupWorkItemActivityReply': GraphWriteRule(allowsNoop: false),
  'deleteGroupWorkItemActivityNote': GraphWriteRule(allowsNoop: false),
  'editGroupWorkItemActivityNote': GraphWriteRule(allowsNoop: true),
  'updateGroupWorkItemContent': GraphWriteRule(allowsNoop: true),
  'updateGroupWorkItemLabels': GraphWriteRule(allowsNoop: true),
  'setGroupWorkItemActivityNoteReaction': GraphWriteRule(allowsNoop: true),
  'setGroupWorkItemNotifications': GraphWriteRule(allowsNoop: true),
  // Exact Todo GID and the normalized requested UTC instant (or null on clear)
  // must be checked by the family before setting acknowledged. No extra read.
  'snoozeTodo': GraphWriteRule(allowsNoop: false, readback: false),
  'unsnoozeTodo': GraphWriteRule(allowsNoop: false, readback: false),
};

enum GraphWriteDisposition { notExecuted, noChange, succeeded, writeUncertain }

GraphWriteDisposition classifyGraphWrite(
  String operationId,
  GraphHooks span, {
  Object? result,
  Object? error,
}) {
  final rule = graphWriteRules[operationId];
  if (span.accepted) {
    return !span.contractViolated &&
            error == null &&
            rule != null &&
            result is GraphWriteResult &&
            !result.noChange &&
            result.mutationSent &&
            result.acknowledged &&
            (!rule.readback || result.readbackVerified)
        ? GraphWriteDisposition.succeeded
        : GraphWriteDisposition.writeUncertain;
  }
  if (span.state == GraphWriteSpanState.notHooked &&
      !span.contractViolated &&
      error == null &&
      rule?.allowsNoop == true &&
      result is GraphWriteResult &&
      result.noChange &&
      !result.mutationSent) {
    return GraphWriteDisposition.noChange;
  }
  return GraphWriteDisposition.notExecuted;
}
