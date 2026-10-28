import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';

/// Host-only candidate selection, never imported by app entrypoints. Candidate
/// evidence is not production release evidence. No environment/QA override.
AiReleasePolicyView mr7CandidateReleasePolicy({
  required Set<String> readNames,
  required Map<String, Set<AiTargetKind>> writeTargets,
}) => _CandidateReleasePolicy(readNames, writeTargets);

final class _CandidateReleasePolicy implements AiReleasePolicyView {
  _CandidateReleasePolicy(
    Set<String> reads,
    Map<String, Set<AiTargetKind>> writes,
  ) : readNames = Set.unmodifiable(reads),
      writeTargets = Map.unmodifiable({
        for (final entry in writes.entries)
          entry.key: Set<AiTargetKind>.unmodifiable(entry.value),
      });

  @override
  final Set<String> readNames;

  @override
  final Map<String, Set<AiTargetKind>> writeTargets;
}
