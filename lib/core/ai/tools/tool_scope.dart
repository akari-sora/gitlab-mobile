enum AiResourceKind { job, mergeRequest, issue, file }

final class AiResourceRef {
  const AiResourceRef({required this.kind, required this.id, this.path});

  final AiResourceKind kind;
  final int id;
  final String? path;
}

final class AiResourceScope {
  const AiResourceScope({
    required this.accountKey,
    required this.instanceKey,
    required this.projectId,
    required this.projectPath,
    required this.current,
    this.headSha,
    this.baseSha,
    this.pipelineId,
    this.jobId,
    this.defaultBranch,
  });

  final String accountKey;
  final String instanceKey;
  final int projectId;
  final String projectPath;
  final AiResourceRef current;
  final String? headSha;
  final String? baseSha;
  final int? pipelineId;
  final int? jobId;
  final String? defaultBranch;
}

enum AiProvenanceFreshness { pinnedHead, pinnedBase, live }

final class AiToolProvenance {
  const AiToolProvenance({
    required this.resource,
    required this.freshness,
    this.revision,
    this.observedAt,
  });

  final String resource;
  final AiProvenanceFreshness freshness;
  final String? revision;
  final DateTime? observedAt;

  String get label {
    final suffix = switch (freshness) {
      AiProvenanceFreshness.pinnedHead =>
        '${_shortSha(revision)} (pinned head)',
      AiProvenanceFreshness.pinnedBase =>
        '${_shortSha(revision)} (pinned base)',
      AiProvenanceFreshness.live =>
        'live, ${observedAt!.toUtc().toIso8601String()}',
    };
    return '[source: $resource @ $suffix]';
  }
}

String _shortSha(String? value) {
  if (value == null) return 'unavailable';
  return value.length <= 12 ? value : value.substring(0, 12);
}
