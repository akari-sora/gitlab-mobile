import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

/// Explicit synthetic coverage of the pre-release catalogue. This view is
/// confined to tests and grants only operation IDs that already have rows.
final AiReleasePolicyView fixtureReleasePolicy = _FixtureReleasePolicy();
final ProductionAiLedger fixtureAiLedger = ProductionAiLedger(
  releasePolicy: fixtureReleasePolicy,
);

final class _FixtureReleasePolicy implements AiReleasePolicyView {
  @override
  final Set<String> readNames = const {
    'read_file',
    'list_directory',
    'get_issue',
    'get_merge_request',
    'get_merge_request_diff',
    'get_pipeline_jobs',
    'get_job_log',
    'get_commit',
    'get_commit_diff',
    'search_project',
    'get_release',
    'get_milestone',
    'get_snippet',
    'get_group_work_item',
  };

  @override
  final Map<String, Set<AiTargetKind>> writeTargets = Map.unmodifiable({
    for (final row in ProductionAiLedger.rows)
      row.operationId: Set<AiTargetKind>.unmodifiable(AiTargetKind.values),
  });
}
