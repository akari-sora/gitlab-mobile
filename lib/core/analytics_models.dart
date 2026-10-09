/// A repository contributor summary deliberately contains no email or account
/// identity. GitLab's contributors endpoint describes authored commits rather
/// than GitLab users, so equal display names remain separate rows.
final class ContributorSummary {
  const ContributorSummary({
    required this.displayName,
    required this.commits,
    required this.additions,
    required this.deletions,
  });

  final String displayName;
  final int commits;
  final int additions;
  final int deletions;
}

/// The small, non-content subset required to aggregate repository activity.
final class RepositoryActivityCommit {
  const RepositoryActivityCommit({
    required this.id,
    required this.committedAt,
    required this.parentCount,
    required this.additions,
    required this.deletions,
  });

  final String id;
  final DateTime committedAt;
  final int parentCount;
  final int? additions;
  final int? deletions;
}

enum AnalyticsPeriod {
  day('DAY'),
  week('WEEK'),
  month('MONTH');

  const AnalyticsPeriod(this.graphQLValue);
  final String graphQLValue;
}

enum AnalyticsPipelineSource {
  any(null),
  unknown('UNKNOWN'),
  push('PUSH'),
  web('WEB'),
  trigger('TRIGGER'),
  schedule('SCHEDULE'),
  api('API'),
  external('EXTERNAL'),
  pipeline('PIPELINE'),
  chat('CHAT'),
  webIde('WEBIDE'),
  mergeRequestEvent('MERGE_REQUEST_EVENT'),
  externalPullRequestEvent('EXTERNAL_PULL_REQUEST_EVENT'),
  parentPipeline('PARENT_PIPELINE'),
  onDemandDastScan('ONDEMAND_DAST_SCAN'),
  onDemandDastValidation('ONDEMAND_DAST_VALIDATION'),
  securityOrchestrationPolicy('SECURITY_ORCHESTRATION_POLICY'),
  containerRegistryPush('CONTAINER_REGISTRY_PUSH'),
  duoWorkflow('DUO_WORKFLOW'),
  pipelineExecutionPolicySchedule('PIPELINE_EXECUTION_POLICY_SCHEDULE'),
  dependencyManagementSecurityUpdate('DEPENDENCY_MANAGEMENT_SECURITY_UPDATE');

  const AnalyticsPipelineSource(this.graphQLValue);
  final String? graphQLValue;
}

final class PipelineAnalyticsBucket {
  const PipelineAnalyticsBucket({
    required this.label,
    required this.total,
    required this.successful,
    required this.failed,
    required this.other,
    required this.p50Seconds,
    required this.p95Seconds,
  });

  final DateTime? label;
  final BigInt? total;
  final BigInt? successful;
  final BigInt? failed;
  final BigInt? other;
  final double? p50Seconds;
  final double? p95Seconds;
}

final class PipelineAnalyticsSnapshot {
  PipelineAnalyticsSnapshot({
    required Iterable<PipelineAnalyticsBucket> buckets,
    required this.aggregate,
  }) : buckets = List.unmodifiable(buckets);

  final List<PipelineAnalyticsBucket> buckets;
  final PipelineAnalyticsBucket? aggregate;
}

final class CoverageSummary {
  const CoverageSummary({
    required this.averageCoverage,
    required this.coverageCount,
    required this.lastUpdatedOn,
  });

  final double? averageCoverage;
  final BigInt? coverageCount;
  final DateTime? lastUpdatedOn;
}
