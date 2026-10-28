import 'dart:convert';

import 'target_binding.dart' show AiTargetKind;
import 'tool_catalogue.dart' show aiReleasedReadNames;
import 'write_ledger.dart' show aiReleasedWriteTargets;

/// The release boundary shared by catalogue, disclosure and write dispatch.
/// Tests and the host sandbox may inject an explicit fixture view; app wiring
/// uses only [productionAiReleasePolicy].
abstract interface class AiReleasePolicyView {
  Set<String> get readNames;
  Map<String, Set<AiTargetKind>> get writeTargets;
}

extension AiReleasePolicyChecks on AiReleasePolicyView {
  /// Stable snapshot for consent; map and set insertion order is irrelevant.
  String get canonicalIdentity {
    final reads = readNames.toList()..sort();
    final operations = writeTargets.keys.toList()..sort();
    return jsonEncode({
      'readNames': reads,
      'writeTargets': {
        for (final operation in operations)
          operation: writeTargets[operation]!.map((kind) => kind.name).toList()
            ..sort(),
      },
    });
  }

  bool allowsRead(String name) => readNames.contains(name);

  bool allowsWriteOperation(String operationId) =>
      writeTargets[operationId]?.isNotEmpty ?? false;

  bool allowsWrite(String operationId, AiTargetKind target) =>
      writeTargets[operationId]?.contains(target) ?? false;
}

/// Stateless: the immutable allowlists remain in their owning catalogues.
const AiReleasePolicyView productionAiReleasePolicy =
    _ProductionReleasePolicy();

final class _ProductionReleasePolicy implements AiReleasePolicyView {
  const _ProductionReleasePolicy();

  @override
  Set<String> get readNames => aiReleasedReadNames;

  @override
  Map<String, Set<AiTargetKind>> get writeTargets => aiReleasedWriteTargets;
}
