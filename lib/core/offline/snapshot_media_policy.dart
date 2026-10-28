import 'snapshot_schema.dart';

/// A resolved repository coordinate; callers must not map uploads or external
/// URLs into this type. No policy decision initiates a network request.
final class SnapshotMediaCoordinate {
  const SnapshotMediaCoordinate({
    required this.accountKey,
    required this.instanceKey,
    required this.projectId,
    required this.projectPath,
    required this.ref,
    required this.path,
    required this.relative,
  });
  final String accountKey, instanceKey, projectPath, ref, path;
  final int? projectId;
  final bool relative;
}

final class SnapshotMediaPolicy {
  const SnapshotMediaPolicy({
    required this.accountKey,
    required this.instanceKey,
    required this.projectId,
    required this.projectPath,
    required this.sha,
    required this.refName,
    required this.subPath,
  });
  final String accountKey, instanceKey, projectPath, sha, refName, subPath;
  final int projectId;

  bool permits(SnapshotMediaCoordinate source, SnapshotTreeEntry? entry) {
    if (source.accountKey != accountKey ||
        source.instanceKey != instanceKey ||
        !validSnapshotPath(source.path) ||
        entry == null ||
        entry.path != source.path ||
        (subPath.isNotEmpty && !source.path.startsWith('$subPath/'))) {
      return false;
    }
    if (source.relative) {
      if (source.projectId != projectId || source.ref != sha) return false;
    } else {
      if (source.projectPath != projectPath ||
          (source.ref != refName && source.ref != sha)) {
        return false;
      }
    }
    if (entry.type != SnapshotEntryType.blob ||
        entry.state != SnapshotEntryState.saved) {
      return false;
    }
    return entry.kind == SnapshotContentKind.image ||
        (entry.kind == SnapshotContentKind.text &&
            source.path.toLowerCase().endsWith('.svg'));
  }
}
