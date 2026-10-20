import 'failure.dart';

import '../l10n/l10n.dart';
typedef WorkItemJson = Map<String, dynamic>;

String _text(WorkItemJson value, String key) =>
    value[key] is String ? value[key] as String : '';
int _int(WorkItemJson value, String key) => value[key] is int
    ? value[key] as int
    : int.tryParse('${value[key] ?? ''}') ?? 0;

enum ProjectWorkItemType { issue, task, incident }

extension ProjectWorkItemTypeInfo on ProjectWorkItemType {
  String get apiValue => switch (this) {
    ProjectWorkItemType.issue => 'issue',
    ProjectWorkItemType.task => 'task',
    ProjectWorkItemType.incident => 'incident',
  };

  String get title => switch (this) {
    ProjectWorkItemType.issue => l10n.issueTypeName,
    ProjectWorkItemType.task => 'Task',
    ProjectWorkItemType.incident => 'Incident',
  };

  String get listTitle => switch (this) {
    ProjectWorkItemType.issue => l10n.issues,
    ProjectWorkItemType.task => 'Tasks',
    ProjectWorkItemType.incident => 'Incidents',
  };

  String get createTitle =>
      this == ProjectWorkItemType.issue ? l10n.newIssue : l10n.newItemWithTitle(title);
  String get searchHint =>
      this == ProjectWorkItemType.issue ? l10n.searchIssues : l10n.searchItemWithTitle(title);
  String get emptyLabel => l10n.noMatchingTitle(title);
  String get selectionHint => l10n.selectTitleFromLeftList(title);
}

ProjectWorkItemType workItemTypeFromJson(WorkItemJson value) {
  if (!value.containsKey('issue_type')) return ProjectWorkItemType.issue;
  final raw = value['issue_type'];
  if (raw is! String) throw const ApiFailure(FailureKind.invalidResponse);
  return switch (raw.toLowerCase()) {
      'issue' => ProjectWorkItemType.issue,
      'task' => ProjectWorkItemType.task,
      'incident' => ProjectWorkItemType.incident,
      _ => throw const ApiFailure(FailureKind.invalidResponse),
    };
}

void validateWorkItemIdentity(
  WorkItemJson value, {
  required ProjectWorkItemType expectedType,
  required int expectedProjectId,
}) {
  if (workItemTypeFromJson(value) != expectedType ||
      _int(value, 'iid') <= 0) {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  if (value['project_id'] is! int || value['project_id'] != expectedProjectId) {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

enum IncidentSeverity { unknown, low, medium, high, critical }

extension IncidentSeverityInfo on IncidentSeverity {
  String get apiValue => name;
  String get label => switch (this) {
    IncidentSeverity.unknown => l10n.severityUnclassified,
    IncidentSeverity.low => l10n.severityLow,
    IncidentSeverity.medium => l10n.severityMedium,
    IncidentSeverity.high => l10n.severityHigh,
    IncidentSeverity.critical => l10n.severityCritical,
  };
}

IncidentSeverity? incidentSeverityFromJson(WorkItemJson value) {
  final raw = _text(value, 'severity').toLowerCase();
  for (final severity in IncidentSeverity.values) {
    if (severity.apiValue == raw) return severity;
  }
  return null;
}

enum IncidentLifecycle { triggered, acknowledged, resolved, ignored }

extension IncidentLifecycleInfo on IncidentLifecycle {
  String get apiValue => name.toUpperCase();
  String get label => switch (this) {
    IncidentLifecycle.triggered => l10n.incidentTriggered,
    IncidentLifecycle.acknowledged => l10n.incidentAcknowledged,
    IncidentLifecycle.resolved => l10n.resolvedLabel,
    IncidentLifecycle.ignored => l10n.incidentIgnored,
  };

  bool get canSet => this != IncidentLifecycle.ignored;
}

final class IncidentStatusSnapshot {
  const IncidentStatusSnapshot({
    required this.projectId,
    required this.iid,
    required this.issueState,
    required this.severity,
    required this.lifecycle,
    required this.updatedAt,
  });

  factory IncidentStatusSnapshot.fromJson(
    WorkItemJson value, {
    required int expectedProjectId,
    required int expectedIid,
  }) {
    final projectId = _int(value, 'projectId');
    final iid = int.tryParse(_text(value, 'iid')) ?? _int(value, 'iid');
    final issueState = _text(value, 'state').toLowerCase();
    final severity = _text(value, 'severity').toUpperCase();
    final lifecycleRaw = _text(value, 'escalationStatus').toUpperCase();
    final updatedAt = _text(value, 'updatedAt');
    if (projectId != expectedProjectId ||
        iid != expectedIid ||
        !const {'opened', 'closed', 'locked'}.contains(issueState) ||
        (severity.isNotEmpty &&
            !const {
              'UNKNOWN',
              'LOW',
              'MEDIUM',
              'HIGH',
              'CRITICAL',
            }.contains(severity)) ||
        updatedAt.isEmpty) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    final lifecycle = IncidentLifecycle.values
        .cast<IncidentLifecycle?>()
        .firstWhere(
          (status) => status?.apiValue == lifecycleRaw,
          orElse: () => null,
        );
    if (lifecycle == null) throw const ApiFailure(FailureKind.unsupported);
    return IncidentStatusSnapshot(
      projectId: projectId,
      iid: iid,
      issueState: issueState,
      severity: severity.isEmpty ? null : severity,
      lifecycle: lifecycle,
      updatedAt: updatedAt,
    );
  }

  final int projectId;
  final int iid;
  final String issueState;
  final String? severity;
  final IncidentLifecycle lifecycle;
  final String updatedAt;
}
